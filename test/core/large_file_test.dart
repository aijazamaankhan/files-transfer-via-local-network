/// Multi-gigabyte style tests. Run with:
///   LANBEAM_LARGE_TESTS=1 flutter test test/core/large_file_test.dart
@Timeout(Duration(minutes: 20))
@Tags(['large'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanbeam/core/models/transfer_models.dart';
import 'package:lanbeam/core/transfer/file_scanner.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  final enabled = Platform.environment['LANBEAM_LARGE_TESTS'] == '1';

  test('1 GB file transfer with isolate hashing and bounded memory', () async {
    final phone = await TestPeer.start('Phone', isolateChecksums: true);
    final pc = await TestPeer.start('PC', isolateChecksums: true);
    final src = await Directory.systemTemp.createTemp('lanbeam_large');
    try {
      await pairPeers(phone, pc);
      const size = 1024 * 1024 * 1024;
      final file = p.join(src.path, 'big.iso');
      final hash = await writeRandomFile(file, size);
      final rssBefore = ProcessInfo.currentRss;
      var maxRss = rssBefore;
      final sw = Stopwatch()..start();
      final t = await phone.engine.send(pc.engine.identity.deviceId, [
        LocalPathSelection(file),
      ]);
      t.addListener(() {
        final rss = ProcessInfo.currentRss;
        if (rss > maxRss) maxRss = rss;
      });
      await waitForStatus(
        t,
        (s) => s.isFinal || s == TransferStatus.failed,
        timeout: const Duration(minutes: 15),
      );
      sw.stop();
      expect(t.status, TransferStatus.completed, reason: '${t.error}');
      expect(await sha256File(p.join(pc.downloads, 'big.iso')), hash);
      final mbps = size / 1024 / 1024 / (sw.elapsedMilliseconds / 1000);
      // Both peers share this process; growth must stay far below file size.
      final growthMb = (maxRss - rssBefore) / 1024 / 1024;
      // ignore: avoid_print
      print(
        '1 GB in ${sw.elapsed} (${mbps.toStringAsFixed(1)} MB/s), RSS growth ${growthMb.toStringAsFixed(0)} MB',
      );
      expect(growthMb, lessThan(300));
    } finally {
      await phone.stop();
      await pc.stop();
      await src.delete(recursive: true);
    }
  }, skip: enabled ? false : 'set LANBEAM_LARGE_TESTS=1 to run');
}
