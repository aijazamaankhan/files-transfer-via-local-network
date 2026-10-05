import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/device_info.dart';
import '../models/transfer_models.dart';
import '../networking/peer_client.dart';
import '../protocol/protocol.dart';
import '../util/errors.dart';
import 'checksum.dart';
import 'file_scanner.dart';
import 'file_source.dart';
import 'transfer_task.dart';

class _PausedSignal implements Exception {
  const _PausedSignal();
}

class _CancelledSignal implements Exception {
  const _CancelledSignal();
}

/// An outgoing transfer (sender side of the protocol).
///
/// Lifecycle: connect → offer → wait for approval → upload files (up to
/// [concurrency] at once) → verify each digest → finish. Network failures are
/// retried with exponential backoff, resuming from the receiver's committed
/// offsets; pause/resume/cancel work from either side.
class OutgoingTransfer extends TransferTask {
  OutgoingTransfer({
    required super.manifest,
    required super.peer,
    required this.sources,
    required this.client,
    required this.checksums,
    this.concurrency = 3,
    this.maxAttempts = 6,
    this.resolveHosts,
    this.decisionTimeout = const Duration(minutes: 10),
    this.onSettled,
    super.startedAt,
  }) : super(direction: TransferDirection.outgoing);

  /// Source for each manifest file id.
  final Map<String, FileSource> sources;
  final PeerClient client;
  final ChecksumService checksums;
  final int concurrency;
  final int maxAttempts;
  final Duration decisionTimeout;

  /// Refreshes candidate addresses (e.g. from discovery) before a retry.
  final Future<List<String>> Function()? resolveHosts;

  /// Called whenever the transfer stops running (completed, failed, …).
  final void Function(OutgoingTransfer)? onSettled;

  final Map<String, int> _offsets = {};

  /// Cached block digests per file so a resume does not re-read data.
  final Map<String, List<Digest>> _blockCache = {};
  final Set<UploadHandle> _inFlight = {};
  final Map<String, int> _checksumRetries = {};

  WebSocket? _events;
  StreamSubscription? _eventsSub;
  Completer<Map<String, Object?>>? _decision;
  Completer<void>? _resumeSignal;
  bool _localPause = false;
  bool _cancelRequested = false;
  bool _running = false;
  Future<void>? _loop;

  bool get isRunning => _running;

  /// Serializable data to resume after an app restart.
  Map<String, Object?> resumeData() => {
    'manifest': manifest.toJson(),
    'peer': peer.toJson(),
    'sources': {for (final e in sources.entries) e.key: e.value.toJson()},
  };

  /// Starts (or restarts after failure) the transfer.
  Future<void> start() {
    if (_running) return _loop!;
    _running = true;
    _cancelRequested = false;
    _loop = _run().whenComplete(() {
      _running = false;
      onSettled?.call(this);
    });
    return _loop!;
  }

  void pause() {
    if (status.isFinal || _localPause) return;
    _localPause = true;
    _abortInFlight();
    setStatus(TransferStatus.paused);
    unawaited(_bestEffort(() => client.command(id, 'pause')));
  }

  void resume() {
    if (!_localPause) return;
    _localPause = false;
    unawaited(_bestEffort(() => client.command(id, 'resume')));
    if (!pausedRemotely) setStatus(TransferStatus.active);
    _signalResume();
    if (!_running && !status.isFinal) start();
  }

  Future<void> cancel() async {
    if (status.isFinal) return;
    _cancelRequested = true;
    _abortInFlight();
    _signalResume();
    _decision?.completeError(const _CancelledSignal());
    setStatus(TransferStatus.cancelled);
    await _bestEffort(() => client.command(id, 'cancel'));
    await _closeEvents();
  }

  /// Retries a failed transfer from where it stopped.
  Future<void> retry() {
    if (status != TransferStatus.failed) return Future.value();
    error = null;
    for (final f in files.values) {
      if (f.state == FileTransferState.failed) f.state = FileTransferState.queued;
    }
    _checksumRetries.clear();
    return start();
  }

