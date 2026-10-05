// ignore_for_file: avoid_print
/// Headless LanBeam peer for scripting, servers and interoperability tests.
///
///   dart run tool/lanbeam_cli.dart --data DIR [--name NAME] [--out DIR] COMMAND
///
/// Commands:
///   serve                     Receive files (auto-accepts paired devices).
///   qr                        Print a pairing code, then serve (approves pairing).
///   pair-pin HOST:PORT        Pair using the PIN shown on the other device
///                             (read from --pin-file, polled, or stdin).
///   devices                   List paired devices.
///   send DEVICE PATH...       Send files/folders to a paired device (name or id).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lanbeam/core/engine.dart';
import 'package:lanbeam/core/models/device_info.dart';
import 'package:lanbeam/core/models/settings.dart';
import 'package:lanbeam/core/models/transfer_models.dart';
import 'package:lanbeam/core/networking/network_service.dart';
import 'package:lanbeam/core/protocol/protocol.dart';
import 'package:lanbeam/core/security/pairing_service.dart';
import 'package:lanbeam/core/transfer/file_scanner.dart';
import 'package:lanbeam/core/transfer/transfer_task.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final args = List.of(argv);
  String? opt(String name) {
    final i = args.indexOf('--$name');
    if (i < 0 || i + 1 >= args.length) return null;
    final v = args[i + 1];
    args.removeRange(i, i + 2);
    return v;
  }

  final data =
      opt('data') ??
      p.join(Platform.environment['HOME'] ?? '.', '.lanbeam-cli');
  final name = opt('name') ?? 'LanBeam CLI';
  final out = opt('out') ?? p.join(data, 'received');
  final port = int.tryParse(opt('port') ?? '') ?? Protocol.defaultServicePort;
  final pinFile = opt('pin-file');
  if (args.isEmpty) {
    print(
      'usage: lanbeam_cli --data DIR [--name N] [--out DIR] serve|qr|pair-pin|devices|send',
    );
    exit(64);
  }

  final engine = LanBeamEngine(
    EngineConfig(
      dataDirectory: data,
      deviceType: DeviceType.desktop,
      defaultSettings: AppSettings(
        deviceName: name,
        downloadDirectory: out,
        askWhereToSave: false,
        autoAcceptTrusted: true,
        conflictPolicy: ConflictPolicy.rename,
        servicePort: port,
      ),
    ),
  );
  await engine.start();
  await engine.updateSettings(
    (s) => s.copyWith(deviceName: name, downloadDirectory: out),
  );
  print(
    '${engine.localInfo.name} ready on port ${engine.server.port} '
    '(code ${shortFingerprint(engine.identity.fingerprint)})',
  );

  void watch(TransferTask t) {
    var last = '';
    t.addListener(() {
      final line =
          '${t.direction.name} ${t.title}: ${t.status.name} '
          '${(t.progress * 100).toStringAsFixed(0)}%';
      if (line != last) {
        last = line;
        print(line + (t.error != null ? ' (${t.error!.userMessage})' : ''));
      }
    });
  }

  engine.receiver.added.listen(watch);
  engine.pairing.prompts.listen((prompt) {
    if (prompt is PairingApprovalPrompt) {
      print('Approving pairing request from ${prompt.device.name}');
      prompt.respond(true);
    } else if (prompt is PairingPinPrompt) {
      print('PIN for ${prompt.device.name}: ${prompt.pin}');
    } else if (prompt is PairingCompletedPrompt) {
      print('Paired with ${prompt.device.name}');
    }
  });

  switch (args.first) {
    case 'serve':
      await _forever();
    case 'qr':
      final payload = await engine.createQrPayload();
      print(payload.toUri());
      await _forever();
    case 'devices':
      for (final d in engine.trustedDevices.all) {
        print(
          '${d.id}  ${d.name}  ${d.info.os.label}  ${d.lastAddresses.join(',')}:${d.info.port}',
        );
      }
      await engine.dispose();
    case 'pair-pin':
      final target = NetworkService.parseHostPort(
        args[1],
        Protocol.defaultServicePort,
      )!;
      final info = await engine.probe(target.$1, target.$2);
      print(
        'Found ${info.name} (code ${shortFingerprint(info.fingerprint)}); requesting PIN…',
      );
      final session = await engine.startPinPairing(
        target.$1,
        target.$2,
        info.fingerprint,
      );
      final pin = await _readPin(pinFile);
      final trusted = await session.submit(pin);
      print('Paired with ${trusted.name} (${trusted.id})');
      await engine.dispose();
    case 'send':
      final query = args[1];
      final device = engine.trustedDevices.all.firstWhere(
        (d) => d.id == query || d.name == query,
        orElse: () {
          print('No paired device "$query"');
          exit(1);
        },
      );
      final t = await engine.send(device.id, [
        for (final path in args.skip(2)) LocalPathSelection(path),
      ]);
      watch(t);
      final done = Completer<void>();
      t.addListener(() {
        if (!t.isRunning &&
            !done.isCompleted &&
            t.status != TransferStatus.paused)
          done.complete();
      });
      await done.future;
      print('Result: ${t.status.name}');
      await engine.dispose();
      exit(t.status == TransferStatus.completed ? 0 : 1);
    default:
      print('Unknown command ${args.first}');
      exit(64);
  }
}

Future<String> _readPin(String? pinFile) async {
  if (pinFile == null) {
    stdout.write('PIN: ');
    return stdin.readLineSync(encoding: utf8)!.trim();
  }
  print('Waiting for PIN in $pinFile');
  while (true) {
    final f = File(pinFile);
    if (await f.exists()) {
      final v = (await f.readAsString()).trim();
      if (v.length == 6) {
        await f.delete();
        return v;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

Future<void> _forever() => Completer<void>().future;
