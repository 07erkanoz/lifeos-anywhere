import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;

import 'package:anyware/core/logger.dart';
import 'package:anyware/core/responsive.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/transfer/data/transfer_queue.dart';
import 'package:anyware/features/transfer/presentation/file_preview_screen.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:anyware/widgets/app_states.dart';

/// A stable, testable projection of the transfer list used by the responsive
/// screen. Each group is ordered newest first.
class TransferGroups {
  const TransferGroups({
    required this.active,
    required this.attention,
    required this.completed,
  });

  factory TransferGroups.from(List<Transfer> transfers) {
    final active = <Transfer>[];
    final attention = <Transfer>[];
    final completed = <Transfer>[];

    for (final transfer in transfers) {
      if (transfer.isActive) {
        active.add(transfer);
      } else if (transfer.status == TransferStatus.completed) {
        completed.add(transfer);
      } else {
        attention.add(transfer);
      }
    }

    int newestFirst(Transfer a, Transfer b) =>
        b.createdAt.compareTo(a.createdAt);
    active.sort(newestFirst);
    attention.sort(newestFirst);
    completed.sort(newestFirst);

    return TransferGroups(
      active: active,
      attention: attention,
      completed: completed,
    );
  }

  final List<Transfer> active;
  final List<Transfer> attention;
  final List<Transfer> completed;
}

class TransferScreen extends ConsumerWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final transfers = ref.watch(activeTransfersProvider);
    final queueItems =
        ref.watch(transferQueueItemsProvider).valueOrNull ??
        const <QueueItem>[];
    final hasFinished = transfers.any((t) => t.isFinished);

    final groups = TransferGroups.from(transfers);

    final actions = <Widget>[
      if (hasFinished)
        context.isCompact
            ? IconButton(
                onPressed: () {
                  ref.read(activeTransfersProvider.notifier).clearFinished();
                },
                tooltip: AppLocalizations.get('clearCompleted', locale),
                icon: const Icon(Icons.clear_all_rounded),
              )
            : TextButton.icon(
                onPressed: () {
                  ref.read(activeTransfersProvider.notifier).clearFinished();
                },
                icon: const Icon(Icons.clear_all, size: 20),
                label: Text(AppLocalizations.get('clearCompleted', locale)),
              ),
    ];

    final body = transfers.isEmpty && queueItems.isEmpty
        ? _EmptyTransfersView(locale: locale)
        : _GroupedTransferList(
            groups: groups,
            queueItems: queueItems,
            locale: locale,
            addHorizontalPadding: !DesktopShellScope.of(context),
          );

    if (DesktopShellScope.of(context)) {
      return DesktopContentShell(
        title: AppLocalizations.get('transferHistory', locale),
        actions: actions,
        child: body,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('transferHistory', locale)),
        actions: actions,
      ),
      body: body,
    );
  }
}

class _GroupedTransferList extends StatelessWidget {
  const _GroupedTransferList({
    required this.groups,
    required this.queueItems,
    required this.locale,
    required this.addHorizontalPadding,
  });

  final TransferGroups groups;
  final List<QueueItem> queueItems;
  final String locale;
  final bool addHorizontalPadding;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = addHorizontalPadding
        ? context.adaptivePagePadding
        : 0.0;
    var autofocusAssigned = false;

    Widget section({
      required String title,
      required IconData icon,
      required List<Transfer> transfers,
    }) {
      final autofocusFirst = !autofocusAssigned && transfers.isNotEmpty;
      if (autofocusFirst) autofocusAssigned = true;
      return _TransferGroupSection(
        title: title,
        icon: icon,
        transfers: transfers,
        locale: locale,
        autofocusFirst: autofocusFirst,
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        AppSpacing.md,
        horizontalPadding,
        AppSpacing.lg,
      ),
      children: [
        if (queueItems.isNotEmpty)
          _TransferQueueSection(
            items: queueItems,
            locale: locale,
            autofocus:
                groups.active.isEmpty &&
                groups.attention.isEmpty &&
                groups.completed.isEmpty,
          ),
        if (groups.active.isNotEmpty)
          section(
            title: AppLocalizations.get('activeTransfers', locale),
            icon: Icons.sync_rounded,
            transfers: groups.active,
          ),
        if (groups.attention.isNotEmpty)
          section(
            title: AppLocalizations.get('attentionRequired', locale),
            icon: Icons.error_outline_rounded,
            transfers: groups.attention,
          ),
        if (groups.completed.isNotEmpty)
          section(
            title: AppLocalizations.get('recentTransfers', locale),
            icon: Icons.history_rounded,
            transfers: groups.completed,
          ),
      ],
    );
  }
}

