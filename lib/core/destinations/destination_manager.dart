import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/settings.dart';
import '../models/transfer_models.dart';
import '../security/path_safety.dart';
import '../util/errors.dart';
import 'file_category.dart';

enum ConflictAction { replace, skip, rename }

/// Where one incoming file will be stored.
class PlannedFile {
  PlannedFile({required this.file, required this.root, required this.target});

  final ManifestFile file;

  /// Approved destination root this file must stay inside.
  final String root;

  /// Sanitized absolute target path (inside [root]).
  final String target;

  bool conflict = false;
  ConflictAction? action;

  Map<String, Object?> toJson() => {
    'id': file.id,
    'root': root,
    'target': target,
    'action': action?.name,
  };
}

class DestinationPlan {
  DestinationPlan(this.files);
  final Map<String, PlannedFile> files;

  List<PlannedFile> get conflicts =>
      files.values.where((f) => f.conflict).toList();

  Set<String> get roots => files.values.map((f) => f.root).toSet();

  /// Short label for UI ("~/Downloads" or "3 folders").
  String get label {
    final r = roots;
    if (r.isEmpty) return '';
    if (r.length == 1) return r.first;
    return '${r.length} folders (by file type)';
  }

  /// Applies a single action to every conflicting file ("Apply to all").
  void resolveAll(ConflictAction action) {
    for (final f in conflicts) {
      f.action = action;
    }
  }
}

/// Decides destination folders by rule, validates them, detects conflicts and
/// moves verified files into place.
class DestinationManager {
  DestinationManager();

  static const stagingDirName = '.lanbeam-partial';

  /// Computes target paths for [manifest].
  ///
  /// If [overrideRoot] is given every file goes there (folder structure kept).
  /// Otherwise rules (when enabled) route by category, falling back to the
  /// default download directory. Throws [FormatException]/[PathTraversalException]
  /// for unsafe paths.
  DestinationPlan plan(
    TransferManifest manifest,
    AppSettings settings, {
    String? overrideRoot,
  }) {
    final files = <String, PlannedFile>{};
    for (final f in manifest.files) {
      final root = overrideRoot ?? rootFor(f, settings);
      final target = PathSafety.resolveInside(root, f.path);
      files[f.id] = PlannedFile(
        file: f,
        root: p.normalize(p.absolute(root)),
        target: target,
      );
    }
    return DestinationPlan(files);
  }

  String rootFor(ManifestFile f, AppSettings settings) {
    if (!settings.useDestinationRules) return settings.downloadDirectory;
    final category = f.path.contains('/')
        ? FileCategory.folders
        : FileCategory.forPath(f.path, mime: f.mime);
    final rule = settings.destinationRules[category];
    return (rule == null || rule.isEmpty) ? settings.downloadDirectory : rule;
  }

  /// Ensures every root exists and is writable; marks conflicts.
  Future<void> prepare(DestinationPlan plan) async {
    for (final root in plan.roots) {
      await ensureWritable(root);
    }
    for (final f in plan.files.values) {
      await PathSafety.ensureNoSymlinkEscape(f.root, f.target);
      f.conflict =
          await FileSystemEntity.type(f.target, followLinks: false) !=
          FileSystemEntityType.notFound;
    }
  }

  /// Verifies [root] can be written, creating it if needed.
  Future<void> ensureWritable(String root) async {
    try {
      final dir = Directory(root);
      await dir.create(recursive: true);
      final probe = File(
        p.join(
          root,
          '.lanbeam-write-test-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException catch (e) {
      final c = classifyError(e);
      throw LanBeamException(
        c.kind == FailureKind.permissionDenied || c.kind == FailureKind.diskFull
            ? c.kind
            : FailureKind.destinationUnavailable,
        '$root: ${e.message}',
      );
    }
  }

  /// Staging directory for partial files of [transferId] under [root].
  String stagingDir(String root, String transferId) =>
      p.join(root, stagingDirName, transferId);

  /// Moves a verified partial file to its final location applying the
  /// conflict [action]. Returns the final path.
  Future<String> finalize(
    String partPath,
    PlannedFile planned, {
    DateTime? modified,
  }) async {
    var target = planned.target;
    await PathSafety.ensureNoSymlinkEscape(planned.root, target);
    await Directory(p.dirname(target)).create(recursive: true);
    // Re-check after creating directories (defense in depth).
    await PathSafety.ensureNoSymlinkEscape(planned.root, target);

    final existing = await FileSystemEntity.type(target, followLinks: false);
    if (existing != FileSystemEntityType.notFound) {
      final action = planned.action ?? ConflictAction.rename;
      if (action == ConflictAction.replace &&
          existing != FileSystemEntityType.directory) {
        // Removing a link removes the link itself, never its target.
        await (existing == FileSystemEntityType.link
            ? Link(target).delete()
            : File(target).delete());
      } else {
        // skip is handled before upload; an unexpected new conflict, or a
        // directory in the way, falls back to renaming.
        target = await PathSafety.uniquePath(target);
      }
    }

    try {
      await File(partPath).rename(target);
    } on FileSystemException {
      // Cross-device rename (staging on another volume): copy + delete.
      await File(partPath).copy(target);
      await File(partPath).delete();
    }
    if (modified != null) {
      try {
        await File(target).setLastModified(modified);
      } catch (_) {}
    }
    return target;
  }

  /// Removes the staging directory for a transfer under every root.
  Future<void> cleanupStaging(Iterable<String> roots, String transferId) async {
    for (final root in roots) {
      final dir = Directory(stagingDir(root, transferId));
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
        final parent = Directory(p.join(root, stagingDirName));
        if (await parent.exists() && await parent.list().isEmpty) {
          await parent.delete();
        }
      } catch (_) {}
    }
  }
}
