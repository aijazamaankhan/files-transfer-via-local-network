import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../destinations/destination_manager.dart';
import '../models/device_info.dart';
import '../models/settings.dart';
import '../models/transfer_models.dart';
import '../networking/http_utils.dart';
import '../protocol/protocol.dart';
import '../security/crypto_utils.dart';
import '../security/path_safety.dart';
import '../storage/json_store.dart';
import '../storage/stores.dart';
import '../util/errors.dart';
import 'checksum.dart';
import 'chunk_writer.dart';
import 'transfer_task.dart';

/// An incoming transfer as seen by the receiving device.
class IncomingTransfer extends TransferTask {
  IncomingTransfer({
    required super.manifest,
    required super.peer,
    super.startedAt,
  }) : super(direction: TransferDirection.incoming);

  DestinationPlan? plan;
  final Map<String, PartialFile> partials = {};
  final List<WebSocket> _sockets = [];
  int _activeUploads = 0;
  bool localPaused = false;
  Timer? _decisionTimeout;
  Timer? _disconnectTimer;

  bool get isAccepted => plan != null;
  bool get allFilesFinished => files.values.every((f) => f.state.isFinished);
}

/// What the UI receives when a transfer needs a decision.
class IncomingRequest {
  IncomingRequest(this._receiver, this.task, this.defaultPlan);

  final TransferReceiver _receiver;
  final IncomingTransfer task;

  /// Destination plan from current settings (may be null if the default
  /// destination is unavailable).
  final DestinationPlan? defaultPlan;

  DeviceInfo get sender => task.peer;
  List<PlannedFile> get conflicts => defaultPlan?.conflicts ?? const [];

  /// Re-plans into [root] (user picked a folder) and returns conflicts.
  Future<DestinationPlan> planFor(String? root) =>
      _receiver._buildPlan(task, overrideRoot: root);

  /// Accepts using [plan] (from [planFor] or [defaultPlan]). Conflicting files
  /// without an action use [applyToAll] or the settings default.
  Future<void> accept(DestinationPlan plan, {ConflictAction? applyToAll}) =>
      _receiver._accept(task, plan, applyToAll: applyToAll);

  Future<void> reject() => _receiver._reject(task, 'rejected');
}

class OfferResult {
  const OfferResult(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}

/// Receiver side of the transfer protocol: validates offers, asks the user,
/// writes uploads to staging, verifies digests and moves files into place.
class TransferReceiver {
  TransferReceiver({
    required this.settings,
    required this.trustedDevices,
    required this.destinations,
    required this.checksums,
    required this.history,
    required this.inboxDirectory,
    this.decisionTimeout = const Duration(minutes: 10),
    this.disconnectGrace = const Duration(seconds: 8),
  });

  final AppSettings Function() settings;
  final TrustedDeviceStore trustedDevices;
  final DestinationManager destinations;
  final ChecksumService checksums;
  final TransferHistoryService history;
  final String inboxDirectory;
  final Duration decisionTimeout;
  final Duration disconnectGrace;

  final Map<String, IncomingTransfer> _transfers = {};
  final _requests = StreamController<IncomingRequest>.broadcast();
  final _added = StreamController<IncomingTransfer>.broadcast();
  final _finished = StreamController<IncomingTransfer>.broadcast();

  /// Transfers waiting for the user to accept/reject.
  Stream<IncomingRequest> get requests => _requests.stream;
  Stream<IncomingTransfer> get added => _added.stream;

  /// Fires when a transfer reaches completed/cancelled/failed.
  Stream<IncomingTransfer> get finished => _finished.stream;

  List<IncomingTransfer> get transfers => _transfers.values.toList();
  IncomingTransfer? operator [](String id) => _transfers[id];

  // ---------------------------------------------------------------------
  // Persistence (resume across restarts)

  final Map<String, JsonFileStore> _inboxStores = {};

  JsonFileStore _inbox(String id) => _inboxStores.putIfAbsent(
    id,
    () => JsonFileStore(p.join(inboxDirectory, '$id.json')),
  );