class _TransferQueueSection extends ConsumerWidget {
  const _TransferQueueSection({
    required this.items,
    required this.locale,
    required this.autofocus,
  });

  final List<QueueItem> items;
  final String locale;
  final bool autofocus;

  Future<void> _cancelAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.get('cancelQueue', locale)),
        content: Text(AppLocalizations.get('cancelQueueConfirm', locale)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.get('no', locale)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppLocalizations.get('yes', locale)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final queue = await ref.read(transferQueueProvider.future);
    queue.cancelAll();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firstMovable =
        items.isNotEmpty && items.first.status == QueueStatus.sending ? 1 : 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: AppSectionHeader(
              icon: Icons.queue_rounded,
              title: AppLocalizations.get('transferQueue', locale),
              count: items.length.toString(),
              actions: [
                IconButton(
                  autofocus: autofocus,
                  onPressed: () => _cancelAll(context, ref),
                  tooltip: AppLocalizations.get('cancelQueue', locale),
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          for (var index = 0; index < items.length; index++)
            _TransferEntryAnimation(
              key: ValueKey(items[index].id),
              index: index,
              child: _QueuedTransferCard(
                item: items[index],
                locale: locale,
                position: index + 1,
                canMoveUp:
                    items[index].status == QueueStatus.queued &&
                    index > firstMovable,
                canMoveDown:
                    items[index].status == QueueStatus.queued &&
                    index < items.length - 1,
                onMoveUp: () async {
                  final queue = await ref.read(transferQueueProvider.future);
                  queue.move(items[index].id, -1);
                },
                onMoveDown: () async {
                  final queue = await ref.read(transferQueueProvider.future);
                  queue.move(items[index].id, 1);
                },
                onRemove: () async {
                  final queue = await ref.read(transferQueueProvider.future);
                  queue.remove(items[index].id);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _QueuedTransferCard extends StatelessWidget {
  const _QueuedTransferCard({
    required this.item,
    required this.locale,
    required this.position,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });

  final QueueItem item;
  final String locale;
  final int position;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isSending = item.status == QueueStatus.sending;

    final identity = Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
          ),
          child: isSending
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: colors.primary,
                  ),
                )
              : Text(
                  position.toString(),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.basename(item.filePath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${isSending ? AppLocalizations.get('sending', locale) : AppLocalizations.get('waiting', locale)} · ${item.target.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final controls = Wrap(
      spacing: 2,
      children: [
        IconButton(
          onPressed: canMoveUp ? onMoveUp : null,
          tooltip: AppLocalizations.get('moveUp', locale),
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: canMoveDown ? onMoveDown : null,
          tooltip: AppLocalizations.get('moveDown', locale),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: isSending ? null : onRemove,
          tooltip: AppLocalizations.get('removeFromQueue', locale),
          icon: const Icon(Icons.close_rounded),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 460 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.2) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  identity,
                  if (!isSending) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: controls,
                    ),
                  ],
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: identity),
                if (!isSending) controls,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TransferGroupSection extends StatelessWidget {
  const _TransferGroupSection({
    required this.title,
    required this.icon,
    required this.transfers,
    required this.locale,
    required this.autofocusFirst,
  });

  final String title;
  final IconData icon;
  final List<Transfer> transfers;
  final String locale;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: AppSectionHeader(
              icon: icon,
              title: title,
              count: transfers.length.toString(),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          for (var index = 0; index < transfers.length; index++)
            _TransferEntryAnimation(
              key: ValueKey(transfers[index].id),
              index: index,
              child: _TransferCard(
                transfer: transfers[index],
                locale: locale,
                autofocus: autofocusFirst && index == 0,
              ),
            ),
        ],
      ),
    );
  }
}

class _TransferEntryAnimation extends StatelessWidget {
  const _TransferEntryAnimation({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: context.motionDuration(
        Duration(milliseconds: 180 + (index.clamp(0, 4) * 35)),
      ),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - value)),
            child: child,
          ),
        );
      },
    );
  }
}

