import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/device_info.dart';
import '../protocol/protocol.dart';
import '../security/auth_service.dart';
import '../security/device_identity.dart';
import '../security/pairing_service.dart';
import '../transfer/transfer_receiver.dart';
import '../util/errors.dart';
import 'http_utils.dart';

/// The embedded HTTPS + WebSocket server every device runs.
///
/// Only `/info`, `/pair/*` and `/auth/*` are reachable without a session
/// token; everything else requires an authenticated, paired device.
class LanServer {
  LanServer({
    required this.identity,
    required this.localInfo,
    required this.pairing,
    required this.auth,
    required this.receiver,
    this.onPeerSeen,
    this.onPeerRevoked,
  });

  final DeviceIdentity identity;
  final DeviceInfo Function() localInfo;
  final PairingService pairing;
  final AuthenticationService auth;
  final TransferReceiver receiver;

  /// Called with the remote address whenever a paired device authenticates.
  final void Function(String deviceId, String address)? onPeerSeen;
  final void Function(String deviceId)? onPeerRevoked;

  HttpServer? _server;
  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  /// Binds to [preferredPort] on all interfaces, falling back to an ephemeral
  /// port when it is taken. Returns the bound port.
  Future<int> start({
    int preferredPort = Protocol.defaultServicePort,
    InternetAddress? address,
  }) async {
    final context = identity.serverContext();
    Future<HttpServer> bind(InternetAddress a, int port) =>
        HttpServer.bindSecure(a, port, context, v6Only: false);
    HttpServer server;
    final candidates = address != null
        ? [address]
        : [InternetAddress.anyIPv6, InternetAddress.anyIPv4];
    Object? lastError;
    server = await () async {
      for (final a in candidates) {
        for (final p in [preferredPort, 0]) {
          try {
            return await bind(a, p);
          } on SocketException catch (e) {
            lastError = e;
          }
        }
      }
      throw lastError ?? const SocketException('Could not bind server');
    }();
    server.idleTimeout = const Duration(seconds: 60);
    server.autoCompress = false;
    _server = server;
    server.listen((req) => unawaited(_handle(req)), onError: (_) {});
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    req.response.headers.set('Server', 'LanBeam');
    try {
      await _route(req);
    } on ApiError catch (e) {
      await _drain(req);
      await sendError(req.response, e);
    } on PairingFailure catch (e) {
      await sendError(req.response, ApiError(e.code, e.message));
    } on AuthFailure catch (e) {
      await sendError(req.response, ApiError(e.code));
    } on FormatException catch (e) {
      await _drain(req);
      await sendError(req.response, ApiError(ErrorCodes.badRequest, e.message));
    } on LanBeamException catch (e) {
      final code = switch (e.kind) {
        FailureKind.diskFull => ErrorCodes.diskFull,
        FailureKind.permissionDenied ||
        FailureKind.destinationUnavailable => ErrorCodes.forbidden,
        _ => ErrorCodes.internal,
      };
      await sendError(req.response, ApiError(code, e.userMessage));
    } catch (e) {
      await sendError(
        req.response,
        ApiError(ErrorCodes.internal, 'Internal error'),
      );
    }
  }

