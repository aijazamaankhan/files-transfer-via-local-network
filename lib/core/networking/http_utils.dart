import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/protocol.dart';

/// An error that maps directly onto a protocol error response.
class ApiError implements Exception {
  ApiError(this.code, [this.message, this.extra]);
  final String code;
  final String? message;
  final Map<String, Object?>? extra;

  int get status => ErrorCodes.httpStatus(code);

  Map<String, Object?> toJson() => {
    'error': code,
    'message': ?message,
    ...?extra,
  };

  @override
  String toString() => 'ApiError($code${message == null ? '' : ', $message'})';
}

/// Reads a JSON object body, enforcing a size limit.
Future<Map<String, Object?>> readJsonBody(
  HttpRequest request, {
  int maxBytes = Protocol.maxJsonBodyBytes,
}) async {
  final declared = request.contentLength;
  if (declared > maxBytes) throw ApiError(ErrorCodes.badRequest, 'Body too large');
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request) {
    builder.add(chunk);
    if (builder.length > maxBytes) {
      throw ApiError(ErrorCodes.badRequest, 'Body too large');
    }
  }
  try {
    final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    if (decoded is! Map) throw const FormatException();
    return decoded.cast<String, Object?>();
  } on FormatException {
    throw ApiError(ErrorCodes.badRequest, 'Invalid JSON');
  }
}

Future<void> sendJson(HttpResponse response, Object? body, {int status = 200}) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.headers.set('Cache-Control', 'no-store');
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> sendError(HttpResponse response, ApiError error) async {
  try {
    await sendJson(response, error.toJson(), status: error.status);
  } catch (_) {
    // Connection already gone.
  }
}

String? bearerToken(HttpRequest request) {
  final h = request.headers.value(HttpHeaders.authorizationHeader);
  if (h != null && h.startsWith('Bearer ')) return h.substring(7).trim();
  return null;
}

String remoteAddressOf(HttpRequest request) {
  final addr = request.connectionInfo?.remoteAddress.address ?? 'unknown';
  // Normalize IPv4-mapped IPv6 addresses.
  return addr.startsWith('::ffff:') ? addr.substring(7) : addr;
}