/// Show a TV-friendly bottom sheet with file actions when a completed transfer
/// card is selected via D-pad.
void _showTransferActions(
  BuildContext context,
  Transfer transfer,
  String locale,
) {
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                transfer.fileName,
                style: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              autofocus: true,
              leading: const Icon(Icons.open_in_new_rounded),
              title: Text(AppLocalizations.get('openFile', locale)),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _openReceivedFile(context, transfer.filePath!, locale);
              },
            ),
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text(AppLocalizations.get('openFolder', locale)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openFolderStatic(transfer.filePath!);
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// Platform channel for Android-native file opening.
const _platformChannel = MethodChannel('com.lifeos.anyware/platform');

/// Opens a file using the platform's default handler.
///
/// On Android, uses a native Intent via MethodChannel (the `open_file` package
/// silently fails on modern Android). On other platforms, falls back to
/// [OpenFile.open].
Future<bool> _openFileStatic(String path) async {
  try {
    if (Platform.isAndroid) {
      final mimeType = lookupMimeType(path) ?? '*/*';
      return await _platformChannel.invokeMethod<bool>('openFile', {
            'path': path,
            'mimeType': mimeType,
          }) ??
          false;
    } else {
      final mimeType = lookupMimeType(path) ?? 'application/octet-stream';
      final result = await OpenFile.open(path, type: mimeType);
      return result.type == ResultType.done;
    }
  } catch (e) {
    AppLogger('Transfer').warning('Failed to open file: $e');
    return false;
  }
}

Future<void> _openExternallyWithFeedback(
  BuildContext context,
  String path,
  String locale,
) async {
  final opened = await _openFileStatic(path);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.get('previewUnavailable', locale)),
      ),
    );
  }
}

Future<void> _openReceivedFile(
  BuildContext context,
  String path,
  String locale,
) async {
  if (!canPreviewFile(path)) {
    await _openExternallyWithFeedback(context, path, locale);
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (previewContext) => FilePreviewScreen(
        path: path,
        locale: locale,
        onOpenExternally: () =>
            _openExternallyWithFeedback(previewContext, path, locale),
      ),
    ),
  );
}