  void _signalResume() {
    final r = _resumeSignal;
    _resumeSignal = null;
    if (r != null && !r.isCompleted) r.complete();
  }

  void _abortInFlight() {
    for (final h in List.of(_inFlight)) {
      h.abort();
    }
  }

  Future<void> _bestEffort(Future<Object?> Function() f) async {
    try {
      await f().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------

  Future<void> _run() async {
    var attempts = 0;
    while (!_cancelRequested) {
      try {
        if (_localPause || pausedRemotely) {
          await _waitForResume();
          continue;
        }
        if (status != TransferStatus.awaitingApproval) {
          setStatus(TransferStatus.pending);
        }
        await client.ensureAuthenticated();
        var (accepted, body) = await client.offer(manifest);
        await _openEvents();
        if (!accepted) {
          setStatus(TransferStatus.awaitingApproval);
          body = await _waitForDecision();
        }
        if (body['state'] == 'completed') {
          _markAllDone();
          setStatus(TransferStatus.completed);
          await _closeEvents();
          return;
        }
        _applyOffsets(body['files']);
        if (_localPause || pausedRemotely) continue;
        setStatus(TransferStatus.active);
        attempts = 0;
        await _uploadAll();
        if (_cancelRequested) return;

        final failed = files.values.where((f) => f.state == FileTransferState.failed).toList();
        await _bestEffort(() => client.command(id, 'finish'));
        await _closeEvents();
        if (failed.isNotEmpty) {
          setStatus(
            TransferStatus.failed,
            error: LanBeamException(
              _failureKindFor(failed.first.error),
              '${failed.length} file(s) failed',
            ),
          );
        } else {
          setStatus(TransferStatus.completed);
        }
        return;
      } on _PausedSignal {
        continue;
      } on _CancelledSignal {
        if (!status.isFinal) setStatus(TransferStatus.cancelled);
        return;
      } on PeerApiException catch (e) {
        final err = e.toLanBeam();
        if (err.kind == FailureKind.rejected) {
          setStatus(TransferStatus.rejected, error: err);
          await _closeEvents();
          return;
        }
        if (err.kind == FailureKind.cancelled) {
          setStatus(TransferStatus.cancelled, error: err);
          await _closeEvents();
          return;
        }
        if (e.code == 'paused') {
          pausedRemotely = true;
          setStatus(TransferStatus.paused);
          continue;
        }
        if (!err.isRetryable || ++attempts >= maxAttempts) {
          setStatus(TransferStatus.failed, error: err);
          await _closeEvents();
          return;
        }
        await _backoff(attempts);
      } on LanBeamException catch (e) {
        if (_cancelRequested) return;
        if (!e.isRetryable || ++attempts >= maxAttempts) {
          setStatus(TransferStatus.failed, error: e);
          await _closeEvents();
          return;
        }
        await _backoff(attempts);
      } catch (e) {
        if (_cancelRequested) return;
        final err = classifyError(e);
        if (!err.isRetryable || ++attempts >= maxAttempts) {
          setStatus(TransferStatus.failed, error: err);
          await _closeEvents();
          return;
        }
        await _backoff(attempts);
      }
    }
  }

  FailureKind _failureKindFor(String? message) {
    for (final k in FailureKind.values) {
      if (k.message == message) return k;
    }
    return FailureKind.unknown;
  }

  Future<void> _backoff(int attempt) async {
    await _closeEvents();
    final delay = Duration(milliseconds: min(16000, 500 * pow(2, attempt).toInt()));
    if (status != TransferStatus.paused) {
      setStatus(TransferStatus.pending, error: error);
    }
    await Future<void>.delayed(delay);
    final resolver = resolveHosts;
    if (resolver != null) {
      try {
        final hosts = await resolver();
        if (hosts.isNotEmpty) client.hosts = hosts;
      } catch (_) {}
    }
  }

  Future<void> _waitForResume() async {
    setStatus(TransferStatus.paused);
    final signal = _resumeSignal ??= Completer<void>();
    if (pausedRemotely && !_localPause) {
      // The receiver paused: poll in case the event channel is gone.
      while (!signal.isCompleted && pausedRemotely && !_cancelRequested) {
        await Future.any([signal.future, Future<void>.delayed(const Duration(seconds: 5))]);
        if (signal.isCompleted || !pausedRemotely) break;
        try {
          final s = await client.status(id);
          if (s['paused'] != true && s['state'] != 'paused') pausedRemotely = false;
          if (s['state'] == 'cancelled') throw const _CancelledSignal();
        } on _CancelledSignal {
          rethrow;
        } catch (_) {}
      }
      if (!pausedRemotely) _signalResume();
    }
    await signal.future;
    if (_cancelRequested) throw const _CancelledSignal();
  }

  void _markAllDone() {
    for (final f in files.values) {
      if (f.state != FileTransferState.skipped) {
        setFileState(f.file.id, FileTransferState.done, transferred: f.file.size);
      }
    }
  }

  void _applyOffsets(Object? raw) {
    if (raw is! Map) throw const LanBeamException(FailureKind.protocol, 'files');
    for (final f in files.values) {
      final entry = raw[f.file.id];
      if (entry is! Map) continue;
      if (entry['skip'] == true) {
        setFileState(f.file.id, FileTransferState.skipped, transferred: 0);
        continue;
      }
      final offset = (entry['offset'] as int?) ?? 0;
      _offsets[f.file.id] = offset;
      if (entry['state'] == 'done') {
        setFileState(f.file.id, FileTransferState.done, transferred: f.file.size);
      } else if (f.state != FileTransferState.failed) {
        setFileState(f.file.id, FileTransferState.queued, transferred: offset);
      }
    }
  }

  Future<Map<String, Object?>> _waitForDecision() async {
    final completer = _decision = Completer<Map<String, Object?>>();
    final deadline = DateTime.now().add(decisionTimeout);
    // Poll as a fallback in case the WebSocket is unavailable.
    final poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (completer.isCompleted) return;
      try {
        final s = await client.status(id);
        if (completer.isCompleted) return;
        switch (s['state']) {
          case 'accepted' || 'completed':
            completer.complete(s);
          case 'rejected':
            completer.completeError(PeerApiException(403, 'rejected', null, s));
          case 'cancelled':
            completer.completeError(PeerApiException(410, 'gone', null, s));
        }
      } catch (_) {}
      if (DateTime.now().isAfter(deadline) && !completer.isCompleted) {
        completer.completeError(PeerApiException(408, 'rejected', 'No response', const {}));
      }
    });
    try {
      return await completer.future;
    } finally {
      poll.cancel();
      _decision = null;
    }
  }

