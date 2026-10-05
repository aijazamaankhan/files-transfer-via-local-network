import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/trusted_device.dart';
import '../../core/transfer/file_scanner.dart';
import '../../core/util/errors.dart';
import '../../ui/format.dart';
import '../../ui/widgets.dart';

/// Send flow: 1) pick files/folder, 2) pick device, 3) confirm, 4) start.
Future<void> startSendFlow(
  BuildContext context,
  AppController controller, {
  String? deviceId,
  List<SendSelection>? selections,
  bool folder = false,
}) async {
  var picked = selections;
  if (picked == null) {
    try {
      picked = folder
          ? await controller.pickers.pickFolder()
          : await controller.pickers.pickFiles();
    } catch (e) {
      controller.toast(classifyError(e).userMessage, error: true);
      return;
    }
  }
  if (picked == null || picked.isEmpty || !context.mounted) return;

  // Scan (stat) everything first so the confirmation shows real totals.
  final ScanResult scan;
  try {
    scan = await _scanWithProgress(context, picked);
  } catch (e) {
    controller.toast(classifyError(e).userMessage, error: true);
    return;
  }
  if (scan.files.isEmpty) {
    controller.toast(
      'There is nothing to send in this selection.',
      error: true,
    );
    return;
  }
  if (!context.mounted) return;

  var targetId = deviceId;
  targetId ??= await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DevicePickerSheet(controller: controller),
  );
  if (targetId == null || !context.mounted) return;
  final device = controller.engine.trustedDevices.get(targetId);
  if (device == null) return;

  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ConfirmSheet(device: device, scan: scan),
  );
  if (confirmed != true) return;
  try {
    await controller.engine.sendScanned(device.id, scan);
    controller.tab.value = 1;
  } catch (e) {
    controller.toast(classifyError(e).userMessage, error: true);
  }
}

Future<ScanResult> _scanWithProgress(
  BuildContext context,
  List<SendSelection> picked,
) async {
  final navigator = Navigator.of(context);
  var shown = false;
  final timer = Timer(const Duration(milliseconds: 300), () {
    shown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('Preparing files…'),
          ],
        ),
      ),
    );
  });
  try {
    return await FileScanner().scan(picked);
  } finally {
    timer.cancel();
    if (shown) navigator.pop();
  }
}

/// Lists paired devices, online ones first.
class DevicePickerSheet extends StatelessWidget {
  const DevicePickerSheet({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    return NotifierBuilder(
      notifier: engine,
      builder: (context) {
        final online = <String>{
          for (final d in engine.discovery?.devices ?? const []) d.id,
        };
        final devices = engine.trustedDevices.all
          ..sort(
            (a, b) => (online.contains(b.id) ? 1 : 0).compareTo(
              online.contains(a.id) ? 1 : 0,
            ),
          );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Send to', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (devices.isEmpty)
                  const EmptyState(
                    icon: Icons.devices_other,
                    title: 'No paired devices',
                    message: 'Pair a device first from the home screen.',
                  ),
                for (final d in devices)
                  ListTile(
                    leading: DeviceAvatar(
                      info: d.info,
                      online: online.contains(d.id),
                    ),
                    title: Text(d.name),
                    subtitle: Text(
                      online.contains(d.id)
                          ? 'Nearby'
                          : 'Not seen on this network — will try last address',
                    ),
                    onTap: () => Navigator.pop(context, d.id),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.device, required this.scan});
  final TrustedDevice device;
  final ScanResult scan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = scan.files.length == 1
        ? scan.files.first.relativePath.split('/').last
        : scan.files.first.relativePath.contains('/') &&
              scan.kind.name == 'folder'
        ? scan.files.first.relativePath.split('/').first
        : pluralize(scan.files.length, 'file');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Ready to send', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inventory_2_outlined, size: 32),
              title: Text(title, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${pluralize(scan.files.length, 'file')} · ${formatBytes(scan.totalSize)}'
                '${scan.skipped > 0 ? ' · ${scan.skipped} skipped (links/unreadable)' : ''}',
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: DeviceAvatar(info: device.info, size: 36),
              title: Text(device.name),
              subtitle: Text(device.info.os.label),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.send),
              label: const Text('Send'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