Future<void> _openFolderStatic(String path) async {
  try {
    if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      final dir = File(path).parent.path;
      Process.run('xdg-open', [dir]);
    } else if (Platform.isAndroid) {
      await _platformChannel.invokeMethod('openFolder', {'path': path});
    }
  } catch (e) {
    AppLogger('Transfer').warning('Failed to open folder: $e');
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyTransfersView extends StatelessWidget {
  const _EmptyTransfersView({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.swap_horiz_rounded,
      title: AppLocalizations.get('noTransfers', locale),
      description: AppLocalizations.get('noTransfersDesc', locale),
    );
  }
}

// ---------------------------------------------------------------------------
// Transfer card — redesigned with rich info & actions
// ---------------------------------------------------------------------------

class _TransferCard extends ConsumerWidget {
  const _TransferCard({
    required this.transfer,
    required this.locale,
    this.autofocus = false,
  });

  final Transfer transfer;
  final String locale;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = _statusColor(transfer.status, colorScheme);
    final isIncoming = !transfer.isSending;
    final isTv = Platform.isAndroid && TvDetector.isTVCached;
    final canOpen =
        transfer.status == TransferStatus.completed &&
        transfer.filePath != null;

    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showTransferContextMenu(context, details.globalPosition),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 5),
        child: InkWell(
          autofocus: autofocus,
          borderRadius: BorderRadius.circular(12),
          focusColor: colorScheme.primary.withValues(alpha: 0.12),
          onTap: canOpen
              ? () => isTv
                    ? _openReceivedFile(context, transfer.filePath!, locale)
                    : _showTransferActions(context, transfer, locale)
              : (isTv ? () {} : null),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TransferCardHeader(
                  transfer: transfer,
                  statusColor: statusColor,
                  statusLabel: _localizedStatus(transfer.status, locale),
                  fileIcon: _fileIcon(transfer.fileName),
                  formattedDate: _formatDateTime(transfer.createdAt),
                ),

                // ── Progress bar ──
                if (transfer.status == TransferStatus.transferring ||
                    transfer.status == TransferStatus.accepted ||
                    transfer.status == TransferStatus.paused) ...[
                  const SizedBox(height: 12),
                  _AnimatedProgressBar(
                    progress: transfer.progress,
                    color: statusColor,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    runSpacing: 4,
                    spacing: 12,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${transfer.progressPercent}%',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (transfer.status != TransferStatus.paused &&
                              transfer.speed != null &&
                              transfer.speed! > 0) ...[
                            const SizedBox(width: 8),
                            Text(
                              '${_humanSize(transfer.speed!.round())}/s',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _formatTransferredSize(transfer),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (transfer.status != TransferStatus.paused &&
                              transfer.estimatedTimeLeft != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              _formatEta(transfer.estimatedTimeLeft!),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],

                // ── Device info row ──
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      isIncoming
                          ? Icons.arrow_downward_rounded
                          : Icons.arrow_upward_rounded,
                      size: 14,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isIncoming
                            ? '${AppLocalizations.get('receivedFrom', locale)}: ${transfer.senderDevice.name}'
                            : '${AppLocalizations.get('sentTo', locale)}: ${transfer.receiverDevice?.name ?? ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),

                // ── File path (save location) ──
                if (transfer.filePath != null &&
                    transfer.status == TransferStatus.completed) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.6,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          transfer.filePath!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ],

                // ── Pause/resume and cancel controls ──
                if (transfer.isActive && transfer.isSending) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      if (transfer.status == TransferStatus.transferring ||
                          transfer.status == TransferStatus.paused)
                        _PauseResumeTransferChip(
                          transfer: transfer,
                          locale: locale,
                        ),
                      _CancelTransferChip(transfer: transfer, locale: locale),
                    ],
                  ),
                ],

                // ── Action buttons for completed files ──
                if (!isTv &&
                    transfer.status == TransferStatus.completed &&
                    transfer.filePath != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      _ActionChip(
                        icon: Icons.open_in_new_rounded,
                        label: AppLocalizations.get('openFile', locale),
                        onTap: () => _openReceivedFile(
                          context,
                          transfer.filePath!,
                          locale,
                        ),
                      ),
                      _ActionChip(
                        icon: Icons.folder_open_rounded,
                        label: AppLocalizations.get('openFolder', locale),
                        onTap: () => _openFolder(transfer.filePath!),
                      ),
                    ],
                  ),
                ],

                // ── Error message ──
                if (transfer.error != null &&
                    transfer.status == TransferStatus.failed) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 16,
                          color: colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            transfer.error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.error,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (transfer.status == TransferStatus.failed &&
                    transfer.isSending &&
                    transfer.receiverDevice != null &&
                    transfer.sourceFilePath != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  _RetryTransferChip(transfer: transfer, locale: locale),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Context menu ──

  Future<void> _showTransferContextMenu(
    BuildContext context,
    Offset position,
  ) async {
    final items = <PopupMenuEntry<String>>[];

    if (transfer.status == TransferStatus.completed &&
        transfer.filePath != null) {
      items.addAll([
        PopupMenuItem(
          value: 'openFile',
          child: Row(
            children: [
              const Icon(Icons.open_in_new_rounded, size: 18),
              const SizedBox(width: 10),
              Text(AppLocalizations.get('openFile', locale)),
            ],
          ),
        ),
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          PopupMenuItem(
            value: 'openFolder',
            child: Row(
              children: [
                const Icon(Icons.folder_open_rounded, size: 18),
                const SizedBox(width: 10),
                Text(AppLocalizations.get('openFolder', locale)),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'copyPath',
          child: Row(
            children: [
              const Icon(Icons.copy_rounded, size: 18),
              const SizedBox(width: 10),
              Text(AppLocalizations.get('copyPath', locale)),
            ],
          ),
        ),
      ]);
    }

    if (items.isEmpty) return;

    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: items,
    );
    if (value == null || !context.mounted) return;
    switch (value) {
      case 'openFile':
        await _openReceivedFile(context, transfer.filePath!, locale);
        break;
      case 'openFolder':
        await _openFolderStatic(transfer.filePath!);
        break;
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: transfer.filePath!));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.get('copied', locale)),
              duration: const Duration(seconds: 1),
            ),
          );
        }
        break;
    }
  }

  // ── Helpers ──

  void _openFolder(String path) {
    _openFolderStatic(path);
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(dt.year, dt.month, dt.day);

    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    if (dateDay == today) {
      return time;
    } else {
      return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} $time';
    }
  }

  String _formatEta(Duration eta) {
    if (eta.inHours > 0) {
      return '~${eta.inHours}h ${eta.inMinutes.remainder(60)}m';
    } else if (eta.inMinutes > 0) {
      return '~${eta.inMinutes}m ${eta.inSeconds.remainder(60)}s';
    }
    return '~${eta.inSeconds}s';
  }

  String _formatTransferredSize(Transfer t) {
    final transferred = (t.progress * t.fileSize).round();
    return '${_humanSize(transferred)} / ${t.formattedSize}';
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _localizedStatus(TransferStatus status, String locale) {
    switch (status) {
      case TransferStatus.pending:
        return AppLocalizations.get('pending', locale);
      case TransferStatus.accepted:
        return AppLocalizations.get('accepted', locale);
      case TransferStatus.rejected:
        return AppLocalizations.get('rejected', locale);
      case TransferStatus.transferring:
        return AppLocalizations.get('transferring', locale);
      case TransferStatus.paused:
        return AppLocalizations.get('paused', locale);
      case TransferStatus.completed:
        return AppLocalizations.get('completed', locale);
      case TransferStatus.failed:
        return AppLocalizations.get('failed', locale);
      case TransferStatus.cancelled:
        return AppLocalizations.get('cancelled', locale);
    }
  }

  Color _statusColor(TransferStatus status, ColorScheme colorScheme) {
    switch (status) {
      case TransferStatus.pending:
      case TransferStatus.accepted:
        return colorScheme.tertiary;
      case TransferStatus.transferring:
        return colorScheme.primary;
      case TransferStatus.paused:
        return colorScheme.tertiary;
      case TransferStatus.completed:
        return AppColors.statusConnected;
      case TransferStatus.failed:
        return colorScheme.error;
      case TransferStatus.cancelled:
      case TransferStatus.rejected:
        return colorScheme.onSurfaceVariant;
    }
  }

  IconData _fileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'svg':
      case 'bmp':
        return Icons.image_rounded;
      case 'mp4':
      case 'avi':
      case 'mkv':
      case 'mov':
      case 'wmv':
        return Icons.video_file_rounded;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
      case 'ogg':
        return Icons.audio_file_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'doc':
      case 'docx':
      case 'txt':
      case 'rtf':
        return Icons.description_rounded;
      case 'xls':
      case 'xlsx':
      case 'csv':
        return Icons.table_chart_rounded;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.archive_rounded;
      case 'apk':
      case 'exe':
      case 'msi':
      case 'dmg':
        return Icons.install_desktop_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }
}

