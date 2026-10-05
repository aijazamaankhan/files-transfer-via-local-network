import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/protocol.dart';

/// Computes the LanBeam file digest from per-block SHA-256 hashes
/// (PROTOCOL.md §3).
String fileDigest(
  int size,
  List<Digest> blocks, {
  int blockSize = Protocol.blockSize,
}) {
  final out = AccumulatorSink<Digest>();
  final input = sha256.startChunkedConversion(out)
    ..add(utf8.encode('lanbeam-blocks-v1:$size:$blockSize:'));
  for (final b in blocks) {
    input.add(b.bytes);
  }
  input.close();
  return out.events.single.toString();
}

/// Minimal accumulator (avoids depending on package:convert).
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}

/// Incrementally hashes a byte stream in fixed-size blocks.
///
/// [onBlock] fires with the digest of each completed block, in order.
abstract class BlockHasher {
  /// Feeds bytes. Must be called sequentially. The returned future completes
  /// immediately unless too much data is waiting to be hashed, in which case
  /// it completes once the backlog drains (backpressure).
  Future<void> add(Uint8List data);

  /// Returns all block digests produced since creation, in order. When
  /// [includePartial] is true the trailing partial block is hashed as the
  /// final block (end of file); otherwise it is discarded (interrupted
  /// upload — only whole blocks are committed).
  Future<List<Digest>> close({bool includePartial = true});

  /// Abandons hashing.
  void abort();
}

/// Factory for [BlockHasher]s; allows swapping the isolate-backed
/// implementation for an inline one (tests, tiny files).
abstract class ChecksumService {
  BlockHasher createHasher({
    void Function(int index, Digest digest)? onBlock,
    int blockSize = Protocol.blockSize,
  });

  Future<void> dispose();
}

/// Hashes on the calling isolate.
class InlineChecksumService implements ChecksumService {
  @override
  BlockHasher createHasher({
    void Function(int index, Digest digest)? onBlock,
    int blockSize = Protocol.blockSize,
  }) => _InlineBlockHasher(blockSize, onBlock);

  @override
  Future<void> dispose() async {}
}

class _InlineBlockHasher implements BlockHasher {
  _InlineBlockHasher(this.blockSize, this.onBlock);

  final int blockSize;
  final void Function(int, Digest)? onBlock;
  final List<Digest> _digests = [];
  AccumulatorSink<Digest> _sink = AccumulatorSink();
  late ByteConversionSink _input = sha256.startChunkedConversion(_sink);
  int _inBlock = 0;

  @override
  Future<void> add(Uint8List data) {
    addSync(data);
    return Future.value();
  }

  void addSync(Uint8List data) {
    var offset = 0;
    while (offset < data.length) {
      final take = (blockSize - _inBlock).clamp(0, data.length - offset);
      _input.addSlice(data, offset, offset + take, false);
      _inBlock += take;
      offset += take;
      if (_inBlock == blockSize) _finishBlock();
    }
  }

  void _finishBlock() {
    _input.close();
    final d = _sink.events.single;
    _digests.add(d);
    onBlock?.call(_digests.length - 1, d);
    _sink = AccumulatorSink();
    _input = sha256.startChunkedConversion(_sink);
    _inBlock = 0;
  }

  @override
  Future<List<Digest>> close({bool includePartial = true}) async {
    if (_inBlock > 0 && includePartial) _finishBlock();
    return List.unmodifiable(_digests);
  }

  @override
  void abort() {}
}

