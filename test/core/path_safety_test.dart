import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanbeam/core/destinations/destination_manager.dart';
import 'package:lanbeam/core/destinations/file_category.dart';
import 'package:lanbeam/core/models/settings.dart';
import 'package:lanbeam/core/models/transfer_models.dart';
import 'package:lanbeam/core/security/path_safety.dart';
import 'package:path/path.dart' as p;

void main() {
  group('validateRelativePath', () {
    for (final bad in [
      '../etc/passwd',
      'a/../../b',
      '/etc/passwd',
      '\\windows\\system32',
      'C:/Windows/evil.dll',
      'c:evil',
      'a//b',
      'a/./b',
      'dir/..',
      'a\\..\\..\\b',
      'nul\x00byte',
      '',
    ]) {
      test('rejects "$bad"', () {
        expect(() => PathSafety.validateRelativePath(bad), throwsFormatException);
      });
    }

    test('rejects excessive depth', () {
      final deep = List.filled(100, 'd').join('/');
      expect(() => PathSafety.validateRelativePath(deep), throwsFormatException);
    });

    for (final good in ['photo.jpg', 'DCIM/Camera/IMG001.jpg', '..hidden', 'a..b/c']) {
      test('accepts "$good"', () => PathSafety.validateRelativePath(good));
    }
  });

  group('sanitizeSegment', () {
    test('replaces characters invalid on Windows', () {
      expect(PathSafety.sanitizeSegment('a<b>c:d"e|f?g*h'), 'a_b_c_d_e_f_g_h');
    });
    test('strips control chars and trailing dots/spaces', () {
      expect(PathSafety.sanitizeSegment('name\x07.txt. . '), 'name.txt');
    });
    test('prefixes reserved device names', () {
      expect(PathSafety.sanitizeSegment('CON'), '_CON');
      expect(PathSafety.sanitizeSegment('nul.txt'), '_nul.txt');
      expect(PathSafety.sanitizeSegment('com1.log'), '_com1.log');
      expect(PathSafety.sanitizeSegment('console.txt'), 'console.txt');
    });
    test('truncates long names keeping the extension', () {
      final long = '${'é' * 300}.jpeg';
      final s = PathSafety.sanitizeSegment(long);
      expect(s.endsWith('.jpeg'), isTrue);
      expect(s.length, lessThan(long.length));
    });
    test('never returns empty or dot names', () {
      expect(PathSafety.sanitizeSegment('...'), '_');
      expect(PathSafety.sanitizeSegment('   '), '_');
    });
  });

  group('resolveInside', () {
    test('keeps results inside the root', () {
      final root = p.join(Directory.systemTemp.path, 'root');
      final r = PathSafety.resolveInside(root, 'DCIM/Camera/a.jpg');
      expect(p.isWithin(root, r), isTrue);
      expect(r, p.join(root, 'DCIM', 'Camera', 'a.jpg'));
    });
    test('throws on traversal', () {
      expect(() => PathSafety.resolveInside('/tmp/root', '../x'), throwsFormatException);
    });
  });

  group('symlink protection', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ps'));
    tearDown(() => tmp.delete(recursive: true));

    test('detects a directory symlink that escapes the root', () async {
      if (Platform.isWindows) return;
      final root = Directory(p.join(tmp.path, 'root'))..createSync();
      final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
      Link(p.join(root.path, 'escape')).createSync(outside.path);
      final target = PathSafety.resolveInside(root.path, 'escape/evil.txt');
      expect(
        () => PathSafety.ensureNoSymlinkEscape(root.path, target),
        throwsA(isA<PathTraversalException>()),
      );
    });

    test('allows normal nested paths', () async {
      final root = Directory(p.join(tmp.path, 'root'))..createSync();
      final target = PathSafety.resolveInside(root.path, 'a/b/c.txt');
      await PathSafety.ensureNoSymlinkEscape(root.path, target);
    });
  });

  group('unique names', () {
    test('numbered names', () {
      expect(PathSafety.numberedName('photo.jpg', 1), 'photo (1).jpg');
      expect(PathSafety.numberedName('README', 2), 'README (2)');
      expect(PathSafety.numberedName('.bashrc', 1), '.bashrc (1)');
    });

    test('uniquePath increments', () async {
      final tmp = await Directory.systemTemp.createTemp('uniq');
      final base = p.join(tmp.path, 'photo.jpg');
      expect(await PathSafety.uniquePath(base), base);
      File(base).writeAsStringSync('x');
      expect(p.basename(await PathSafety.uniquePath(base)), 'photo (1).jpg');
      File(p.join(tmp.path, 'photo (1).jpg')).writeAsStringSync('x');
      expect(p.basename(await PathSafety.uniquePath(base)), 'photo (2).jpg');
      await tmp.delete(recursive: true);
    });
  });

  group('manifest validation', () {
    test('rejects duplicate ids and paths', () {
      Map<String, Object?> m(List<Map<String, Object?>> files) =>
          {'transferId': 'abcdefgh-1234', 'kind': 'files', 'files': files};
      expect(
        () => TransferManifest.fromJson(m([
          {'id': 'a', 'path': 'x', 'size': 1},
          {'id': 'a', 'path': 'y', 'size': 1},
        ])),
        throwsFormatException,
      );
      expect(
        () => TransferManifest.fromJson(m([
          {'id': 'a', 'path': 'x', 'size': 1},
          {'id': 'b', 'path': 'X', 'size': 1},
        ])),
        throwsFormatException,
      );
      expect(
        () => TransferManifest.fromJson(m([
          {'id': 'a', 'path': '../x', 'size': 1},
        ])),
        throwsFormatException,
      );
      expect(
        () => TransferManifest.fromJson(m([
          {'id': 'a', 'path': 'x', 'size': -5},
        ])),
        throwsFormatException,
      );
    });
  });

  group('destination rules', () {
    test('routes by category and keeps folders together', () {
      final settings = AppSettings(
        deviceName: 'x',
        downloadDirectory: '/dl',
        useDestinationRules: true,
        destinationRules: {
          FileCategory.images: '/pics',
          FileCategory.videos: '/vids',
          FileCategory.folders: '/folders',
        },
      );
      final manifest = TransferManifest(transferId: 'abcdefgh-1', kind: TransferKind.mixed, files: const [
        ManifestFile(id: 'a', path: 'a.JPG', size: 1),
        ManifestFile(id: 'b', path: 'clip.mp4', size: 1),
        ManifestFile(id: 'c', path: 'notes.pdf', size: 1),
        ManifestFile(id: 'd', path: 'DCIM/Camera/x.jpg', size: 1),
      ]);
      final plan = DestinationManager().plan(manifest, settings);
      expect(plan.files['a']!.root, p.normalize(p.absolute('/pics')));
      expect(plan.files['b']!.root, p.normalize(p.absolute('/vids')));
      expect(plan.files['c']!.root, p.normalize(p.absolute('/dl')));
      expect(plan.files['d']!.target, p.join(p.normalize(p.absolute('/folders')), 'DCIM', 'Camera', 'x.jpg'));
    });

    test('categories', () {
      expect(FileCategory.forPath('a.HEIC'), FileCategory.images);
      expect(FileCategory.forPath('a.mkv'), FileCategory.videos);
      expect(FileCategory.forPath('a.flac'), FileCategory.audio);
      expect(FileCategory.forPath('a.docx'), FileCategory.documents);
      expect(FileCategory.forPath('a.zip'), FileCategory.archives);
      expect(FileCategory.forPath('a.bin'), FileCategory.other);
      expect(FileCategory.forPath('noext', mime: 'image/png'), FileCategory.images);
    });
  });
}
