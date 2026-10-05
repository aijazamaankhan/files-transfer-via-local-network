import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_controller.dart';
import '../../core/models/device_info.dart';
import '../../core/networking/network_service.dart';
import '../../core/protocol/protocol.dart';
import '../../core/security/pairing_service.dart';
import '../../core/util/errors.dart';
import '../../ui/widgets.dart';

/// Asked on the device that displayed the QR code.
class PairingApprovalDialog extends StatelessWidget {
  const PairingApprovalDialog({super.key, required this.prompt});
  final PairingApprovalPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final d = prompt.device;
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.link),
      title: const Text('Pair with this device?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: DeviceAvatar(info: d),
            title: Text(d.name),
            subtitle: Text('${d.os.label} · ${prompt.remoteAddress}'),
          ),
          const SizedBox(height: 8),
          Text(
            'Only approve if you just scanned this device’s pairing code. '
            'Paired devices can send you files.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Verification code: ${shortFingerprint(d.fingerprint)}',
            style: theme.textTheme.labelMedium,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Approve'),
        ),
      ],
    );
  }
}

/// Shows the PIN another device must type to pair with us.
class PinDisplayDialog extends StatefulWidget {
  const PinDisplayDialog({
    super.key,
    required this.prompt,
    required this.onCancel,
  });
  final PairingPinPrompt prompt;
  final VoidCallback onCancel;

  @override
  State<PinDisplayDialog> createState() => _PinDisplayDialogState();
}

