import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../security/device_identity.dart' show restrictPermissions;

/// Durable JSON document stored in a single file.
///
/// Writes go to a temporary file which is then atomically renamed over the
/// target, so a crash mid-write never leaves a truncated document. Writes are
/// serialized; concurrent [write] calls coalesce to the latest value.
class JsonFileStore {
  JsonFileStore(this.path, {this.sensitive = false});

  final String path;

  /// Restrict file permissions to the owner (secrets).
  final bool sensitive;

  Future<void> _chain = Future.value();
  Object? _pending;
  bool _scheduled = false;

  Future<Object?> read() async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } on FormatException {
      // Keep the corrupt file for diagnosis and start fresh.
      await file.rename('$path.corrupt').catchError((_) => file);
      return null;
    }
  }

  Future<void> write(Object? value) {
    _pending = value;
    if (_scheduled) return _chain;
    _scheduled = true;
    _chain = _chain.then((_) async {
      _scheduled = false;
      final data = _pending;
      try {
        final file = File(path);
        await file.parent.create(recursive: true);
        final tmp = File('$path.tmp');
        await tmp.writeAsString(jsonEncode(data), flush: true);
        if (sensitive) await restrictPermissions(tmp.path);
        await tmp.rename(path);
      } catch (e) {
        // Persisting is best effort (e.g. disk full, directory removed); a
        // failed write must not break the chain or crash the app.
        lastError = e;
      }
    });
    return _chain;
  }

  /// Error from the most recent failed write, if any.
  Object? lastError;

  Future<void> flush() => _chain;
}
