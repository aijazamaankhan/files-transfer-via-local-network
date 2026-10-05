import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../protocol/protocol.dart';

/// Thrown when a path from a peer would escape its destination root.
class PathTraversalException implements Exception {
  PathTraversalException(this.message);
  final String message;
  @override
  String toString() => 'PathTraversalException: $message';
}

/// Validation and sanitization of untrusted, peer-supplied paths.
///
/// Two layers of defense:
/// 1. [validateRelativePath] rejects any manifest containing traversal
///    attempts outright (absolute paths, `..`, drive letters, …).
/// 2. [resolveInside] sanitizes each segment for the local filesystem and
///    re-checks that the joined, normalized result is inside the root, and
///    [ensureNoSymlinkEscape] verifies existing ancestors do not link outside.
abstract final class PathSafety {
  static final _controlChars = RegExp(r'[\x00-\x1f\x7f]');
  static final _windowsInvalid = RegExp(r'[<>:"/\\|?*]');
  static final _driveLetter = RegExp(r'^[A-Za-z]:');
  static final _reservedNames = RegExp(
    r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³]|conin\$|conout\$)$',
    caseSensitive: false,
  );

  /// Max bytes per path segment (most filesystems allow 255).
  static const maxSegmentBytes = 200;

  /// Throws [FormatException] if [path] is not an acceptable relative path.
  static void validateRelativePath(String path) {
    if (path.isEmpty || path.length > 4096) {
      throw const FormatException('path empty or too long');
    }
    if (path.contains('\x00')) throw const FormatException('NUL in path');
    if (path.startsWith('/') || path.startsWith('\\')) {
      throw const FormatException('absolute path');
    }
    if (_driveLetter.hasMatch(path)) {
      throw const FormatException('drive-qualified path');
    }
    final segments = path.split('/');
    if (segments.length > Protocol.maxPathDepth) {
      throw const FormatException('path too deep');
    }
    for (final s in segments) {
      // Treat backslash as a separator too when checking for traversal, since
      // the receiver may be Windows.
      for (final part in s.split('\\')) {
        if (part == '..' || part == '.') {
          throw const FormatException('path traversal');
        }
      }
      if (s.isEmpty) throw const FormatException('empty path segment');
    }
  }

  /// Makes one path segment safe on every supported filesystem.
  static String sanitizeSegment(String segment) {
    var s = segment
        .replaceAll(_controlChars, '')
        .replaceAll(_windowsInvalid, '_')
        .trim();
    // Windows silently strips trailing dots and spaces.
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty || s == '.' || s == '..') s = '_';
    final stem = s.split('.').first;
    if (_reservedNames.hasMatch(stem)) s = '_$s';
    return _truncateUtf8(s, maxSegmentBytes);
  }

  static String _truncateUtf8(String s, int maxBytes) {
    if (utf8.encode(s).length <= maxBytes) return s;
    final ext = p.extension(s);
    final keepExt = ext.length <= 16 ? ext : '';
    final stem = s.substring(0, s.length - keepExt.length);
    final budget = maxBytes - utf8.encode(keepExt).length;
    final runes = stem.runes.toList();
    var bytes = 0;
    final out = StringBuffer();
    for (final r in runes) {
      final len = utf8.encode(String.fromCharCode(r)).length;
      if (bytes + len > budget) break;
      bytes += len;
      out.writeCharCode(r);
    }
    return '$out$keepExt';
  }

  /// Validates then sanitizes a relative path into safe segments.
  static List<String> sanitizeRelativePath(String path) {
    validateRelativePath(path);
    return path.split('/').map(sanitizeSegment).toList();
  }

  /// Joins [relativePath] (peer-supplied) under [root] safely.
  static String resolveInside(String root, String relativePath) {
    final segments = sanitizeRelativePath(relativePath);
    final normalizedRoot = p.normalize(p.absolute(root));
    final target = p.normalize(p.joinAll([normalizedRoot, ...segments]));
    if (!p.isWithin(normalizedRoot, target)) {
      throw PathTraversalException('$relativePath escapes destination');
    }
    return target;
  }

  /// Verifies that the nearest existing ancestor of [target] resolves (after
  /// following symlinks) to a location inside [root].
  static Future<void> ensureNoSymlinkEscape(String root, String target) async {
    final canonicalRoot = await Directory(root).resolveSymbolicLinks();
    var dir = p.dirname(target);
    while (!await Directory(dir).exists()) {
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    final canonicalDir = await Directory(dir).resolveSymbolicLinks();
    if (canonicalDir != canonicalRoot &&
        !p.isWithin(canonicalRoot, canonicalDir)) {
      throw PathTraversalException('symlink escapes destination');
    }
    final link = Link(target);
    if (await link.exists()) {
      final resolved = await link.resolveSymbolicLinks().catchError((_) => '');
      if (resolved.isEmpty || !p.isWithin(canonicalRoot, resolved)) {
        throw PathTraversalException('target is a symlink outside destination');
      }
    }
  }

  /// "photo.jpg" → "photo (1).jpg"; keeps dotfiles intact.
  static String numberedName(String name, int n) {
    final ext = p.extension(name);
    final stem = (ext.isEmpty || ext == name)
        ? name
        : name.substring(0, name.length - ext.length);
    final e = ext == name ? '' : ext;
    return '$stem ($n)$e';
  }

  /// Returns a path that does not exist yet by appending " (n)".
  static Future<String> uniquePath(String path) async {
    if (!await _exists(path)) return path;
    final dir = p.dirname(path);
    final name = p.basename(path);
    for (var n = 1; n < 100000; n++) {
      final candidate = p.join(dir, numberedName(name, n));
      if (!await _exists(candidate)) return candidate;
    }
    throw const FileSystemException('could not find a free file name');
  }

  static Future<bool> _exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;
}
