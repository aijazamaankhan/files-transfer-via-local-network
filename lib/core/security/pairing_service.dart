import 'dart:async';

import '../models/device_info.dart';
import '../models/trusted_device.dart';
import '../protocol/protocol.dart';
import '../storage/stores.dart';
import 'auth_service.dart';
import 'crypto_utils.dart';

/// Contents of the pairing QR code (see PROTOCOL.md §2.2).
class QrPairingPayload {
  const QrPairingPayload({
    required this.deviceId,
    required this.name,
    required this.addresses,
    required this.port,
    required this.fingerprint,
    required this.token,
  });

  final String deviceId;
  final String name;
  final List<String> addresses;
  final int port;
  final String fingerprint;
  final String token;

  String toUri() => Uri(
    scheme: 'lanbeam',
    host: 'pair',
    queryParameters: {
      'v': '${Protocol.version}',
      'id': deviceId,
      'n': name,
      'a': addresses.join(','),
      'p': '$port',
      'fp': fingerprint,
      't': token,
    },
  ).toString();

  /// Parses a scanned QR string. Throws [FormatException] if invalid.
  factory QrPairingPayload.parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'lanbeam' || uri.host != 'pair') {
      throw const FormatException('Not a LanBeam pairing code');
    }
    final q = uri.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    final fp = q['fp'] ?? '';
    final addresses = (q['a'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (q['v'] != '${Protocol.version}') {
      throw const FormatException('Unsupported pairing code version');
    }
    if (port == null ||
        port <= 0 ||
        port > 65535 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp) ||
        addresses.isEmpty ||
        (q['t'] ?? '').length < 16 ||
        (q['id'] ?? '').isEmpty) {
      throw const FormatException('Incomplete pairing code');
    }
    return QrPairingPayload(
      deviceId: q['id']!,
      name: sanitizeDisplayName(q['n'] ?? 'Unknown device'),
      addresses: addresses,
      port: port,
      fingerprint: fp,
      token: q['t']!,
    );
  }
}

/// Prompts the UI must show during pairing.
sealed class PairingPrompt {
  const PairingPrompt(this.device);
  final DeviceInfo device;
}

/// A device that scanned our QR code asks to pair. Call [respond].
class PairingApprovalPrompt extends PairingPrompt {
  PairingApprovalPrompt(super.device, this.remoteAddress);
  final String remoteAddress;
  final Completer<bool> _decision = Completer();

  bool get isDecided => _decision.isCompleted;
  Future<bool> get decision => _decision.future;

  void respond(bool approve) {
    if (!_decision.isCompleted) _decision.complete(approve);
  }
}

/// A device asked to pair by PIN: display [pin] until [expiresAt].
class PairingPinPrompt extends PairingPrompt {
  const PairingPinPrompt(super.device, this.pin, this.expiresAt);
  final String pin;
  final DateTime expiresAt;
}

/// Pairing finished (successfully) — UI can close dialogs.
class PairingCompletedPrompt extends PairingPrompt {
  const PairingCompletedPrompt(super.device);
}

/// A PIN session ended without success (expired / too many attempts).
class PairingCancelledPrompt extends PairingPrompt {
  const PairingCancelledPrompt(super.device);
}

class PairingFailure implements Exception {
  const PairingFailure(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'PairingFailure($code, $message)';
}

class _QrSession {
  _QrSession(this.token, this.expires);
  final String token;
  final DateTime expires;
  bool consumed = false;
}

class _PinSession {
  _PinSession(this.pin, this.nonce, this.device, this.expires);
  final String pin;
  final String nonce;
  final DeviceInfo device;
  final DateTime expires;
  int attempts = 0;
}

/// Server-side pairing: QR tokens, PIN sessions and user approval.
class PairingService {
  PairingService({
    required this.localFingerprint,
    required this.trustedDevices,
    required this.onPaired,
    DateTime Function()? clock,
    RateLimiter? rateLimiter,
  }) : _clock = clock ?? DateTime.now,
       rateLimiter = rateLimiter ?? RateLimiter(maxFailures: 8);

  final String localFingerprint;
  final TrustedDeviceStore trustedDevices;

  /// Called after a device is stored as trusted.
  final void Function(TrustedDevice device) onPaired;

  final DateTime Function() _clock;
  final RateLimiter rateLimiter;
  final _prompts = StreamController<PairingPrompt>.broadcast();

  _QrSession? _qr;
  _PinSession? _pin;
  Timer? _pinExpiry;

  /// Whether approval is required for QR pairing (setting).
  bool requireApprovalForQr = true;

