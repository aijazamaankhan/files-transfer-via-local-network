import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/destinations/destination_manager.dart';
import '../../core/models/transfer_models.dart';
import '../../core/transfer/transfer_receiver.dart';
import '../../core/util/errors.dart';
import '../../ui/format.dart';
import '../../ui/widgets.dart';

/// "Phone wants to send you 12 files" — accept/reject, destination and
/// conflict resolution.
class IncomingRequestDialog extends StatefulWidget {
  const IncomingRequestDialog({
    super.key,
    required this.controller,
    required this.request,
  });
  final AppController controller;
  final IncomingRequest request;

  @override
  State<IncomingRequestDialog> createState() => _IncomingRequestDialogState();
}

class _IncomingRequestDialogState extends State<IncomingRequestDialog> {
  DestinationPlan? _plan;
  ConflictAction _applyAll = ConflictAction.rename;
  bool _perFile = false;
  bool _busy = false;
  String? _error;

  IncomingTransfer get _task => widget.request.task;

  @override
  void initState() {
    super.initState();
    // The default destination is preselected as a suggestion; "Change…"
    // opens the native folder picker.
    _plan = widget.request.defaultPlan;
    _task.addListener(_onTaskChanged);
  }

  @override
  void dispose() {
    _task.removeListener(_onTaskChanged);
    super.dispose();
  }

  void _onTaskChanged() {
    // Sender cancelled or the request timed out while the dialog was open.
    if (_task.status != TransferStatus.awaitingApproval && mounted && !_busy) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _chooseFolder() async {
    final dir = await widget.controller.pickers.chooseDirectory(
      initial:
          _plan?.roots.firstOrNull ??
          widget.controller.settings.downloadDirectory,
      title: 'Save files to…',
    );
    if (dir == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await widget.request.planFor(dir);
      setState(() => _plan = plan);
    } on LanBeamException catch (e) {
      setState(() => _error = e.userMessage);
    } catch (e) {
      setState(() => _error = classifyError(e).userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final plan = _plan;
    if (plan == null) {
      await _chooseFolder();
      return;
    }
    setState(() => _busy = true);
    try {
      if (!_perFile) {
        for (final c in plan.conflicts) {
          c.action = _applyAll;
        }
      }
      await widget.request.accept(plan, applyToAll: _applyAll);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = classifyError(e).userMessage;
      });
    }
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    await widget.request.reject();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = _task;
    final files = t.manifest.files;
    final plan = _plan;
    final conflicts = plan?.conflicts ?? const <PlannedFile>[];
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Row(
        children: [
          DeviceAvatar(info: t.peer, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.peer.name, style: theme.textTheme.titleMedium),
                Text(
                  'wants to send you ${pluralize(files.length, 'file')}',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Card.outlined(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            t.manifest.kind == TransferKind.folder
                                ? Icons.folder_outlined
                                : Icons.insert_drive_file_outlined,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              t.title,
                              style: theme.textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            formatBytes(t.totalBytes),
                            style: theme.textTheme.labelLarge,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final f in files.take(5))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  f.path,
                                  style: theme.textTheme.bodySmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                formatBytes(f.size),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      if (files.length > 5)
                        Text(
                          '+ ${files.length - 5} more',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Save to', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.folder, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      plan == null
                          ? 'Choose a folder'
                          : widget.controller.settings.useDestinationRules &&
                                plan.roots.length > 1
                          ? 'Sorted by file type (${plan.roots.length} folders)'
                          : plan.label,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _chooseFolder,
                    child: const Text('Change…'),
                  ),
                ],
              ),
              if (conflicts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.tertiary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${pluralize(conflicts.length, 'file')} already exist${conflicts.length == 1 ? 's' : ''}',
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (!_perFile)
                  SegmentedButton<ConflictAction>(
                    segments: const [
                      ButtonSegment(
                        value: ConflictAction.rename,
                        label: Text('Keep both'),
                        icon: Icon(Icons.copy_all_outlined),
                      ),
                      ButtonSegment(
                        value: ConflictAction.replace,
                        label: Text('Replace'),
                        icon: Icon(Icons.swap_horiz),
                      ),
                      ButtonSegment(
                        value: ConflictAction.skip,
                        label: Text('Skip'),
                        icon: Icon(Icons.block),
                      ),
                    ],
                    selected: {_applyAll},
                    onSelectionChanged: (s) =>
                        setState(() => _applyAll = s.first),
                  ),
                if (_perFile)
                  for (final c in conflicts)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.file.path,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        DropdownButton<ConflictAction>(
                          value: c.action ?? _applyAll,
                          isDense: true,
                          items: const [
                            DropdownMenuItem(
                              value: ConflictAction.rename,
                              child: Text('Keep both'),
                            ),
                            DropdownMenuItem(
                              value: ConflictAction.replace,
                              child: Text('Replace'),
                            ),
                            DropdownMenuItem(
                              value: ConflictAction.skip,
                              child: Text('Skip'),
                            ),
                          ],
                          onChanged: (v) => setState(() => c.action = v),
                        ),
                      ],
                    ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: !_perFile,
                  title: const Text('Apply to all'),
                  onChanged: (v) => setState(() {
                    _perFile = !(v ?? true);
                    if (_perFile) {
                      for (final c in conflicts) {
                        c.action ??= _applyAll;
                      }
                    }
                  }),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _reject,
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: _busy ? null : _accept,
          child: Text(plan == null ? 'Choose folder' : 'Accept'),
        ),
      ],
    );
  }
}
