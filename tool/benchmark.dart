// ignore_for_file: avoid_print
// Loopback throughput benchmark: dart run tool/benchmark.dart [MB] [iso]
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lanbeam/core/engine.dart';
import 'package:lanbeam/core/models/device_info.dart';
import 'package:lanbeam/core/models/settings.dart';
import 'package:lanbeam/core/models/transfer_models.dart';
import 'package:lanbeam/core/security/pairing_service.dart';
import 'package:lanbeam/core/transfer/file_scanner.dart';
import 'package:path/path.dart' as p;

Future<LanBeamEngine> start(String name, Directory root, bool iso) async {
  final e = LanBeamEngine(
    EngineConfig(
      dataDirectory: p.join(root.path, name, 'data'),
      defaultSettings: AppSettings(
        deviceName: name,
        downloadDirectory: p.join(root.path, name, 'dl'),
        askWhereToSave: false,
        autoAcceptTrusted: true,
        servicePort: 0,
        conflictPolicy: ConflictPolicy.rename,
      ),
      deviceType: DeviceType.desktop,
      enableDiscovery: false,
      useIsolateChecksums: iso,
      bindAddress: InternetAddress.loopbackIPv4,
    ),
  );
  await e.start();
  return e;
}

Future<void> main(List<String> args) async {
  final iso = args.contains('iso');
  final mb = int.parse(
    args.firstWhere((a) => int.tryParse(a) != null, orElse: () => '256'),
  );
  final root = await Directory.systemTemp.createTemp('be');
  final a = await start('A', root, iso), b = await start('B', root, iso);
  b.pairing.prompts.listen((pr) {
    if (pr is PairingApprovalPrompt) pr.respond(true);
  });
  final qr = await b.createQrPayload();
  await a.pairWithQr(
    QrPairingPayload(
      deviceId: qr.deviceId,
      name: qr.name,
      addresses: ['127.0.0.1'],
      port: qr.port,
      fingerprint: qr.fingerprint,
      token: qr.token,
    ),
  );
  final f = File(p.join(root.path, 'x.bin'));
  final rnd = Random(1);
  final buf = Uint8List(1 << 20);
  for (var i = 0; i < buf.length; i++) {
    buf[i] = rnd.nextInt(256);
  }
  final sink = f.openWrite();
  for (var i = 0; i < mb; i++) {
    sink.add(buf);
  }
  await sink.close();
  final sw = Stopwatch()..start();
  final t = await a.send(b.identity.deviceId, [LocalPathSelection(f.path)]);
  final c = Completer<void>();
  t.addListener(() {
    if (!t.status.isRunning &&
        t.status != TransferStatus.paused &&
        !c.isCompleted)
      c.complete();
  });
  await c.future;
  print(
    'iso=$iso ${t.status} ${(mb / (sw.elapsedMilliseconds / 1000)).toStringAsFixed(1)} MB/s',
  );
  await a.dispose();
  await b.dispose();
  await root.delete(recursive: true);
  exit(0);
}