/// Hashes in a long-lived worker isolate so that SHA-256 of 100 MB/s streams
/// never competes with the UI isolate. Data crosses as
/// [TransferableTypedData] (a single copy, no serialization).
class IsolateChecksumService implements ChecksumService {
  IsolateChecksumService._(
    this._isolate,
    this._toWorker,
    this._port,
    Stream<dynamic> messages,
  ) {
    _subscription = messages.listen(_onMessage);
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _port;
  late final StreamSubscription<dynamic> _subscription;
  final Map<int, _IsolateBlockHasher> _hashers = {};
  int _nextId = 0;

  static Future<IsolateChecksumService> spawn() async {
    final port = ReceivePort();
    final messages = port.asBroadcastStream();
    final isolate = await Isolate.spawn(
      _workerMain,
      port.sendPort,
      debugName: 'lanbeam-checksum',
    );
    final toWorker =
        await messages.firstWhere((m) => m is SendPort) as SendPort;
    return IsolateChecksumService._(isolate, toWorker, port, messages);
  }

  void _onMessage(dynamic msg) {
    // [id, kind, index, bytes]
    final list = msg as List;
    final hasher = _hashers[list[0] as int];
    if (hasher == null) return;
    switch (list[1] as int) {
      case 0: // block
        hasher._onBlock(list[2] as int, Digest(list[3] as Uint8List));
      case 1: // closed
        _hashers.remove(list[0]);
        hasher._onClosed();
      case 2: // data consumed
        hasher._onConsumed(list[2] as int);
    }
  }

  @override
  BlockHasher createHasher({
    void Function(int index, Digest digest)? onBlock,
    int blockSize = Protocol.blockSize,
  }) {
    final id = _nextId++;
    final h = _IsolateBlockHasher(this, id, onBlock);
    _hashers[id] = h;
    _toWorker.send([id, 0, blockSize]);
    return h;
  }

  @override
  Future<void> dispose() async {
    _toWorker.send(null);
    await _subscription.cancel();
    _port.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static void _workerMain(SendPort toMain) {
    final port = ReceivePort();
    toMain.send(port.sendPort);
    final hashers = <int, _InlineBlockHasher>{};
    port.listen((msg) {
      if (msg == null) {
        port.close();
        return;
      }
      final list = msg as List;
      final id = list[0] as int;
      switch (list[1] as int) {
        case 0: // create
          hashers[id] = _InlineBlockHasher(list[2] as int, (i, d) {
            toMain.send([id, 0, i, Uint8List.fromList(d.bytes)]);
          });
        case 1: // data
          final data = (list[2] as TransferableTypedData)
              .materialize()
              .asUint8List();
          hashers[id]?.addSync(data);
          toMain.send([id, 2, data.length, null]);
        case 2: // close
          final h = hashers.remove(id);
          if (h != null) {
            h
                .close(includePartial: list[2] as bool)
                .then((_) => toMain.send([id, 1, 0, null]));
          } else {
            toMain.send([id, 1, 0, null]);
          }
        case 3: // abort
          hashers.remove(id);
      }
    });
  }
}

class _IsolateBlockHasher implements BlockHasher {
  _IsolateBlockHasher(this._service, this._id, this._onBlockCb);

  final IsolateChecksumService _service;
  final int _id;
  final void Function(int, Digest)? _onBlockCb;
  final List<Digest> _digests = [];
  final Completer<List<Digest>> _closed = Completer();

  /// Bytes sent to the worker but not yet hashed.
  int _outstanding = 0;
  Completer<void>? _drained;
  static const _maxOutstanding = 16 * 1024 * 1024;

  void _onConsumed(int bytes) {
    _outstanding -= bytes;
    final d = _drained;
    if (d != null && _outstanding <= _maxOutstanding ~/ 2) {
      _drained = null;
      d.complete();
    }
  }

  void _onBlock(int index, Digest d) {
    _digests.add(d);
    _onBlockCb?.call(index, d);
  }

  void _onClosed() {
    if (!_closed.isCompleted) _closed.complete(List.unmodifiable(_digests));
    _drained?.complete();
    _drained = null;
  }

  @override
  Future<void> add(Uint8List data) {
    if (data.isEmpty) return Future.value();
    _outstanding += data.length;
    _service._toWorker.send([
      _id,
      1,
      TransferableTypedData.fromList([data]),
    ]);
    if (_outstanding <= _maxOutstanding) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  @override
  Future<List<Digest>> close({bool includePartial = true}) {
    _service._toWorker.send([_id, 2, includePartial]);
    return _closed.future;
  }

  @override
  void abort() {
    _service._toWorker.send([_id, 3]);
    _service._hashers.remove(_id);
    _drained?.complete();
    _drained = null;
  }
}
