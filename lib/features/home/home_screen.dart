import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/networking/network_service.dart';
import '../../ui/widgets.dart';
import '../devices/device_widgets.dart';
import '../history/history_screen.dart';
import '../pairing/pairing_dialogs.dart';
import '../send/send_flow.dart';
import '../transfers/transfer_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<String> _addresses = const [];
  Timer? _addressTimer;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _loadAddresses();
    // Wi-Fi changes alter our IP; refresh periodically.
    _addressTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _loadAddresses(),
    );
  }

  @override
  void dispose() {
    _addressTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAddresses() async {
    final a = await NetworkService.localAddresses();
    if (mounted && a.join() != _addresses.join())
      setState(() => _addresses = a);
  }

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    return Scaffold(
      appBar: AppBar(
        title: const Text('LanBeam'),
        actions: [
          IconButton(
            tooltip: 'Look for devices',
            icon: const Icon(Icons.refresh),
            onPressed: () => engine.discovery?.refresh(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: NotifierBuilder(
        notifier: engine,
        builder: (context) {
          final discovered = engine.discovery?.devices ?? const [];
          final onlineIds = {for (final d in discovered) d.id};
          final paired = engine.trustedDevices.all;
          final pairedIds = {for (final d in paired) d.id};
          final nearby = discovered
              .where((d) => !pairedIds.contains(d.id))
              .toList();
          final active = engine.transfers
              .where((t) => t.status.isRunning || t.status.name == 'paused')
              .toList();
          final recent = engine.history.records.take(3).toList();
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final left = <Widget>[
                _ThisDeviceCard(controller: controller, addresses: _addresses),
                const SizedBox(height: 12),
                _SendActions(controller: controller),
                SectionHeader(
                  'Paired devices',
                  trailing: Text('${paired.length}'),
                ),
                if (paired.isEmpty)
                  Card.outlined(
                    child: EmptyState(
                      icon: Icons.devices_other,
                      title: 'No paired devices yet',
                      message: controller.engine.localInfo.deviceType.isMobile
                          ? 'Scan the QR code shown on your computer, or pair with a nearby device below.'
                          : 'Click “Pair device” and scan the code with your phone.',
                    ),
                  ),
                for (final d in paired)
                  PairedDeviceTile(
                    controller: controller,
                    device: d,
                    online: onlineIds.contains(d.id),
                  ),
                SectionHeader(
                  'Nearby devices',
                  trailing: engine.discovery?.isRunning == true
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Discovery off'),
                ),
                if (nearby.isEmpty)
                  const Card.outlined(
                    child: EmptyState(
                      icon: Icons.wifi_find,
                      title: 'Looking for devices…',
                      message:
                          'Open LanBeam on the other device and make sure both are on the same Wi-Fi. '
                          'If nothing shows up, use “Connect by IP”.',
                    ),
                  ),
                for (final d in nearby)
                  NearbyDeviceTile(controller: controller, device: d),
              ];
              final right = <Widget>[
                SectionHeader(
                  'Transfers',
                  trailing: TextButton(
                    onPressed: () => controller.tab.value = 1,
                    child: const Text('See all'),
                  ),
                ),
                if (active.isEmpty)
                  const Card.outlined(
                    child: EmptyState(
                      icon: Icons.check_circle_outline,
                      title: 'Nothing in progress',
                    ),
                  ),
                for (final t in active.take(3))
                  TransferCard(controller: controller, task: t, compact: true),
                SectionHeader(
                  'Recent',
                  trailing: TextButton(
                    onPressed: () => controller.tab.value = 2,
                    child: const Text('History'),
                  ),
                ),
                if (recent.isEmpty)
                  const Card.outlined(
                    child: EmptyState(
                      icon: Icons.history,
                      title: 'No transfers yet',
                    ),
                  ),
                for (final r in recent)
                  HistoryTile(controller: controller, record: r),
              ];
              if (wide) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: left,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: right,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [...left, ...right],
              );
            },
          );
        },
      ),
    );
  }
}

class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.controller, required this.addresses});
  final AppController controller;
  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = controller.engine.localInfo;
    final running = controller.engine.server.isRunning;
    final canScan = QrScanScreen.cameraSupported;
    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DeviceAvatar(info: info, online: running, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        running
                            ? addresses.isEmpty
                                  ? 'Ready · not connected to a network'
                                  : 'Ready to receive · ${addresses.first}:${info.port}'
                            : 'Receiving is unavailable',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Pair device'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => QrPairingDialog(controller: controller),
                  ),
                ),
                if (canScan)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR code'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => QrScanScreen(controller: controller),
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.lan_outlined),
                  label: const Text('Connect by IP'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ConnectByIpDialog(controller: controller),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SendActions extends StatelessWidget {
  const _SendActions({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget big(IconData icon, String label, String sub, VoidCallback onTap) =>
        Expanded(
          child: Card.outlined(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 28, color: theme.colorScheme.primary),
                    const SizedBox(height: 10),
                    Text(label, style: theme.textTheme.titleMedium),
                    Text(sub, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        );
    final drop = controller.engine.localInfo.deviceType.isMobile
        ? ''
        : ' · or drop them here';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          big(
            Icons.upload_file,
            'Send files',
            'Photos, videos, documents$drop',
            () => startSendFlow(context, controller),
          ),
          const SizedBox(width: 8),
          big(
            Icons.drive_folder_upload_outlined,
            'Send folder',
            'Keeps the folder structure',
            () => startSendFlow(context, controller, folder: true),
          ),
        ],
      ),
    );
  }
}