// ---------------------------------------------------------------------------
// Responsive transfer card header
// ---------------------------------------------------------------------------

class _TransferCardHeader extends StatelessWidget {
  const _TransferCardHeader({
    required this.transfer,
    required this.statusColor,
    required this.statusLabel,
    required this.fileIcon,
    required this.formattedDate,
  });

  final Transfer transfer;
  final Color statusColor;
  final String statusLabel;
  final IconData fileIcon;
  final String formattedDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(1);

    final fileIdentity = Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(fileIcon, color: statusColor, size: 22),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                transfer.fileName,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              const SizedBox(height: 3),
              Text(
                '${transfer.formattedSize}  ·  $formattedDate',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ],
    );

    final statusBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (transfer.status == TransferStatus.transferring) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: statusColor,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            statusLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 400 || textScale > 1.2;
        if (stack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              fileIdentity,
              const SizedBox(height: AppSpacing.xs),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: statusBadge,
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: fileIdentity),
            const SizedBox(width: AppSpacing.xs),
            statusBadge,
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Animated progress bar
// ---------------------------------------------------------------------------

class _AnimatedProgressBar extends StatelessWidget {
  const _AnimatedProgressBar({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: progress),
        duration: context.motionDuration(AppMotion.progress),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) {
          return LinearProgressIndicator(
            value: value,
            minHeight: 6,
            backgroundColor: color.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(color),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small action chip
// ---------------------------------------------------------------------------

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.primaryContainer.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: colorScheme.primary),
              const SizedBox(width: 5),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Retry and cancel transfer chips
// ---------------------------------------------------------------------------

class _RetryTransferChip extends ConsumerStatefulWidget {
  const _RetryTransferChip({required this.transfer, required this.locale});

  final Transfer transfer;
  final String locale;

  @override
  ConsumerState<_RetryTransferChip> createState() => _RetryTransferChipState();
}

class _RetryTransferChipState extends ConsumerState<_RetryTransferChip> {
  bool _isRetrying = false;

  Future<void> _retry() async {
    final sourcePath = widget.transfer.sourceFilePath;
    final target = widget.transfer.receiverDevice;
    if (_isRetrying || sourcePath == null || target == null) return;

    setState(() => _isRetrying = true);
    try {
      if (!await File(sourcePath).exists()) {
        throw FileSystemException('Source file no longer exists', sourcePath);
      }

      final queue = await ref.read(transferQueueProvider.future);
      queue.enqueue(target, sourcePath);
      ref.read(activeTransfersProvider.notifier).remove(widget.transfer.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppLocalizations.get('retryFailed', widget.locale)}: $error',
          ),
        ),
      );
      setState(() => _isRetrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ActionChip(
      icon: _isRetrying ? Icons.hourglass_top_rounded : Icons.refresh_rounded,
      label: AppLocalizations.get('retry', widget.locale),
      onTap: _retry,
    );
  }
}

class _PauseResumeTransferChip extends ConsumerStatefulWidget {
  const _PauseResumeTransferChip({
    required this.transfer,
    required this.locale,
  });

