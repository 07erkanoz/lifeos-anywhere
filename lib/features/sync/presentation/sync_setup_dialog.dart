import 'dart:io';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

final _log = AppLogger('SyncSetupDialog');

/// Dialog shown when a remote device sends a sync setup request.
///
/// The user can:
/// - See the sender device name, job name, direction, file count, total size
/// - Pick a target folder
/// - Accept or reject the request
class SyncSetupDialog extends ConsumerStatefulWidget {
  const SyncSetupDialog({
    super.key,
    required this.request,
  });

  final SyncSetupRequest request;

  @override
  ConsumerState<SyncSetupDialog> createState() => _SyncSetupDialogState();
}

class _SyncSetupDialogState extends ConsumerState<SyncSetupDialog> {
  late String _selectedFolder;
  bool _isAccepting = false;

  @override
  void initState() {
    super.initState();
    // Default folder: <syncReceiveFolder>/<jobName> or <downloadPath>/Sync/<jobName>
    final syncService = ref.read(syncServiceProvider.notifier);
    final baseFolder = syncService.getSyncReceiveFolder();
    _selectedFolder = p.join(baseFolder, _sanitize(widget.request.jobName));
  }

  String _sanitize(String name) {
    var sanitized = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    sanitized = sanitized.replaceAll(RegExp(r'_+'), '_');
    sanitized = sanitized.trim().replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (sanitized.isEmpty) sanitized = 'sync';
    return sanitized;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _directionLabel(SyncDirection direction, String locale) {
    switch (direction) {
      case SyncDirection.oneWay:
        return AppLocalizations.get('syncDirectionOneWay', locale);
      case SyncDirection.bidirectional:
        return AppLocalizations.get('syncDirectionBidirectional', locale);
    }
  }

  Future<void> _pickFolder() async {
    _log.info('_pickFolder called');
    try {
      String? result;

      if (Platform.isWindows) {
        // On Windows, FilePicker.getDirectoryPath can fail silently inside
        // a Flutter dialog.  Use native PowerShell folder-browser instead.
        result = await _pickFolderWindows();
      } else {
        // On Android, request storage permission first
        if (Platform.isAndroid) {
          final status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            _log.warning('Storage permission denied for folder picker');
          }
        }
        result = await FilePickerHelper.getDirectoryPath();
      }

      _log.info('Folder picker result: $result');
      if (result != null && result.isNotEmpty) {
        setState(() => _selectedFolder = result!);
      }
    } catch (e) {
      _log.error('Folder picker error: $e', error: e);
      if (mounted) {
        _showManualPathDialog();
      }
    }
  }

  /// Native Windows folder picker via PowerShell — works reliably even
  /// when called from inside a Flutter AlertDialog.
  Future<String?> _pickFolderWindows() async {
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$d = New-Object System.Windows.Forms.FolderBrowserDialog
\$d.Description = "Select sync folder"
\$d.ShowNewFolderButton = \$true
\$result = \$d.ShowDialog()
if (\$result -eq 'OK') { \$d.SelectedPath }
''';
    final proc = await Process.run(
      'powershell',
      ['-NoProfile', '-Command', script],
    );
    final path = (proc.stdout as String).trim();
    if (path.isNotEmpty && proc.exitCode == 0) return path;
    return null;
  }

  void _showManualPathDialog() {
    final controller = TextEditingController(text: _selectedFolder);
    final settings = ref.read(settingsProvider);
    final locale = settings.locale;

    showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.get('syncSetupSelectFolder', locale)),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/Sync',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(AppLocalizations.get('confirm', locale)),
          ),
        ],
      ),
    ).then((value) {
      controller.dispose();
      if (value != null && value.isNotEmpty) {
        setState(() => _selectedFolder = value);
      }
    });
  }

  Future<void> _accept() async {
    setState(() => _isAccepting = true);
    try {
      await ref.read(syncServiceProvider.notifier).acceptSyncSetup(
            widget.request.jobId,
            _selectedFolder,
          );
    } finally {
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  void _reject() {
    ref.read(syncServiceProvider.notifier).rejectSyncSetup(
          widget.request.jobId,
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final req = widget.request;

    final dirIcon = req.direction == SyncDirection.bidirectional
        ? Icons.sync_rounded
        : Icons.arrow_downward_rounded;

    return AlertDialog(
      icon: Icon(
        Icons.sync_rounded,
        size: 40,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(AppLocalizations.get('syncSetupRequest', locale)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sender info card
            Card(
              elevation: 0,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.04),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sender device
                    Row(
                      children: [
                        Icon(
                          Icons.phone_android_rounded,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            req.senderDeviceName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Job name
                    Row(
                      children: [
                        const Icon(Icons.folder_rounded, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          req.jobName,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Direction
                    Row(
                      children: [
                        Icon(dirIcon, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          _directionLabel(req.direction, locale),
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // File count & size
                    Row(
                      children: [
                        const Icon(Icons.description_outlined, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.format(
                            'syncSetupFileInfo',
                            locale,
                            {
                              'count': req.fileCount.toString(),
                              'size': _formatBytes(req.totalSize),
                            },
                          ),
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Folder selector
            Text(
              AppLocalizations.get('syncSetupSelectFolder', locale),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickFolder,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isDark ? Colors.white24 : Colors.black12,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open_rounded, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selectedFolder,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.edit_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isAccepting ? null : _reject,
          child: Text(AppLocalizations.get('syncSetupReject', locale)),
        ),
        FilledButton.icon(
          onPressed: _isAccepting ? null : _accept,
          icon: _isAccepting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded, size: 18),
          label: Text(AppLocalizations.get('syncSetupAccept', locale)),
        ),
      ],
    );
  }
}
