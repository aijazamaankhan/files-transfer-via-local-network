import '../protocol/protocol.dart';
import '../security/path_safety.dart';

enum TransferDirection { outgoing, incoming }

enum TransferStatus {
  /// Outgoing: scanning / connecting. Incoming: waiting for the user.
  pending,
  awaitingApproval,
  active,
  paused,
  completed,
  failed,
  cancelled,
  rejected;

  bool get isFinal =>
      this == completed || this == cancelled || this == rejected;

  bool get isRunning => this == pending || this == awaitingApproval || this == active;

  static TransferStatus parse(Object? v) => TransferStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => failed,
  );
}

enum FileTransferState {
  queued,
  transferring,
  verifying,
  done,
  skipped,
  failed;

  bool get isFinished => this == done || this == skipped;

  static FileTransferState parse(Object? v) => FileTransferState.values
      .firstWhere((e) => e.name == v, orElse: () => queued);
}

enum TransferKind {
  files,
  folder,
  mixed;

  static TransferKind parse(Object? v) =>
      TransferKind.values.firstWhere((e) => e.name == v, orElse: () => files);
}

/// One file in a transfer manifest. [path] is relative, `/`-separated.
class ManifestFile {
  const ManifestFile({
    required this.id,
    required this.path,
    required this.size,
    this.modified,
    this.mime,
  });

  final String id;
  final String path;
  final int size;
  final DateTime? modified;
  final String? mime;

  String get name => path.split('/').last;

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'size': size,
    if (modified != null) 'modified': modified!.millisecondsSinceEpoch,
    if (mime != null) 'mime': mime,
  };

  /// Parses and validates untrusted input.
  factory ManifestFile.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final path = json['path'];
    final size = json['size'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('invalid file id');
    }
    if (path is! String) throw const FormatException('invalid path');
    PathSafety.validateRelativePath(path);
    if (size is! int || size < 0) throw const FormatException('invalid size');
    final modified = json['modified'];
    final mime = json['mime'];
    return ManifestFile(
      id: id,
      path: path,
      size: size,
      modified: modified is int
          ? DateTime.fromMillisecondsSinceEpoch(modified)
          : null,
      mime: mime is String && mime.length < 128 ? mime : null,
    );
  }
}

/// Description of everything a sender proposes to send.
class TransferManifest {
  TransferManifest({
    required this.transferId,
    required this.kind,
    required this.files,
  });

  final String transferId;
  final TransferKind kind;
  final List<ManifestFile> files;

  int get totalSize => files.fold(0, (a, f) => a + f.size);

  /// Display title: the folder name for folder transfers, the file name for a
  /// single file, otherwise "N files".
  String get title {
    if (files.isEmpty) return 'Empty transfer';
    final roots = files.map((f) => f.path.split('/').first).toSet();
    if (roots.length == 1 && files.first.path.contains('/')) return roots.first;
    if (files.length == 1) return files.first.name;
    return '${files.length} files';
  }

  Map<String, Object?> toJson() => {
    'transferId': transferId,
    'kind': kind.name,
    'totalSize': totalSize,
    'files': files.map((f) => f.toJson()).toList(),
  };

  factory TransferManifest.fromJson(Map<String, Object?> json) {
    final id = json['transferId'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) {
      throw const FormatException('invalid transferId');
    }
    final rawFiles = json['files'];
    if (rawFiles is! List) throw const FormatException('files missing');
    if (rawFiles.length > Protocol.maxManifestFiles) {
      throw const FormatException('too many files');
    }
    final files = <ManifestFile>[];
    final ids = <String>{};
    final paths = <String>{};
    for (final raw in rawFiles) {
      if (raw is! Map) throw const FormatException('invalid file entry');
      final f = ManifestFile.fromJson(raw.cast<String, Object?>());
      if (!ids.add(f.id)) throw const FormatException('duplicate file id');
      if (!paths.add(f.path.toLowerCase())) {
        throw const FormatException('duplicate path');
      }
      files.add(f);
    }
    return TransferManifest(
      transferId: id,
      kind: TransferKind.parse(json['kind']),
      files: files,
    );
  }
}
