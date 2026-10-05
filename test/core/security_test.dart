import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanbeam/core/models/device_info.dart';
import 'package:lanbeam/core/models/trusted_device.dart';
import 'package:lanbeam/core/protocol/protocol.dart';
import 'package:lanbeam/core/security/auth_service.dart';
import 'package:lanbeam/core/security/crypto_utils.dart';
import 'package:lanbeam/core/security/device_identity.dart';
import 'package:lanbeam/core/security/pairing_service.dart';
import 'package:lanbeam/core/storage/json_store.dart';
import 'package:lanbeam/core/storage/stores.dart';
import 'package:path/path.dart' as p;

DeviceInfo device(String id, {String fp = ''}) => DeviceInfo(
  id: id,
  name: 'Device $id',
  deviceType: DeviceType.phone,
  os: DeviceOs.android,
  port: 1234,
  fingerprint: fp.isEmpty ? 'a' * 64 : fp,
);

void main() {
  late Directory tmp;
  late TrustedDeviceStore store;
  late DateTime now;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sec');
    store = TrustedDeviceStore(JsonFileStore(p.join(tmp.path, 't.json')));
    now = DateTime(2026, 1, 1, 12);
  });
  tearDown(() => tmp.delete(recursive: true));

  group('DeviceIdentity', () {
    test('generates a usable certificate and persists it', () async {
      final a = await DeviceIdentity.loadOrCreate(tmp.path);
      final b = await DeviceIdentity.loadOrCreate(tmp.path);
      expect(a.deviceId, b.deviceId);
      expect(a.fingerprint, b.fingerprint);
      expect(a.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      a.serverContext(); // loads into BoringSSL without throwing
    });
  });

  group('QR pairing', () {
    PairingService service() => PairingService(
      localFingerprint: 'b' * 64,
      trustedDevices: store,
      onPaired: (_) {},
      clock: () => now,
    );

    test('payload round-trips through the URI', () {
      const payload = QrPairingPayload(
        deviceId: 'dev-1',
        name: "John's PC",
        addresses: ['192.168.1.20', '10.0.0.5'],
        port: 45872,
        fingerprint: 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12',
        token: 'tokentokentokentoken',
      );
      final parsed = QrPairingPayload.parse(payload.toUri());
      expect(parsed.name, "John's PC");
      expect(parsed.addresses, ['192.168.1.20', '10.0.0.5']);
      expect(parsed.port, 45872);
      expect(parsed.token, payload.token);
      expect(() => QrPairingPayload.parse('https://evil.example'), throwsFormatException);
    });

    test('valid token + approval pairs and stores a secret', () async {
      final s = service()..requireApprovalForQr = true;
      s.prompts.listen((p) {
        if (p is PairingApprovalPrompt) p.respond(true);
      });
      final t = s.createQrToken(const Duration(minutes: 5));
      final trusted = await s.handlePairRequest(method: 'qr', device: device('x'), remote: '1.2.3.4', token: t.token);
      expect(trusted.secret.length, 32);
      expect(store.isTrusted('x'), isTrue);
    });

    test('token is single use', () async {
      final s = service()..requireApprovalForQr = false;
      final t = s.createQrToken(const Duration(minutes: 5));
      await s.handlePairRequest(method: 'qr', device: device('x'), remote: 'r', token: t.token);
      expect(
        () => s.handlePairRequest(method: 'qr', device: device('y'), remote: 'r', token: t.token),
        throwsA(isA<PairingFailure>()),
      );
    });

    test('expired token is rejected', () async {
      final s = service()..requireApprovalForQr = false;
      final t = s.createQrToken(const Duration(minutes: 5));
      now = now.add(const Duration(minutes: 6));
      await expectLater(
        s.handlePairRequest(method: 'qr', device: device('x'), remote: 'r', token: t.token),
        throwsA(isA<PairingFailure>().having((e) => e.code, 'code', ErrorCodes.unauthorized)),
      );
      expect(store.isTrusted('x'), isFalse);
    });

    test('user rejection does not pair', () async {
      final s = service()..requireApprovalForQr = true;
      s.prompts.listen((p) {
        if (p is PairingApprovalPrompt) p.respond(false);
      });
      final t = s.createQrToken(const Duration(minutes: 5));
      await expectLater(
        s.handlePairRequest(method: 'qr', device: device('x'), remote: 'r', token: t.token),
        throwsA(isA<PairingFailure>().having((e) => e.code, 'code', ErrorCodes.rejected)),
      );
      expect(store.isTrusted('x'), isFalse);
    });

    test('wrong token is rejected and rate limited', () async {
      final s = service()..requireApprovalForQr = false;
      s.createQrToken(const Duration(minutes: 5));
      for (var i = 0; i < 8; i++) {
        await expectLater(
          s.handlePairRequest(method: 'qr', device: device('x'), remote: 'r', token: 'wrong-token-$i'),
          throwsA(isA<PairingFailure>()),
        );
      }
      await expectLater(
        s.handlePairRequest(method: 'qr', device: device('x'), remote: 'r', token: 'whatever'),
        throwsA(isA<PairingFailure>().having((e) => e.code, 'code', ErrorCodes.rateLimited)),
      );
    });
  });

  group('PIN pairing', () {
    test('correct PIN with matching fingerprints pairs', () async {
      String? pin;
      final s = PairingService(localFingerprint: 'b' * 64, trustedDevices: store, onPaired: (_) {});
      s.prompts.listen((p) {
        if (p is PairingPinPrompt) pin = p.pin;
      });
      final dev = device('phone', fp: 'c' * 64);
      final r = s.startPinSession(dev, 'r');
      await Future<void>.delayed(Duration.zero);
      final proof = AuthProofs.pin(pin!, r.nonce, dev.id, dev.fingerprint, 'b' * 64);
      await s.handlePairRequest(method: 'pin', device: dev, remote: 'r', nonce: r.nonce, proof: proof);
      expect(store.isTrusted('phone'), isTrue);
      s.dispose();
    });

    test('proof computed against a MITM fingerprint fails', () async {
      String? pin;
      final s = PairingService(localFingerprint: 'b' * 64, trustedDevices: store, onPaired: (_) {});
      s.prompts.listen((p) {
        if (p is PairingPinPrompt) pin = p.pin;
      });
      final dev = device('phone', fp: 'c' * 64);
      final r = s.startPinSession(dev, 'r');
      await Future<void>.delayed(Duration.zero);
      final proof = AuthProofs.pin(pin!, r.nonce, dev.id, dev.fingerprint, 'e' * 64);
      await expectLater(
        s.handlePairRequest(method: 'pin', device: dev, remote: 'r', nonce: r.nonce, proof: proof),
        throwsA(isA<PairingFailure>()),
      );
      s.dispose();
    });

    test('session is destroyed after too many wrong PINs', () async {
      String? pin;
      final s = PairingService(localFingerprint: 'b' * 64, trustedDevices: store, onPaired: (_) {});
      s.prompts.listen((p) {
        if (p is PairingPinPrompt) pin = p.pin;
      });
      final dev = device('phone');
      final r = s.startPinSession(dev, 'r');
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < Protocol.pinMaxAttempts; i++) {
        final wrong = ((int.parse(pin!) + 1 + i) % 1000000).toString().padLeft(6, '0');
        await expectLater(
          s.handlePairRequest(method: 'pin', device: dev, remote: 'r$i', nonce: r.nonce,
              proof: AuthProofs.pin(wrong, r.nonce, dev.id, dev.fingerprint, 'b' * 64)),
          throwsA(isA<PairingFailure>()),
        );
      }
      // Even the right PIN no longer works.
      await expectLater(
        s.handlePairRequest(method: 'pin', device: dev, remote: 'rx', nonce: r.nonce,
            proof: AuthProofs.pin(pin!, r.nonce, dev.id, dev.fingerprint, 'b' * 64)),
        throwsA(isA<PairingFailure>()),
      );
      s.dispose();
    });

    test('another device cannot hijack an active PIN session', () {
      final s = PairingService(localFingerprint: 'b' * 64, trustedDevices: store, onPaired: (_) {});
      s.startPinSession(device('one'), 'r1');
      expect(() => s.startPinSession(device('two'), 'r2'), throwsA(isA<PairingFailure>()));
      s.dispose();
    });
  });

  group('AuthenticationService', () {
    late AuthenticationService auth;
    final secret = randomBytes(32);

    setUp(() async {
      await store.put(TrustedDevice(info: device('phone'), secret: secret, pairedAt: now));
      auth = AuthenticationService(localDeviceId: 'pc', trustedDevices: store, clock: () => now);
    });

    test('valid proof yields a token and a verifiable server proof', () {
      final nonce = auth.issueChallenge('phone', 'r');
      final grant = auth.createSession(
        deviceId: 'phone', nonce: nonce, remote: 'r',
        proof: AuthProofs.client(secret, nonce, 'phone', 'pc'),
      );
      expect(auth.validate(grant.token), 'phone');
      expect(grant.serverProof, AuthProofs.server(secret, nonce, 'phone', 'pc'));
    });

    test('nonce cannot be replayed', () {
      final nonce = auth.issueChallenge('phone', 'r');
      final proof = AuthProofs.client(secret, nonce, 'phone', 'pc');
      auth.createSession(deviceId: 'phone', nonce: nonce, proof: proof, remote: 'r');
      expect(
        () => auth.createSession(deviceId: 'phone', nonce: nonce, proof: proof, remote: 'r'),
        throwsA(isA<AuthFailure>()),
      );
    });

    test('wrong secret, unknown device and expired nonce are rejected', () {
      var nonce = auth.issueChallenge('phone', 'r');
      expect(
        () => auth.createSession(deviceId: 'phone', nonce: nonce, remote: 'r',
            proof: AuthProofs.client(randomBytes(32), nonce, 'phone', 'pc')),
        throwsA(isA<AuthFailure>()),
      );
      nonce = auth.issueChallenge('stranger', 'r');
      expect(
        () => auth.createSession(deviceId: 'stranger', nonce: nonce, remote: 'r',
            proof: AuthProofs.client(secret, nonce, 'stranger', 'pc')),
        throwsA(isA<AuthFailure>()),
      );
      nonce = auth.issueChallenge('phone', 'r');
      now = now.add(const Duration(minutes: 1));
      expect(
        () => auth.createSession(deviceId: 'phone', nonce: nonce, remote: 'r',
            proof: AuthProofs.client(secret, nonce, 'phone', 'pc')),
        throwsA(isA<AuthFailure>()),
      );
    });

    test('tokens expire and die with the pairing', () async {
      final nonce = auth.issueChallenge('phone', 'r');
      final grant = auth.createSession(deviceId: 'phone', nonce: nonce, remote: 'r',
          proof: AuthProofs.client(secret, nonce, 'phone', 'pc'));
      expect(auth.validate(grant.token), 'phone');
      await store.remove('phone');
      expect(auth.validate(grant.token), isNull);
    });

    test('token expiry', () {
      final nonce = auth.issueChallenge('phone', 'r');
      final grant = auth.createSession(deviceId: 'phone', nonce: nonce, remote: 'r',
          proof: AuthProofs.client(secret, nonce, 'phone', 'pc'));
      now = now.add(Protocol.sessionTokenTtl + const Duration(seconds: 1));
      expect(auth.validate(grant.token), isNull);
    });
  });

  test('constantTimeEquals', () {
    expect(constantTimeEquals('abc', 'abc'), isTrue);
    expect(constantTimeEquals('abc', 'abd'), isFalse);
    expect(constantTimeEquals('abc', 'abcd'), isFalse);
    expect(randomPin(), matches(RegExp(r'^\d{6}$')));
  });
}