class _PinDisplayDialogState extends State<PinDisplayDialog> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.prompt.expiresAt.difference(DateTime.now());
    final pin = widget.prompt.pin;
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.pin_outlined),
      title: Text('Pair with ${widget.prompt.device.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter this PIN on the other device:'),
          const SizedBox(height: 16),
          SelectableText(
            '${pin.substring(0, 3)} ${pin.substring(3)}',
            style: theme.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 6,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            left.isNegative ? 'Expired' : 'Expires in ${left.inSeconds}s',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.onCancel();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Displays this device's pairing QR code (refreshes before expiry).
class QrPairingDialog extends StatefulWidget {
  const QrPairingDialog({super.key, required this.controller});
  final AppController controller;

  @override
  State<QrPairingDialog> createState() => _QrPairingDialogState();
}

class _QrPairingDialogState extends State<QrPairingDialog> {
  QrPairingPayload? _payload;
  DateTime? _expires;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refresh();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_expires != null && DateTime.now().isAfter(_expires!)) {
        _refresh();
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _refresh() async {
    final payload = await widget.controller.engine.createQrPayload();
    if (!mounted) return;
    setState(() {
      _payload = payload;
      _expires = DateTime.now().add(
        Duration(minutes: widget.controller.settings.qrTokenTtlMinutes),
      );
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.controller.engine.pairing.invalidateQrToken();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    final theme = Theme.of(context);
    final left = _expires?.difference(DateTime.now());
    return AlertDialog(
      title: const Text('Pair a device'),
      content: SizedBox(
        width: 340,
        child: p == null
            ? const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Scan this code with LanBeam on your phone.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: QrImageView(
                      data: p.toUri(),
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Code refreshes in ${left == null || left.isNegative ? 0 : left.inSeconds}s · single use',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Divider(height: 28),
                  Text(
                    'No camera? On the other device open “Connect by IP” and enter:',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  for (final a in p.addresses.take(3))
                    SelectableText(
                      '$a:${p.port}',
                      style: theme.textTheme.titleSmall,
                    ),
                  const SizedBox(height: 6),
                  Text(
                    'Verification code: ${shortFingerprint(p.fingerprint)}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Camera-based QR scanner (falls back to pasting the code where no camera
/// plugin is available, e.g. Windows/Linux).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, required this.controller});
  final AppController controller;

  static bool get cameraSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _scanner = QrScanScreen.cameraSupported
      ? MobileScannerController(formats: const [BarcodeFormat.qrCode])
      : null;
  final _manual = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void dispose() {
    _scanner?.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _handle(String raw) async {
    if (_busy) return;
    final QrPairingPayload payload;
    try {
      payload = QrPairingPayload.parse(raw);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Waiting for ${payload.name} to approve…';
    });
    await _scanner?.stop();
    try {
      final device = await widget.controller.engine.pairWithQr(payload);
      if (!mounted) return;
      widget.controller.toast('Paired with ${device.name}');
      Navigator.pop(context, true);
    } on LanBeamException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
        _error = e.userMessage;
      });
      await _scanner?.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_scanner != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _scanner,
                      onDetect: (capture) {
                        final raw = capture.barcodes.firstOrNull?.rawValue;
                        if (raw != null) _handle(raw);
                      },
                      errorBuilder: (context, error) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                error.errorCode ==
                                        MobileScannerErrorCode.permissionDenied
                                    ? 'Allow camera access to scan pairing codes, or paste the code below.'
                                    : 'Camera unavailable (${error.errorCode.name}). Paste the code below instead.',
                                textAlign: TextAlign.center,
                              ),
                              if (error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied)
                                TextButton(
                                  onPressed: widget
                                      .controller
                                      .permissions
                                      .openSettings,
                                  child: const Text('Open settings'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_busy)
                      Container(
                        color: Colors.black54,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text(
            'On your computer, open LanBeam and choose “Pair device” to show a code.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Flexible(child: Text(_status!)),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          ExpansionTile(
            title: const Text('Paste a pairing code instead'),
            initiallyExpanded: _scanner == null,
            children: [
              TextField(
                controller: _manual,
                decoration: const InputDecoration(
                  labelText: 'lanbeam://pair?…',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _busy ? null : () => _handle(_manual.text),
                  child: const Text('Pair'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for the 6-digit PIN shown on the other device.
class PinEntryDialog extends StatefulWidget {
  const PinEntryDialog({super.key, required this.deviceName, this.error});
  final String deviceName;
  final String? error;

  @override
  State<PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<PinEntryDialog> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _pin.text.replaceAll(' ', '');
    if (v.length == 6) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.pin_outlined),
    title: Text('Enter PIN for ${widget.deviceName}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Type the 6-digit PIN now shown on the other device.'),
        const SizedBox(height: 16),
        TextField(
          controller: _pin,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(letterSpacing: 8),
          decoration: InputDecoration(
            counterText: '',
            errorText: widget.error,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Pair')),
    ],
  );
}

/// Full PIN pairing flow against [host]:[port] whose certificate is
/// [fingerprint]. Returns true when paired.
Future<bool> runPinPairing(
  BuildContext context,
  AppController controller, {
  required String host,
  required int port,
  required String fingerprint,
  required String name,
}) async {
  final engine = controller.engine;
  final session = await _withProgress(
    context,
    'Asking $name to show a PIN…',
    () => engine.startPinPairing(host, port, fingerprint),
  );
  if (session == null || !context.mounted) return false;
  String? error;
  for (var attempt = 0; attempt < Protocol.pinMaxAttempts; attempt++) {
    if (!context.mounted) break;
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => PinEntryDialog(deviceName: name, error: error),
    );
    if (pin == null || !context.mounted) {
      session.cancel();
      return false;
    }
    try {
      final device = await session.submit(pin);
      controller.toast('Paired with ${device.name}');
      return true;
    } on LanBeamException catch (e) {
      if (e.kind == FailureKind.pairingFailed) {
        error = 'Incorrect PIN, try again';
        continue;
      }
      controller.toast(e.userMessage, error: true);
      return false;
    }
  }
  controller.toast('Too many attempts. Start pairing again.', error: true);
  return false;
}

Future<T?> _withProgress<T>(
  BuildContext context,
  String label,
  Future<T> Function() task,
) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  );
  try {
    return await task();
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(classifyError(e).userMessage),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return null;
  } finally {
    navigator.pop();
  }
}

/// Manual connection by IP address (when discovery is blocked).
class ConnectByIpDialog extends StatefulWidget {
  const ConnectByIpDialog({super.key, required this.controller});
  final AppController controller;

  @override
  State<ConnectByIpDialog> createState() => _ConnectByIpDialogState();
}

class _ConnectByIpDialogState extends State<ConnectByIpDialog> {
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;
  DeviceInfo? _found;
  (String, int)? _target;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final parsed = NetworkService.parseHostPort(
      _address.text,
      Protocol.defaultServicePort,
    );
    if (parsed == null) {
      setState(() => _error = 'Enter an address like 192.168.1.20:45872');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _found = null;
    });
    try {
      final info = await widget.controller.engine.probe(parsed.$1, parsed.$2);
      setState(() {
        _found = info;
        _target = parsed;
      });
    } on LanBeamException catch (e) {
      setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair() async {
    final info = _found!;
    final target = _target!;
    final engine = widget.controller.engine;
    final existing = engine.trustedDevices.get(info.id);
    if (existing != null && existing.fingerprint == info.fingerprint) {
      engine.trustedDevices.touch(
        info.id,
        addresses: [target.$1],
        port: target.$2,
      );
      widget.controller.toast(
        '${info.name} is already paired — address updated',
      );
      Navigator.pop(context, true);
      return;
    }
    final navigator = Navigator.of(context);
    final ok = await runPinPairing(
      context,
      widget.controller,
      host: target.$1,
      port: target.$2,
      fingerprint: info.fingerprint,
      name: info.name,
    );
    if (ok) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final found = _found;
    return AlertDialog(
      title: const Text('Connect using IP address'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the address shown on the other device (Settings › Network or the pairing screen).',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Address',
                hintText: '192.168.1.20:${Protocol.defaultServicePort}',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _probe(),
            ),
            if (found != null) ...[
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: DeviceAvatar(info: found),
                title: Text(found.name),
                subtitle: Text(
                  '${found.os.label} · LanBeam ${found.appVersion}',
                ),
              ),
              Text(
                'Verification code: ${shortFingerprint(found.fingerprint)}\n'
                'Check that the other device shows the same code.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (found == null)
          FilledButton(
            onPressed: _busy ? null : _probe,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Connect'),
          )
        else
          FilledButton(onPressed: _pair, child: const Text('Pair')),
      ],
    );
  }
}
