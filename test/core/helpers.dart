import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:lanbeam/core/engine.dart';
import 'package:lanbeam/core/models/device_info.dart';
import 'package:lanbeam/core/models/settings.dart';
import 'package:lanbeam/core/models/transfer_models.dart';
import 'package:lanbeam/core/security/pairing_service.dart';
import 'package:lanbeam/core/transfer/transfer_task.dart';
import 'package:path/path.dart' as p;

/// A running engine bound to loopback with its own temp directories.
class TestPeer {
  TestPeer._(this.engine, this.root);

  final LanBeamEngine engine;
  final Directory root;

  String get downloads => p.join(root.path, 'downloads');
  String get data => p.join(root.path, 'data');

  static Future<TestPeer> start(
    String name, {
    Directory? reuseRoot,
    bool isolateChecksums = false,
    AppSettings Function(AppSettings)? settings,
    int? port,
  }) async {
    final root = reuseRoot ?? await Directory.systemTemp.createTemp('lanbeam_$name');
    final defaults = AppSettings(
      deviceName: name,
      downloadDirectory: p.join(root.path, 'downloads'),
      askWhereToSave: false,
      autoAcceptTrusted: true,
      conflictPolicy: ConflictPolicy.rename,
      servicePort: port ?? 0,
    );
    final engine = LanBeamEngine(
      EngineConfig(
        dataDirectory: p.join(root.path, 'data'),
        defaultSettings: settings?.call(defaults) ?? defaults,
        deviceType: DeviceType.desktop,
        enableDiscovery: false,
        useIsolateChecksums: isolateChecksums,
        bindAddress: InternetAddress.loopbackIPv4,
      ),
    );
    await engine.start();
    return TestPeer._(engine, root);
  }

  Future<void> stop({bool deleteFiles = true}) async {
    await engine.dispose();
    if (deleteFiles) await root.delete(recursive: true).catchError((_) => root);
  }
}

/// Pairs [a] with [b] using the QR flow (b displays, a scans); approves on b.
Future<void> pairPeers(TestPeer a, TestPeer b) async {
  final sub = b.engine.pairing.prompts.listen((prompt) {
    if (prompt is PairingApprovalPrompt) prompt.respond(true);
  });
  final payload = await b.engine.createQrPayload();
  final fixed = QrPairingPayload(
    deviceId: payload.deviceId,
    name: payload.name,
    addresses: ['127.0.0.1'],
    port: payload.port,
    fingerprint: payload.fingerprint,
    token: payload.token,
  );
  await a.engine.pairWithQr(QrPairingPayload.parse(fixed.toUri()));
  await sub.cancel();
}

/// Writes a file of [size] pseudo-random bytes and returns its SHA-256.
Future<String> writeRandomFile(String path, int size, {int seed = 1}) async {
  await Directory(p.dirname(path)).create(recursive: true);
  final rnd = Random(seed);
  final sink = File(path).openWrite();
  final out = AccumulatorSinkDigest();
  final hasher = sha256.startChunkedConversion(out);
  const chunk = 1 << 20;
  var remaining = size;
  while (remaining > 0) {
    final n = min(chunk, remaining);
    final buf = Uint8List(n);
    for (var i = 0; i < n; i += 4) {
      final v = rnd.nextInt(1 << 32);
      for (var j = 0; j < 4 && i + j < n; j++) {
        buf[i + j] = (v >> (8 * j)) & 0xff;
      }
    }
    sink.add(buf);
    hasher.add(buf);
    remaining -= n;
  }
  await sink.close();
  hasher.close();
  return out.value.toString();
}

Future<String> sha256File(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class AccumulatorSinkDigest implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Waits until [task] reaches a non-running status (or [status] if given).
Future<void> waitForStatus(
  TransferTask task,
  bool Function(TransferStatus) predicate, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  if (predicate(task.status)) return;
  final c = Completer<void>();
  void listener() {
    if (predicate(task.status) && !c.isCompleted) c.complete();
  }

  task.addListener(listener);
  try {
    await c.future.timeout(timeout, onTimeout: () {
      throw TimeoutException('status was ${task.status} (${task.error})');
    });
  } finally {
    task.removeListener(listener);
  }
}

Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
