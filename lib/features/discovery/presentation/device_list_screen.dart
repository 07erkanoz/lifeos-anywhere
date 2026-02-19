import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/tv_focus_wrapper.dart';

/// Provider that holds file paths shared via Explorer context menu (--share).
/// When set, the device list screen will show a device picker dialog.
final pendingShareProvider = StateProvider<List<String>?>((ref) => null);

class DeviceListScreen extends ConsumerStatefulWidget {
  const DeviceListScreen({super.key});

  @override
  ConsumerState<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends ConsumerState<DeviceListScreen> {
  bool _isDragging = false;

  /// Set to true when a card-level DropTarget handles the drop.
  /// Prevents the parent DropTarget from also processing the same drop.
  bool _dropHandledByCard = false;

  /// Cached device list used by drop-on-card detection.
  List<Device> _currentDevices = [];

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

    final body = Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('devices', locale)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: AppLocalizations.get('scanning', locale),
            onPressed: () {
              ref.read(refreshDiscoveryProvider)();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(refreshDiscoveryProvider)();
        },
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            // --- Local device header card ---
            localDeviceAsync.when(
              data: (localDevice) => _LocalDeviceCard(
                device: localDevice,
                locale: locale,
              ),
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  error.toString(),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
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
                return FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Column(
                    children: [
                      for (int i = 0; i < devices.length; i++)
                        FocusTraversalOrder(
                          order: NumericFocusOrder(i.toDouble()),
                          child: TvFocusWrapper(
                            autofocus: i == 0,
                            onSelect: () =>
                                _pickAndSendFile(context, ref, devices[i]),
                            child: _DeviceDropTarget(
                              device: devices[i],
                              locale: locale,
                              isDragging: _isDragging,
                              onSendFile: () =>
                                  _pickAndSendFile(context, ref, devices[i]),
                              onFilesDropped: (paths) {
                                _dropHandledByCard = true;
                                _sendFilesToDevice(context, ref, devices[i], paths);
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 48,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        error.toString(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: () => ref.read(refreshDiscoveryProvider)(),
                        icon: const Icon(Icons.refresh),
                        label: Text(AppLocalizations.get('retry', locale)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Wrap with DropTarget only on desktop platforms.
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: (details) {
          setState(() => _isDragging = false);

          // If a card-level DropTarget already handled this drop, skip.
          if (_dropHandledByCard) {
            _dropHandledByCard = false;
            return;
          }

          final paths = details.files.map((f) => f.path).toList();
          if (paths.isEmpty) return;

          // Files dropped on the general area → show device picker.
          _showDevicePickerDialog(context, ref, paths, locale);
        },
        child: Stack(
          children: [
            body,
            if (_isDragging) _DragOverlay(locale: locale),
          ],
        ),
      );
    }

    return body;
  }

  // -------------------------------------------------------------------------
  // File sending helpers
  // -------------------------------------------------------------------------

  Future<void> _pickAndSendFile(
    BuildContext context,
    WidgetRef ref,
    Device target,
  ) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
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
        SnackBar(content: Text('${AppLocalizations.get('sendFileFailed', AppLocalizations.detectLocale())}: $e')),
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
    final devices = _currentDevices;
    if (devices.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.get('noDevices', locale)),
          ),
        );
      }
      return;
    }

    // If only one device, send directly.
    if (devices.length == 1) {
      await _sendFilesToDevice(context, ref, devices.first, filePaths);
      return;
    }

    if (!context.mounted) return;

    final fileNames = filePaths
        .map((p) => p.split(Platform.pathSeparator).last)
        .join(', ');

    final selectedDevice = await showDialog<Device>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          title: Text(AppLocalizations.get('selectDeviceToSend', locale)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // File name(s) preview
                Text(
                  fileNames,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                // Device list
                ...devices.map((device) => ListTile(
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: colorScheme.secondaryContainer,
                    child: Icon(
                      _platformIconData(device.platformIcon),
                      color: colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                  ),
                  title: Text(device.name),
                  subtitle: Text(
                    '${device.ip}  \u00b7  ${device.platformLabel}',
                    style: theme.textTheme.bodySmall,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onTap: () => Navigator.of(context).pop(device),
                )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppLocalizations.get('cancel', locale)),
            ),
          ],
        );
      },
    );

    if (selectedDevice != null && context.mounted) {
      await _sendFilesToDevice(context, ref, selectedDevice, filePaths);
    }
  }
}

// ---------------------------------------------------------------------------
// Drag overlay shown when files are being dragged over the window
// ---------------------------------------------------------------------------

class _DragOverlay extends StatelessWidget {
  const _DragOverlay({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.12),
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.6),
              width: 3,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          margin: const EdgeInsets.all(8),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 56,
                  color: colorScheme.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.get('dropFilesHere', locale),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
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
// Device card with drop target wrapper
// ---------------------------------------------------------------------------

class _DeviceDropTarget extends StatefulWidget {
  const _DeviceDropTarget({
    required this.device,
    required this.locale,
    required this.isDragging,
    required this.onSendFile,
    required this.onFilesDropped,
  });

  final Device device;
  final String locale;
  final bool isDragging;
  final VoidCallback onSendFile;
  final void Function(List<String> paths) onFilesDropped;

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
        ),
      );
    }

    return _DeviceCard(
      device: widget.device,
      locale: widget.locale,
      onSendFile: widget.onSendFile,
      isDropHovering: false,
      isDragging: false,
    );
  }
}

// ---------------------------------------------------------------------------
// Local device header card
// ---------------------------------------------------------------------------

class _LocalDeviceCard extends StatelessWidget {
  const _LocalDeviceCard({
    required this.device,
    required this.locale,
  });

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

class _EmptyDevicesView extends StatefulWidget {
  const _EmptyDevicesView({required this.locale});

  final String locale;

  @override
  State<_EmptyDevicesView> createState() => _EmptyDevicesViewState();
}

class _EmptyDevicesViewState extends State<_EmptyDevicesView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: _controller,
              child: Icon(
                Icons.radar,
                size: 64,
                color: colorScheme.primary.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocalizations.get('noDevices', widget.locale),
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('scanning', widget.locale),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
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
  });

  final Device device;
  final String locale;
  final VoidCallback onSendFile;
  final bool isDropHovering;
  final bool isDragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
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
                      Text(
                        device.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
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
                        horizontal: 12, vertical: 6),
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
