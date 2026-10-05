import '../models/device_info.dart';
import '../models/history_record.dart';
import '../models/transfer_models.dart';
import '../util/errors.dart';
import '../util/notifier.dart';
import '../util/speed_meter.dart';

/// Per-file progress inside a [TransferTask].
class FileProgress {
  FileProgress(this.file);
  final ManifestFile file;
  int transferred = 0;
  FileTransferState state = FileTransferState.queued;
  String? error;

  /// Incoming: final saved path.
  String? savedPath;
}

/// Observable state of one transfer, shared by the sender and receiver
/// implementations and rendered by the UI.
class TransferTask extends ThrottledNotifier {
  TransferTask({
    required this.manifest,
    required this.direction,
    required this.peer,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now(),
       files = {for (final f in manifest.files) f.id: FileProgress(f)};

  final TransferManifest manifest;
  final TransferDirection direction;
  DeviceInfo peer;
  final DateTime startedAt;
  final Map<String, FileProgress> files;
  final SpeedMeter speed = SpeedMeter();

  TransferStatus _status = TransferStatus.pending;
  LanBeamException? error;
  DateTime? finishedAt;

  /// Paused by the remote side (as opposed to locally).
  bool pausedRemotely = false;

  /// Incoming: human-readable destination (folder path).
  String? destinationLabel;

  String get id => manifest.transferId;
  String get title => manifest.title;
  int get totalBytes => manifest.totalSize;
  TransferStatus get status => _status;

  int get transferredBytes => files.values.fold(0, (a, f) => a + f.transferred);

  /// Bytes that still need to cross the network (skipped files excluded).
  int get remainingBytes => files.values
      .where((f) => f.state != FileTransferState.skipped)
      .fold(0, (a, f) => a + (f.file.size - f.transferred));

  double get progress {
    final effective = files.values
        .where((f) => f.state != FileTransferState.skipped)
        .fold(0, (a, f) => a + f.file.size);
    if (effective == 0) {
      return status == TransferStatus.completed ? 1 : 0;
    }
    return (transferredBytes / effective).clamp(0, 1).toDouble();
  }

  double get bytesPerSecond =>
      status == TransferStatus.active ? speed.bytesPerSecond : 0;

  Duration? get eta =>
      status == TransferStatus.active ? speed.eta(remainingBytes) : null;

  int get completedFiles =>
      files.values.where((f) => f.state.isFinished).length;

  /// File currently in flight (for single-line UI display).
  FileProgress? get currentFile => files.values
      .where((f) => f.state == FileTransferState.transferring)
      .firstOrNull;

  void setStatus(TransferStatus s, {LanBeamException? error}) {
    if (_status == s && error == null) return;
    _status = s;
    if (error != null) this.error = error;
    if (s == TransferStatus.active) {
      this.error = null;
      speed.resetWindow();
    }
    if (s.isFinal || s == TransferStatus.failed) {
      finishedAt = DateTime.now();
    } else {
      finishedAt = null;
    }
    notifyNow();
  }

  /// Records [bytes] of progress for [fileId].
  void addProgress(String fileId, int bytes) {
    final f = files[fileId];
    if (f == null) return;
    f.transferred += bytes;
    speed.add(bytes);
    markDirty();
  }

  void setFileState(
    String fileId,
    FileTransferState s, {
    String? error,
    int? transferred,
  }) {
    final f = files[fileId];
    if (f == null) return;
    f.state = s;
    f.error = error;
    if (transferred != null) f.transferred = transferred;
    markDirty();
  }

  HistoryRecord toHistory({
    bool resumable = false,
    Map<String, Object?>? resumeData,
  }) => HistoryRecord(
    transferId: id,
    direction: direction,
    peerId: peer.id,
    peerName: peer.name,
    title: title,
    fileCount: files.length,
    totalBytes: totalBytes,
    transferredBytes: transferredBytes,
    status: status,
    startedAt: startedAt,
    finishedAt: finishedAt ?? (status.isRunning ? null : DateTime.now()),
    error: error?.userMessage,
    destination: destinationLabel,
    resumable: resumable,
    resumeData: resumeData,
  );
}
