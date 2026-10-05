import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanbeam/core/protocol/protocol.dart';
import 'package:lanbeam/core/transfer/checksum.dart';
import 'package:lanbeam/core/transfer/chunk_writer.dart';
import 'package:lanbeam/core/transfer/file_source.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

Future<String> digestOfFile(
  String path,
  ChecksumService svc, {
  int blockSize = Protocol.blockSize,
}) async {
  final h = svc.createHasher(blockSize: blockSize);
  await for (final c in File(path).openRead()) {
    await h.add(Uint8List.fromList(c));
  }
  final d = await h.close();
  return fileDigest(await File(path).length(), d, blockSize: blockSize);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('cw'));
  tearDown(() => tmp.delete(recursive: true));

  test(
    'inline and isolate hashers agree, including block boundaries',
    () async {
      final iso = await IsolateChecksumService.spawn();
      final inline = InlineChecksumService();
      for (final size in [0, 1, 1000, 4096, 4097, 3 * 4096]) {
        final path = p.join(tmp.path, 'f$size');
        await writeRandomFile(path, size, seed: size);
        final a = await digestOfFile(path, inline, blockSize: 4096);
        final b = await digestOfFile(path, iso, blockSize: 4096);
        expect(a, b, reason: 'size $size');
      }
      await iso.dispose();
    },
  );

  test('digest changes when a single byte changes', () async {
    final path = p.join(tmp.path, 'x');
    await writeRandomFile(path, 10000);
    final svc = InlineChecksumService();
    final before = await digestOfFile(path, svc, blockSize: 4096);
    final raf = await File(path).open(mode: FileMode.append);
    await raf.setPosition(5000);
    await raf.writeByte(0);
    await raf.close();
    expect(await digestOfFile(path, svc, blockSize: 4096), isNot(before));
  });

  test(
    'PartialFile resumes at the last whole block after interruption',
    () async {
      const block = 4096;
      final src = p.join(tmp.path, 'src');
      await writeRandomFile(src, block * 5 + 123);
      final size = await File(src).length();
      final svc = InlineChecksumService();
      final staging = p.join(tmp.path, 'staging');

      var partial = PartialFile(
        stagingDir: staging,
        fileId: 'f',
        size: size,
        checksums: svc,
        blockSize: block,
      );
      expect(await partial.prepare(), 0);

      // Deliver 2.5 blocks then fail like a dropped connection.
      final controller = StreamController<List<int>>();
      final bytes = await File(src).readAsBytes();
      final writing = partial.write(controller.stream, 0);
      controller.add(bytes.sublist(0, (block * 2.5).toInt()));
      controller.addError(const SocketException('Connection reset'));
      await expectLater(writing, throwsA(isA<SocketException>()));
      expect(partial.committed, block * 2);

      // A new instance (as after an app restart) sees the same offset.
      partial = PartialFile(
        stagingDir: staging,
        fileId: 'f',
        size: size,
        checksums: svc,
        blockSize: block,
      );
      expect(await partial.prepare(), block * 2);
      await expectLater(
        partial.write(Stream.value(bytes.sublist(block)), block),
        throwsA(isA<OffsetMismatch>()),
      );
      await partial.write(Stream.value(bytes.sublist(block * 2)), block * 2);
      expect(partial.isComplete, isTrue);
      expect(
        await partial.digest(),
        await digestOfFile(src, svc, blockSize: block),
      );
      expect(
        sha256.convert(await File(partial.partPath).readAsBytes()),
        sha256.convert(bytes),
      );
    },
  );

  test('PartialFile rejects bodies larger than the declared size', () async {
    final partial = PartialFile(
      stagingDir: p.join(tmp.path, 's'),
      fileId: 'f',
      size: 10,
      checksums: InlineChecksumService(),
    );
    await expectLater(
      partial.write(Stream.value(List.filled(20, 1)), 0),
      throwsFormatException,
    );
  });

  test('LocalFileSource streams from an offset', () async {
    final path = p.join(tmp.path, 'src');
    await writeRandomFile(path, 3 * 1024 * 1024 + 7);
    final all = await File(path).readAsBytes();
    final src = LocalFileSource(path);
    final read = <int>[];
    await for (final c in src.openRead(1234567)) {
      read.addAll(c);
    }
    expect(read.length, all.length - 1234567);
    expect(read, all.sublist(1234567));
    expect((await src.stat()).size, all.length);
  });
}
