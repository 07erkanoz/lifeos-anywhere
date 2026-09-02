import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/core/responsive.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/i18n/app_localizations.dart';

sealed class ShareTarget {
  const ShareTarget();
}

final class DeviceShareTarget extends ShareTarget {
  const DeviceShareTarget(this.device);
  final Device device;
}

final class AccountShareTarget extends ShareTarget {
  const AccountShareTarget(this.account);
  final SyncAccount account;
}

class ShareQueueResult {
  const ShareQueueResult({required this.target, required this.filePaths});

  final ShareTarget target;
  final List<String> filePaths;
}

/// Opens the same destination picker on every platform.
///
/// Compact layouts use a draggable bottom sheet while wider layouts use a
/// constrained dialog. A single available target is returned immediately.
Future<ShareQueueResult?> showShareTargetPicker({
  required BuildContext context,
  required List<Device> devices,
  required List<SyncAccount> accounts,
  required List<String> filePaths,
  required String locale,
}) async {
  final targets = <ShareTarget>[
    ...devices.map(DeviceShareTarget.new),
    ...accounts.map(AccountShareTarget.new),
  ];

  if (targets.isEmpty) return null;
  if (!context.mounted) return null;

  final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.compact;
  if (compact) {
    return showModalBottomSheet<ShareQueueResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        minChildSize: 0.64,
        maxChildSize: 0.96,
        builder: (_, scrollController) => _ShareQueueContent(
          devices: devices,
          accounts: accounts,
          filePaths: filePaths,
          locale: locale,
          scrollController: scrollController,
          onSubmitted: (result) => Navigator.of(sheetContext).pop(result),
        ),
      ),
    );
  }

  return showDialog<ShareQueueResult>(
    context: context,
    builder: (dialogContext) {
      final size = MediaQuery.sizeOf(dialogContext);
      final width = (size.width - 48).clamp(300.0, 580.0).toDouble();
      final height = (size.height - 72).clamp(420.0, 680.0).toDouble();
      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        contentPadding: EdgeInsets.zero,
        content: SizedBox(
          width: width,
          height: height,
          child: _ShareQueueContent(
            devices: devices,
            accounts: accounts,
            filePaths: filePaths,
            locale: locale,
            onSubmitted: (result) => Navigator.of(dialogContext).pop(result),
          ),
        ),
      );
    },
  );
}

class _ShareQueueContent extends StatefulWidget {
  const _ShareQueueContent({
    required this.devices,
    required this.accounts,
    required this.filePaths,
    required this.locale,
    required this.onSubmitted,
    this.scrollController,
  });

  final List<Device> devices;
  final List<SyncAccount> accounts;
  final List<String> filePaths;
  final String locale;
  final ValueChanged<ShareQueueResult> onSubmitted;
  final ScrollController? scrollController;

  @override
  State<_ShareQueueContent> createState() => _ShareQueueContentState();
}

class _ShareQueueContentState extends State<_ShareQueueContent> {
  static const _recentTargetsKey = 'share_queue_recent_targets';

  late final List<String> _paths;
  final Map<String, int?> _sizes = {};
  List<String> _recentTargetIds = const [];
  ShareTarget? _selectedTarget;
  bool _addingFiles = false;

  @override
  void initState() {
    super.initState();
    _paths = widget.filePaths.toSet().toList();
    final targets = <ShareTarget>[
      ...widget.devices.map(DeviceShareTarget.new),
      ...widget.accounts.map(AccountShareTarget.new),
    ];
    if (targets.length == 1) _selectedTarget = targets.first;
    _refreshSizes();
    _loadRecentTargets();
  }

  String _targetId(ShareTarget target) => switch (target) {
    DeviceShareTarget(:final device) => 'device:${device.id}',
    AccountShareTarget(:final account) => 'account:${account.id}',
  };

  void _moveSelection(List<ShareTarget> targets, int delta) {
    if (targets.isEmpty) return;
    final selectedId = _selectedTarget == null
        ? null
        : _targetId(_selectedTarget!);
    final currentIndex = targets.indexWhere(
      (target) => _targetId(target) == selectedId,
    );
    final nextIndex = currentIndex < 0
        ? (delta > 0 ? 0 : targets.length - 1)
        : (currentIndex + delta).clamp(0, targets.length - 1);
    setState(() => _selectedTarget = targets[nextIndex]);
  }

