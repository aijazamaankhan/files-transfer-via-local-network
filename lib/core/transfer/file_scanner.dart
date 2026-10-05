import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/transfer_models.dart';
import '../util/errors.dart';
import 'file_source.dart';

/// A file selected for sending, with its manifest metadata.
class OutgoingFile {
  OutgoingFile({
    required this.id,
    required this.relativePath,
    required this.source,
    required this.size,
    this.modified,
    this.mime,
  });

  final String id;
  final String relativePath;
  final FileSource source;
  final int size;
  final DateTime? modified;
  final String? mime;

  ManifestFile toManifest() => ManifestFile(
    id: id,
    path: relativePath,
    size: size,
    modified: modified,
    mime: mime,
  );
}

/// Something the user picked: a single file, or a folder to send recursively.
sealed class SendSelection {
  const SendSelection();
}

class FileSelection extends SendSelection {
  const FileSelection(this.source, this.name, {this.size, this.modified, this.mime});
  final FileSource source;
  final String name;
  final int? size;
  final DateTime? modified;
  final String? mime;
}

class LocalPathSelection extends SendSelection {
  const LocalPathSelection(this.path);
  final String path;
}

/// Pre-enumerated tree (e.g. Android SAF): relative paths already computed.
class TreeSelection extends SendSelection {
  const TreeSelection(this.rootName, this.entries);
  final String rootName;
  final List<FileSelection> entries; // names are paths relative to the root
}

class ScanResult {
  const ScanResult(this.files, this.kind, {this.skipped = 0});
  final List<OutgoingFile> files;
  final TransferKind kind;

  /// Entries skipped (symlinks, unreadable, special files).
  final int skipped;

  int get totalSize => files.fold(0, (a, f) => a + f.size);
}

/// Expands user selections into a flat list of files with relative paths
/// that preserve folder structure. Never follows symlinks (avoids loops and
/// accidentally sending files outside the chosen folder).
class FileScanner {
  Future<ScanResult> scan(List<SendSelection> selections) async {
    final files = <OutgoingFile>[];
    final usedPaths = <String>{};
    var skipped = 0;
    var folders = 0;
    var loose = 0;
    var nextId = 0;

    String uniqueRelative(String rel) {
      var candidate = rel;
      var n = 1;
      while (!usedPaths.add(candidate.toLowerCase())) {
        final dir = p.posix.dirname(rel);
        final base = p.posix.basename(rel);
        final ext = p.posix.extension(base);
        final stem = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
        final name = '$stem ($n)$ext';
        candidate = dir == '.' ? name : '$dir/$name';
        n++;
      }
      return candidate;
    }

    void add(FileSource source, String rel, int size, DateTime? modified, String? mime) {
      files.add(
        OutgoingFile(
          id: 'f${nextId++}',
          relativePath: uniqueRelative(rel),
          source: source,
          size: size,
          modified: modified,
          mime: mime,
        ),
      );
    }

    for (final sel in selections) {
      switch (sel) {
        case FileSelection():
          final st = (sel.size == null) ? await sel.source.stat() : null;
          add(sel.source, _cleanName(sel.name), sel.size ?? st!.size,
              sel.modified ?? st?.modified, sel.mime);
          loose++;
        case TreeSelection():
          folders++;
          final root = _cleanName(sel.rootName);
          for (final e in sel.entries) {
            final st = (e.size == null) ? await e.source.stat() : null;
            final rel = e.name.split('/').map(_cleanName).join('/');
            add(e.source, '$root/$rel', e.size ?? st!.size,
                e.modified ?? st?.modified, e.mime);
          }
        case LocalPathSelection():
          final type = await FileSystemEntity.type(sel.path, followLinks: false);
          switch (type) {
            case FileSystemEntityType.file:
              final st = await File(sel.path).stat();
              add(LocalFileSource(sel.path), _cleanName(p.basename(sel.path)),
                  st.size, st.modified, null);
              loose++;
            case FileSystemEntityType.directory:
              folders++;
              final rootName = _cleanName(p.basename(p.normalize(sel.path)));
              try {
                await for (final entity
                    in Directory(sel.path).list(recursive: true, followLinks: false)) {
                  if (entity is! File) {
                    if (entity is Link) skipped++;
                    continue;
                  }
                  try {
                    final st = await entity.stat();
                    final rel = p
                        .split(p.relative(entity.path, from: sel.path))
                        .map(_cleanName)
                        .join('/');
                    add(LocalFileSource(entity.path), '$rootName/$rel', st.size,
                        st.modified, null);
                  } on FileSystemException {
                    skipped++;
                  }
                }
              } on FileSystemException catch (e) {
                throw classifyError(e);
              }
            case FileSystemEntityType.notFound:
              throw LanBeamException(FailureKind.fileMissing, sel.path);
            default:
              skipped++;
          }
      }
    }
    final kind = folders > 0 && loose == 0
        ? TransferKind.folder
        : folders > 0
        ? TransferKind.mixed
        : TransferKind.files;
    return ScanResult(files, kind, skipped: skipped);
  }

  /// Senders must never emit separators or traversal segments inside a name.
  static String _cleanName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return '_';
    return cleaned;
  }
}