  final Transfer transfer;
  final String locale;

  @override
  ConsumerState<_PauseResumeTransferChip> createState() =>
      _PauseResumeTransferChipState();
}

class _PauseResumeTransferChipState
    extends ConsumerState<_PauseResumeTransferChip> {
  bool _isChanging = false;

  Future<void> _toggle() async {
    if (_isChanging) return;
    setState(() => _isChanging = true);

    try {
      final sender = await ref.read(fileSenderProvider.future);
      final isPaused = widget.transfer.status == TransferStatus.paused;
      final changed = isPaused
          ? sender.resumeTransfer(widget.transfer.id)
          : await sender.pauseTransfer(widget.transfer.id);
      if (!changed && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.get('transferControlUnavailable', widget.locale),
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.get('transferControlUnavailable', widget.locale),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isChanging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPaused = widget.transfer.status == TransferStatus.paused;
    return _ActionChip(
      icon: _isChanging
          ? Icons.hourglass_top_rounded
          : isPaused
          ? Icons.play_arrow_rounded
          : Icons.pause_rounded,
      label: AppLocalizations.get(isPaused ? 'resume' : 'pause', widget.locale),
      onTap: _toggle,
    );
  }
}

class _CancelTransferChip extends ConsumerWidget {
  const _CancelTransferChip({required this.transfer, required this.locale});

  final Transfer transfer;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.errorContainer.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(AppLocalizations.get('cancelTransfer', locale)),
              content: Text(
                AppLocalizations.get('cancelTransferConfirm', locale),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(AppLocalizations.get('no', locale)),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.error,
                  ),
                  child: Text(AppLocalizations.get('yes', locale)),
                ),
              ],
            ),
          );

          if (confirmed == true) {
            final sender = await ref.read(fileSenderProvider.future);
            final cancelled = sender.cancelTransfer(transfer.id);
            if (cancelled) {
              ref
                  .read(activeTransfersProvider.notifier)
                  .addOrUpdate(
                    transfer.copyWith(status: TransferStatus.cancelled),
                  );
            }
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close_rounded, size: 15, color: colorScheme.error),
              const SizedBox(width: 5),
              Text(
                AppLocalizations.get('cancel', locale),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
