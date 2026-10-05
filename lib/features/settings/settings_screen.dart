import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/destinations/file_category.dart';
import '../../core/models/device_info.dart';
import '../../core/models/settings.dart';
import '../../core/networking/network_service.dart';
import '../../core/platform_interfaces.dart';
import '../../core/protocol/protocol.dart';
import '../../platform/platform_services.dart';
import '../../ui/widgets.dart';
import '../devices/device_widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: NotifierBuilder(
        notifier: controller.engine.settings,
        builder: (context) {
          final s = controller.settings;
          final theme = Theme.of(context);
          Future<void> update(AppSettings Function(AppSettings) f) =>
              controller.updateSettings(f);
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              const SectionHeader('Device'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: const Text('Device name'),
                      subtitle: Text(s.deviceName),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final name = await _editText(
                          context,
                          'Device name',
                          s.deviceName,
                          maxLength: 64,
                        );
                        if (name != null && name.trim().isNotEmpty) {
                          await update(
                            (x) => x.copyWith(
                              deviceName: sanitizeDisplayName(name),
                            ),
                          );
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.fingerprint),
                      title: const Text('Verification code'),
                      subtitle: Text(
                        shortFingerprint(
                          controller.engine.identity.fingerprint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SectionHeader('Receiving'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: const Text('Download folder'),
                      subtitle: Text(s.downloadDirectory),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final dir = await controller.pickers.chooseDirectory(
                          initial: s.downloadDirectory,
                          title: 'Default download folder',
                        );
                        if (dir != null)
                          await update(
                            (x) => x.copyWith(downloadDirectory: dir),
                          );
                      },
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.rule_folder_outlined),
                      title: const Text('Sort by file type'),
                      subtitle: const Text(
                        'Save images, videos, documents… to their own folders automatically',
                      ),
                      value: s.useDestinationRules,
                      onChanged: (v) =>
                          update((x) => x.copyWith(useDestinationRules: v)),
                    ),
                    ListTile(
                      enabled: s.useDestinationRules,
                      leading: const SizedBox(width: 24),
                      title: const Text('File-type destinations'),
                      subtitle: Text(
                        s.destinationRules.isEmpty
                            ? 'Everything goes to the download folder'
                            : '${s.destinationRules.length} rule(s) configured',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              DestinationRulesScreen(controller: controller),
                        ),
                      ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.help_outline),
                      title: const Text('Ask where to save'),
                      subtitle: const Text(
                        'Choose a folder for each incoming transfer',
                      ),
                      value: s.askWhereToSave && !s.useDestinationRules,
                      onChanged: s.useDestinationRules
                          ? null
                          : (v) => update((x) => x.copyWith(askWhereToSave: v)),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.verified_user_outlined),
                      title: const Text('Auto-accept from paired devices'),
                      subtitle: const Text(
                        'Skip the confirmation when a paired device sends files (requires a fixed destination)',
                      ),
                      value: s.autoAcceptTrusted,
                      onChanged: (v) =>
                          update((x) => x.copyWith(autoAcceptTrusted: v)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.file_copy_outlined),
                      title: const Text('When a file already exists'),
                      trailing: DropdownButton<ConflictPolicy>(
                        value: s.conflictPolicy,
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(
                            value: ConflictPolicy.ask,
                            child: Text('Ask me'),
                          ),
                          DropdownMenuItem(
                            value: ConflictPolicy.rename,
                            child: Text('Keep both'),
                          ),
                          DropdownMenuItem(
                            value: ConflictPolicy.replace,
                            child: Text('Replace'),
                          ),
                          DropdownMenuItem(
                            value: ConflictPolicy.skip,
                            child: Text('Skip'),
                          ),
                        ],
                        onChanged: (v) => v == null
                            ? null
                            : update((x) => x.copyWith(conflictPolicy: v)),
                      ),
                    ),
                  ],
                ),
              ),

              const SectionHeader('Pairing'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.devices),
                      title: const Text('Paired devices'),
                      subtitle: Text(
                        '${controller.engine.trustedDevices.all.length} device(s)',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              PairedDevicesScreen(controller: controller),
                        ),
                      ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.how_to_reg_outlined),
                      title: const Text('Approve QR pairing requests'),
                      subtitle: const Text(
                        'Ask before a device that scanned your code is paired',
                      ),
                      value: s.requireApprovalForQr,
                      onChanged: (v) =>
                          update((x) => x.copyWith(requireApprovalForQr: v)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('Pairing code valid for'),
                      trailing: DropdownButton<int>(
                        value: s.qrTokenTtlMinutes,
                        underline: const SizedBox(),
                        items: [
                          for (final m in const [1, 2, 5, 10, 30])
                            DropdownMenuItem(value: m, child: Text('$m min')),
                        ],
                        onChanged: (v) => v == null
                            ? null
                            : update((x) => x.copyWith(qrTokenTtlMinutes: v)),
                      ),
                    ),
                  ],
                ),
              ),

              const SectionHeader('Network'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.wifi_tethering),
                      title: const Text('Discoverable'),
                      subtitle: const Text(
                        'Announce this device and find others on the local network',
                      ),
                      value: s.discoveryEnabled,
                      onChanged: (v) =>
                          update((x) => x.copyWith(discoveryEnabled: v)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.settings_ethernet),
                      title: const Text('Transfer port'),
                      subtitle: Text(
                        controller.engine.server.port == s.servicePort
                            ? '${s.servicePort}'
                            : '${s.servicePort} (busy — using ${controller.engine.server.port})',
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final v = await _editText(
                          context,
                          'Transfer port (1024–65535)',
                          '${s.servicePort}',
                          numeric: true,
                          maxLength: 5,
                        );
                        final port = int.tryParse(v ?? '');
                        if (port != null && port >= 1024 && port <= 65535) {
                          await update((x) => x.copyWith(servicePort: port));
                        }
                      },
                    ),
                    FutureBuilder<List<String>>(
                      future: NetworkService.localAddresses(),
                      builder: (context, snap) => ListTile(
                        leading: const Icon(Icons.lan_outlined),
                        title: const Text('This device’s addresses'),
                        subtitle: Text(
                          (snap.data ?? const []).isEmpty
                              ? 'Not connected to a local network'
                              : snap.data!
                                    .map(
                                      (a) =>
                                          '$a:${controller.engine.server.port}',
                                    )
                                    .join('\n'),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'LanBeam works without Internet access. If devices cannot see each other, allow LanBeam '
                        'through your firewall on private networks (TCP ${controller.engine.server.port}, '
                        'UDP ${Protocol.discoveryPort}) and check that your Wi-Fi does not isolate clients.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),

              const SectionHeader('Bluetooth'),
              Card(
                child: FutureBuilder<BluetoothAvailability>(
                  future: controller.bluetooth.availability(),
                  builder: (context, snap) => ListTile(
                    leading: const Icon(Icons.bluetooth_disabled),
                    title: const Text('Bluetooth connection'),
                    subtitle: const Text(
                      'Not available in this version. Bluetooth will be used to find devices and set up the '
                      'connection; files always travel over Wi-Fi for speed. Use Wi-Fi or “Connect by IP” meanwhile.',
                    ),
                    enabled: snap.data != BluetoothAvailability.unsupported,
                  ),
                ),
              ),

              if (isDesktop) ...[
                const SectionHeader('Startup'),
                Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.power_settings_new),
                    title: const Text('Launch at login'),
                    subtitle: const Text(
                      'Be ready to receive files as soon as you sign in',
                    ),
                    value: s.launchAtStartup,
                    onChanged: (v) =>
                        update((x) => x.copyWith(launchAtStartup: v)),
                  ),
                ),
              ],

              const SectionHeader('Notifications'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Notifications'),
                  subtitle: const Text(
                    'Incoming requests and completed transfers',
                  ),
                  value: s.notificationsEnabled,
                  onChanged: (v) async {
                    if (v) await controller.notifications.requestPermission();
                    await update((x) => x.copyWith(notificationsEnabled: v));
                  },
                ),
              ),

              const SectionHeader('Appearance'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme'),
                  trailing: DropdownButton<String>(
                    value: s.themeMode,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: 'system', child: Text('System')),
                      DropdownMenuItem(value: 'light', child: Text('Light')),
                      DropdownMenuItem(value: 'dark', child: Text('Dark')),
                    ],
                    onChanged: (v) => v == null
                        ? null
                        : update((x) => x.copyWith(themeMode: v)),
                  ),
                ),
              ),

              const SectionHeader('About'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: Text('LanBeam ${Protocol.appVersion}'),
                  subtitle: const Text(
                    'Files go directly between your devices over an encrypted connection. Nothing is uploaded '
                    'to a server, and your transfer history stays on this device.',
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

Future<String?> _editText(
  BuildContext context,
  String title,
  String initial, {
  bool numeric = false,
  int? maxLength,
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: maxLength,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        inputFormatters: numeric
            ? [FilteringTextInputFormatter.digitsOnly]
            : null,
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Images → D:\Phone\Pictures, Videos → D:\Phone\Videos, …
class DestinationRulesScreen extends StatelessWidget {
  const DestinationRulesScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('File-type destinations')),
      body: NotifierBuilder(
        notifier: controller.engine.settings,
        builder: (context) {
          final s = controller.settings;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Incoming files are saved to the folder for their type. Folders keep their structure and go '
                  'to the “Folders” destination. Anything without a rule goes to the download folder.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (final cat in FileCategory.values)
                      ListTile(
                        leading: Icon(_icon(cat)),
                        title: Text(cat.label),
                        subtitle: Text(
                          s.destinationRules[cat] ??
                              'Download folder (${s.downloadDirectory})',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (s.destinationRules.containsKey(cat))
                              IconButton(
                                tooltip: 'Use download folder',
                                icon: const Icon(Icons.close),
                                onPressed: () => controller.updateSettings(
                                  (x) => x.copyWith(
                                    destinationRules: Map.of(x.destinationRules)
                                      ..remove(cat),
                                  ),
                                ),
                              ),
                            const Icon(Icons.folder_open),
                          ],
                        ),
                        onTap: () async {
                          final dir = await controller.pickers.chooseDirectory(
                            initial:
                                s.destinationRules[cat] ?? s.downloadDirectory,
                            title: '${cat.label} destination',
                          );
                          if (dir == null) return;
                          await controller.updateSettings(
                            (x) => x.copyWith(
                              destinationRules: {
                                ...x.destinationRules,
                                cat: dir,
                              },
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static IconData _icon(FileCategory c) => switch (c) {
    FileCategory.images => Icons.image_outlined,
    FileCategory.videos => Icons.movie_outlined,
    FileCategory.audio => Icons.music_note_outlined,
    FileCategory.documents => Icons.description_outlined,
    FileCategory.archives => Icons.archive_outlined,
    FileCategory.folders => Icons.folder_copy_outlined,
    FileCategory.other => Icons.insert_drive_file_outlined,
  };
}

class PairedDevicesScreen extends StatelessWidget {
  const PairedDevicesScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    return Scaffold(
      appBar: AppBar(title: const Text('Paired devices')),
      body: NotifierBuilder(
        notifier: engine,
        builder: (context) {
          final online = {
            for (final d in engine.discovery?.devices ?? const []) d.id,
          };
          final devices = engine.trustedDevices.all;
          if (devices.isEmpty) {
            return const Center(
              child: EmptyState(
                icon: Icons.devices_other,
                title: 'No paired devices',
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final d in devices)
                PairedDeviceTile(
                  controller: controller,
                  device: d,
                  online: online.contains(d.id),
                ),
            ],
          );
        },
      ),
    );
  }
}
