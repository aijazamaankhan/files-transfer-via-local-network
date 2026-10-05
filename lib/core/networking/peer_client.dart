import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/device_info.dart';
import '../models/transfer_models.dart';
import '../protocol/protocol.dart';
import '../security/auth_service.dart';
import '../security/crypto_utils.dart';
import '../util/errors.dart';

/// Non-2xx response from a peer.
class PeerApiException implements Exception {
  PeerApiException(this.status, this.code, this.message, this.body);
  final int status;
  final String code;
  final String? message;
  final Map<String, Object?> body;

  LanBeamException toLanBeam() => LanBeamException(switch (code) {
    ErrorCodes.unauthorized => FailureKind.unauthorized,
    ErrorCodes.forbidden => FailureKind.unauthorized,
    ErrorCodes.rejected => FailureKind.rejected,
    ErrorCodes.gone => FailureKind.cancelled,
    ErrorCodes.diskFull => FailureKind.diskFull,
    ErrorCodes.checksumMismatch => FailureKind.checksumMismatch,
    ErrorCodes.rateLimited => FailureKind.rateLimited,
    ErrorCodes.timeout => FailureKind.timeout,
    _ => FailureKind.protocol,
  }, '$status $code ${message ?? ''}');

  @override
  String toString() => 'PeerApiException($status, $code, $message)';
}

/// Response to a pairing request.
class PairingResult {
  const PairingResult(this.device, this.secret);
  final DeviceInfo device;
  final Uint8List secret;
}

/// An in-flight upload that can be aborted (pause/cancel).
class UploadHandle {
  UploadHandle._(this.done, this._abort);
  final Future<int> done;
  final void Function() _abort;
  void abort() => _abort();
}

/// HTTPS client for talking to one peer, with certificate pinning.
///
/// Every connection verifies that the server certificate's SHA-256
/// fingerprint equals [expectedFingerprint]. There is no fallback to system
/// trust: a mismatch fails the TLS handshake.
class PeerClient {
  PeerClient({
    required this.hosts,
    required this.port,
    required this.expectedFingerprint,
    required this.localInfo,
    this.secret,
    this.connectTimeout = const Duration(seconds: 4),
  }) {
    _http = _createHttpClient();
  }

  /// Candidate addresses, tried in order; the first that works is preferred.
  List<String> hosts;
  int port;
  final String expectedFingerprint;
  final DeviceInfo Function() localInfo;

  /// Shared pairing secret (null before pairing).
  Uint8List? secret;
  final Duration connectTimeout;

  late HttpClient _http;
  String? _activeHost;
  String? _token;
  DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _authInFlight;

  String? get activeHost => _activeHost;

  /// Current session token. Exposed for protocol tests only.
  String? get debugToken => _token;

  HttpClient _createHttpClient() {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 6
      ..autoUncompress = false
      ..userAgent = 'LanBeam/${Protocol.appVersion}';
    client.badCertificateCallback = (cert, host, port) =>
        sha256.convert(cert.der).toString() == expectedFingerprint;
    return client;
  }

