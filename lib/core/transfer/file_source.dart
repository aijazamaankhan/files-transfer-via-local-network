import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/protocol.dart';

/// Size and modification time used to detect changes during a transfer.
class SourceStat {
  const SourceStat(this.size, this.modified);
  final int size;
  final DateTime? modified;

  bool sameAs(SourceStat other) =>
      size == other.size &&
      (modified == null ||
          other.modified == null ||
          modified!.millisecondsSinceEpoch ~/ 1000 ==
              other.modified!.millisecondsSinceEpoch ~/ 1000);
}

/// A readable file to send (FileChunkReader). Implementations: local paths
/// ([LocalFileSource]) and, on Android, Storage Access Framework URIs.
abstract class FileSource {
  /// Human-readable location for logs/UI.
  String get displayPath;

  Future<SourceStat> stat();

  /// Streams the content from byte [start] in chunks of about
  /// [Protocol.ioChunkSize]. The stream is single-subscription and honors
  /// pause (backpressure): no read happens while the consumer is paused.
  Stream<Uint8List> openRead(int start);

  /// Serialized form to resume after an app restart; `type` selects the
  /// deserializer registered in [FileSourceRegistry].
  Map<String, Object?> toJson();
}

class LocalFileSource implements FileSource {
  LocalFileSource(this.path);
  final String path;

  @override
  String get displayPath => path;

  @override
  Future<SourceStat> stat() async {
    final s = await File(path).stat();
    if (s.type == FileSystemEntityType.notFound) {
      throw FileSystemException('File not found', path, const OSError('', 2));
    }
    return SourceStat(s.size, s.modified);
  }

  @override
  Stream<Uint8List> openRead(int start) async* {
    final raf = await File(path).open();
    try {
      await raf.setPosition(start);
      while (true) {
        // `yield` suspends here while the subscriber is paused, so reads are
        // driven by the consumer's pace (backpressure).
        final chunk = await raf.read(Protocol.ioChunkSize);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Map<String, Object?> toJson() => {'type': 'local', 'path': path};
}

typedef FileSourceFactory = FileSource Function(Map<String, Object?> json);

/// Deserializes persisted sources; platform layers register extra types.
class FileSourceRegistry {
  FileSourceRegistry() {
    register('local', (j) => LocalFileSource(j['path'] as String));
  }

  final Map<String, FileSourceFactory> _factories = {};

  void register(String type, FileSourceFactory factory) =>
      _factories[type] = factory;

  FileSource? fromJson(Map<String, Object?> json) {
    final f = _factories[json['type']];
    if (f == null) return null;
    try {
      return f(json);
    } catch (_) {
      return null;
    }
  }
}
