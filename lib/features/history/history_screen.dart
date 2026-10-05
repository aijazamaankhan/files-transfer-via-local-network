import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/history_record.dart';
import '../../core/models/transfer_models.dart';
import '../../core/util/errors.dart';
import '../../platform/platform_services.dart';
import '../../ui/format.dart';
import '../../ui/widgets.dart';

enum _Filter { all, sent, received, failed }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  _Filter _filter = _Filter.all;

  bool _matches(HistoryRecord r) => switch (_filter) {
    _Filter.all => true,
    _Filter.sent => r.direction == TransferDirection.outgoing,
    _Filter.received => r.direction == TransferDirection.incoming,
    _Filter.failed => r.status != TransferStatus.completed,
  };

  @override
  Widget build(BuildContext context) {
    final history = widget.controller.engine.history;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Clear transfer history?'),
                  content: const Text('Received files are not deleted.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (ok == true) await history.clear();
            },
          ),
        ],
      ),
      body: NotifierBuilder(
        notifier: history,
        builder: (context) {
          final records = history.records.where(_matches).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final f in _Filter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(switch (f) {
                              _Filter.all => 'All',
                              _Filter.sent => 'Sent',
                              _Filter.received => 'Received',
                              _Filter.failed => 'Not completed',
                            }),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: records.isEmpty
                    ? const Center(
                        child: EmptyState(
                          icon: Icons.history,
                          title: 'No transfers',
                          message: 'History is stored only on this device.',
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: records.length,
                        itemBuilder: (_, i) => HistoryTile(
                          controller: widget.controller,
                          record: records[i],
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class HistoryTile extends StatelessWidget {
  const HistoryTile({
    super.key,
    required this.controller,
    required this.record,
  });
  final AppController controller;
  final HistoryRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = record;
    final outgoing = r.direction == TransferDirection.outgoing;
    final live = controller.engine.outgoingById(r.transferId);
    final canResume =
        outgoing &&
        r.resumable &&
        r.resumeData != null &&
        (live == null || !live.isRunning) &&
        r.status != TransferStatus.completed;
    final parts = <String>[
      formatDateTime(r.startedAt),
      '${outgoing ? 'To' : 'From'} ${r.peerName}',
      formatBytes(r.totalBytes),
      if (r.duration != null && r.status == TransferStatus.completed)
        formatDuration(r.duration!),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          outgoing ? Icons.north_east : Icons.south_west,
          color: r.status == TransferStatus.completed
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        title: Text(r.title, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${parts.join(' · ')}${r.error != null && r.status != TransferStatus.completed ? '\n${r.error}' : ''}',
        ),
        isThreeLine: r.error != null && r.status != TransferStatus.completed,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusChip(r.status, direction: r.direction),
            PopupMenuButton<String>(
              itemBuilder: (_) => [
                if (canResume)
                  const PopupMenuItem(value: 'resume', child: Text('Resume')),
                if (!outgoing && r.destination != null && isDesktop)
                  const PopupMenuItem(
                    value: 'open',
                    child: Text('Show in folder'),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Remove from history'),
                ),
              ],
              onSelected: (v) async {
                switch (v) {
                  case 'resume':
                    try {
                      await controller.engine.resumeFromHistory(r);
                      controller.tab.value = 1;
                    } catch (e) {
                      controller.toast(
                        classifyError(e).userMessage,
                        error: true,
                      );
                    }
                  case 'open':
                    await revealInFileManager(r.destination!);
                  case 'delete':
                    await controller.engine.history.remove(r.transferId);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
