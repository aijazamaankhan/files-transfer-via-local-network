import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/protocol/protocol.dart';
import '../core/transfer/file_scanner.dart';
import '../core/transfer/file_source.dart';

/// Dart side of `MainActivity.kt` (Android only).
class AndroidBridge {
  AndroidBridge._();
  static final instance = AndroidBridge._();

  static const _channel = MethodChannel('com.lanbeam/android');

  bool get available => Platform.isAndroid;

  Future<Map<String, Object?>> deviceInfo() async =>
      (await _channel.invokeMapMethod<String, Object?>('deviceInfo')) ?? {};

  Future<String?> downloadsDirectory() =>
      _channel.invokeMethod<String>('downloadsDirectory');

  Future<void> acquireMulticastLock() async {
    if (available) await _channel.invokeMethod('acquireMulticastLock');
  }

  Future<void> releaseMulticastLock() async {
    if (available) await _channel.invokeMethod('releaseMulticastLock');
  }

  Future<void> startTransferService(String title) async {
    if (available)
      await _channel.invokeMethod('startTransferService', {'title': title});
  }

  Future<void> stopTransferService() async {
    if (available) await _channel.invokeMethod('stopTransferService');
  }

  Future<void> scanMedia(List<String> paths) async {
    if (available && paths.isNotEmpty) {
      await _channel.invokeMethod('scanMedia', {'paths': paths});
    }
  }

  /// System document picker (multiple files). Null when cancelled.
  Future<List<SendSelection>?> pickFiles() async {
    final raw = await _channel.invokeListMethod<Object?>('pickFiles');
    if (raw == null) return null;
    return [
      for (final e in raw.cast<Map>())
        FileSelection(
          ContentUriFileSource(e['uri'] as String),
          e['name'] as String,
          size: (e['size'] as num?)?.toInt(),
          modified: _date(e['modified']),
          mime: e['mime'] as String?,
        ),
    ];
  }

  /// System folder picker; returns the whole tree. Null when cancelled.
  Future<TreeSelection?> pickTree() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('pickTree');
    if (raw == null) return null;
    final entries = (raw['entries'] as List).cast<Map>();
    return TreeSelection(raw['rootName'] as String, [
      for (final e in entries)
        FileSelection(
          ContentUriFileSource(e['uri'] as String),
          e['path'] as String,
          size: (e['size'] as num?)?.toInt(),
          modified: _date(e['modified']),
          mime: e['mime'] as String?,
        ),
    ]);
  }

  static DateTime? _date(Object? v) =>
      v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

  Future<int> _open(String uri) async =>
      (await _channel.invokeMethod<int>('open', {'uri': uri}))!;

  Future<Uint8List> _read(int handle, int offset, int length) async =>
      (await _channel.invokeMethod<Uint8List>('read', {
        'handle': handle,
        'offset': offset,
        'length': length,
      }))!;

  Future<void> _close(int handle) =>
      _channel.invokeMethod('close', {'handle': handle});

  Future<Map<String, Object?>> _stat(String uri) async =>
      (await _channel.invokeMapMethod<String, Object?>('stat', {'uri': uri}))!;
}

/// A file selected through Android's Storage Access Framework, read by
/// offset via the native bridge (no copy into the app cache).
class ContentUriFileSource implements FileSource {
  ContentUriFileSource(this.uri);
  final String uri;

  static final _bridge = AndroidBridge.instance;

  @override
  String get displayPath => uri;

  @override
  Future<SourceStat> stat() async {
    try {
      final s = await _bridge._stat(uri);
      return SourceStat(
        (s['size'] as num).toInt(),
        AndroidBridge._date(s['modified']),
      );
    } on PlatformException catch (e) {
      throw _toFsError(e);
    }
  }

  @override
  Stream<Uint8List> openRead(int start) async* {
    final int handle;
    try {
      handle = await _bridge._open(uri);
    } on PlatformException catch (e) {
      throw _toFsError(e);
    }
    try {
      var offset = start;
      while (true) {
        final chunk = await _bridge._read(handle, offset, Protocol.ioChunkSize);
        if (chunk.isEmpty) break;
        offset += chunk.length;
        yield chunk;
      }
    } on PlatformException catch (e) {
      throw _toFsError(e);
    } finally {
      await _bridge._close(handle);
    }
  }

  FileSystemException _toFsError(PlatformException e) => FileSystemException(
    e.message ?? 'I/O error',
    uri,
    OSError(e.code, switch (e.code) {
      'permission_denied' => 13,
      'not_found' => 2,
      _ => 5,
    }),
  );

  @override
  Map<String, Object?> toJson() => {'type': 'content', 'uri': uri};
}
