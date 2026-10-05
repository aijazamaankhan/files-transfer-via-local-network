import 'transfer_models.dart';

/// One entry of the local transfer history.
class HistoryRecord {
  const HistoryRecord({
    required this.transferId,
    required this.direction,
    required this.peerId,
    required this.peerName,
    required this.title,
    required this.fileCount,
    required this.totalBytes,
    required this.transferredBytes,
    required this.status,
    required this.startedAt,
    this.finishedAt,
    this.error,
    this.destination,
    this.resumable = false,
    this.resumeData,
  });

  final String transferId;
  final TransferDirection direction;
  final String peerId;
  final String peerName;
  final String title;
  final int fileCount;
  final int totalBytes;
  final int transferredBytes;
  final TransferStatus status;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? error;

  /// Incoming: folder the files were saved to.
  final String? destination;

  /// Outgoing failed/paused transfers that can be retried after restart.
  final bool resumable;

  /// Outgoing: manifest and serialized sources needed to resume after an
  /// app restart (paths or content URIs). Stays on this device.
  final Map<String, Object?>? resumeData;

  Duration? get duration => finishedAt?.difference(startedAt);

  Map<String, Object?> toJson() => {
    'transferId': transferId,
    'direction': direction.name,
    'peerId': peerId,
    'peerName': peerName,
    'title': title,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    'transferredBytes': transferredBytes,
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'error': error,
    'destination': destination,
    'resumable': resumable,
    'resumeData': resumeData,
  };

  factory HistoryRecord.fromJson(Map<String, Object?> j) => HistoryRecord(
    transferId: j['transferId'] as String,
    direction: TransferDirection.values.byName(j['direction'] as String),
    peerId: j['peerId'] as String,
    peerName: j['peerName'] as String,
    title: j['title'] as String,
    fileCount: j['fileCount'] as int,
    totalBytes: j['totalBytes'] as int,
    transferredBytes: (j['transferredBytes'] as int?) ?? 0,
    status: TransferStatus.parse(j['status']),
    startedAt: DateTime.parse(j['startedAt'] as String),
    finishedAt: j['finishedAt'] == null
        ? null
        : DateTime.parse(j['finishedAt'] as String),
    error: j['error'] as String?,
    destination: j['destination'] as String?,
    resumable: (j['resumable'] as bool?) ?? false,
    resumeData: (j['resumeData'] as Map?)?.cast<String, Object?>(),
  );
}
