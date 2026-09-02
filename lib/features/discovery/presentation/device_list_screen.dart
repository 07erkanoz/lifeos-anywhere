import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/core/responsive.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/sharing/data/sharing_service.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/pairing/presentation/manual_ip_dialog.dart';
import 'package:anyware/features/pairing/presentation/qr_options_dialog.dart';
import 'package:anyware/features/platform/android/direct_share_service.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/sharing/presentation/share_target_picker.dart';
import 'package:anyware/features/sharing/data/dropped_file_expander.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/app_states.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';

/// Provider that holds file paths shared via Explorer context menu (--share).
/// When set, the device list screen will show a device picker dialog.
final pendingShareProvider = StateProvider<List<String>?>((ref) => null);

class DeviceListScreen extends ConsumerStatefulWidget {
  const DeviceListScreen({super.key});

  @override
  ConsumerState<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends ConsumerState<DeviceListScreen> {
  static final _log = AppLogger('DeviceListScreen');

  bool _isDragging = false;

  /// Set to true when a card-level DropTarget handles the drop.
  /// Prevents the parent DropTarget from also processing the same drop.
  bool _dropHandledByCard = false;

  /// Cached device list used by drop-on-card detection.
  List<Device> _currentDevices = [];

  /// Subscription for Android/iOS share intent stream.
  StreamSubscription? _intentSub;

  /// File paths from a share intent waiting for devices to be discovered.
  /// Set in [_handleSharingIntent], consumed in [build] when devices arrive.
  List<String>? _pendingIntentPaths;

  /// Whether the share-intent picker has already been shown for
  /// [_pendingIntentPaths] so we don't re-trigger on every rebuild.
  bool _intentPickerShown = false;

  /// Target selected in Android's Direct Share row, if any.
  DirectShareTargetInfo? _pendingDirectShareTarget;

  @override
  void initState() {
    super.initState();
    _handleSharingIntent();
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  /// Listens for files shared from other Android/iOS apps via the system
  /// share sheet. Stores the file paths and lets [build] show the picker
  /// once devices have been discovered.
  void _handleSharingIntent() {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      final service = ref.read(sharingServiceProvider);

      // Stream: media shared while the app is already in memory.
      _intentSub = service.getMediaStream().listen(
        (List<SharedMediaFile> value) {
          if (value.isNotEmpty && mounted) {
            _queueSharedFiles(service, value, source: 'stream');
          }
        },
        onError: (err) {
          _log.warning('getIntentDataStream error: $err');
        },
      );

      // Initial: media intent that launched / resumed the app.
      service.getInitialMedia().then((List<SharedMediaFile> value) {
        if (value.isNotEmpty && mounted) {
          _queueSharedFiles(service, value, source: 'initial');
          service.reset();
        }
      });
    } catch (e) {
      _log.error('Sharing intent initialization error: $e', error: e);
    }
  }

  Future<void> _queueSharedFiles(
    SharingService service,
    List<SharedMediaFile> files, {
    required String source,
  }) async {
    final target = await service.consumeDirectShareTarget();
    if (!mounted) return;
    final paths = files.map((file) => file.path).toList();
    _log.info('Share $source received ${paths.length} files');
    setState(() {
      _pendingIntentPaths = paths;
      _pendingDirectShareTarget = target;
      _intentPickerShown = false;
    });
  }

  /// Tries to show the device picker for pending intent paths.
  /// Called from [build] when devices become available.
  void _tryShowIntentPicker(String locale) {
    if (_pendingIntentPaths == null || _intentPickerShown) return;
    final accounts = ref.read(serverSyncServiceProvider).accounts;
    if (_pendingDirectShareTarget != null && _currentDevices.isEmpty) return;
    if (_currentDevices.isEmpty && accounts.isEmpty) return;

    _intentPickerShown = true;
    final paths = _pendingIntentPaths!;
    final directTarget = _pendingDirectShareTarget;
    _pendingIntentPaths = null;
    _pendingDirectShareTarget = null;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      Device? selectedDevice;
      if (directTarget != null) {
        for (final device in _currentDevices) {
          if (device.id == directTarget.id ||
              (directTarget.ip.isNotEmpty && device.ip == directTarget.ip)) {
            selectedDevice = device;
            break;
          }
        }
      }

      if (selectedDevice != null) {
        _log.info('Sending directly to ${selectedDevice.name}');
        await _sendFilesToDevice(context, ref, selectedDevice, paths);
        return;
      }
      _showDevicePickerDialog(context, ref, paths, locale);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final localDeviceAsync = ref.watch(localDeviceProvider);
    final devicesAsync = ref.watch(devicesProvider);

    // Listen for pending share files from Explorer context menu.
    ref.listen<List<String>?>(pendingShareProvider, (prev, next) {
      if (next != null && next.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showDevicePickerDialog(context, ref, next, locale);
          ref.read(pendingShareProvider.notifier).state = null;
        });
      }
    });

