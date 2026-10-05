import 'package:flutter/material.dart';

import '../core/models/device_info.dart';
import '../core/models/transfer_models.dart';
import '../core/util/notifier.dart';

/// Rebuilds when a core [Notifier] changes.
class NotifierBuilder extends StatefulWidget {
  const NotifierBuilder({
    super.key,
    required this.notifier,
    required this.builder,
  });

  final Notifier notifier;
  final WidgetBuilder builder;

  @override
  State<NotifierBuilder> createState() => _NotifierBuilderState();
}

class _NotifierBuilderState extends State<NotifierBuilder> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_changed);
  }

  @override
  void didUpdateWidget(NotifierBuilder old) {
    super.didUpdateWidget(old);
    if (old.notifier != widget.notifier) {
      old.notifier.removeListener(_changed);
      widget.notifier.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

IconData deviceIcon(DeviceType type, DeviceOs os) => switch (type) {
  DeviceType.phone =>
    os == DeviceOs.ios ? Icons.phone_iphone : Icons.phone_android,
  DeviceType.tablet => Icons.tablet_mac,
  DeviceType.laptop => Icons.laptop,
  DeviceType.desktop =>
    os == DeviceOs.macos ? Icons.desktop_mac : Icons.desktop_windows,
};

class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({
    super.key,
    required this.info,
    this.online = false,
    this.size = 44,
  });
  final DeviceInfo info;
  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
          child: Icon(
            deviceIcon(info.deviceType, info.os),
            color: scheme.onPrimaryContainer,
            size: size * 0.55,
          ),
        ),
        if (online)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: Colors.green.shade500,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// Coloured status label for transfers.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.direction});
  final TransferStatus status;
  final TransferDirection? direction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      TransferStatus.pending => ('Connecting', scheme.tertiary),
      TransferStatus.awaitingApproval => (
        direction == TransferDirection.incoming
            ? 'Needs approval'
            : 'Waiting for approval',
        scheme.tertiary,
      ),
      TransferStatus.active => ('Transferring', scheme.primary),
      TransferStatus.paused => ('Paused', scheme.secondary),
      TransferStatus.completed => ('Completed', Colors.green.shade600),
      TransferStatus.failed => ('Interrupted', scheme.error),
      TransferStatus.cancelled => ('Cancelled', scheme.outline),
      TransferStatus.rejected => ('Declined', scheme.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}
