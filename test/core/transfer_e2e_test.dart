@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanbeam/core/destinations/destination_manager.dart';
import 'package:lanbeam/core/models/settings.dart';
import 'package:lanbeam/core/models/transfer_models.dart';
import 'package:lanbeam/core/networking/peer_client.dart';
import 'package:lanbeam/core/protocol/protocol.dart';
import 'package:lanbeam/core/transfer/file_scanner.dart';
import 'package:lanbeam/core/transfer/file_source.dart';
import 'package:lanbeam/core/transfer/transfer_receiver.dart';
import 'package:lanbeam/core/transfer/transfer_service.dart';
import 'package:lanbeam/core/util/errors.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

/// A source that delivers bytes slowly so tests can interrupt mid-transfer.
class ThrottledSource implements FileSource {
  ThrottledSource(
    this.inner, {
    this.chunkDelay = const Duration(milliseconds: 5),
  });
  final LocalFileSource inner;
  Duration chunkDelay;
  int bytesRead = 0;

  @override
  String get displayPath => inner.displayPath;
  @override
  Future<SourceStat> stat() => inner.stat();
  @override
  Map<String, Object?> toJson() => inner.toJson();

  @override
  Stream<Uint8List> openRead(int start) async* {
    await for (final chunk in inner.openRead(start)) {
      if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      bytesRead += chunk.length;
      yield chunk;
    }
  }
}

