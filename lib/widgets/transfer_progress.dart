import 'package:flutter/material.dart';

import 'package:anyware/features/transfer/domain/transfer.dart';

/// A reusable widget that displays a file transfer's progress and status.
class TransferProgress extends StatelessWidget {
  final Transfer transfer;
  final VoidCallback? onCancel;

  const TransferProgress({
    super.key,
    required this.transfer,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top row: file icon, name/size, status icon, cancel button
            Row(
              children: [
                // File type icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _fileIcon(transfer.fileName),
                    color: colorScheme.onSecondaryContainer,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),

                // File name, size, and device
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        transfer.fileName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitleText(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),

                // Status icon
                _StatusIcon(status: transfer.status),

                // Cancel button (only when active)
                if (transfer.isActive && onCancel != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close),
                    iconSize: 20,
                    tooltip: 'Cancel transfer',
                    style: IconButton.styleFrom(
                      foregroundColor: colorScheme.error,
                      minimumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ],
            ),

            // Progress bar and percentage (only during transfer)
            if (transfer.status == TransferStatus.transferring) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: transfer.progress,
                        minHeight: 6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${transfer.progressPercent}%',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],

            // Status label row
            const SizedBox(height: 8),
            Text(
              transfer.statusLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: _statusColor(transfer.status, colorScheme),
                fontWeight: FontWeight.w500,
              ),
            ),

            // Error message if failed
            if (transfer.status == TransferStatus.failed &&
                transfer.error != null) ...[
              const SizedBox(height: 4),
              Text(
                transfer.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the subtitle text showing file size and device name.
  String _subtitleText() {
    final deviceName = transfer.receiverDevice?.name ??
        transfer.senderDevice.name;
    return '${transfer.formattedSize} \u00b7 $deviceName';
  }

  /// Returns an appropriate icon for the file based on its extension.
  IconData _fileIcon(String fileName) {
    final extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
      case 'svg':
        return Icons.image;
      case 'mp4':
      case 'avi':
      case 'mov':
      case 'mkv':
      case 'wmv':
      case 'flv':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
      case 'ogg':
      case 'wma':
        return Icons.audio_file;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
      case 'txt':
      case 'rtf':
      case 'odt':
        return Icons.description;
      case 'xls':
      case 'xlsx':
      case 'csv':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip;
      case 'apk':
        return Icons.android;
      case 'exe':
      case 'msi':
        return Icons.install_desktop;
      default:
        return Icons.insert_drive_file;
    }
  }

  /// Returns the appropriate color for a given transfer status.
  Color _statusColor(TransferStatus status, ColorScheme colorScheme) {
    switch (status) {
      case TransferStatus.pending:
        return colorScheme.onSurfaceVariant;
      case TransferStatus.accepted:
        return colorScheme.primary;
      case TransferStatus.rejected:
        return colorScheme.error;
      case TransferStatus.transferring:
        return colorScheme.primary;
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.failed:
        return colorScheme.error;
      case TransferStatus.cancelled:
        return colorScheme.onSurfaceVariant;
    }
  }
}

/// Internal widget that displays a status icon for the transfer.
class _StatusIcon extends StatelessWidget {
  final TransferStatus status;

  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _iconAndColor(context);

    return Icon(icon, color: color, size: 22);
  }

  (IconData, Color) _iconAndColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    switch (status) {
      case TransferStatus.pending:
        return (Icons.hourglass_empty, colorScheme.onSurfaceVariant);
      case TransferStatus.accepted:
        return (Icons.thumb_up_alt_outlined, colorScheme.primary);
      case TransferStatus.rejected:
        return (Icons.block, colorScheme.error);
      case TransferStatus.transferring:
        return (Icons.sync, colorScheme.primary);
      case TransferStatus.completed:
        return (Icons.check_circle, Colors.green);
      case TransferStatus.failed:
        return (Icons.error, colorScheme.error);
      case TransferStatus.cancelled:
        return (Icons.cancel, colorScheme.onSurfaceVariant);
    }
  }
}
