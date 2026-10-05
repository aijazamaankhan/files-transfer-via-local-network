import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final Random _secure = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}

/// URL-safe base64 without padding.
String randomToken([int bytes = 32]) =>
    base64Url.encode(randomBytes(bytes)).replaceAll('=', '');

/// Uniformly random 6-digit PIN.
String randomPin() => _secure.nextInt(1000000).toString().padLeft(6, '0');

String hmacHex(List<int> key, String message) =>
    Hmac(sha256, key).convert(utf8.encode(message)).toString();

String sha256Hex(List<int> data) => sha256.convert(data).toString();

/// Compares two strings in time independent of where they differ.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}