void main() {
  late TestPeer phone;
  late TestPeer pc;
  late Directory src;

  setUp(() async {
    phone = await TestPeer.start('Phone');
    pc = await TestPeer.start('PC');
    src = await Directory.systemTemp.createTemp('lanbeam_src');
    await pairPeers(phone, pc);
  });

  tearDown(() async {
    await phone.stop();
    await pc.stop();
    await src.delete(recursive: true);
  });

  String pcId() => pc.engine.identity.deviceId;
  String phoneId() => phone.engine.identity.deviceId;

  test('pairing is mutual and pins fingerprints', () {
    final onPhone = phone.engine.trustedDevices.get(pcId())!;
    final onPc = pc.engine.trustedDevices.get(phoneId())!;
    expect(onPhone.fingerprint, pc.engine.identity.fingerprint);
    expect(onPc.fingerprint, phone.engine.identity.fingerprint);
    expect(onPhone.secret, onPc.secret);
  });

  test('1 MB file transfer with checksum verification', () async {
    final file = p.join(src.path, 'photo.jpg');
    final hash = await writeRandomFile(file, 1024 * 1024);
    final t = await phone.engine.send(pcId(), [LocalPathSelection(file)]);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    final received = p.join(pc.downloads, 'photo.jpg');
    expect(await sha256File(received), hash);
    expect(pc.engine.history.records.first.status, TransferStatus.completed);
    expect(phone.engine.history.records.first.status, TransferStatus.completed);
    // Staging area is cleaned up.
    expect(
      Directory(p.join(pc.downloads, DestinationManager.stagingDirName))
          .existsSync(),
      isFalse,
    );
  });

  test('transfers in both directions (symmetric peers)', () async {
    final file = p.join(src.path, 'report.pdf');
    final hash = await writeRandomFile(file, 300000);
    final t = await pc.engine.send(phoneId(), [LocalPathSelection(file)]);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    expect(await sha256File(p.join(phone.downloads, 'report.pdf')), hash);
  });

  test('multi-file transfer including an empty file', () async {
    final hashes = <String, String>{};
    for (var i = 0; i < 12; i++) {
      final f = p.join(src.path, 'file$i.bin');
      hashes['file$i.bin'] = await writeRandomFile(f, i * 37000, seed: i);
    }
    final t = await phone.engine.send(pcId(), [
      for (var i = 0; i < 12; i++)
        LocalPathSelection(p.join(src.path, 'file$i.bin')),
    ]);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    for (final e in hashes.entries) {
      expect(
        await sha256File(p.join(pc.downloads, e.key)),
        e.value,
        reason: e.key,
      );
    }
  });

  test('recursive folder transfer preserves structure', () async {
    final dcim = p.join(src.path, 'DCIM');
    final files = {
      'Camera/IMG001.jpg': 120000,
      'Camera/IMG002.jpg': 80000,
      'Screenshots/screenshot.png': 50000,
      'Screenshots/nested/deep/x.txt': 10,
    };
    final hashes = <String, String>{};
    var seed = 0;
    for (final e in files.entries) {
      hashes[e.key] = await writeRandomFile(
        p.join(dcim, e.key),
        e.value,
        seed: seed++,
      );
    }
    final t = await phone.engine.send(pcId(), [LocalPathSelection(dcim)]);
    expect(t.manifest.kind, TransferKind.folder);
    expect(t.title, 'DCIM');
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    for (final e in hashes.entries) {
      final path = p.joinAll([pc.downloads, 'DCIM', ...e.key.split('/')]);
      expect(await sha256File(path), e.value, reason: e.key);
    }
  });

  group('duplicate filename handling', () {
    Future<void> sendOnce(String file) async {
      final t = await phone.engine.send(pcId(), [LocalPathSelection(file)]);
      await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
      expect(t.status, TransferStatus.completed, reason: '${t.error}');
    }

    test('rename produces photo (1).jpg, photo (2).jpg', () async {
      final file = p.join(src.path, 'photo.jpg');
      await writeRandomFile(file, 1000);
      await sendOnce(file);
      await sendOnce(file);
      await sendOnce(file);
      expect(File(p.join(pc.downloads, 'photo.jpg')).existsSync(), isTrue);
      expect(File(p.join(pc.downloads, 'photo (1).jpg')).existsSync(), isTrue);
      expect(File(p.join(pc.downloads, 'photo (2).jpg')).existsSync(), isTrue);
    });

    test('replace overwrites, skip keeps the original', () async {
      final file = p.join(src.path, 'doc.txt');
      final existing = p.join(pc.downloads, 'doc.txt');
      await Directory(pc.downloads).create(recursive: true);

      await pc.engine.updateSettings(
        (s) => s.copyWith(conflictPolicy: ConflictPolicy.replace),
      );
      File(existing).writeAsStringSync('old');
      final newHash = await writeRandomFile(file, 5000);
      await sendOnce(file);
      expect(await sha256File(existing), newHash);
      expect(File(p.join(pc.downloads, 'doc (1).txt')).existsSync(), isFalse);

      await pc.engine.updateSettings(
        (s) => s.copyWith(conflictPolicy: ConflictPolicy.skip),
      );
      File(existing).writeAsStringSync('keep me');
      await sendOnce(file);
      expect(File(existing).readAsStringSync(), 'keep me');
    });

    test('ask: user resolves conflicts with "apply to all"', () async {
      await pc.engine.updateSettings(
        (s) => s.copyWith(conflictPolicy: ConflictPolicy.ask),
      );
      await Directory(pc.downloads).create(recursive: true);
      File(p.join(pc.downloads, 'a.txt')).writeAsStringSync('old a');
      File(p.join(pc.downloads, 'b.txt')).writeAsStringSync('old b');
      await writeRandomFile(p.join(src.path, 'a.txt'), 10);
      await writeRandomFile(p.join(src.path, 'b.txt'), 10);
      await writeRandomFile(p.join(src.path, 'c.txt'), 10);

      final requests = <IncomingRequest>[];
      final sub = pc.engine.receiver.requests.listen(requests.add);
      final t = await phone.engine.send(pcId(), [
        for (final n in ['a.txt', 'b.txt', 'c.txt'])
          LocalPathSelection(p.join(src.path, n)),
      ]);
      await waitUntil(() => requests.isNotEmpty, reason: 'no request');
      final req = requests.single;
      expect(req.conflicts.map((c) => c.file.path).toSet(), {'a.txt', 'b.txt'});
      await req.accept(req.defaultPlan!, applyToAll: ConflictAction.skip);
      await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
      expect(t.status, TransferStatus.completed, reason: '${t.error}');
      expect(File(p.join(pc.downloads, 'a.txt')).readAsStringSync(), 'old a');
      expect(File(p.join(pc.downloads, 'c.txt')).existsSync(), isTrue);
      await sub.cancel();
    });
  });

  test('receiver asks the user, who picks a folder and accepts', () async {
    await pc.engine.updateSettings((s) => s.copyWith(autoAcceptTrusted: false));
    final file = p.join(src.path, 'video.mp4');
    final hash = await writeRandomFile(file, 200000);
    final chosen = p.join(pc.root.path, 'Chosen');
    final sub = pc.engine.receiver.requests.listen((req) async {
      expect(req.sender.name, 'Phone');
      final plan = await req.planFor(chosen);
      await req.accept(plan);
    });
    final t = await phone.engine.send(pcId(), [LocalPathSelection(file)]);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    expect(await sha256File(p.join(chosen, 'video.mp4')), hash);
    await sub.cancel();
  });

  test('receiver rejection is reported to the sender', () async {
    await pc.engine.updateSettings((s) => s.copyWith(autoAcceptTrusted: false));
    final file = p.join(src.path, 'x.bin');
    await writeRandomFile(file, 100);
    final sub = pc.engine.receiver.requests.listen((req) => req.reject());
    final t = await phone.engine.send(pcId(), [LocalPathSelection(file)]);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.rejected);
    expect(File(p.join(pc.downloads, 'x.bin')).existsSync(), isFalse);
    await sub.cancel();
  });

  test(
    'interrupted transfer resumes from the committed offset after reconnect',
    () async {
      final size = Protocol.blockSize * 3 + 12345;
      final file = p.join(src.path, 'big.bin');
      final hash = await writeRandomFile(file, size);
      final source = ThrottledSource(
        LocalFileSource(file),
        chunkDelay: const Duration(milliseconds: 4),
      );
      final scan = ScanResult([
        OutgoingFile(
          id: 'f0',
          relativePath: 'big.bin',
          source: source,
          size: size,
          modified: File(file).lastModifiedSync(),
        ),
      ], TransferKind.files);
      final t = await phone.engine.sendScanned(pcId(), scan);

      // Wait until more than one block has been committed by the receiver.
      await waitUntil(
        () {
          final r = pc.engine.receiver[t.id];
          return r != null &&
              (r.partials['f0']?.committed ?? 0) >= Protocol.blockSize;
        },
        timeout: const Duration(seconds: 60),
        reason: 'no block committed',
      );

      // Simulate the PC disappearing from the network (server stops).
      final port = pc.engine.server.port;
      await pc.engine.server.stop();
      await waitForStatus(
        t,
        (s) => s == TransferStatus.pending || s == TransferStatus.failed,
        timeout: const Duration(seconds: 20),
      );
      final committedBefore =
          pc.engine.receiver[t.id]!.partials['f0']!.committed;
      expect(committedBefore, greaterThanOrEqualTo(Protocol.blockSize));

      // PC comes back on the same port; the sender's retry loop reconnects.
      source.chunkDelay = Duration.zero;
      final readBefore = source.bytesRead;
      await pc.engine.server.start(
        preferredPort: port,
        address: InternetAddress.loopbackIPv4,
      );
      await waitForStatus(
        t,
        (s) => s.isFinal || s == TransferStatus.failed,
        timeout: const Duration(seconds: 90),
      );
      expect(t.status, TransferStatus.completed, reason: '${t.error}');
      expect(await sha256File(p.join(pc.downloads, 'big.bin')), hash);
      // The resumed upload started at the committed offset, not zero.
      final reread = source.bytesRead - readBefore;
      expect(
        reread,
        lessThanOrEqualTo(size - committedBefore + Protocol.ioChunkSize),
      );
    },
  );

  test('pause and resume from the sender', () async {
    final size = Protocol.blockSize * 2 + 999;
    final file = p.join(src.path, 'pause.bin');
    final hash = await writeRandomFile(file, size);
    final source = ThrottledSource(
      LocalFileSource(file),
      chunkDelay: const Duration(milliseconds: 3),
    );
    final t = await phone.engine.sendScanned(
      pcId(),
      ScanResult([
        OutgoingFile(
          id: 'f0',
          relativePath: 'pause.bin',
          source: source,
          size: size,
        ),
      ], TransferKind.files),
    );
    await waitUntil(
      () => t.transferredBytes > Protocol.blockSize + Protocol.ioChunkSize,
    );
    t.pause();
    expect(t.status, TransferStatus.paused);
    await waitUntil(
      () => pc.engine.receiver[t.id]?.status == TransferStatus.paused,
      reason: 'receiver did not see pause',
    );
    source.chunkDelay = Duration.zero;
    t.resume();
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    expect(await sha256File(p.join(pc.downloads, 'pause.bin')), hash);
  });

  test('receiver can pause, resume and the transfer completes', () async {
    final size = Protocol.blockSize + 4096;
    final file = p.join(src.path, 'rp.bin');
    final hash = await writeRandomFile(file, size);
    final source = ThrottledSource(
      LocalFileSource(file),
      chunkDelay: const Duration(milliseconds: 3),
    );
    final t = await phone.engine.sendScanned(
      pcId(),
      ScanResult([
        OutgoingFile(
          id: 'f0',
          relativePath: 'rp.bin',
          source: source,
          size: size,
        ),
      ], TransferKind.files),
    );
    await waitUntil(
      () =>
          (pc.engine.receiver[t.id]?.transferredBytes ?? 0) >
          2 * Protocol.ioChunkSize,
    );
    pc.engine.receiver.pause(t.id);
    await waitForStatus(
      t,
      (s) => s == TransferStatus.paused,
      timeout: const Duration(seconds: 10),
    );
    expect(t.pausedRemotely, isTrue);
    source.chunkDelay = Duration.zero;
    pc.engine.receiver.resume(t.id);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    expect(await sha256File(p.join(pc.downloads, 'rp.bin')), hash);
  });

  test('receiver cancel stops the sender and removes partial data', () async {
    final size = Protocol.blockSize * 2;
    final file = p.join(src.path, 'c.bin');
    await writeRandomFile(file, size);
    final source = ThrottledSource(
      LocalFileSource(file),
      chunkDelay: const Duration(milliseconds: 5),
    );
    final t = await phone.engine.sendScanned(
      pcId(),
      ScanResult([
        OutgoingFile(
          id: 'f0',
          relativePath: 'c.bin',
          source: source,
          size: size,
        ),
      ], TransferKind.files),
    );
    await waitUntil(
      () =>
          (pc.engine.receiver[t.id]?.transferredBytes ?? 0) >
          Protocol.ioChunkSize,
    );
    await pc.engine.receiver.cancel(t.id);
    await waitForStatus(
      t,
      (s) => s.isFinal || s == TransferStatus.failed,
      timeout: const Duration(seconds: 15),
    );
    expect(t.status, TransferStatus.cancelled);
    expect(File(p.join(pc.downloads, 'c.bin')).existsSync(), isFalse);
    expect(
      Directory(p.join(pc.downloads, DestinationManager.stagingDirName, t.id))
          .existsSync(),
      isFalse,
    );
  });

  test('corrupted partial data is detected by checksum and re-sent', () async {
    final size = Protocol.blockSize + 50000;
    final file = p.join(src.path, 'corrupt.bin');
    final hash = await writeRandomFile(file, size);
    final source = ThrottledSource(
      LocalFileSource(file),
      chunkDelay: const Duration(milliseconds: 4),
    );
    final t = await phone.engine.sendScanned(
      pcId(),
      ScanResult([
        OutgoingFile(
          id: 'f0',
          relativePath: 'corrupt.bin',
          source: source,
          size: size,
        ),
      ], TransferKind.files),
    );
    await waitUntil(
      () =>
          (pc.engine.receiver[t.id]?.partials['f0']?.committed ?? 0) >=
          Protocol.blockSize,
      timeout: const Duration(seconds: 60),
    );
    t.pause();
    await waitUntil(
      () =>
          pc.engine.receiver[t.id]!.partials['f0']!.committed >=
          Protocol.blockSize,
    );
    // Flip a byte inside the committed block (simulates disk corruption).
    final partPath = pc.engine.receiver[t.id]!.partials['f0']!.partPath;
    final raf = File(partPath).openSync(mode: FileMode.append);
    raf.setPositionSync(1000);
    raf.writeByteSync(raf.readByteSync() ^ 0xff);
    raf.closeSync();

    source.chunkDelay = Duration.zero;
    t.resume();
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    expect(await sha256File(p.join(pc.downloads, 'corrupt.bin')), hash);
  });

  test('file modified during transfer is reported', () async {
    final file = p.join(src.path, 'changing.bin');
    await writeRandomFile(file, 400000);
    final scan = await FileScanner().scan([LocalPathSelection(file)]);
    await File(file).writeAsString('changed', mode: FileMode.append);
    final t = await phone.engine.sendScanned(pcId(), scan);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.failed);
    expect(t.error?.kind, FailureKind.fileChanged);
  });

  test('unavailable destination folder fails with a clear error', () async {
    // A path below a regular file can never be created (works even as root).
    final blocker = File(p.join(pc.root.path, 'not_a_dir'))
      ..writeAsStringSync('x');
    await pc.engine.updateSettings(
      (s) => s.copyWith(downloadDirectory: p.join(blocker.path, 'sub')),
    );
    await pc.engine.updateSettings((s) => s.copyWith(autoAcceptTrusted: false));
    IncomingRequest? request;
    final sub = pc.engine.receiver.requests.listen((r) => request = r);
    final file = p.join(src.path, 'a.txt');
    await writeRandomFile(file, 10);
    final t = await phone.engine.send(pcId(), [LocalPathSelection(file)]);
    await waitUntil(() => request != null);
    // Default destination is unusable, so there is no default plan…
    expect(request!.defaultPlan, isNull);
    // …and choosing it explicitly fails with a destination error.
    await expectLater(
      request!.planFor(p.join(blocker.path, 'sub')),
      throwsA(
        isA<LanBeamException>().having(
          (e) => e.kind,
          'kind',
          FailureKind.destinationUnavailable,
        ),
      ),
    );
    await request!.reject();
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    await sub.cancel();
  });

  test(
    'receiver restart: transfer resumes from persisted partial data',
    () async {
      final size = Protocol.blockSize * 2 + 777;
      final file = p.join(src.path, 'restart.bin');
      final hash = await writeRandomFile(file, size);
      final source = ThrottledSource(
        LocalFileSource(file),
        chunkDelay: const Duration(milliseconds: 4),
      );
      final t = await phone.engine.sendScanned(
        pcId(),
        ScanResult([
          OutgoingFile(
            id: 'f0',
            relativePath: 'restart.bin',
            source: source,
            size: size,
            modified: File(file).lastModifiedSync(),
          ),
        ], TransferKind.files),
      );
      await waitUntil(
        () =>
            (pc.engine.receiver[t.id]?.partials['f0']?.committed ?? 0) >=
            Protocol.blockSize,
        timeout: const Duration(seconds: 60),
      );
      final port = pc.engine.server.port;
      // Full app restart of the receiver (new engine, same data directory).
      await pc.engine.dispose();
      source.chunkDelay = Duration.zero;
      final root = pc.root;
      pc = await TestPeer.start('PC', reuseRoot: root, port: port);
      expect(pc.engine.receiver[t.id], isNotNull, reason: 'inbox not restored');
      expect(
        pc.engine.receiver[t.id]!.transferredBytes,
        greaterThanOrEqualTo(Protocol.blockSize),
      );
      await waitForStatus(
        t,
        (s) => s.isFinal || s == TransferStatus.failed,
        timeout: const Duration(seconds: 90),
      );
      expect(t.status, TransferStatus.completed, reason: '${t.error}');
      expect(await sha256File(p.join(pc.downloads, 'restart.bin')), hash);
    },
  );

  test(
    'sender restart: resume from history continues the same transfer',
    () async {
      final size = Protocol.blockSize * 2 + 4242;
      final file = p.join(src.path, 'sres.bin');
      final hash = await writeRandomFile(file, size);
      final source = ThrottledSource(
        LocalFileSource(file),
        chunkDelay: const Duration(milliseconds: 4),
      );
      final t = await phone.engine.sendScanned(
        pcId(),
        ScanResult([
          OutgoingFile(
            id: 'f0',
            relativePath: 'sres.bin',
            source: source,
            size: size,
            modified: File(file).lastModifiedSync(),
          ),
        ], TransferKind.files),
      );
      await waitUntil(
        () =>
            (pc.engine.receiver[t.id]?.partials['f0']?.committed ?? 0) >=
            Protocol.blockSize,
        timeout: const Duration(seconds: 60),
      );
      t.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final record = phone.engine.history.records.firstWhere(
        (r) => r.transferId == t.id,
      );
      expect(record.resumeData, isNotNull);

      // Restart the phone app.
      final root = phone.root;
      await phone.engine.dispose();
      phone = await TestPeer.start('Phone', reuseRoot: root);
      final saved = phone.engine.history.records.firstWhere(
        (r) => r.transferId == t.id,
      );
      final resumed = await phone.engine.resumeFromHistory(saved);
      expect(resumed.id, t.id);
      await waitForStatus(
        resumed,
        (s) => s.isFinal || s == TransferStatus.failed,
      );
      expect(
        resumed.status,
        TransferStatus.completed,
        reason: '${resumed.error}',
      );
      expect(await sha256File(p.join(pc.downloads, 'sres.bin')), hash);
    },
  );

  group('unauthorized access', () {
    test('an unpaired device cannot authenticate or upload', () async {
      final stranger = await TestPeer.start('Stranger');
      try {
        final client = PeerClient(
          hosts: ['127.0.0.1'],
          port: pc.engine.server.port,
          expectedFingerprint: pc.engine.identity.fingerprint,
          localInfo: () => stranger.engine.localInfo,
          secret: Uint8List(32), // guessed secret
        );
        await expectLater(
          client.offer(
            TransferManifest(
              transferId: 'abcdefgh-0000',
              kind: TransferKind.files,
              files: const [],
            ),
          ),
          throwsA(
            isA<LanBeamException>().having(
              (e) => e.kind,
              'kind',
              FailureKind.unauthorized,
            ),
          ),
        );
        client.close();
      } finally {
        await stranger.stop();
      }
    });

    test(
      'raw requests without a token get 401 on every protected endpoint',
      () async {
        final http = HttpClient()..badCertificateCallback = (_, _, _) => true;
        final port = pc.engine.server.port;
        for (final (method, path) in [
          ('POST', '/api/v1/transfers'),
          ('GET', '/api/v1/transfers/abc'),
          ('PUT', '/api/v1/transfers/abc/files/f0?offset=0'),
          ('POST', '/api/v1/transfers/abc/cancel'),
          ('POST', '/api/v1/pair/revoke'),
        ]) {
          final req = await http.openUrl(
            method,
            Uri.parse('https://127.0.0.1:$port$path'),
          );
          req.headers.set('Authorization', 'Bearer forged-token');
          final res = await req.close();
          await res.drain<void>();
          expect(res.statusCode, 401, reason: '$method $path');
        }
        http.close(force: true);
      },
    );

    test('a man-in-the-middle certificate is refused (pinning)', () async {
      final client = PeerClient(
        hosts: ['127.0.0.1'],
        port: pc.engine.server.port,
        expectedFingerprint: 'f' * 64,
        localInfo: () => phone.engine.localInfo,
      );
      await expectLater(
        client.info(),
        throwsA(
          isA<LanBeamException>().having(
            (e) => e.kind,
            'kind',
            FailureKind.untrustedCertificate,
          ),
        ),
      );
      client.close();
    });

    test('a paired device sending a traversal path is rejected', () async {
      final trusted = phone.engine.trustedDevices.get(pcId())!;
      final client = PeerClient(
        hosts: ['127.0.0.1'],
        port: pc.engine.server.port,
        expectedFingerprint: trusted.fingerprint,
        localInfo: () => phone.engine.localInfo,
        secret: trusted.secret,
      );
      for (final evil in [
        '../evil.txt',
        '/etc/evil',
        'a/../../evil',
        'C:/evil.dll',
      ]) {
        final m = TransferManifest(
          transferId: 'abcdefgh-evil',
          kind: TransferKind.files,
          files: [ManifestFile(id: 'f0', path: 'ok.txt', size: 1)],
        );
        final json = m.toJson();
        ((json['files'] as List).first as Map)['path'] = evil;
        await client.ensureAuthenticated();
        final http = HttpClient()..badCertificateCallback = (_, _, _) => true;
        // Use a raw request so the client-side manifest validation is bypassed.
        final nonceReq = await http.postUrl(
          Uri.parse(
            'https://127.0.0.1:${pc.engine.server.port}/api/v1/transfers',
          ),
        );
        nonceReq.headers.contentType = ContentType.json;
        nonceReq.headers.set('Authorization', 'Bearer ${await _token(client)}');
        nonceReq.write(jsonEncode(json));
        final res = await nonceReq.close();
        await res.drain<void>();
        expect(res.statusCode, 400, reason: evil);
        http.close(force: true);
      }
      client.close();
      expect(File(p.join(pc.root.path, 'evil.txt')).existsSync(), isFalse);
    });

    test('unpairing revokes access on both sides', () async {
      await phone.engine.unpair(pcId());
      expect(phone.engine.trustedDevices.isTrusted(pcId()), isFalse);
      await waitUntil(
        () => !pc.engine.trustedDevices.isTrusted(phoneId()),
        reason: 'remote not revoked',
      );
    });
  });

  test('PIN pairing end-to-end (direct IP probe + PIN)', () async {
    final laptop = await TestPeer.start('Laptop');
    try {
      final info = await phone.engine.probe(
        '127.0.0.1',
        laptop.engine.server.port,
      );
      expect(info.name, 'Laptop');
      String? pin;
      final sub = laptop.engine.pairing.prompts.listen((prompt) {
        if (prompt.runtimeType.toString() == 'PairingPinPrompt')
          pin = (prompt as dynamic).pin as String;
      });
      final session = await phone.engine.startPinPairing(
        '127.0.0.1',
        info.port,
        info.fingerprint,
      );
      await waitUntil(() => pin != null);
      await expectLater(
        session.submit('000000' == pin ? '111111' : '000000'),
        throwsA(isA<LanBeamException>()),
      );
      final trusted = await session.submit(pin!);
      expect(trusted.id, laptop.engine.identity.deviceId);
      expect(laptop.engine.trustedDevices.isTrusted(phoneId()), isTrue);
      await sub.cancel();
    } finally {
      await laptop.stop();
    }
  });

  test('bytes on disk match after concurrent multi-file upload with isolate hashing', () async {
    await phone.stop();
    await pc.stop();
    phone = await TestPeer.start('Phone', isolateChecksums: true);
    pc = await TestPeer.start('PC', isolateChecksums: true);
    await pairPeers(phone, pc);
    final hashes = <String, String>{};
    for (var i = 0; i < 4; i++) {
      hashes['m$i.bin'] = await writeRandomFile(
        p.join(src.path, 'm$i.bin'),
        Protocol.blockSize ~/ 2 + i * 1000000,
        seed: 40 + i,
      );
    }
    final t = await phone.engine.send(pcId(), [
      for (final n in hashes.keys) LocalPathSelection(p.join(src.path, n)),
    ]);
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
    expect(t.status, TransferStatus.completed, reason: '${t.error}');
    for (final e in hashes.entries) {
      expect(await sha256File(p.join(pc.downloads, e.key)), e.value);
    }
  });

  test('speed and ETA are reported while active', () async {
    final size = Protocol.blockSize;
    final file = p.join(src.path, 'speed.bin');
    await writeRandomFile(file, size);
    final source = ThrottledSource(
      LocalFileSource(file),
      chunkDelay: const Duration(milliseconds: 20),
    );
    final OutgoingTransfer t = await phone.engine.sendScanned(
      pcId(),
      ScanResult([
        OutgoingFile(
          id: 'f0',
          relativePath: 'speed.bin',
          source: source,
          size: size,
        ),
      ], TransferKind.files),
    );
    await waitUntil(() => t.transferredBytes > 4 * Protocol.ioChunkSize);
    expect(t.bytesPerSecond, greaterThan(0));
    expect(t.eta, isNotNull);
    expect(t.progress, inExclusiveRange(0, 1));
    source.chunkDelay = Duration.zero;
    await waitForStatus(t, (s) => s.isFinal || s == TransferStatus.failed);
  });
}

/// Extracts a session token by performing the handshake via the client.
Future<String> _token(PeerClient client) async {
  // ensureAuthenticated stored it privately; obtain a fresh one via the API.
  final dynamic c = client;
  // ignore: avoid_dynamic_calls
  return c.debugToken as String;
}

/// Hash helper kept for readability in assertions.
String digestOf(List<int> bytes) => sha256.convert(bytes).toString();