    // Cache devices for drop hit-test.
    devicesAsync.whenData((devices) {
      _currentDevices = devices;
    });

    // When devices arrive and a share intent is waiting, show picker.
    if (_pendingIntentPaths != null && _currentDevices.isNotEmpty) {
      _tryShowIntentPicker(locale);
    }

    final headerActions = <Widget>[
      IconButton(
        icon: const Icon(Icons.qr_code_rounded),
        tooltip: AppLocalizations.get('qrOptions', locale),
        onPressed: () {
          showDialog(
            context: context,
            builder: (_) => QrOptionsDialog(locale: locale),
          );
        },
      ),
      IconButton(
        icon: const Icon(Icons.add_link),
        tooltip: AppLocalizations.get('addManually', locale),
        onPressed: () {
          showDialog(
            context: context,
            builder: (_) => ManualIpDialog(locale: locale),
          );
        },
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: AppLocalizations.get('scanning', locale),
        onPressed: () {
          ref.read(refreshDiscoveryProvider)();
        },
      ),
    ];

    final bodyContent = RefreshIndicator(
      onRefresh: () async {
        await ref.read(refreshDiscoveryProvider)();
      },
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          // --- Local device header card ---
          localDeviceAsync.when(
            data: (localDevice) =>
                _LocalDeviceCard(device: localDevice, locale: locale),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // --- Discovered devices ---
          devicesAsync.when(
            data: (devices) {
              if (devices.isEmpty) {
                return _EmptyDevicesView(locale: locale);
              }
              return Column(
                children: [
                  for (int i = 0; i < devices.length; i++)
                    _DeviceDropTarget(
                      device: devices[i],
                      locale: locale,
                      isDragging: _isDragging,
                      autofocus: i == 0,
                      onSendFile: () =>
                          _pickAndSendFile(context, ref, devices[i]),
                      onFilesDropped: (rawPaths) async {
                        _dropHandledByCard = true;
                        final paths = await expandDroppedPaths(rawPaths);
                        if (!context.mounted || paths.isEmpty) return;
                        _sendFilesToDevice(context, ref, devices[i], paths);
                      },
                    ),
                ],
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => AppEmptyState(
              icon: Icons.wifi_off_rounded,
              title: AppLocalizations.get('failed', locale),
              description: error.toString(),
              accentColor: Theme.of(context).colorScheme.error,
              actionLabel: AppLocalizations.get('retry', locale),
              actionIcon: Icons.refresh_rounded,
              onAction: () => ref.read(refreshDiscoveryProvider)(),
            ),
          ),
        ],
      ),
    );

    final Widget screen;
    if (DesktopShellScope.of(context)) {
      screen = DesktopContentShell(
        title: AppLocalizations.get('devices', locale),
        maxWidth: 1100,
        actions: headerActions,
        child: bodyContent,
      );
    } else {
      screen = Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizations.get('devices', locale)),
          actions: headerActions,
        ),
        body: bodyContent,
      );
    }

    // Wrap with DropTarget only on desktop platforms.
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: (details) {
          setState(() => _isDragging = false);

          final rawPaths = details.files.map((f) => f.path).toList();
          if (rawPaths.isEmpty) return;
          Future.microtask(() async {
            // If a card-level DropTarget already handled this drop, skip.
            if (_dropHandledByCard) {
              _dropHandledByCard = false;
              return;
            }
            final paths = await expandDroppedPaths(rawPaths);
            if (!context.mounted || paths.isEmpty) return;
            _showDevicePickerDialog(context, ref, paths, locale);
          });
        },
        child: Stack(
          children: [
            screen,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedSwitcher(
                  duration: context.motionDuration(AppMotion.standard),
                  child: _isDragging
                      ? AppDropOverlay(
                          key: const ValueKey('drop-overlay'),
                          label: AppLocalizations.get('dropFilesHere', locale),
                        )
                      : const SizedBox.shrink(
                          key: ValueKey('drop-overlay-hidden'),
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return screen;
  }

  // -------------------------------------------------------------------------
  // File sending helpers
  // -------------------------------------------------------------------------

  Future<void> _pickAndSendFile(
    BuildContext context,
    WidgetRef ref,
    Device target,
  ) async {
    final result = await FilePickerHelper.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    if (!context.mounted) return;
    await _sendFilesToDevice(context, ref, target, paths);
  }

  Future<void> _sendFilesToDevice(
    BuildContext context,
    WidgetRef ref,
    Device target,
    List<String> filePaths,
  ) async {
    try {
      final queue = await ref.read(transferQueueProvider.future);
      queue.enqueueAll(target, filePaths);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${AppLocalizations.get('sendFileFailed', AppLocalizations.detectLocale())}: $e',
          ),
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Device picker dialog (for drag-drop on empty area or --share)
  // -------------------------------------------------------------------------

  Future<void> _showDevicePickerDialog(
    BuildContext context,
    WidgetRef ref,
    List<String> filePaths,
    String locale,
  ) async {
    final devices = ref.read(devicesProvider).valueOrNull ?? _currentDevices;
    final accounts = ref.read(serverSyncServiceProvider).accounts;

    if (devices.isEmpty && accounts.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.get('noDevices', locale))),
        );
      }
      return;
    }

    if (!context.mounted) return;
    final selection = await showShareTargetPicker(
      context: context,
      devices: devices,
      accounts: accounts,
      filePaths: filePaths,
      locale: locale,
    );

    if (selection == null || !context.mounted) return;

    final selected = selection.target;
    final queuedPaths = selection.filePaths;
    if (selected is DeviceShareTarget) {
      await _sendFilesToDevice(context, ref, selected.device, queuedPaths);
    } else if (selected is AccountShareTarget) {
      await _sendFilesToServer(
        context,
        ref,
        selected.account,
        queuedPaths,
        locale,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Send files to a server account (quick upload)
  // -------------------------------------------------------------------------

  Future<void> _sendFilesToServer(
    BuildContext context,
    WidgetRef ref,
    SyncAccount account,
    List<String> filePaths,
    String locale,
  ) async {
    final service = ref.read(serverSyncServiceProvider.notifier);
    final remoteDir = account.remotePath.isEmpty ? '/' : account.remotePath;

    if (!context.mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ServerUploadProgressDialog(
        stream: service.uploadFilesToAccount(account.id, filePaths, remoteDir),
        totalFiles: filePaths.length,
        serverName: account.name,
        locale: locale,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Device card with drop target wrapper
// ---------------------------------------------------------------------------

class _DeviceDropTarget extends StatefulWidget {
  const _DeviceDropTarget({
    required this.device,
    required this.locale,
    required this.isDragging,
    required this.onSendFile,
    required this.onFilesDropped,
    this.autofocus = false,
  });

  final Device device;
  final String locale;
  final bool isDragging;
  final VoidCallback onSendFile;
  final void Function(List<String> paths) onFilesDropped;
  final bool autofocus;

  @override
  State<_DeviceDropTarget> createState() => _DeviceDropTargetState();
}

class _DeviceDropTargetState extends State<_DeviceDropTarget> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    // Only wrap in DropTarget on desktop.
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return DropTarget(
        onDragEntered: (_) => setState(() => _isHovering = true),
        onDragExited: (_) => setState(() => _isHovering = false),
        onDragDone: (details) {
          setState(() => _isHovering = false);
          final paths = details.files.map((f) => f.path).toList();
          if (paths.isNotEmpty) {
            widget.onFilesDropped(paths);
          }
        },
        child: _DeviceCard(
          device: widget.device,
          locale: widget.locale,
          onSendFile: widget.onSendFile,
          isDropHovering: _isHovering,
          isDragging: widget.isDragging,
          autofocus: widget.autofocus,
        ),
      );
    }

    return _DeviceCard(
      device: widget.device,
      locale: widget.locale,
      onSendFile: widget.onSendFile,
      isDropHovering: false,
      isDragging: false,
      autofocus: widget.autofocus,
    );
  }
}

// ---------------------------------------------------------------------------
// Local device header card
// ---------------------------------------------------------------------------

class _LocalDeviceCard extends StatelessWidget {
  const _LocalDeviceCard({required this.device, required this.locale});

  final Device device;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      color: colorScheme.primaryContainer.withValues(alpha: 0.35),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primary,
              child: Icon(
                _platformIconData(device.platformIcon),
                color: colorScheme.onPrimary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${device.ip}  \u00b7  ${device.platformLabel}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                AppLocalizations.get('thisDevice', locale),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state with scanning animation
// ---------------------------------------------------------------------------

class _EmptyDevicesView extends ConsumerWidget {
  const _EmptyDevicesView({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diagnostics = ref.watch(networkDiagnosticsProvider);

    return AppEmptyState(
      icon: Icons.radar_rounded,
      title: AppLocalizations.get('noDevices', locale),
      description: AppLocalizations.get('scanning', locale),
      busy: true,
      details: diagnostics.whenOrNull(
        data: (diag) {
          if (!diag.hasIssues) return null;
          return _MobileDiagnosticTips(diagnostics: diag, locale: locale);
        },
      ),
    );
  }
}

class _MobileDiagnosticTips extends StatelessWidget {
  const _MobileDiagnosticTips({
    required this.diagnostics,
    required this.locale,
  });

  final NetworkDiagnostics diagnostics;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final tips = <String>[];

    for (final issue in diagnostics.issues) {
      switch (issue) {
        case NetworkIssue.noNetwork:
          tips.add(AppLocalizations.get('diagNoNetwork', locale));
          break;
        case NetworkIssue.virtualAdapters:
          tips.add(
            AppLocalizations.get(
              'diagVirtualAdapter',
              locale,
            ).replaceAll('{names}', diagnostics.virtualAdapterNames.join(', ')),
          );
          break;
      }
    }

    tips.add(AppLocalizations.get('diagSameNetwork', locale));
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      tips.add(
        AppLocalizations.get(
          'diagFirewall',
          locale,
        ).replaceAll('{port}', '${AppConstants.discoveryPort}'),
      );
    }
    tips.add(AppLocalizations.get('diagTryManualIp', locale));

    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: colorScheme.error),
              const SizedBox(width: 6),
              Text(
                AppLocalizations.get('networkTroubleshooting', locale),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...tips.map(
            (tip) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '\u2022 $tip',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Discovered device card
// ---------------------------------------------------------------------------

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.locale,
    required this.onSendFile,
    this.isDropHovering = false,
    this.isDragging = false,
    this.autofocus = false,
  });

  final Device device;
  final String locale;
  final VoidCallback onSendFile;
  final bool isDropHovering;
  final bool isDragging;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AnimatedContainer(
      duration: context.motionDuration(AppMotion.fast),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: isDropHovering
              ? BorderSide(color: colorScheme.primary, width: 2)
              : BorderSide.none,
        ),
        color: isDropHovering
            ? colorScheme.primary.withValues(alpha: 0.08)
            : null,
        child: InkWell(
          autofocus: autofocus,
          borderRadius: BorderRadius.circular(14),
          onTap: onSendFile,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: device.isOnline
                      ? colorScheme.secondaryContainer
                      : colorScheme.surfaceContainerHighest,
                  child: Icon(
                    _platformIconData(device.platformIcon),
                    color: device.isOnline
                        ? colorScheme.onSecondaryContainer
                        : colorScheme.onSurfaceVariant,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              device.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${device.ip}  \u00b7  ${device.platformLabel}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isDropHovering)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      AppLocalizations.get('dropToSend', locale),
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else if (isDragging)
                  Icon(
                    Icons.file_download_outlined,
                    color: colorScheme.primary.withValues(alpha: 0.5),
                    size: 24,
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: onSendFile,
                    icon: const Icon(Icons.send, size: 18),
                    label: Text(AppLocalizations.get('sendFile', locale)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Icon mapping helper
// ---------------------------------------------------------------------------

IconData _platformIconData(String platformIcon) {
  switch (platformIcon) {
    case 'phone_android':
      return Icons.phone_android;
    case 'tv':
      return Icons.tv;
    case 'desktop_windows':
      return Icons.desktop_windows;
    case 'phone_iphone':
      return Icons.phone_iphone;
    case 'computer':
      return Icons.computer;
    default:
      return Icons.devices;
  }
}