  int _recentRank(String id) {
    final index = _recentTargetIds.indexOf(id);
    return index < 0 ? 999 : index;
  }

  Future<void> _loadRecentTargets() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recentTargetIds = prefs.getStringList(_recentTargetsKey) ?? const [];
    });
  }

  Future<void> _refreshSizes() async {
    final next = <String, int?>{};
    for (final path in _paths) {
      try {
        final stat = await FileStat.stat(path);
        next[path] = stat.type == FileSystemEntityType.file ? stat.size : null;
      } catch (_) {
        next[path] = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _sizes
        ..clear()
        ..addAll(next);
    });
  }

  Future<void> _addFiles() async {
    if (_addingFiles) return;
    setState(() => _addingFiles = true);
    try {
      final result = await FilePickerHelper.pickFiles(allowMultiple: true);
      if (!mounted || result == null) return;
      final additions = result.files
          .map((file) => file.path)
          .whereType<String>();
      setState(() {
        for (final path in additions) {
          if (!_paths.contains(path)) _paths.add(path);
        }
      });
      await _refreshSizes();
    } finally {
      if (mounted) setState(() => _addingFiles = false);
    }
  }

  Future<void> _submit() async {
    final target = _selectedTarget;
    if (target == null || _paths.isEmpty) return;

    final id = _targetId(target);
    final recent = <String>[
      id,
      ..._recentTargetIds.where((value) => value != id),
    ].take(5).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentTargetsKey, recent);
    if (!mounted) return;
    widget.onSubmitted(
      ShareQueueResult(target: target, filePaths: List.unmodifiable(_paths)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final totalBytes = _sizes.values.whereType<int>().fold<int>(
      0,
      (total, size) => total + size,
    );
    final devices = [...widget.devices]
      ..sort(
        (a, b) => _recentRank(
          'device:${a.id}',
        ).compareTo(_recentRank('device:${b.id}')),
      );
    final accounts = [...widget.accounts]
      ..sort(
        (a, b) => _recentRank(
          'account:${a.id}',
        ).compareTo(_recentRank('account:${b.id}')),
      );
    final orderedTargets = <ShareTarget>[
      ...devices.map(DeviceShareTarget.new),
      ...accounts.map(AccountShareTarget.new),
    ];
    final targetsById = {
      for (final target in orderedTargets) _targetId(target): target,
    };
    final recentTargets = _recentTargetIds
        .map((id) => targetsById[id])
        .whereType<ShareTarget>()
        .take(3)
        .toList();

    return Column(
      children: [
        Flexible(
          flex: 4,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            children: [
              Text(
                AppLocalizations.get('selectDeviceToSend', widget.locale),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final stackSummary =
                      constraints.maxWidth < 360 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.4;
                  final summary = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.format('filesCount', widget.locale, {
                          'count': '${_paths.length}',
                        }),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (totalBytes > 0)
                        Text(
                          _formatBytes(totalBytes),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  );
                  final addButton = OutlinedButton.icon(
                    onPressed: _addingFiles ? null : _addFiles,
                    icon: _addingFiles
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded, size: 18),
                    label: Text(
                      AppLocalizations.get('selectFile', widget.locale),
                    ),
                  );
                  if (stackSummary) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [summary, const SizedBox(height: 8), addButton],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: summary),
                      const SizedBox(width: 12),
                      addButton,
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              if (_paths.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      AppLocalizations.get('selectFile', widget.locale),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                )
              else
                for (final path in _paths)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.insert_drive_file_outlined,
                        color: colors.onSurfaceVariant,
                      ),
                      title: Text(
                        path.split(Platform.pathSeparator).last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _sizes[path] == null
                          ? null
                          : Text(_formatBytes(_sizes[path]!)),
                      trailing: IconButton(
                        tooltip: AppLocalizations.get('remove', widget.locale),
                        onPressed: () {
                          setState(() {
                            _paths.remove(path);
                            _sizes.remove(path);
                          });
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: colors.outlineVariant),
                      ),
                    ),
                  ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant),
        Expanded(
          flex: 3,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                  _moveSelection(orderedTargets, 1);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                  _moveSelection(orderedTargets, -1);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: _ShareTargetContent(
                devices: devices,
                accounts: accounts,
                recentTargets: recentTargets,
                filePaths: _paths,
                locale: widget.locale,
                scrollController: widget.scrollController,
                selectedTargetId: _selectedTarget == null
                    ? null
                    : _targetId(_selectedTarget!),
                showFileSummary: false,
                showTitle: false,
                onSelected: (target) =>
                    setState(() => _selectedTarget = target),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: colors.outlineVariant),
        SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stackActions =
                  constraints.maxWidth < 420 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.4;
              final cancel = OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(AppLocalizations.get('cancel', widget.locale)),
              );
              final send = FilledButton.icon(
                onPressed: _selectedTarget != null && _paths.isNotEmpty
                    ? _submit
                    : null,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(AppLocalizations.get('sendFiles', widget.locale)),
              );
              return Padding(
                padding: const EdgeInsets.all(16),
                child: stackActions
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [send, const SizedBox(height: 8), cancel],
                      )
                    : Row(
                        children: [
                          Expanded(child: cancel),
                          const SizedBox(width: 10),
                          Expanded(child: send),
                        ],
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ShareTargetContent extends StatelessWidget {
  const _ShareTargetContent({
    required this.devices,
    required this.accounts,
    required this.recentTargets,
    required this.filePaths,
    required this.locale,
    required this.onSelected,
    this.scrollController,
    this.selectedTargetId,
    this.showFileSummary = true,
    this.showTitle = true,
  });

  final List<Device> devices;
  final List<SyncAccount> accounts;
  final List<ShareTarget> recentTargets;
  final List<String> filePaths;
  final String locale;
  final ValueChanged<ShareTarget> onSelected;
  final ScrollController? scrollController;
  final String? selectedTargetId;
  final bool showFileSummary;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final firstFileName = filePaths.isEmpty
        ? ''
        : filePaths.first.split(Platform.pathSeparator).last;
    final fileSummary = filePaths.isEmpty
        ? AppLocalizations.get('files', locale)
        : filePaths.length == 1
        ? firstFileName
        : '${AppLocalizations.format('filesCount', locale, {'count': '${filePaths.length}'})} · $firstFileName';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.get('selectDeviceToSend', locale),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (showFileSummary) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: 0.55,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.attach_file_rounded,
                          size: 17,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            fileSummary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (showTitle) Divider(height: 1, color: colors.outlineVariant),
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
            children: [
              if (recentTargets.isNotEmpty) ...[
                _SectionLabel(
                  icon: Icons.history_rounded,
                  label: AppLocalizations.get('recentTargets', locale),
                  count: recentTargets.length,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: recentTargets.map((target) {
                      final id = _shareTargetId(target);
                      return ChoiceChip(
                        selected: selectedTargetId == id,
                        avatar: Icon(_shareTargetIcon(target), size: 17),
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            _shareTargetTitle(target),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        onSelected: (_) => onSelected(target),
                      );
                    }).toList(),
                  ),
                ),
              ],
              if (devices.isNotEmpty) ...[
                _SectionLabel(
                  icon: Icons.wifi_tethering_rounded,
                  label: AppLocalizations.get('devices', locale),
                  count: devices.length,
                ),
                ...devices.map(
                  (device) => _TargetTile(
                    icon: _platformIcon(device.platformIcon),
                    iconColor: colors.onSurfaceVariant,
                    title: device.name,
                    subtitle: '${device.platformLabel} · ${device.ip}',
                    selected: selectedTargetId == 'device:${device.id}',
                    onTap: () => onSelected(DeviceShareTarget(device)),
                  ),
                ),
              ],
              if (accounts.isNotEmpty) ...[
                if (devices.isNotEmpty) const SizedBox(height: 12),
                _SectionLabel(
                  icon: Icons.cloud_outlined,
                  label: AppLocalizations.get('servers', locale),
                  count: accounts.length,
                ),
                ...accounts.map((account) {
                  final visual = _accountVisual(account.providerType);
                  return _TargetTile(
                    icon: visual.$1,
                    iconColor: visual.$2,
                    title: account.name,
                    subtitle: account.subtitle,
                    badge: account.providerType.shortLabel,
                    selected: selectedTargetId == 'account:${account.id}',
                    onTap: () => onSelected(AccountShareTarget(account)),
                  );
                }),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _shareTargetId(ShareTarget target) => switch (target) {
  DeviceShareTarget(:final device) => 'device:${device.id}',
  AccountShareTarget(:final account) => 'account:${account.id}',
};

String _shareTargetTitle(ShareTarget target) => switch (target) {
  DeviceShareTarget(:final device) => device.name,
  AccountShareTarget(:final account) => account.name,
};

IconData _shareTargetIcon(ShareTarget target) => switch (target) {
  DeviceShareTarget(:final device) => _platformIcon(device.platformIcon),
  AccountShareTarget(:final account) => _accountVisual(account.providerType).$1,
};

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.count,
  });

  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label · $count',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
    this.selected = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String? badge;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        selected: selected,
        selectedColor: colors.onSurface,
        selectedTileColor: colors.surfaceContainerHighest,
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: iconColor.withValues(alpha: 0.12),
          child: Icon(icon, size: 20, color: iconColor),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.chevron_right_rounded,
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onTap: onTap,
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Shared progress UI for quick uploads to cloud and server accounts.
class ServerUploadProgressDialog extends StatefulWidget {
  const ServerUploadProgressDialog({
    super.key,
    required this.stream,
    required this.totalFiles,
    required this.serverName,
    required this.locale,
  });

  final Stream<(int, int, String)> stream;
  final int totalFiles;
  final String serverName;
  final String locale;

  @override
  State<ServerUploadProgressDialog> createState() =>
      _ServerUploadProgressDialogState();
}

class _ServerUploadProgressDialogState
    extends State<ServerUploadProgressDialog> {
  int _completed = 0;
  String _currentFile = '';
  String? _error;
  bool _done = false;
  bool _closeScheduled = false;
  StreamSubscription<(int, int, String)>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(
      (event) {
        final (completed, total, fileName) = event;
        if (!mounted) return;
        setState(() {
          _completed = completed;
          _currentFile = fileName;
          if (completed >= total) _done = true;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _error = error.toString());
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _done = true);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_done && _error == null && !_closeScheduled) {
      _closeScheduled = true;
      final navigator = Navigator.of(context);
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) navigator.pop();
      });
    }

    return AlertDialog(
      title: AnimatedSwitcher(
        duration: context.motionDuration(AppMotion.standard),
        child: Text(
          _error != null
              ? AppLocalizations.get('uploadFailed', widget.locale)
              : _done
              ? AppLocalizations.get('uploadComplete', widget.locale)
              : AppLocalizations.get('uploadingToServer', widget.locale),
          key: ValueKey((_error != null, _done)),
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              )
            else ...[
              LinearProgressIndicator(
                value: widget.totalFiles > 0
                    ? _completed / widget.totalFiles
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                _done
                    ? '$_completed / ${widget.totalFiles}'
                    : '$_completed / ${widget.totalFiles}  —  $_currentFile',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null || _done)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.get('ok', widget.locale)),
          ),
      ],
    );
  }
}

IconData _platformIcon(String platformIcon) {
  switch (platformIcon) {
    case 'phone_android':
      return Icons.phone_android_rounded;
    case 'tv':
      return Icons.tv_rounded;
    case 'desktop_windows':
      return Icons.desktop_windows_rounded;
    case 'phone_iphone':
      return Icons.phone_iphone_rounded;
    case 'computer':
      return Icons.computer_rounded;
    default:
      return Icons.devices_rounded;
  }
}

(IconData, Color) _accountVisual(SyncProviderType type) {
  switch (type) {
    case SyncProviderType.sftp:
      return (Icons.dns_rounded, const Color(0xFF6366F1));
    case SyncProviderType.ftp:
      return (Icons.folder_shared_rounded, const Color(0xFF795548));
    case SyncProviderType.webdav:
      return (Icons.language_rounded, const Color(0xFF00897B));
    case SyncProviderType.gdrive:
      return (Icons.cloud_rounded, const Color(0xFF34A853));
    case SyncProviderType.onedrive:
      return (Icons.cloud_queue_rounded, const Color(0xFF0078D4));
  }
}
