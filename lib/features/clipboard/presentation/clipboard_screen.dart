import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';

/// Dedicated Pano (Clipboard) screen showing clipboard sharing history
/// as modern note-style cards with one-tap copy and delete actions.
class ClipboardScreen extends ConsumerWidget {
  const ClipboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final entries = ref.watch(clipboardHistoryProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isDesktopShell = DesktopShellScope.of(context);

    final actions = <Widget>[
      IconButton(
        icon: const Icon(Icons.content_paste_go_rounded),
        tooltip: AppLocalizations.get('clipboardPasteAndSend', locale),
        onPressed: () => _pasteAndSend(context, ref, locale),
      ),
      if (entries.isNotEmpty)
        TextButton.icon(
          onPressed: () {
            ref.read(clipboardHistoryProvider.notifier).clear();
          },
          icon: const Icon(Icons.clear_all_rounded, size: 20),
          label: Text(AppLocalizations.get('clearAll', locale)),
        ),
    ];

    final body = entries.isEmpty
        ? _EmptyClipboardView(
            locale: locale,
            isDark: isDark,
            onSend: () => _pasteAndSend(context, ref, locale),
          )
        : ListView.builder(
            padding: EdgeInsets.only(
              top: 8,
              bottom: isDesktopShell ? 24 : 80, // extra padding for FAB on mobile
              left: 16,
              right: 16,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _ClipboardCard(
                entry: entry,
                locale: locale,
                isDark: isDark,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: entry.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.get('copied', locale),
                      ),
                      backgroundColor: AppColors.neonGreen,
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                onDelete: () {
                  ref
                      .read(clipboardHistoryProvider.notifier)
                      .removeAt(index);
                },
              );
            },
          );

