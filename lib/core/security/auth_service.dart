import 'dart:convert';

import '../protocol/protocol.dart';
import '../storage/stores.dart';
import 'crypto_utils.dart';

/// Proof strings for the challenge/response handshake (see PROTOCOL.md §2.3).
abstract final class AuthProofs {
  static String client(
    List<int> secret,
    String nonce,
    String clientId,
    String serverId,
  ) => hmacHex(secret, 'lanbeam-auth-v1|client|$nonce|$clientId|$serverId');

  static String server(
    List<int> secret,
    String nonce,
    String clientId,
    String serverId,
  ) => hmacHex(secret, 'lanbeam-auth-v1|server|$nonce|$clientId|$serverId');

  static String pin(
    String pin,
    String nonce,
    String clientId,
    String clientFp,
    String serverFp,
  ) => hmacHex(
    utf8.encode(pin),
    'lanbeam-pin-v1|$nonce|$clientId|$clientFp|$serverFp',
  );
}

class AuthFailure implements Exception {
  const AuthFailure(this.code);
  final String code;
  @override
  String toString() => 'AuthFailure($code)';
}

class SessionGrant {
  const SessionGrant(this.token, this.expiresIn, this.serverProof);
  final String token;
  final Duration expiresIn;
  final String serverProof;
}

/// Sliding-window failure counter keyed by remote address.
class RateLimiter {
  RateLimiter({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 1),
    this.lockout = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxFailures;
  final Duration window;
  final Duration lockout;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};

  bool isLocked(String key) {
    final until = _lockedUntil[key];
    if (until == null) return false;
    if (_clock().isAfter(until)) {
      _lockedUntil.remove(key);
      _failures.remove(key);
      return false;
    }
    return true;
  }

  void recordFailure(String key) {
    final now = _clock();
    final list = _failures.putIfAbsent(key, () => [])
      ..add(now)
      ..removeWhere((t) => now.difference(t) > window);
    if (list.length >= maxFailures) _lockedUntil[key] = now.add(lockout);
    if (_failures.length > 4096) _failures.remove(_failures.keys.first);
  }

  void recordSuccess(String key) => _failures.remove(key);
}

/// Server-side authentication of paired devices.
class AuthenticationService {
  AuthenticationService({
    required this.localDeviceId,
    required this.trustedDevices,
    DateTime Function()? clock,
    RateLimiter? rateLimiter,
  }) : _clock = clock ?? DateTime.now,
       rateLimiter = rateLimiter ?? RateLimiter();

  final String localDeviceId;
  final TrustedDeviceStore trustedDevices;
  final DateTime Function() _clock;
  final RateLimiter rateLimiter;

  final Map<String, ({String deviceId, DateTime expires})> _nonces = {};
  final Map<String, ({String deviceId, DateTime expires})> _sessions = {};

  void _purge() {
    final now = _clock();
    _nonces.removeWhere((_, v) => now.isAfter(v.expires));
    _sessions.removeWhere((_, v) => now.isAfter(v.expires));
  }

  /// Issues a single-use nonce. Always succeeds (even for unknown devices) so
  /// the endpoint cannot be used to enumerate paired devices.
  String issueChallenge(String deviceId, String remote) {
    if (rateLimiter.isLocked(remote)) {
      throw const AuthFailure(ErrorCodes.rateLimited);
    }
    _purge();
    if (_nonces.length > 1024) {
      throw const AuthFailure(ErrorCodes.rateLimited);
    }
    final nonce = randomToken(24);
    _nonces[nonce] = (
      deviceId: deviceId,
      expires: _clock().add(Protocol.authNonceTtl),
    );
    return nonce;
  }

  SessionGrant createSession({
    required String deviceId,
    required String nonce,
    required String proof,
    required String remote,
  }) {
    if (rateLimiter.isLocked(remote)) {
      throw const AuthFailure(ErrorCodes.rateLimited);
    }
    _purge();
    final entry = _nonces.remove(nonce); // single use, even on failure
    final device = trustedDevices.get(deviceId);
    if (entry == null || entry.deviceId != deviceId || device == null) {
      rateLimiter.recordFailure(remote);
      throw const AuthFailure(ErrorCodes.unauthorized);
    }
    final expected = AuthProofs.client(
      device.secret,
      nonce,
      deviceId,
      localDeviceId,
    );
    if (!constantTimeEquals(expected, proof)) {
      rateLimiter.recordFailure(remote);
      throw const AuthFailure(ErrorCodes.unauthorized);
    }
    rateLimiter.recordSuccess(remote);
    final token = randomToken(32);
    _sessions[token] = (
      deviceId: deviceId,
      expires: _clock().add(Protocol.sessionTokenTtl),
    );
    return SessionGrant(
      token,
      Protocol.sessionTokenTtl,
      AuthProofs.server(device.secret, nonce, deviceId, localDeviceId),
    );
  }

  /// Returns the authenticated device id for a bearer token, or null.
  String? validate(String? token) {
    if (token == null) return null;
    final s = _sessions[token];
    if (s == null) return null;
    if (_clock().isAfter(s.expires)) {
      _sessions.remove(token);
      return null;
    }
    // The device may have been unpaired since the token was issued.
    if (!trustedDevices.isTrusted(s.deviceId)) {
      _sessions.remove(token);
      return null;
    }
    return s.deviceId;
  }

  void revokeDevice(String deviceId) =>
      _sessions.removeWhere((_, v) => v.deviceId == deviceId);
}