  Future<void> _drain(HttpRequest req) async {
    try {
      await req.drain<void>().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _route(HttpRequest req) async {
    final segments = req.uri.pathSegments;
    if (segments.length < 3 || segments[0] != 'api' || segments[1] != 'v1') {
      throw ApiError(ErrorCodes.notFound);
    }
    final path = segments.sublist(2);
    final method = req.method;
    final remote = remoteAddressOf(req);

    // ---- Public endpoints ----
    if (path case ['info'] when method == 'GET') {
      return sendJson(req.response, localInfo().toJson());
    }
    if (path case ['pair', 'pin'] when method == 'POST') {
      final body = await readJsonBody(req);
      final device = _deviceFrom(body);
      final r = pairing.startPinSession(device, remote);
      return sendJson(req.response, {
        'nonce': r.nonce,
        'expiresIn': r.expiresIn.inSeconds,
      });
    }
    if (path case ['pair', 'request'] when method == 'POST') {
      final body = await readJsonBody(req);
      final device = _deviceFrom(body);
      final trusted = await pairing.handlePairRequest(
        method: body['method'] as String? ?? '',
        device: device,
        remote: remote,
        token: body['token'] as String?,
        nonce: body['nonce'] as String?,
        proof: body['proof'] as String?,
      );
      return sendJson(req.response, {
        'status': 'approved',
        'secret': base64.encode(trusted.secret),
        'device': localInfo().toJson(),
      });
    }
    if (path case ['auth', 'challenge'] when method == 'POST') {
      final body = await readJsonBody(req);
      final id = body['deviceId'];
      if (id is! String) throw ApiError(ErrorCodes.badRequest);
      return sendJson(req.response, {'nonce': auth.issueChallenge(id, remote)});
    }
    if (path case ['auth', 'session'] when method == 'POST') {
      final body = await readJsonBody(req);
      final id = body['deviceId'], nonce = body['nonce'], proof = body['proof'];
      if (id is! String || nonce is! String || proof is! String) {
        throw ApiError(ErrorCodes.badRequest);
      }
      final grant = auth.createSession(
        deviceId: id,
        nonce: nonce,
        proof: proof,
        remote: remote,
      );
      onPeerSeen?.call(id, remote);
      return sendJson(req.response, {
        'token': grant.token,
        'expiresIn': grant.expiresIn.inSeconds,
        'serverProof': grant.serverProof,
      });
    }

    // ---- Authenticated endpoints ----
    final deviceId = auth.validate(bearerToken(req));
    if (deviceId == null) {
      throw ApiError(ErrorCodes.unauthorized, 'Not authenticated');
    }

    switch (path) {
      case ['pair', 'revoke'] when method == 'POST':
        await _drain(req);
        auth.revokeDevice(deviceId);
        onPeerRevoked?.call(deviceId);
        return sendJson(req.response, {'status': 'ok'});

      case ['transfers'] when method == 'POST':
        final body = await readJsonBody(
          req,
          maxBytes: Protocol.maxManifestBytes,
        );
        final result = await receiver.handleOffer(deviceId, body);
        return sendJson(req.response, result.body, status: result.status);

      case ['transfers', final id] when method == 'GET':
        return sendJson(req.response, receiver.statusOf(deviceId, id));

      case ['transfers', final id, 'events'] when method == 'GET':
        if (!WebSocketTransformer.isUpgradeRequest(req)) {
          throw ApiError(ErrorCodes.badRequest, 'WebSocket upgrade required');
        }
        receiver.checkAccess(deviceId, id);
        final socket = await WebSocketTransformer.upgrade(req);
        socket.pingInterval = const Duration(seconds: 10);
        receiver.attachEvents(deviceId, id, socket);
        return;

      case ['transfers', final id, 'files', final fileId] when method == 'PUT':
        final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '');
        if (offset == null || offset < 0) {
          throw ApiError(ErrorCodes.badRequest, 'offset');
        }
        final received = await receiver.handleUpload(
          deviceId,
          id,
          fileId,
          offset,
          req,
        );
        return sendJson(req.response, {'received': received});

      case ['transfers', final id, 'files', final fileId, 'complete']
          when method == 'POST':
        final body = await readJsonBody(req);
        final digest = body['digest'];
        if (digest is! String) throw ApiError(ErrorCodes.badRequest, 'digest');
        final name = await receiver.handleComplete(
          deviceId,
          id,
          fileId,
          digest,
        );
        return sendJson(req.response, {'state': 'verified', 'name': name});

      case ['transfers', final id, final command]
          when method == 'POST' &&
              const {'pause', 'resume', 'cancel', 'finish'}.contains(command):
        await _drain(req);
        await receiver.handleCommand(deviceId, id, command);
        return sendJson(
          req.response,
          receiver.statusOf(deviceId, id, allowFinished: true),
        );
    }
    throw ApiError(ErrorCodes.notFound);
  }

  DeviceInfo _deviceFrom(Map<String, Object?> body) {
    final d = body['device'];
    if (d is! Map) throw ApiError(ErrorCodes.badRequest, 'device missing');
    return DeviceInfo.fromJson(d.cast());
  }
}