  Future<void> _persist(IncomingTransfer t) async {
    final plan = t.plan;
    if (plan == null) return;
    await _inbox(t.id).write({
      'manifest': t.manifest.toJson(),
      'peer': t.peer.toJson(),
      'startedAt': t.startedAt.toIso8601String(),
      'plan': plan.files.values.map((f) => f.toJson()).toList(),
      'files': {
        for (final f in t.files.values)
          f.file.id: {'state': f.state.name, 'savedPath': f.savedPath},
      },
    });
  }

  Future<void> _deleteInbox(String id) async {
    await _inboxStores.remove(id)?.flush();
    try {
      await File(p.join(inboxDirectory, '$id.json')).delete();
    } catch (_) {}
  }

  /// Restores accepted-but-unfinished transfers so senders can resume them.
  Future<void> loadInbox() async {
    final dir = Directory(inboxDirectory);
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString()) as Map;
        final manifest = TransferManifest.fromJson(
          (json['manifest'] as Map).cast(),
        );
        final peer = DeviceInfo.fromJson((json['peer'] as Map).cast());
        final t = IncomingTransfer(
          manifest: manifest,
          peer: peer,
          startedAt: DateTime.parse(json['startedAt'] as String),
        );
        final planned = <String, PlannedFile>{};
        for (final raw in (json['plan'] as List).cast<Map>()) {
          final file = manifest.files.firstWhere((f) => f.id == raw['id']);
          final root = raw['root'] as String;
          // Re-validate: never trust persisted paths blindly.
          final target = PathSafety.resolveInside(root, file.path);
          planned[file.id] = PlannedFile(file: file, root: root, target: target)
            ..action = ConflictAction.values
                .where((a) => a.name == raw['action'])
                .firstOrNull;
        }
        t.plan = DestinationPlan(planned);
        t.destinationLabel = t.plan!.label;
        final states = (json['files'] as Map).cast<String, Object?>();
        for (final e in states.entries) {
          final s = (e.value as Map).cast<String, Object?>();
          final fp = t.files[e.key];
          if (fp == null) continue;
          fp.state = FileTransferState.parse(s['state']);
          fp.savedPath = s['savedPath'] as String?;
          if (fp.state.isFinished) fp.transferred = fp.file.size;
          if (fp.state == FileTransferState.transferring ||
              fp.state == FileTransferState.verifying) {
            fp.state = FileTransferState.queued;
          }
        }
        for (final f in planned.values) {
          if (t.files[f.file.id]!.state.isFinished) continue;
          final partial = PartialFile(
            stagingDir: destinations.stagingDir(f.root, t.id),
            fileId: f.file.id,
            size: f.file.size,
            checksums: checksums,
          );
          t.partials[f.file.id] = partial;
          t.files[f.file.id]!.transferred = await partial.prepare();
        }
        t.setStatus(
          TransferStatus.failed,
          error: const LanBeamException(FailureKind.connectionLost),
        );
        _transfers[t.id] = t;
      } catch (_) {
        // Unreadable inbox entry: drop it.
        await entity.delete().catchError((_) => entity);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Protocol handlers

  IncomingTransfer _get(String deviceId, String id) {
    final t = _transfers[id];
    if (t == null || t.peer.id != deviceId) {
      throw ApiError(ErrorCodes.notFound, 'Unknown transfer');
    }
    return t;
  }

  void checkAccess(String deviceId, String id) => _get(deviceId, id);

  Future<OfferResult> handleOffer(
    String deviceId,
    Map<String, Object?> body,
  ) async {
    final manifest = TransferManifest.fromJson(body);
    final trusted = trustedDevices.get(deviceId);
    if (trusted == null) throw ApiError(ErrorCodes.forbidden);

    final existing = _transfers[manifest.transferId];
    if (existing != null) {
      if (existing.peer.id != deviceId) throw ApiError(ErrorCodes.forbidden);
      if (!_sameManifest(existing.manifest, manifest)) {
        throw ApiError(ErrorCodes.badRequest, 'Manifest changed');
      }
      switch (existing.status) {
        case TransferStatus.rejected:
          throw ApiError(ErrorCodes.rejected, 'Transfer was declined');
        case TransferStatus.cancelled:
          throw ApiError(ErrorCodes.gone, 'Transfer was cancelled');
        case TransferStatus.completed:
          return OfferResult(200, _decisionBody(existing));
        default:
          if (!existing.isAccepted) {
            return OfferResult(202, {
              'transferId': existing.id,
              'state': 'pending',
            });
          }
          // Resume of a known transfer: no new approval needed.
          if (!existing.localPaused) existing.setStatus(TransferStatus.active);
          existing.pausedRemotely = false;
          await _refreshOffsets(existing);
          return OfferResult(200, _decisionBody(existing));
      }
    }

    final t = IncomingTransfer(manifest: manifest, peer: trusted.info);
    _transfers[t.id] = t;
    _added.add(t);

    final s = settings();
    DestinationPlan? plan;
    try {
      plan = await _buildPlan(t);
    } on FormatException {
      _transfers.remove(t.id);
      rethrow;
    } on PathTraversalException catch (e) {
      _transfers.remove(t.id);
      throw ApiError(ErrorCodes.badRequest, e.message);
    } on LanBeamException {
      plan = null; // destination unavailable: the user must choose
    }

    final autoAccept =
        (trusted.autoAccept ?? s.autoAcceptTrusted) &&
        (s.useDestinationRules || !s.askWhereToSave) &&
        plan != null &&
        (plan.conflicts.isEmpty || s.conflictPolicy != ConflictPolicy.ask);

    if (autoAccept) {
      await _accept(t, plan);
      return OfferResult(200, _decisionBody(t));
    }

    t.setStatus(TransferStatus.awaitingApproval);
    t._decisionTimeout = Timer(decisionTimeout, () {
      if (!t.isAccepted && t.status == TransferStatus.awaitingApproval) {
        unawaited(_reject(t, 'timeout'));
      }
    });
    _requests.add(IncomingRequest(this, t, plan));
    return OfferResult(202, {'transferId': t.id, 'state': 'pending'});
  }

  bool _sameManifest(TransferManifest a, TransferManifest b) {
    if (a.files.length != b.files.length) return false;
    for (var i = 0; i < a.files.length; i++) {
      final x = a.files[i], y = b.files[i];
      if (x.id != y.id || x.path != y.path || x.size != y.size) return false;
    }
    return true;
  }

  Future<DestinationPlan> _buildPlan(
    IncomingTransfer t, {
    String? overrideRoot,
  }) async {
    final plan = destinations.plan(
      t.manifest,
      settings(),
      overrideRoot: overrideRoot,
    );
    await destinations.prepare(plan);
    final policy = settings().conflictPolicy;
    if (policy != ConflictPolicy.ask) {
      plan.resolveAll(switch (policy) {
        ConflictPolicy.replace => ConflictAction.replace,
        ConflictPolicy.skip => ConflictAction.skip,
        _ => ConflictAction.rename,
      });
    }
    return plan;
  }

  Future<void> _accept(
    IncomingTransfer t,
    DestinationPlan plan, {
    ConflictAction? applyToAll,
  }) async {
    if (t.isAccepted || t.status.isFinal) return;
    t._decisionTimeout?.cancel();
    for (final f in plan.conflicts) {
      f.action ??= applyToAll ?? ConflictAction.rename;
    }
    for (final root in plan.roots) {
      await destinations.ensureWritable(root);
    }
    for (final planned in plan.files.values) {
      final id = planned.file.id;
      if (planned.conflict && planned.action == ConflictAction.skip) {
        t.setFileState(id, FileTransferState.skipped);
        continue;
      }
      final partial = PartialFile(
        stagingDir: destinations.stagingDir(planned.root, t.id),
        fileId: id,
        size: planned.file.size,
        checksums: checksums,
      );
      t.partials[id] = partial;
      t.files[id]!.transferred = await partial.prepare();
    }
    t.plan = plan;
    t.destinationLabel = plan.label;
    t.setStatus(TransferStatus.active);
    await _persist(t);
    _broadcast(t, _decisionEvent(t));
    if (t.allFilesFinished) await _complete(t);
  }

  Future<void> _reject(IncomingTransfer t, String reason) async {
    if (t.isAccepted || t.status.isFinal) return;
    t._decisionTimeout?.cancel();
    t.setStatus(TransferStatus.rejected);
    _broadcast(t, {'type': 'decision', 'accepted': false, 'reason': reason});
    await history.record(t.toHistory());
    _finished.add(t);
  }

  Future<void> _refreshOffsets(IncomingTransfer t) async {
    for (final e in t.partials.entries) {
      final fp = t.files[e.key]!;
      if (fp.state.isFinished) continue;
      fp.transferred = await e.value.prepare();
    }
  }

  Map<String, Object?> _decisionBody(IncomingTransfer t) => {
    'transferId': t.id,
    'state': t.status == TransferStatus.completed ? 'completed' : 'accepted',
    'files': _fileOffsets(t),
  };

  Map<String, Object?> _decisionEvent(IncomingTransfer t) => {
    'type': 'decision',
    'accepted': true,
    'files': _fileOffsets(t),
  };

  Map<String, Object?> _fileOffsets(IncomingTransfer t) => {
    for (final f in t.files.values)
      f.file.id: {
        'offset': f.state.isFinished
            ? f.file.size
            : (t.partials[f.file.id]?.committed ?? 0),
        'skip': f.state == FileTransferState.skipped,
        'state': f.state.name,
      },
  };

  Map<String, Object?> statusOf(
    String deviceId,
    String id, {
    bool allowFinished = false,
  }) {
    final t = _get(deviceId, id);
    return {
      'transferId': t.id,
      'state': switch (t.status) {
        TransferStatus.awaitingApproval || TransferStatus.pending => 'pending',
        TransferStatus.paused => 'paused',
        TransferStatus.completed => 'completed',
        TransferStatus.cancelled => 'cancelled',
        TransferStatus.rejected => 'rejected',
        _ => 'accepted',
      },
      'paused': t.localPaused,
      if (t.isAccepted) 'files': _fileOffsets(t),
    };
  }

  Future<int> handleUpload(
    String deviceId,
    String id,
    String fileId,
    int offset,
    Stream<List<int>> body,
  ) async {
    final t = _get(deviceId, id);
    switch (t.status) {
      case TransferStatus.cancelled:
        throw ApiError(ErrorCodes.gone);
      case TransferStatus.rejected:
        throw ApiError(ErrorCodes.rejected);
      case TransferStatus.completed:
        throw ApiError(ErrorCodes.gone, 'Transfer already completed');
      default:
    }
    if (!t.isAccepted) throw ApiError(ErrorCodes.forbidden, 'Not accepted yet');
    if (t.localPaused) throw ApiError(ErrorCodes.paused);
    final partial = t.partials[fileId];
    if (partial == null) throw ApiError(ErrorCodes.notFound, 'Unknown file');
    if (t.files[fileId]!.state.isFinished) {
      throw ApiError(ErrorCodes.offsetMismatch, null, {'offset': partial.size});
    }

    if (t.status != TransferStatus.active) t.setStatus(TransferStatus.active);
    t.pausedRemotely = false;
    t._disconnectTimer?.cancel();
    t._activeUploads++;
    t.setFileState(fileId, FileTransferState.transferring, transferred: offset);
    try {
      final committed = await partial.write(
        body,
        offset,
        onBytes: (n) => t.addProgress(fileId, n),
        shouldStop: () => t.status == TransferStatus.cancelled
            ? 'cancelled'
            : t.localPaused
            ? 'paused'
            : null,
      );
      t.setFileState(
        fileId,
        FileTransferState.verifying,
        transferred: committed,
      );
      return committed;
    } on OffsetMismatch catch (e) {
      t.setFileState(fileId, FileTransferState.queued, transferred: e.expected);
      throw ApiError(ErrorCodes.offsetMismatch, null, {'offset': e.expected});
    } on UploadInterrupted catch (e) {
      t.setFileState(
        fileId,
        FileTransferState.queued,
        transferred: partial.committed,
      );
      if (e.reason == 'cancelled') throw ApiError(ErrorCodes.gone);
      if (e.reason == 'paused') throw ApiError(ErrorCodes.paused);
      throw ApiError(ErrorCodes.badRequest, e.reason);
    } on FileSystemException catch (e) {
      final err = classifyError(e);
      t.setFileState(
        fileId,
        FileTransferState.failed,
        error: err.userMessage,
        transferred: partial.committed,
      );
      if (err.kind == FailureKind.diskFull) {
        t.setStatus(TransferStatus.failed, error: err);
        _broadcast(t, {
          'type': 'error',
          'error': ErrorCodes.diskFull,
          'message': err.userMessage,
        });
        throw ApiError(ErrorCodes.diskFull, err.userMessage);
      }
      throw err;
    } catch (e) {
      // Connection dropped mid-upload; committed data is kept for resume.
      t.setFileState(
        fileId,
        FileTransferState.queued,
        transferred: partial.committed,
      );
      rethrow;
    } finally {
      t._activeUploads--;
      _scheduleDisconnectCheck(t);
    }
  }

  Future<String> handleComplete(
    String deviceId,
    String id,
    String fileId,
    String digest,
  ) async {
    final t = _get(deviceId, id);
    if (t.status == TransferStatus.cancelled) throw ApiError(ErrorCodes.gone);
    final fp = t.files[fileId];
    final planned = t.plan?.files[fileId];
    if (fp == null || planned == null) throw ApiError(ErrorCodes.notFound);
    if (fp.state == FileTransferState.done)
      return p.basename(fp.savedPath ?? fp.file.name);
    final partial = t.partials[fileId];
    if (partial == null) throw ApiError(ErrorCodes.notFound);
    if (!partial.isComplete) {
      throw ApiError(ErrorCodes.offsetMismatch, null, {
        'offset': partial.committed,
      });
    }
    final ours = await partial.digest();
    if (!constantTimeEquals(ours, digest.toLowerCase())) {
      await partial.discard();
      await partial.prepare();
      t.setFileState(fileId, FileTransferState.queued, transferred: 0);
      throw ApiError(ErrorCodes.checksumMismatch, 'Checksum mismatch');
    }
    final String saved;
    try {
      saved = await destinations.finalize(
        partial.partPath,
        planned,
        modified: fp.file.modified,
      );
    } on PathTraversalException catch (e) {
      throw ApiError(ErrorCodes.forbidden, e.message);
    } on FileSystemException catch (e) {
      throw classifyError(e);
    }
    await partial.discard();
    t.partials.remove(fileId);
    fp.savedPath = saved;
    t.setFileState(fileId, FileTransferState.done, transferred: fp.file.size);
    _broadcast(t, {'type': 'file', 'fileId': fileId, 'state': 'verified'});
    await _persist(t);
    if (t.allFilesFinished) await _complete(t);
    return p.basename(saved);
  }

  Future<void> _complete(IncomingTransfer t) async {
    if (t.status == TransferStatus.completed) return;
    t.setStatus(TransferStatus.completed);
    _broadcast(t, {'type': 'completed'});
    await destinations.cleanupStaging(t.plan?.roots ?? const [], t.id);
    await _deleteInbox(t.id);
    await history.record(t.toHistory());
    _finished.add(t);
  }

  Future<void> handleCommand(String deviceId, String id, String command) async {
    final t = _get(deviceId, id);
    switch (command) {
      case 'pause':
        if (!t.status.isFinal) {
          t.pausedRemotely = true;
          t.setStatus(TransferStatus.paused);
        }
      case 'resume':
        if (t.status == TransferStatus.paused ||
            t.status == TransferStatus.failed) {
          t.pausedRemotely = false;
          if (!t.localPaused) t.setStatus(TransferStatus.active);
        }
      case 'cancel':
        await _cancel(t, notifyPeer: false);
      case 'finish':
        if (t.isAccepted && t.allFilesFinished) await _complete(t);
    }
  }

  // ---------------------------------------------------------------------
  // Local user controls

  void pause(String id) {
    final t = _transfers[id];
    if (t == null || t.status.isFinal || !t.isAccepted) return;
    t.localPaused = true;
    t.setStatus(TransferStatus.paused);
    _broadcast(t, {'type': 'paused'});
  }

  void resume(String id) {
    final t = _transfers[id];
    if (t == null || !t.localPaused) return;
    t.localPaused = false;
    t.setStatus(
      t.pausedRemotely ? TransferStatus.paused : TransferStatus.active,
    );
    _broadcast(t, {'type': 'resumed'});
  }

  Future<void> cancel(String id) async {
    final t = _transfers[id];
    if (t == null) return;
    if (!t.isAccepted && t.status == TransferStatus.awaitingApproval) {
      return _reject(t, 'rejected');
    }
    await _cancel(t, notifyPeer: true);
  }

  Future<void> _cancel(IncomingTransfer t, {required bool notifyPeer}) async {
    if (t.status.isFinal) return;
    t._decisionTimeout?.cancel();
    t.setStatus(TransferStatus.cancelled);
    if (notifyPeer) _broadcast(t, {'type': 'cancelled', 'by': 'receiver'});
    // Give in-flight uploads a moment to observe the cancellation.
    for (var i = 0; i < 20 && t._activeUploads > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    for (final partial in t.partials.values) {
      await partial.discard();
    }
    await destinations.cleanupStaging(t.plan?.roots ?? const [], t.id);
    await _deleteInbox(t.id);
    await history.record(t.toHistory());
    _finished.add(t);
  }

  /// Removes a finished transfer from the active list.
  void dismiss(String id) {
    final t = _transfers[id];
    if (t != null && !t.status.isRunning && t.status != TransferStatus.paused) {
      _transfers.remove(id);
    }
  }

  // ---------------------------------------------------------------------
  // Events

  void attachEvents(String deviceId, String id, WebSocket socket) {
    final t = _get(deviceId, id);
    t._sockets.add(socket);
    t._disconnectTimer?.cancel();
    if (t.isAccepted) socket.add(jsonEncode(_decisionEvent(t)));
    if (t.status == TransferStatus.rejected) {
      socket.add(
        jsonEncode({
          'type': 'decision',
          'accepted': false,
          'reason': 'rejected',
        }),
      );
    }
    if (t.localPaused) socket.add(jsonEncode({'type': 'paused'}));
    if (t.status == TransferStatus.cancelled) {
      socket.add(jsonEncode({'type': 'cancelled', 'by': 'receiver'}));
    }
    socket.listen(
      (data) {
        if (data is! String || data.length > 4096) return;
        try {
          final msg = jsonDecode(data);
          final type = msg is Map ? msg['type'] : null;
          if (type is String &&
              const {'pause', 'resume', 'cancel'}.contains(type)) {
            unawaited(handleCommand(deviceId, id, type));
          }
        } catch (_) {}
      },
      onDone: () {
        t._sockets.remove(socket);
        _scheduleDisconnectCheck(t);
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  /// When the sender disappears (no uploads, no event channel) mark the
  /// transfer interrupted; it stays resumable.
  void _scheduleDisconnectCheck(IncomingTransfer t) {
    t._disconnectTimer?.cancel();
    if (t._sockets.isNotEmpty || t._activeUploads > 0) return;
    t._disconnectTimer = Timer(disconnectGrace, () {
      if (t._sockets.isEmpty &&
          t._activeUploads == 0 &&
          t.isAccepted &&
          (t.status == TransferStatus.active ||
              (t.status == TransferStatus.paused && t.pausedRemotely))) {
        t.setStatus(
          TransferStatus.failed,
          error: const LanBeamException(FailureKind.connectionLost),
        );
      }
    });
  }

  void _broadcast(IncomingTransfer t, Map<String, Object?> event) {
    final data = jsonEncode(event);
    for (final s in List.of(t._sockets)) {
      try {
        s.add(data);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    for (final s in _inboxStores.values) {
      await s.flush();
    }
    for (final t in _transfers.values) {
      t._decisionTimeout?.cancel();
      t._disconnectTimer?.cancel();
      for (final s in t._sockets) {
        await s.close().catchError((_) {});
      }
    }
    await _requests.close();
    await _added.close();
    await _finished.close();
  }
}