    if (isDesktopShell) {
      return DesktopContentShell(
        title: AppLocalizations.get('clipboard', locale),
        actions: actions,
        child: body,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('clipboard', locale)),
        actions: actions,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _pasteAndSend(context, ref, locale),
        backgroundColor: AppColors.neonGreen,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.send_rounded),
        label: Text(
          AppLocalizations.get('clipboardSend', locale),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: body,
    );
  }
  /// Reads the device clipboard and sends it to the paired sync target device.
  Future<void> _pasteAndSend(
    BuildContext context, WidgetRef ref, String locale,
  ) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.get('clipboardEmpty', locale)),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // Find paired target device.
      final target = ref.read(clipboardSyncTargetProvider);
      if (target == null) {
        // No target — try first available device.
        final devices = ref.read(devicesProvider).valueOrNull ?? [];
        if (devices.isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.get('noDevices', locale)),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        // Show device picker if multiple.
        if (devices.length == 1) {
          if (!context.mounted) return;
          await _sendClipboardTo(context, ref, locale, text, devices.first);
        } else {
          if (!context.mounted) return;
          _showDevicePicker(context, ref, locale, text, devices);
        }
      } else {
        if (!context.mounted) return;
        await _sendClipboardTo(context, ref, locale, text, target);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Clipboard error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _sendClipboardTo(
    BuildContext context, WidgetRef ref, String locale,
    String text, dynamic target,
  ) async {
    final localDevice = ref.read(localDeviceProvider).valueOrNull;
    final clipboardService = ref.read(clipboardServiceProvider);

    await clipboardService.sendClipboard(
      target,
      text,
      senderName: localDevice?.name ?? 'Unknown',
      senderDeviceId: localDevice?.id ?? '',
    );

    // Add to local history.
    ref.read(clipboardHistoryProvider.notifier).addEntry(
      ClipboardEntry(
        text: text,
        senderName: localDevice?.name ?? 'This Device',
        senderDeviceId: localDevice?.id ?? '',
        timestamp: DateTime.now(),
      ),
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppLocalizations.get('clipboardSentTo', locale)} ${target.name}',
          ),
          backgroundColor: AppColors.neonGreen,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showDevicePicker(
    BuildContext context, WidgetRef ref, String locale,
    String text, List<dynamic> devices,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                AppLocalizations.get('syncSelectDevice', locale),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            for (final device in devices)
              ListTile(
                leading: const Icon(Icons.devices),
                title: Text(device.name),
                subtitle: Text(device.ip),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _sendClipboardTo(context, ref, locale, text, device);
                },
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyClipboardView extends StatelessWidget {
  const _EmptyClipboardView({
    required this.locale,
    required this.isDark,
    required this.onSend,
  });

  final String locale;
  final bool isDark;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.neonBlue.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.content_paste_rounded,
                size: 40,
                color: AppColors.neonBlue.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              AppLocalizations.get('clipboardNoEntries', locale),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: isDark ? AppColors.textPrimary : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('clipboardNoEntriesDesc', locale),
              style: TextStyle(
                fontSize: 14,
                color: isDark ? AppColors.textSecondary : Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            // ── Prominent send CTA button ──
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: onSend,
                icon: const Icon(Icons.content_paste_go_rounded, size: 22),
                label: Text(
                  AppLocalizations.get('clipboardPasteAndSend', locale),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.neonGreen,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: isDark ? 0 : 2,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.get('clipboardSendHint', locale),
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondary.withValues(alpha: 0.7)
                    : Colors.grey.shade500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Clipboard card
// ---------------------------------------------------------------------------

class _ClipboardCard extends StatelessWidget {
  const _ClipboardCard({
    required this.entry,
    required this.locale,
    required this.isDark,
    required this.onCopy,
    required this.onDelete,
  });

  final ClipboardEntry entry;
  final String locale;
  final bool isDark;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isImage = entry.type == ClipboardContentType.image;
    final accentColor = isImage ? AppColors.neonPurple : AppColors.neonBlue;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(isDark ? 16 : 14),
        side: BorderSide(
          color: isDark
              ? accentColor.withValues(alpha: 0.15)
              : Colors.grey.shade200,
          width: 1,
        ),
      ),
      elevation: isDark ? 0 : 1,
      color: isDark ? AppColors.darkCard : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── Header row: type icon + content preview ───
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Type icon
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isImage
                        ? Icons.image_rounded
                        : Icons.text_snippet_rounded,
                    color: accentColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),

                // Content preview
                Expanded(
                  child: isImage
                      ? _buildImagePreview()
                      : _buildTextPreview(),
                ),
              ],
            ),

            const SizedBox(height: 10),
            // ─── Divider ───
            Divider(
              height: 1,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.grey.shade200,
            ),
            const SizedBox(height: 10),

            // ─── Footer: sender + timestamp + actions ───
            Row(
              children: [
                // Sender device
                Icon(
                  Icons.devices_rounded,
                  size: 14,
                  color: isDark
                      ? AppColors.textSecondary
                      : Colors.grey.shade500,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    entry.senderName,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textSecondary
                          : Colors.grey.shade600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Timestamp
                Text(
                  _formatDateTime(entry.timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textSecondary.withValues(alpha: 0.7)
                        : Colors.grey.shade400,
                  ),
                ),
                const SizedBox(width: 12),

                // Copy button
                _ActionButton(
                  icon: Icons.copy_rounded,
                  label: AppLocalizations.get('copy', locale),
                  color: AppColors.neonGreen,
                  isDark: isDark,
                  onTap: onCopy,
                ),
                const SizedBox(width: 6),

                // Delete button
                _ActionButton(
                  icon: Icons.delete_outline_rounded,
                  label: AppLocalizations.get('delete', locale),
                  color: isDark ? Colors.redAccent : Colors.red.shade400,
                  isDark: isDark,
                  onTap: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextPreview() {
    return Text(
      entry.text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14,
        height: 1.4,
        color: isDark ? AppColors.textPrimary : Colors.black87,
      ),
    );
  }

  Widget _buildImagePreview() {
    if (entry.imagePath != null && File(entry.imagePath!).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(entry.imagePath!),
          height: 100,
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _imageFallback(),
        ),
      );
    }
    return _imageFallback();
  }

  Widget _imageFallback() {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: AppColors.neonPurple.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          AppLocalizations.get('clipboardImage', locale),
          style: TextStyle(
            color: isDark ? AppColors.textSecondary : Colors.grey.shade500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateDay = DateTime(dt.year, dt.month, dt.day);
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (dateDay == today) return time;
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} $time';
  }
}

// ---------------------------------------------------------------------------
// Small action button
// ---------------------------------------------------------------------------

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
