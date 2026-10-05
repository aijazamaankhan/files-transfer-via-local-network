import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/app_controller.dart';
import '../../core/models/transfer_models.dart';
import '../../core/transfer/transfer_service.dart';
import '../../core/transfer/transfer_task.dart';
import '../../platform/platform_services.dart';
import '../../ui/format.dart';
import '../../ui/widgets.dart';

/// Card showing one transfer with progress, speed, ETA and controls.
class TransferCard extends StatelessWidget {
  const TransferCard({
    super.key,
    required this.controller,
    required this.task,
    this.compact = false,
  });
  final AppController controller;
  final TransferTask task;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return NotifierBuilder(
      notifier: task,
      builder: (context) {
        final theme = Theme.of(context);
        final t = task;
        final outgoing = t.direction == TransferDirection.outgoing;
        final showProgress =
            t.status == TransferStatus.active ||
            t.status == TransferStatus.paused ||
            (t.status == TransferStatus.failed && t.transferredBytes > 0);
        final details = <String>[
          '${formatBytes(t.transferredBytes)} of ${formatBytes(t.totalBytes)}',
          if (t.status == TransferStatus.active && t.bytesPerSecond > 0)
            formatSpeed(t.bytesPerSecond),
          if (t.status == TransferStatus.active && t.eta != null)
            formatEta(t.eta),
        ];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (_) =>
                  TransferDetailsSheet(controller: controller, task: t),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        child: Icon(
                          outgoing ? Icons.north_east : Icons.south_west,
                          size: 18,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.title,
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${outgoing ? 'To' : 'From'} ${t.peer.name} · ${pluralize(t.files.length, 'file')}',
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      StatusChip(t.status, direction: t.direction),
                      _Actions(controller: controller, task: t),
                    ],
                  ),
                  if (showProgress) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: LinearProgressIndicator(
                        value: t.progress,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(details.join(' · '), style: theme.textTheme.bodySmall),
                    if (!compact && t.currentFile != null)
                      Text(
                        t.currentFile!.file.path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                  if (t.status == TransferStatus.awaitingApproval && outgoing)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Waiting for ${t.peer.name} to accept…',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (t.error != null &&
                      !t.status.isRunning &&
                      t.status != TransferStatus.completed)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: Text(
                        t.error!.userMessage,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  if (t.status == TransferStatus.pending && t.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: Text(
                        'Reconnecting… (${t.error!.userMessage})',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.controller, required this.task});
  final AppController controller;
  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;
    final t = task;
    final buttons = <Widget>[];
    switch (t.status) {
      case TransferStatus.active:
        buttons.add(
          IconButton(
            tooltip: 'Pause',
            icon: const Icon(Icons.pause_circle_outline),
            onPressed: () => engine.pauseTransfer(t),
          ),
        );
      case TransferStatus.paused:
        buttons.add(
          IconButton(
            tooltip: 'Resume',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => engine.resumeTransfer(t),
          ),
        );
      case TransferStatus.failed when t is OutgoingTransfer:
        buttons.add(
          IconButton(
            tooltip: 'Retry',
            icon: const Icon(Icons.refresh),
            onPressed: () => engine.resumeTransfer(t),
          ),
        );
      default:
    }
    final finished =
        t.status.isFinal ||
        (t.status == TransferStatus.failed && t is OutgoingTransfer);
    return PopupMenuButton<String>(
      tooltip: 'More',
      itemBuilder: (_) => [
        if (!t.status.isFinal)
          const PopupMenuItem(value: 'cancel', child: Text('Cancel transfer')),
        if (t.direction == TransferDirection.incoming &&
            t.status == TransferStatus.completed &&
            isDesktop)
          const PopupMenuItem(value: 'open', child: Text('Show in folder')),
        if (finished)
          const PopupMenuItem(
            value: 'dismiss',
            child: Text('Remove from list'),
          ),
      ],
      onSelected: (v) async {
        switch (v) {
          case 'cancel':
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Cancel transfer?'),
                content: Text(
                  '“${t.title}” will be stopped and partial data removed.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Keep'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Cancel transfer'),
                  ),
                ],
              ),
            );
            if (ok == true) await engine.cancelTransfer(t);
          case 'open':
            final saved = t.files.values
                .map((f) => f.savedPath)
                .whereType<String>()
                .firstOrNull;
            if (saved != null) await revealInFileManager(saved);
          case 'dismiss':
            engine.dismiss(t.id);
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...buttons,
          const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.more_vert),
          ),
        ],
      ),
    );
  }
}

/// Per-file breakdown of a transfer.
class TransferDetailsSheet extends StatelessWidget {
  const TransferDetailsSheet({
    super.key,
    required this.controller,
    required this.task,
  });
  final AppController controller;
  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => NotifierBuilder(
        notifier: task,
        builder: (context) {
          final theme = Theme.of(context);
          final files = task.files.values.toList();
          return ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(task.title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '${task.direction == TransferDirection.outgoing ? 'To' : 'From'} ${task.peer.name} · '
                '${formatBytes(task.totalBytes)} · started ${formatDateTime(task.startedAt)}',
                style: theme.textTheme.bodySmall,
              ),
              if (task.destinationLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Saving to ${task.destinationLabel}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              for (final f in files)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (f.state) {
                      FileTransferState.done => Icons.check_circle,
                      FileTransferState.skipped => Icons.remove_circle_outline,
                      FileTransferState.failed => Icons.error_outline,
                      FileTransferState.verifying => Icons.verified_outlined,
                      FileTransferState.transferring => Icons.sync,
                      FileTransferState.queued => Icons.schedule,
                    },
                    color: switch (f.state) {
                      FileTransferState.done => Colors.green.shade600,
                      FileTransferState.failed => theme.colorScheme.error,
                      _ => theme.colorScheme.outline,
                    },
                  ),
                  title: Text(f.file.path, overflow: TextOverflow.ellipsis),
                  subtitle: f.error != null
                      ? Text(
                          f.error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        )
                      : f.state == FileTransferState.transferring
                      ? LinearProgressIndicator(
                          value: f.file.size == 0
                              ? null
                              : f.transferred / f.file.size,
                        )
                      : f.savedPath != null &&
                            p.basename(f.savedPath!) != f.file.name
                      ? Text('Saved as ${p.basename(f.savedPath!)}')
                      : null,
                  trailing: Text(
                    formatBytes(f.file.size),
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap:
                      f.savedPath != null &&
                          (Platform.isWindows ||
                              Platform.isMacOS ||
                              Platform.isLinux)
                      ? () => revealInFileManager(f.savedPath!)
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transfers')),
      body: NotifierBuilder(
        notifier: controller.engine,
        builder: (context) {
          final transfers = controller.engine.transfers;
          if (transfers.isEmpty) {
            return const Center(
              child: EmptyState(
                icon: Icons.swap_vert_circle_outlined,
                title: 'No active transfers',
                message: 'Files you send or receive appear here.',
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final t in transfers)
                TransferCard(controller: controller, task: t),
            ],
          );
        },
      ),
    );
  }
}
