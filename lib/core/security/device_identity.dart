import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'crypto_utils.dart';

/// This device's long-term identity: a stable id plus a self-signed ECDSA
/// P-256 certificate. The certificate fingerprint is what peers pin.
class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.certificatePem,
    required this.privateKeyPem,
  }) : fingerprint = fingerprintOfPem(certificatePem);

  final String deviceId;
  final String certificatePem;
  final String privateKeyPem;

  /// SHA-256 over the DER certificate, lowercase hex.
  final String fingerprint;

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  static String fingerprintOfPem(String pem) {
    final body = pem
        .split(RegExp(r'\r?\n'))
        .where((l) => !l.startsWith('-----'))
        .join()
        .replaceAll(RegExp(r'\s'), '');
    return sha256Hex(base64.decode(body));
  }

  /// Generates a fresh identity. Key generation runs in a background isolate
  /// since it takes a noticeable amount of CPU on slow phones.
  static Future<DeviceIdentity> generate({String? deviceId}) async {
    final id = deviceId ?? const Uuid().v4();
    final (cert, key) = await Isolate.run(() => _generateCert(id));
    return DeviceIdentity(
      deviceId: id,
      certificatePem: cert,
      privateKeyPem: key,
    );
  }

  static (String, String) _generateCert(String id) {
    final pair = CryptoUtils.generateEcKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'LanBeam $id', 'O': 'LanBeam'},
      priv,
      pub,
    );
    final cert = X509Utils.generateSelfSignedCertificate(
      priv,
      csr,
      365 * 20,
      serialNumber: DateTime.now().millisecondsSinceEpoch.toString(),
      // Tolerate peers whose clocks are behind; dates are not used for trust.
      notBefore: DateTime.now().subtract(const Duration(days: 2)),
    );
    return (cert, CryptoUtils.encodeEcPrivateKeyToPem(priv));
  }

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'certificate': certificatePem,
    'privateKey': privateKeyPem,
  };

  factory DeviceIdentity.fromJson(Map<String, Object?> json) => DeviceIdentity(
    deviceId: json['deviceId'] as String,
    certificatePem: json['certificate'] as String,
    privateKeyPem: json['privateKey'] as String,
  );

  /// Loads the identity from [directory], creating it on first run.
  /// The file is written with owner-only permissions where supported.
  static Future<DeviceIdentity> loadOrCreate(String directory) async {
    final file = File(p.join(directory, 'identity.json'));
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map;
        final identity = DeviceIdentity.fromJson(json.cast());
        // Validate that the key material still loads.
        identity.serverContext();
        return identity;
      } catch (_) {
        // Corrupted identity: regenerate. Peers will need to re-pair, which
        // is the safe failure mode.
      }
    }
    final identity = await generate();
    await Directory(directory).create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(identity.toJson()), flush: true);
    await restrictPermissions(tmp.path);
    await tmp.rename(file.path);
    return identity;
  }
}

/// chmod 600 on POSIX desktop systems. On mobile the app sandbox already
/// isolates app data; on Windows the per-user profile ACLs apply.
Future<void> restrictPermissions(String path) async {
  if (Platform.isLinux || Platform.isMacOS) {
    try {
      await Process.run('chmod', ['600', path]);
    } catch (_) {}
  }
}