  Future<void> _openEvents() async {
    if (_events != null) return;
    try {
      final ws = await client.events(id);
      _events = ws;
      _eventsSub = ws.listen(
        _onEvent,
        onDone: () {
          _events = null;
          _eventsSub = null;
        },
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (_) {
      // Events are an optimization; REST polling covers their absence.
    }
  }

  Future<void> _closeEvents() async {
    final ws = _events;
    _events = null;
    await _eventsSub?.cancel();
    _eventsSub = null;
    await ws?.close().catchError((_) {});
  }

  void _onEvent(dynamic data) {
    if (data is! String) return;
    final Map msg;
    try {
      msg = jsonDecode(data) as Map;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'decision':
        final c = _decision;
        if (c != null && !c.isCompleted) {
          if (msg['accepted'] == true) {
            c.complete({'state': 'accepted', 'files': msg['files']});
          } else {
            c.completeError(PeerApiException(403, 'rejected', msg['reason'] as String?, const {}));
          }
        }
      case 'paused':
        pausedRemotely = true;
        _abortInFlight();
        setStatus(TransferStatus.paused);
      case 'resumed':
        pausedRemotely = false;
        if (!_localPause) {
          setStatus(TransferStatus.active);
          _signalResume();
        }
      case 'cancelled':
        _cancelRequested = true;
        _abortInFlight();
        _signalResume();
        _decision?.completeError(const _CancelledSignal());
        setStatus(
          TransferStatus.cancelled,
          error: const LanBeamException(FailureKind.cancelled, 'by receiver'),
        );
      case 'error':
        if (msg['error'] == 'disk_full') {
          _abortInFlight();
          error = const LanBeamException(FailureKind.diskFull);
        }
    }
  }

  // ---------------------------------------------------------------------
  // Uploading

  Future<void> _uploadAll() async {
    final queue = files.values
        .where((f) => !f.state.isFinished && f.state != FileTransferState.failed)
        .map((f) => f.file.id)
        .toList();
    Object? fatal;
    Future<void> worker() async {
      while (queue.isNotEmpty && fatal == null) {
        final fileId = queue.removeAt(0);
        try {
          await _uploadFile(fileId);
        } on _PausedSignal catch (e) {
          fatal ??= e;
        } on _CancelledSignal catch (e) {
          fatal ??= e;
        } on _FileFailure catch (e) {
          setFileState(fileId, FileTransferState.failed, error: e.error.userMessage);
        } catch (e) {
          fatal ??= e;
          // Stop the other workers' uploads promptly; they will resume.
          _abortInFlight();
        }
      }
    }

    await Future.wait([for (var i = 0; i < max(1, concurrency); i++) worker()]);
    if (fatal != null) {
      if (_cancelRequested) throw const _CancelledSignal();
      if (_localPause || pausedRemotely) throw const _PausedSignal();
      throw fatal!;
    }
    if (_cancelRequested) throw const _CancelledSignal();
    if (_localPause || pausedRemotely) throw const _PausedSignal();
  }

  Future<void> _uploadFile(String fileId) async {
    final progress = files[fileId]!;
    final source = sources[fileId]!;
    final meta = progress.file;

    for (var round = 0; round < 4; round++) {
      _checkInterrupt();
      final before = await _statOrFail(source);
      if (before.size != meta.size ||
          (meta.modified != null && !before.sameAs(SourceStat(meta.size, meta.modified)))) {
        throw const _FileFailure(LanBeamException(FailureKind.fileChanged));
      }
      var offset = _offsets[fileId] ?? 0;
      if (offset > meta.size || offset % Protocol.blockSize != 0 && offset != meta.size) {
        offset = 0;
      }
      setFileState(fileId, FileTransferState.transferring, transferred: offset);

      final prefix = await _prefixDigests(fileId, source, offset);
      final startBlock = offset ~/ Protocol.blockSize;
      final cache = _blockCache[fileId] = List.of(prefix);
      final hasher = checksums.createHasher(
        onBlock: (i, d) {
          final idx = startBlock + i;
          if (idx == cache.length) cache.add(d);
        },
      );

      if (offset < meta.size) {
        final data = source.openRead(offset).asyncMap<List<int>>((chunk) async {
          await hasher.add(chunk);
          addProgress(fileId, chunk.length);
          return chunk;
        });
        UploadHandle? handle;
        try {
          handle = await client.upload(id, fileId, offset, meta.size - offset, data);
          _inFlight.add(handle);
          await handle.done;
        } on UploadAborted {
          hasher.abort();
          _checkInterrupt();
          throw const _PausedSignal();
        } on PeerApiException catch (e) {
          hasher.abort();
          if (e.code == 'offset_mismatch' && e.body['offset'] is int) {
            _offsets[fileId] = e.body['offset'] as int;
            setFileState(fileId, FileTransferState.queued, transferred: _offsets[fileId]);
            continue;
          }
          if (e.code == 'paused') {
            pausedRemotely = true;
            throw const _PausedSignal();
          }
          if (e.code == 'gone') throw const _CancelledSignal();
          rethrow;
        } catch (e) {
          hasher.abort();
          _checkInterrupt();
          rethrow;
        } finally {
          if (handle != null) _inFlight.remove(handle);
        }
      }

      final tail = await hasher.close();
      final digests = [...prefix, ...tail];
      final after = await _statOrFail(source);
      if (!after.sameAs(before)) {
        throw const _FileFailure(LanBeamException(FailureKind.fileChanged));
      }
      setFileState(fileId, FileTransferState.verifying, transferred: meta.size);
      try {
        await client.complete(id, fileId, fileDigest(meta.size, digests));
        setFileState(fileId, FileTransferState.done, transferred: meta.size);
        _blockCache.remove(fileId);
        return;
      } on PeerApiException catch (e) {
        if (e.code == 'checksum_mismatch') {
          final n = _checksumRetries[fileId] = (_checksumRetries[fileId] ?? 0) + 1;
          _blockCache.remove(fileId);
          _offsets[fileId] = 0;
          if (n > 2) {
            throw const _FileFailure(LanBeamException(FailureKind.checksumMismatch));
          }
          continue;
        }
        if (e.code == 'offset_mismatch' && e.body['offset'] is int) {
          _offsets[fileId] = e.body['offset'] as int;
          continue;
        }
        if (e.code == 'gone') throw const _CancelledSignal();
        rethrow;
      }
    }
    throw const _FileFailure(LanBeamException(FailureKind.protocol, 'too many restarts'));
  }

  void _checkInterrupt() {
    if (_cancelRequested) throw const _CancelledSignal();
    if (_localPause || pausedRemotely) throw const _PausedSignal();
  }

  Future<SourceStat> _statOrFail(FileSource source) async {
    try {
      return await source.stat();
    } catch (e) {
      final err = classifyError(e);
      throw _FileFailure(
        err.kind == FailureKind.permissionDenied
            ? err
            : LanBeamException(FailureKind.fileMissing, err.detail),
      );
    }
  }

  /// Block digests for bytes `[0, offset)`, from cache or by re-reading.
  Future<List<Digest>> _prefixDigests(String fileId, FileSource source, int offset) async {
    final blocks = offset ~/ Protocol.blockSize;
    if (blocks == 0) return const [];
    final cached = _blockCache[fileId];
    if (cached != null && cached.length >= blocks) return cached.sublist(0, blocks);
    // Re-hash locally (fast compared to the network); happens only when
    // resuming after an app restart.
    final hasher = checksums.createHasher();
    var read = 0;
    await for (final chunk in source.openRead(0)) {
      final take = min(chunk.length, offset - read);
      await hasher.add(take == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, take));
      read += take;
      if (read >= offset) break;
    }
    final d = await hasher.close(includePartial: false);
    return d.sublist(0, blocks);
  }
}

class _FileFailure implements Exception {
  const _FileFailure(this.error);
  final LanBeamException error;
}

/// Runs outgoing transfers with a cap on how many are active at once.
class TransferQueue {
  TransferQueue({this.maxActive = 2});
  final int maxActive;
  final List<OutgoingTransfer> _waiting = [];
  final Set<OutgoingTransfer> _active = {};

