import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/discovery/discovery_service.dart';
import '../../core/models/device_info.dart';
import '../../core/models/trusted_device.dart';
import '../../ui/format.dart';
import '../../ui/widgets.dart';
import '../pairing/pairing_dialogs.dart';
import '../send/send_flow.dart';

class PairedDeviceTile extends StatelessWidget {
  const PairedDeviceTile({
    super.key,
    required this.controller,
    required this.device,
    required this.online,
  });
  final AppController controller;
  final TrustedDevice device;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: DeviceAvatar(info: device.info, online: online),
        title: Text(device.name),
        subtitle: Text(
          online
              ? '${device.info.os.label} · Nearby'
              : '${device.info.os.label} · ${device.lastSeen == null ? 'Not seen yet' : 'Last seen ${formatDateTime(device.lastSeen!)}'}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Send files',
              icon: const Icon(Icons.upload_file),
              onPressed: () =>
                  startSendFlow(context, controller, deviceId: device.id),
            ),
            IconButton(
              tooltip: 'Send folder',
              icon: const Icon(Icons.drive_folder_upload_outlined),
              onPressed: () => startSendFlow(
                context,
                controller,
                deviceId: device.id,
                folder: true,
              ),
            ),
          ],
        ),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (_) =>
              DeviceDetailsSheet(controller: controller, device: device),
        ),
      ),
    );
  }
}

class NearbyDeviceTile extends StatelessWidget {
  const NearbyDeviceTile({
    super.key,
    required this.controller,
    required this.device,
  });
  final AppController controller;
  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    final info = device.info;
    final compatible = info.supportsCurrentProtocol;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: DeviceAvatar(info: info, online: true),
        title: Text(info.name),
        subtitle: Text(
          compatible
              ? '${info.os.label} · ${device.address}'
              : 'Incompatible version (${info.appVersion}) — update LanBeam',
        ),
        trailing: FilledButton.tonal(
          onPressed: compatible
              ? () => runPinPairing(
                  context,
                  controller,
                  host: device.address,
                  port: info.port,
                  fingerprint: info.fingerprint,
                  name: info.name,
                )
              : null,
          child: const Text('Pair'),
        ),
      ),
    );
  }
}

class DeviceDetailsSheet extends StatelessWidget {
  const DeviceDetailsSheet({
    super.key,
    required this.controller,
    required this.device,
  });
  final AppController controller;
  final TrustedDevice device;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final theme = Theme.of(context);
    return NotifierBuilder(
      notifier: engine.trustedDevices,
      builder: (context) {
        final d = engine.trustedDevices.get(device.id) ?? device;
        final global = controller.settings.autoAcceptTrusted;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: DeviceAvatar(info: d.info, size: 48),
                  title: Text(d.name, style: theme.textTheme.titleLarge),
                  subtitle: Text(
                    '${d.info.os.label} · LanBeam ${d.info.appVersion}',
                  ),
                ),
                _row(context, 'Paired', formatDateTime(d.pairedAt)),
                _row(
                  context,
                  'Last address',
                  d.lastAddresses.isEmpty
                      ? '—'
                      : '${d.lastAddresses.first}:${d.info.port}',
                ),
                _row(
                  context,
                  'Verification code',
                  shortFingerprint(d.fingerprint),
                ),
                const SizedBox(height: 8),
                Text(
                  'Incoming files from this device',
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 0,
                      label: Text('Default (${global ? 'accept' : 'ask'})'),
                    ),
                    const ButtonSegment(value: 1, label: Text('Always ask')),
                    const ButtonSegment(value: 2, label: Text('Auto-accept')),
                  ],
                  selected: {
                    d.autoAccept == null ? 0 : (d.autoAccept! ? 2 : 1),
                  },
                  onSelectionChanged: (s) =>
                      engine.setDeviceAutoAccept(d.id, switch (s.first) {
                        1 => false,
                        2 => true,
                        _ => null,
                      }),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.link_off),
                        label: const Text('Unpair'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: Text('Unpair ${d.name}?'),
                              content: const Text(
                                'Both devices will forget each other. You will need to pair again to transfer files.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Unpair'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await engine.unpair(d.id);
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
