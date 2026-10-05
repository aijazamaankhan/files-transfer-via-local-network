import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/protocol.dart';
import 'checksum.dart';

class OffsetMismatch implements Exception {
  const OffsetMismatch(this.expected);
  final int expected;
}

class UploadInterrupted implements Exception {
  const UploadInterrupted(this.reason);
  final String reason;
}

/// Receiver-side partial file (FileChunkWriter).
///
/// Data is written to `<fileId>.part`; the SHA-256 of every completed block is
/// appended to `<fileId>.blocks`. The committed offset is always
/// `blocks × blockSize` (or the full size once complete), so an interrupted
/// upload resumes without re-reading any data.
class PartialFile {
  PartialFile({
    required this.stagingDir,
    required this.fileId,
    required this.size,
    required this.checksums,
    this.blockSize = Protocol.blockSize,
  });

  final String stagingDir;
  final String fileId;
  final int size;
  final ChecksumService checksums;
  final int blockSize;

  String get partPath => '$stagingDir${Platform.pathSeparator}$fileId.part';
  String get blocksPath => '$stagingDir${Platform.pathSeparator}$fileId.blocks';

  int _committed = 0;
  bool _prepared = false;

  /// Serializes prepare/write/discard so a dying upload can never race a
  /// resumed one on the same file.
  Future<void> _lock = Future.value();

  Future<T> _locked<T>(Future<T> Function() body) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous
        .timeout(const Duration(seconds: 30), onTimeout: () {
          throw const UploadInterrupted('previous upload still running');
        })
        .then((_) => body())
        .whenComplete(done.complete);
  }

  int get committed => _committed;
  bool get isComplete => _prepared && _committed == size;
  int get _totalBlocks => (size + blockSize - 1) ~/ blockSize;

  /// Restores state from disk and returns the committed offset.
  Future<int> prepare() => _locked(_prepare);

  Future<int> _prepare() async {
    await Directory(stagingDir).create(recursive: true);
    final part = File(partPath);
    final blocks = File(blocksPath);
    final partLen = await part.exists() ? await part.length() : 0;
    var hashes = await _readHashes();

    if (hashes.length == _totalBlocks && partLen == size) {
      _committed = size;
      if (!await part.exists()) await part.create(); // empty file
    } else {
      final whole = (partLen ~/ blockSize).clamp(0, hashes.length);
      final keep = whole.clamp(0, size ~/ blockSize);
      hashes = hashes.sublist(0, keep);
      _committed = keep * blockSize;
      if (partLen != _committed || !await part.exists()) {
        final raf = await part.open(mode: FileMode.append);
        await raf.truncate(_committed);
        await raf.close();
      }
      await blocks.writeAsString(hashes.map((h) => '$h\n').join(), flush: true);
    }
    _prepared = true;
    return _committed;
  }

  Future<List<String>> _readHashes() async {
    final f = File(blocksPath);
    if (!await f.exists()) return [];
    final lines = await f.readAsLines();
    final valid = <String>[];
    for (final l in lines) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(l)) break;
      valid.add(l);
    }
    return valid;
  }

  /// Writes [body] starting at [offset] (must equal [committed]).
  ///
  /// [onBytes] reports bytes as they are written. [shouldStop] is polled per
  /// chunk; when it returns a reason the upload is aborted with
  /// [UploadInterrupted] (receiver paused/cancelled).
  Future<int> write(
    Stream<List<int>> body,
    int offset, {
    void Function(int bytes)? onBytes,
    String? Function()? shouldStop,
  }) => _locked(() => _write(body, offset, onBytes: onBytes, shouldStop: shouldStop));

  Future<int> _write(
    Stream<List<int>> body,
    int offset, {
    void Function(int bytes)? onBytes,
    String? Function()? shouldStop,
  }) async {
    if (!_prepared) await _prepare();
    if (offset != _committed) {
      // Drain nothing: the caller responds with the expected offset.
      throw OffsetMismatch(_committed);
    }

    final raf = await File(partPath).open(mode: FileMode.append);
    final blocksSink = File(blocksPath).openWrite(mode: FileMode.append);
    final startBlock = offset ~/ blockSize;
    final hasher = checksums.createHasher(
      blockSize: blockSize,
      onBlock: (i, d) {
        blocksSink.writeln(d.toString());
        // Data is written before it is hashed, so the block is on disk.
        _committed = (startBlock + i + 1) * blockSize;
      },
    );
    final buffer = BytesBuilder(copy: false);
    var position = offset;
    var hashedBlocks = 0;
    var ok = false;

    Future<void> flushBuffer() async {
      if (buffer.isEmpty) return;
      final data = buffer.takeBytes();
      await raf.writeFrom(data);
      await hasher.add(data);
    }

    try {
      await for (final chunk in body) {
        final stop = shouldStop?.call();
        if (stop != null) throw UploadInterrupted(stop);
        if (position + chunk.length > size) {
          throw const FormatException('upload exceeds declared size');
        }
        buffer.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        position += chunk.length;
        onBytes?.call(chunk.length);
        if (buffer.length >= Protocol.ioChunkSize) await flushBuffer();
      }
      await flushBuffer();
      ok = position == size;
    } finally {
      try {
        await flushBuffer();
      } catch (_) {}
      await raf.flush().catchError((_) => raf);
      await raf.close();
      final digests = await hasher.close(includePartial: ok);
      hashedBlocks = digests.length;
      await blocksSink.flush();
      await blocksSink.close();
      if (ok) {
        _committed = size;
      } else {
        // Keep only whole, hashed blocks.
        _committed = (startBlock + hashedBlocks) * blockSize;
        if (_committed > size) _committed = size;
        try {
          final t = await File(partPath).open(mode: FileMode.append);
          await t.truncate(_committed);
          await t.close();
        } catch (_) {}
      }
    }
    if (!ok) throw const UploadInterrupted('incomplete body');
    return _committed;
  }

  /// LanBeam digest of the committed data. Only valid when [isComplete].
  Future<String> digest() async {
    final hashes = await _readHashes();
    final digests = hashes
        .map((h) => Digest(Uint8List.fromList(_hexDecode(h))))
        .toList();
    return fileDigest(size, digests, blockSize: blockSize);
  }

  Future<void> discard() => _locked(_discard);

  Future<void> _discard() async {
    for (final path in [partPath, blocksPath]) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // already gone
      }
    }
    _committed = 0;
    _prepared = false;
  }

  static List<int> _hexDecode(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