  /// Fetches `/info` from [host]:[port] without a pinned fingerprint and
  /// returns it with the fingerprint actually presented by TLS. Used for
  /// direct-IP connections before pairing; callers must verify the result.
  static Future<(DeviceInfo, String)> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    String? seen;
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = timeout;
    client.badCertificateCallback = (cert, h, p) {
      seen = sha256.convert(cert.der).toString();
      return true;
    };
    try {
      final req = await client
          .getUrl(
            Uri(
              scheme: 'https',
              host: host,
              port: port,
              path: '${Protocol.apiBase}/info',
            ),
          )
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      final body = await utf8.decodeStream(res).timeout(timeout);
      if (res.statusCode != 200) {
        throw LanBeamException(FailureKind.protocol, 'info ${res.statusCode}');
      }
      final info = DeviceInfo.fromJson((jsonDecode(body) as Map).cast());
      if (seen == null || info.fingerprint != seen) {
        throw const LanBeamException(
          FailureKind.untrustedCertificate,
          'fingerprint mismatch',
        );
      }
      return (info, seen!);
    } on FormatException catch (e) {
      throw LanBeamException(FailureKind.protocol, e.message);
    } catch (e) {
      throw classifyError(e);
    } finally {
      client.close(force: true);
    }
  }

  Uri _uri(String host, String path, [Map<String, String>? query]) => Uri(
    scheme: 'https',
    host: host,
    port: port,
    path: '${Protocol.apiBase}$path',
    queryParameters: query,
  );

  /// Opens a request against the first reachable host.
  Future<HttpClientRequest> _open(
    String method,
    String path, [
    Map<String, String>? query,
  ]) async {
    final ordered = [?_activeHost, ...hosts.where((h) => h != _activeHost)];
    if (ordered.isEmpty) {
      throw const LanBeamException(FailureKind.deviceUnreachable, 'no address');
    }
    Object? lastError;
    for (final host in ordered) {
      try {
        final req = await _http
            .openUrl(method, _uri(host, path, query))
            .timeout(connectTimeout + const Duration(seconds: 1));
        _activeHost = host;
        return req;
      } catch (e) {
        lastError = e;
        if (e is HandshakeException) break; // wrong identity: don't try others
      }
    }
    if (_activeHost != null && !ordered.contains(_activeHost))
      _activeHost = null;
    throw classifyError(lastError!);
  }

  Future<Map<String, Object?>> _decode(HttpClientResponse res) async {
    final text = await utf8.decodeStream(res);
    if (text.isEmpty) return {};
    try {
      final v = jsonDecode(text);
      return v is Map ? v.cast() : {};
    } on FormatException {
      return {};
    }
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    Duration timeout = const Duration(seconds: 20),
    Set<int> accept = const {200},
    _StatusHolder? status,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (auth) await ensureAuthenticated();
      try {
        final req = await _open(method, path);
        if (auth)
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
        if (body != null) {
          final bytes = utf8.encode(jsonEncode(body));
          req.headers.contentType = ContentType.json;
          req.contentLength = bytes.length;
          req.add(bytes);
        }
        final res = await req.close().timeout(timeout);
        final json = await _decode(res).timeout(timeout);
        if (res.statusCode == 401 && auth && attempt == 0) {
          _token = null; // token expired or server restarted: re-authenticate
          continue;
        }
        if (!accept.contains(res.statusCode)) {
          throw PeerApiException(
            res.statusCode,
            (json['error'] as String?) ?? 'http_${res.statusCode}',
            json['message'] as String?,
            json,
          );
        }
        status?.value = res.statusCode;
        return json;
      } on PeerApiException {
        rethrow;
      } on LanBeamException {
        rethrow;
      } catch (e) {
        throw classifyError(e);
      }
    }
    throw const LanBeamException(FailureKind.unauthorized);
  }

  // ---------------------------------------------------------------------
  // Authentication

  Future<void> ensureAuthenticated() {
    if (_token != null && DateTime.now().isBefore(_tokenExpiry)) {
      return Future.value();
    }
    return _authInFlight ??= _authenticate().whenComplete(
      () => _authInFlight = null,
    );
  }

  Future<void> _authenticate() async {
    final s = secret;
    if (s == null)
      throw const LanBeamException(FailureKind.unauthorized, 'not paired');
    final me = localInfo();
    final challenge = await _json(
      'POST',
      '/auth/challenge',
      body: {'deviceId': me.id},
      auth: false,
    );
    final nonce = challenge['nonce'] as String;
    final serverId = await _serverId();
    try {
      final session = await _json(
        'POST',
        '/auth/session',
        auth: false,
        body: {
          'deviceId': me.id,
          'nonce': nonce,
          'proof': AuthProofs.client(s, nonce, me.id, serverId),
        },
      );
      final expected = AuthProofs.server(s, nonce, me.id, serverId);
      if (!constantTimeEquals(
        expected,
        session['serverProof'] as String? ?? '',
      )) {
        throw const LanBeamException(
          FailureKind.untrustedCertificate,
          'server proof',
        );
      }
      _token = session['token'] as String;
      final ttl = (session['expiresIn'] as int?) ?? 3600;
      _tokenExpiry = DateTime.now().add(Duration(seconds: ttl - 60));
    } on PeerApiException catch (e) {
      if (e.status == 401)
        throw const LanBeamException(FailureKind.unauthorized);
      throw e.toLanBeam();
    }
  }

  String? _serverIdCache;
  Future<String> _serverId() async => _serverIdCache ??= (await info()).id;

  /// Fetches the peer's public info (pinned connection).
  Future<DeviceInfo> info() async {
    final json = await _json(
      'GET',
      '/info',
      auth: false,
      timeout: const Duration(seconds: 8),
    );
    final i = DeviceInfo.fromJson(json);
    if (i.fingerprint != expectedFingerprint) {
      throw const LanBeamException(FailureKind.untrustedCertificate);
    }
    _serverIdCache = i.id;
    return i;
  }

  // ---------------------------------------------------------------------
  // Pairing

  Future<PairingResult> pairWithToken(String token) =>
      _pair({'method': 'qr', 'token': token});

  /// Asks the peer to display a PIN; returns the nonce for [pairWithPin].
  Future<String> requestPin() async {
    final json = await _json(
      'POST',
      '/pair/pin',
      auth: false,
      body: {'device': localInfo().toJson()},
    );
    return json['nonce'] as String;
  }

  Future<PairingResult> pairWithPin(String nonce, String pin) {
    final me = localInfo();
    return _pair({
      'method': 'pin',
      'nonce': nonce,
      'proof': AuthProofs.pin(
        pin,
        nonce,
        me.id,
        me.fingerprint,
        expectedFingerprint,
      ),
    });
  }

  Future<PairingResult> _pair(Map<String, Object?> body) async {
    try {
      final json = await _json(
        'POST',
        '/pair/request',
        auth: false,
        body: {...body, 'device': localInfo().toJson()},
        timeout: Protocol.pairingApprovalTimeout + const Duration(seconds: 10),
      );
      final device = DeviceInfo.fromJson((json['device'] as Map).cast());
      if (device.fingerprint != expectedFingerprint) {
        throw const LanBeamException(FailureKind.untrustedCertificate);
      }
      final s = base64.decode(json['secret'] as String);
      if (s.length != 32)
        throw const LanBeamException(FailureKind.protocol, 'secret');
      secret = s;
      return PairingResult(device, s);
    } on PeerApiException catch (e) {
      throw LanBeamException(switch (e.code) {
        ErrorCodes.rejected => FailureKind.rejected,
        ErrorCodes.rateLimited => FailureKind.rateLimited,
        ErrorCodes.unauthorized => FailureKind.pairingExpired,
        _ => FailureKind.pairingFailed,
      }, e.message);
    }
  }

  Future<void> revoke() async {
    await _json('POST', '/pair/revoke', body: const {});
  }

  // ---------------------------------------------------------------------
  // Transfers

  /// Sends the manifest. Returns (accepted?, body).
  Future<(bool, Map<String, Object?>)> offer(TransferManifest manifest) async {
    final holder = _StatusHolder();
    final json = await _json(
      'POST',
      '/transfers',
      body: manifest.toJson(),
      accept: const {200, 202},
      status: holder,
      timeout: const Duration(seconds: 60),
    );
    return (holder.value == 200, json);
  }

  Future<Map<String, Object?>> status(String transferId) =>
      _json('GET', '/transfers/$transferId');

  Future<Map<String, Object?>> command(String transferId, String command) =>
      _json('POST', '/transfers/$transferId/$command', body: const {});

  Future<Map<String, Object?>> complete(
    String transferId,
    String fileId,
    String digest,
  ) => _json(
    'POST',
    '/transfers/$transferId/files/$fileId/complete',
    body: {'digest': digest},
    timeout: const Duration(minutes: 2),
  );

  /// Opens the transfer event WebSocket.
  Future<WebSocket> events(String transferId) async {
    await ensureAuthenticated();
    final host = _activeHost ?? hosts.first;
    final url = Uri(
      scheme: 'wss',
      host: host,
      port: port,
      path: '${Protocol.apiBase}/transfers/$transferId/events',
    );
    try {
      final ws = await WebSocket.connect(
        url.toString(),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'},
        customClient: _http,
      ).timeout(const Duration(seconds: 10));
      ws.pingInterval = const Duration(seconds: 10);
      return ws;
    } catch (e) {
      throw classifyError(e);
    }
  }

  /// Streams [data] (bytes from [offset] to end) as the body of a PUT.
  Future<UploadHandle> upload(
    String transferId,
    String fileId,
    int offset,
    int length,
    Stream<List<int>> data,
  ) async {
    await ensureAuthenticated();
    final req = await _open('PUT', '/transfers/$transferId/files/$fileId', {
      'offset': '$offset',
    });
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    req.headers.contentType = ContentType.binary;
    req.contentLength = length;
    req.bufferOutput = false;
    var aborted = false;
    final done = () async {
      try {
        await req.addStream(data);
        final res = await req.close();
        final json = await _decode(res);
        if (res.statusCode != 200) {
          throw PeerApiException(
            res.statusCode,
            (json['error'] as String?) ?? 'http_${res.statusCode}',
            json['message'] as String?,
            json,
          );
        }
        return (json['received'] as int?) ?? offset + length;
      } on PeerApiException {
        rethrow;
      } catch (e) {
        if (aborted) throw const UploadAborted();
        // The server may have answered (e.g. 423 paused) and closed early.
        try {
          final res = await req.done.timeout(const Duration(seconds: 2));
          final json = await _decode(res);
          if (res.statusCode != 200) {
            throw PeerApiException(
              res.statusCode,
              (json['error'] as String?) ?? 'http_${res.statusCode}',
              json['message'] as String?,
              json,
            );
          }
        } on PeerApiException {
          rethrow;
        } catch (_) {}
        throw classifyError(e);
      }
    }();
    return UploadHandle._(done, () {
      aborted = true;
      req.abort(const UploadAborted());
    });
  }

  void close() => _http.close(force: true);
}

class UploadAborted implements Exception {
  const UploadAborted();
}

class _StatusHolder {
  int value = 0;
}