  void enqueue(OutgoingTransfer t) {
    if (_active.length < maxActive) {
      _launch(t);
    } else {
      _waiting.add(t);
    }
  }

  void remove(OutgoingTransfer t) => _waiting.remove(t);

  void _launch(OutgoingTransfer t) {
    _active.add(t);
    t.start().whenComplete(() {
      _active.remove(t);
      while (_waiting.isNotEmpty && _active.length < maxActive) {
        final next = _waiting.removeAt(0);
        if (!next.status.isFinal) _launch(next);
      }
    });
  }
}

/// Builds an [OutgoingTransfer] from scanned files.
OutgoingTransfer buildOutgoing({
  required String transferId,
  required ScanResult scan,
  required DeviceInfo peer,
  required PeerClient client,
  required ChecksumService checksums,
  int concurrency = 3,
  Future<List<String>> Function()? resolveHosts,
  void Function(OutgoingTransfer)? onSettled,
}) {
  final manifest = TransferManifest(
    transferId: transferId,
    kind: scan.kind,
    files: scan.files.map((f) => f.toManifest()).toList(),
  );
  return OutgoingTransfer(
    manifest: manifest,
    peer: peer,
    sources: {for (final f in scan.files) f.id: f.source},
    client: client,
    checksums: checksums,
    concurrency: concurrency,
    resolveHosts: resolveHosts,
    onSettled: onSettled,
  );
}
