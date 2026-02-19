import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';

import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/tv_focus_wrapper.dart';

class TransferScreen extends ConsumerWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final transfers = ref.watch(activeTransfersProvider);
    final hasFinished = transfers.any((t) => t.isFinished);

    // Sort: active first, then by date descending
    final sorted = List<Transfer>.from(transfers)
      ..sort((a, b) {
        if (a.isActive && !b.isActive) return -1;
        if (!a.isActive && b.isActive) return 1;
        return b.createdAt.compareTo(a.createdAt);
      });

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('transferHistory', locale)),
        actions: [
          if (hasFinished)
            TextButton.icon(
              onPressed: () {
                ref.read(activeTransfersProvider.notifier).clearFinished();
              },
              icon: const Icon(Icons.clear_all, size: 20),
              label: Text(AppLocalizations.get('clearCompleted', locale)),
            ),
        ],
      ),
      body: sorted.isEmpty
          ? _EmptyTransfersView(locale: locale)
          : FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: sorted.length,
                itemBuilder: (context, index) {
                  final transfer = sorted[index];
                  return FocusTraversalOrder(
                    order: NumericFocusOrder(index.toDouble()),
                    child: TvFocusWrapper(
                      autofocus: index == 0,
                      child: _TransferCard(
                        transfer: transfer,
                        locale: locale,
                      ),
                    ),
                  );
                },
              ),
            ),
    );
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.swap_horiz_rounded,
              size: 40,
              color: colorScheme.primary.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            AppLocalizations.get('noTransfers', locale),
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              AppLocalizations.get('noTransfersDesc', locale),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transfer card — redesigned with rich info & actions
// ---------------------------------------------------------------------------

class _TransferCard extends StatelessWidget {
  const _TransferCard({
    required this.transfer,
    required this.locale,
  });

  final Transfer transfer;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = _statusColor(transfer.status, colorScheme);
    final isIncoming = transfer.receiverDevice != null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: transfer.status == TransferStatus.completed &&
                transfer.filePath != null
            ? () => _openFile(transfer.filePath!)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Top row: file icon + name + status badge ──
              Row(
                children: [
                  // File type icon
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _fileIcon(transfer.fileName),
                      color: statusColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
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
                        Row(
                          children: [
                            Text(
                              transfer.formattedSize,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '\u00b7',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatDateTime(transfer.createdAt),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (transfer.status == TransferStatus.transferring)
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: statusColor,
                              ),
                            ),
                          ),
                        Text(
                          _localizedStatus(transfer.status, locale),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // ── Progress bar ──
              if (transfer.status == TransferStatus.transferring ||
                  transfer.status == TransferStatus.accepted) ...[
                const SizedBox(height: 12),
                _AnimatedProgressBar(
                  progress: transfer.progress,
                  color: statusColor,
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${transfer.progressPercent}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _formatTransferredSize(transfer),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],

              // ── Device info row ──
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    isIncoming ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      isIncoming
                          ? '${AppLocalizations.get('receivedFrom', locale)}: ${transfer.senderDevice.name}'
                          : '${AppLocalizations.get('sentTo', locale)}: ${transfer.receiverDevice?.name ?? ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        transfer.filePath!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ],

              // ── Action buttons for completed files ──
              if (transfer.status == TransferStatus.completed &&
                  transfer.filePath != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    _ActionChip(
                      icon: Icons.open_in_new_rounded,
                      label: AppLocalizations.get('openFile', locale),
                      onTap: () => _openFile(transfer.filePath!),
                    ),
                    const SizedBox(width: 8),
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
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ──

  void _openFile(String path) {
    try {
      OpenFile.open(path);
    } catch (_) {}
  }

  void _openFolder(String path) {
    try {
      final dir = File(path).parent.path;
      if (Platform.isWindows) {
        Process.run('explorer', ['/select,', path]);
      } else if (Platform.isMacOS) {
        Process.run('open', ['-R', path]);
      } else if (Platform.isLinux) {
        Process.run('xdg-open', [dir]);
      } else {
        OpenFile.open(dir);
      }
    } catch (_) {}
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
      case TransferStatus.completed:
        return const Color(0xFF34C759);
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
// Animated progress bar
// ---------------------------------------------------------------------------

class _AnimatedProgressBar extends StatelessWidget {
  const _AnimatedProgressBar({
    required this.progress,
    required this.color,
  });

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: progress),
        duration: const Duration(milliseconds: 400),
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