  Stream<PairingPrompt> get prompts => _prompts.stream;

  /// Creates a new QR token, invalidating the previous one.
  ({String token, DateTime expiresAt}) createQrToken(Duration ttl) {
    final token = randomToken(32);
    final expires = _clock().add(ttl);
    _qr = _QrSession(token, expires);
    return (token: token, expiresAt: expires);
  }

  void invalidateQrToken() => _qr = null;

  /// Starts a PIN session for [device]; the PIN is shown via [prompts].
  ({String nonce, Duration expiresIn}) startPinSession(
    DeviceInfo device,
    String remote,
  ) {
    if (rateLimiter.isLocked(remote)) {
      throw const PairingFailure(ErrorCodes.rateLimited);
    }
    final now = _clock();
    final active = _pin;
    if (active != null &&
        now.isBefore(active.expires) &&
        active.device.id != device.id) {
      // Someone else is mid-pairing; don't let a LAN user hijack the dialog.
      throw const PairingFailure(ErrorCodes.rateLimited, 'Pairing in progress');
    }
    final session = _PinSession(
      randomPin(),
      randomToken(24),
      device,
      now.add(Protocol.pinTtl),
    );
    _pin = session;
    _pinExpiry?.cancel();
    _pinExpiry = Timer(Protocol.pinTtl, () {
      if (identical(_pin, session)) {
        _pin = null;
        _prompts.add(PairingCancelledPrompt(device));
      }
    });
    _prompts.add(PairingPinPrompt(device, session.pin, session.expires));
    return (nonce: session.nonce, expiresIn: Protocol.pinTtl);
  }

  /// Cancels any visible PIN session (user closed the dialog).
  void cancelPinSession() {
    final s = _pin;
    _pin = null;
    _pinExpiry?.cancel();
    if (s != null) _prompts.add(PairingCancelledPrompt(s.device));
  }

  /// Handles `POST /pair/request`. Returns the new trusted device record.
  Future<TrustedDevice> handlePairRequest({
    required String method,
    required DeviceInfo device,
    required String remote,
    String? token,
    String? nonce,
    String? proof,
  }) async {
    if (rateLimiter.isLocked(remote)) {
      throw const PairingFailure(ErrorCodes.rateLimited);
    }
    switch (method) {
      case 'qr':
        final session = _qr;
        final valid =
            session != null &&
            token != null &&
            !session.consumed &&
            _clock().isBefore(session.expires) &&
            constantTimeEquals(session.token, token);
        if (!valid) {
          rateLimiter.recordFailure(remote);
          throw const PairingFailure(
            ErrorCodes.unauthorized,
            'Pairing code invalid or expired',
          );
        }
        session.consumed = true; // single use
        if (requireApprovalForQr) {
          final prompt = PairingApprovalPrompt(device, remote);
          _prompts.add(prompt);
          final approved = await prompt.decision.timeout(
            Protocol.pairingApprovalTimeout,
            onTimeout: () => false,
          );
          if (!approved) {
            throw const PairingFailure(ErrorCodes.rejected, 'Pairing declined');
          }
        }
      case 'pin':
        final session = _pin;
        if (session == null ||
            nonce == null ||
            proof == null ||
            !constantTimeEquals(session.nonce, nonce) ||
            session.device.id != device.id ||
            _clock().isAfter(session.expires)) {
          rateLimiter.recordFailure(remote);
          throw const PairingFailure(
            ErrorCodes.unauthorized,
            'Pairing session expired',
          );
        }
        final expected = AuthProofs.pin(
          session.pin,
          session.nonce,
          device.id,
          device.fingerprint,
          localFingerprint,
        );
        if (!constantTimeEquals(expected, proof)) {
          session.attempts++;
          rateLimiter.recordFailure(remote);
          if (session.attempts >= Protocol.pinMaxAttempts) cancelPinSession();
          throw const PairingFailure(ErrorCodes.forbidden, 'Incorrect PIN');
        }
        _pin = null;
        _pinExpiry?.cancel();
      default:
        throw const PairingFailure(ErrorCodes.badRequest, 'Unknown method');
    }
    rateLimiter.recordSuccess(remote);
    final trusted = TrustedDevice(
      info: device,
      secret: randomBytes(32),
      pairedAt: _clock(),
      lastAddresses: [remote],
    );
    await trustedDevices.put(trusted);
    onPaired(trusted);
    _prompts.add(PairingCompletedPrompt(device));
    return trusted;
  }

  void dispose() {
    _pinExpiry?.cancel();
    _prompts.close();
  }
}
