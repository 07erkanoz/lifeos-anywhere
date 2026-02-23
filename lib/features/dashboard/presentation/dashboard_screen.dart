import 'dart:io';
import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/data/latency_service.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/discovery/presentation/device_list_screen.dart';
import 'package:anyware/features/pairing/presentation/manual_ip_dialog.dart';
import 'package:anyware/features/pairing/presentation/qr_options_dialog.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/glassmorphism.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/sharing/data/sharing_service.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:anyware/features/timeline/presentation/timeline_screen.dart';

final _log = AppLogger('Dashboard');

/// Unified dashboard screen matching the reference design.
///
/// Top area: Discovered devices (horizontal card list)
/// Bottom area: Recent transfers and progress statuses
///
/// File sending features (file picker, drag-and-drop, device picker)
/// are fully integrated into this screen.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _isDragging = false;

  /// Set to true when a card-level DropTarget handles the drop.
  /// Prevents the parent DropTarget from also processing the same drop.
  bool _dropHandledByCard = false;

  /// Timestamp of last drop-initiated send to debounce duplicate drops.
  DateTime? _lastDropSendTime;

  /// Cached device list used by drop-on-card detection & device picker.
  List<Device> _currentDevices = [];

  StreamSubscription? _intentSub;

  @override
  void initState() {
    super.initState();
    _handleSharingIntent();
  }

  void _handleSharingIntent() {
    // receive_sharing_intent only works on mobile platforms.
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      final service = ref.read(sharingServiceProvider);

      // Listen to media coming from outside the app while the app is in the memory.
      _intentSub = service.getMediaStream().listen((List<SharedMediaFile> value) {
        if (value.isNotEmpty) {
          final paths = value.map((f) => f.path).toList();
          _showDevicePickerDialog(paths, AppLocalizations.detectLocale());
        }
      }, onError: (err) {
        _log.warning("getIntentDataStream error: $err");
      });

      // Get the media intent that started the app.
      service.getInitialMedia().then((List<SharedMediaFile> value) {
        if (value.isNotEmpty) {
          final paths = value.map((f) => f.path).toList();
          _showDevicePickerDialog(paths, AppLocalizations.detectLocale());
          service.reset();
        }
      });
    } catch (e) {
      _log.error('Sharing intent initialization error: $e', error: e);
    }
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // File sending helper methods (moved from DeviceListScreen)
  // ─────────────────────────────────────────────────────────────────────────

  /// Opens a menu asking whether to send files or folders when a device
  /// is tapped, then sends the selected content.
  Future<void> _showSendOptions(Device target, String locale) async {
    if (!mounted) return;

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(AppLocalizations.get('sendFiles', locale)),
                onTap: () => Navigator.pop(ctx, 'files'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(AppLocalizations.get('sendFolder', locale)),
                onTap: () => Navigator.pop(ctx, 'folder'),
              ),
              ListTile(
                leading: const Icon(Icons.paste_rounded),
                title: Text(AppLocalizations.get('sendClipboard', locale)),
                onTap: () => Navigator.pop(ctx, 'clipboard'),
              ),
            ],
          ),
        );
      },
    );

    if (choice == null || !mounted) return;

    if (choice == 'files') {
      await _pickAndSendFiles(target);
    } else if (choice == 'folder') {
      await _pickAndSendFolder(target);
    } else if (choice == 'clipboard') {
      await _sendClipboard(target);
    }
  }

  /// Opens a file picker dialog and sends the selected files to the target device.
  Future<void> _pickAndSendFiles(Device target) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;

    await _sendFilesToDevice(target, paths);
  }

  /// Opens a folder picker dialog and sends all files in the folder to the target device.
  Future<void> _pickAndSendFolder(Device target) async {
    final folderPath = await FilePicker.platform.getDirectoryPath();
    if (folderPath == null || folderPath.isEmpty) return;

    try {
      final sender = await ref.read(fileSenderProvider.future);
      final transfers = await sender.sendFolder(target, folderPath);
      for (final transfer in transfers) {
        ref.read(activeTransfersProvider.notifier).addOrUpdate(transfer);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppLocalizations.get('sendFolderFailed', AppLocalizations.detectLocale())}: $e')),
      );
    }
  }

  /// Enqueues and sends files to the target device.
  Future<void> _sendFilesToDevice(Device target, List<String> filePaths) async {
    try {
      final queue = await ref.read(transferQueueProvider.future);
      queue.enqueueAll(target, filePaths);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppLocalizations.get('sendFileFailed', AppLocalizations.detectLocale())}: $e')),
      );
    }
  }

  /// Sends clipboard text to the target device.
  Future<void> _sendClipboard(Device target) async {
    final locale = AppLocalizations.detectLocale();
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.get('clipboardEmpty', locale))),
        );
        return;
      }

      final service = ref.read(clipboardServiceProvider);
      final settings = ref.read(settingsProvider);
      final localDevice = await ref.read(localDeviceProvider.future);
      final senderName = settings.deviceName.isNotEmpty
          ? settings.deviceName
          : localDevice.name;
      await service.sendClipboard(
        target,
        text,
        senderName: senderName,
        senderDeviceId: localDevice.id,
      );

      // Record sent clipboard entry in history.
      ref.read(clipboardHistoryProvider.notifier).addEntry(
        ClipboardEntry(
          text: text,
          senderName: senderName,
          senderDeviceId: localDevice.id,
          timestamp: DateTime.now(),
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.get('clipboardSent', locale)),
          backgroundColor: AppColors.neonGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppLocalizations.get('sendClipboardFailed', AppLocalizations.detectLocale())}: $e')),
      );
    }
  }

  /// Shows a device picker dialog if multiple devices are available,
  /// sends directly if there is only one device.
  Future<void> _showDevicePickerDialog(
    List<String> filePaths,
    String locale,
  ) async {
    final devices = _currentDevices;
    if (devices.isEmpty) {
      if (mounted) {
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
      await _sendFilesToDevice(devices.first, filePaths);
      return;
    }

    if (!mounted) return;

    final fileNames = filePaths
        .map((p) => p.split(Platform.pathSeparator).last)
        .join(', ');

    final selectedDevice = await showDialog<Device>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          title: Text(AppLocalizations.get('selectDeviceToSend', locale)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileNames,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
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
                      onTap: () => Navigator.of(ctx).pop(device),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.get('cancel', locale)),
            ),
          ],
        );
      },
    );

    if (selectedDevice != null && mounted) {
      await _sendFilesToDevice(selectedDevice, filePaths);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isTV = Platform.isAndroid && TvDetector.isTVCached;
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    final devicesAsync = ref.watch(devicesProvider);
    final transfers = ref.watch(activeTransfersProvider);
    final latencyMap = ref.watch(latencyUpdatesProvider).valueOrNull ?? {};

    // Listen for pending share files from Explorer context menu.
    ref.listen<List<String>?>(pendingShareProvider, (prev, next) {
      if (next != null && next.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showDevicePickerDialog(next, locale);
          ref.read(pendingShareProvider.notifier).state = null;
        });
      }
    });

    // Cache devices for drop hit-test.
    devicesAsync.whenData((devices) {
      _currentDevices = devices;
    });

    final isDesktopShell = DesktopShellScope.of(context);

    final headerActions = <Widget>[
      IconButton(
        icon: const Icon(Icons.qr_code_rounded, size: 20),
        tooltip: AppLocalizations.get('qrOptions', locale),
        onPressed: () {
          showDialog(
            context: context,
            builder: (_) => QrOptionsDialog(locale: locale),
          );
        },
      ),
      IconButton(
        icon: const Icon(Icons.add_link, size: 20),
        tooltip: AppLocalizations.get('addManually', locale),
        onPressed: () {
          showDialog(
            context: context,
            builder: (_) => ManualIpDialog(locale: locale),
          );
        },
      ),
      IconButton(
        icon: const Icon(Icons.refresh, size: 20),
        tooltip: AppLocalizations.get('scanning', locale),
        onPressed: () => ref.read(refreshDiscoveryProvider)(),
      ),
    ];

    final content = CustomScrollView(
          slivers: [
            // ─── Header: Discovered Devices ───
            if (!isDesktopShell)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        AppLocalizations.get('discoveredDevices', locale),
                        style: TextStyle(
                          fontSize: isTV ? 22 : 18,
                          fontWeight: FontWeight.w700,
                          color: isDark ? AppColors.textPrimary : Colors.black87,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: headerActions,
                      ),
                    ],
                  ),
                ),
              ),
            if (isDesktopShell)
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

            // ─── Device Cards (Horizontal) ───
            SliverToBoxAdapter(
              child: SizedBox(
                height: isTV ? 220 : 180,
                child: devicesAsync.when(
                  data: (devices) {
                    if (devices.isEmpty) {
                      return _EmptyDevices(locale: locale, isDark: isDark);
                    }
                    return ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: devices.length,
                      itemBuilder: (context, index) => _DeviceGlassCard(
                        device: devices[index],
                        isTV: isTV,
                        isDark: isDark,
                        isDragging: _isDragging,
                        locale: locale,
                        latencyMs: latencyMap[devices[index].id],
                        autofocus: index == 0,
                        onTap: () => _showSendOptions(devices[index], locale),
                        onFilesDropped: (paths) {
                          _dropHandledByCard = true;
                          // Debounce: ignore if another drop just happened (<500ms).
                          final now = DateTime.now();
                          if (_lastDropSendTime != null &&
                              now.difference(_lastDropSendTime!).inMilliseconds < 500) {
                            return;
                          }
                          _lastDropSendTime = now;
                          _sendFilesToDevice(devices[index], paths);
                        },
                      ),
                    );
                  },
                  loading: () => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  error: (err, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Error: $err',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => ref.read(refreshDiscoveryProvider)(),
                          icon: const Icon(Icons.refresh),
                          label:
                              Text(AppLocalizations.get('retry', locale)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ─── Header: Recent Transfers ───
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      AppLocalizations.get('recentTransfers', locale),
                      style: TextStyle(
                        fontSize: isTV ? 22 : 18,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? AppColors.textPrimary : Colors.black87,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.timeline_rounded, size: 20),
                          tooltip: AppLocalizations.get('timeline', locale),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const TimelineScreen(),
                              ),
                            );
                          },
                        ),
                        if (transfers.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              ref
                                  .read(activeTransfersProvider.notifier)
                                  .clearFinished();
                            },
                            child: Text(
                              AppLocalizations.get('clearCompleted', locale),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // ─── Transfer List ───
            if (transfers.isEmpty)
              SliverToBoxAdapter(
                child: _EmptyTransfers(locale: locale, isDark: isDark),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final transfer = transfers[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _TransferCard(
                          transfer: transfer,
                          isDark: isDark,
                          locale: locale,
                        ),
                      );
                    },
                    childCount: transfers.length > 5 ? 5 : transfers.length,
                  ),
                ),
              ),

            // Bottom spacing
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        );

    // Wrap with DesktopContentShell when in desktop shell mode.
    Widget screen = content;

    if (isDesktopShell) {
      final deviceCount = _currentDevices.length;
      screen = DesktopContentShell(
        title: AppLocalizations.get('devices', locale),
        subtitle: deviceCount > 0
            ? '$deviceCount ${AppLocalizations.get('devicesFound', locale)}'
            : null,
        actions: headerActions,
        maxWidth: 1100,
        child: content,
      );
    }

    // Drag-and-drop support on desktop platforms.
    if (isDesktop) {
      return DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: (details) {
          setState(() => _isDragging = false);
          final paths = details.files.map((f) => f.path).toList();
          if (paths.isEmpty) return;
          Future.microtask(() {
            if (_dropHandledByCard) {
              _dropHandledByCard = false;
              return;
            }
            final now = DateTime.now();
            if (_lastDropSendTime != null &&
                now.difference(_lastDropSendTime!).inMilliseconds < 500) {
              return;
            }
            _lastDropSendTime = now;
            _showDevicePickerDialog(paths, locale);
          });
        },
        child: Stack(
          children: [
            screen,
            if (_isDragging) _DragOverlay(locale: locale),
          ],
        ),
      );
    }

    return screen;
  }
}

// =============================================================================
// Drag-and-drop overlay
// =============================================================================

class _DragOverlay extends StatelessWidget {
  const _DragOverlay({required this.locale});
  final String locale;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.neonBlue.withValues(alpha: 0.08)
                : colorScheme.primary.withValues(alpha: 0.12),
            border: Border.all(
              color: isDark
                  ? AppColors.neonBlue.withValues(alpha: 0.5)
                  : colorScheme.primary.withValues(alpha: 0.6),
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
                  color: isDark
                      ? AppColors.neonBlue.withValues(alpha: 0.7)
                      : colorScheme.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.get('dropFilesHere', locale),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: isDark ? AppColors.neonBlue : colorScheme.primary,
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

// =============================================================================
// Device Glass Effect Card
// =============================================================================

class _DeviceGlassCard extends StatefulWidget {
  const _DeviceGlassCard({
    required this.device,
    required this.isTV,
    required this.isDark,
    required this.isDragging,
    required this.locale,
    required this.onTap,
    required this.onFilesDropped,
    this.latencyMs,
    this.autofocus = false,
  });

  final Device device;
  final bool isTV;
  final bool isDark;
  final bool isDragging;
  final String locale;
  final VoidCallback onTap;
  final void Function(List<String> paths) onFilesDropped;
  final int? latencyMs;
  final bool autofocus;

  @override
  State<_DeviceGlassCard> createState() => _DeviceGlassCardState();
}

class _DeviceGlassCardState extends State<_DeviceGlassCard> {
  bool _isFocused = false;
  bool _isDropHovering = false;

  Color get _statusColor {
    if (_isDropHovering) return AppColors.neonGreen;
    if (widget.device.isOnline) return AppColors.statusConnected;
    return AppColors.textTertiary;
  }

  String get _statusLabel {
    if (_isDropHovering) {
      return AppLocalizations.get('dropToSend', widget.locale);
    }
    if (widget.device.isOnline) {
      return AppLocalizations.get('connected', widget.locale);
    }
    return AppLocalizations.get('disconnected', widget.locale);
  }

  @override
  Widget build(BuildContext context) {
    final cardWidth = widget.isTV ? 220.0 : 180.0;
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    Widget card = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: NeonGlowContainer(
        isGlowing: _isFocused || _isDropHovering,
        glowColor: _statusColor,
        borderRadius: 16,
        child: AnimatedScale(
          scale: (_isFocused || _isDropHovering) ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: GlassmorphismCard(
            width: cardWidth,
            onTap: widget.onTap,
            autofocus: widget.autofocus,
            onFocusChange: (focused) => setState(() => _isFocused = focused),
            borderColor: (_isFocused || _isDropHovering)
                ? _statusColor.withValues(alpha: 0.5)
                : null,
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: Platform icon + status/send label
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _platformIconData(widget.device.platformIcon),
                          color: _statusColor,
                          size: 24,
                        ),
                      ),
                      StatusBadge(
                        label: _statusLabel,
                        color: _statusColor,
                      ),
                    ],
                  ),
                  const Spacer(),

                  // Device name
                  Text(
                    widget.device.name,
                    style: TextStyle(
                      fontSize: widget.isTV ? 16 : 14,
                      fontWeight: FontWeight.w700,
                      color: widget.isDark
                          ? AppColors.textPrimary
                          : Colors.black87,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),

                  // Platform label
                  Text(
                    '${widget.device.platformLabel} · ${widget.device.isOnline ? AppLocalizations.get("online", widget.locale) : AppLocalizations.get("offline", widget.locale)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.isDark
                          ? AppColors.textSecondary
                          : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Bottom row: IP + latency + send button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.device.ip,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: widget.isDark
                                      ? AppColors.textTertiary
                                      : Colors.grey.shade500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.latencyMs != null) ...[
                              const SizedBox(width: 6),
                              _LatencyChip(ms: widget.latencyMs!),
                            ],
                          ],
                        ),
                      ),
                      if (widget.isDragging)
                        Icon(
                          Icons.file_download_outlined,
                          color: AppColors.neonBlue.withValues(alpha: 0.5),
                          size: 18,
                        )
                      else
                        Icon(
                          Icons.send_rounded,
                          color: widget.isDark
                              ? AppColors.neonBlue.withValues(alpha: 0.7)
                              : Colors.blue.shade400,
                          size: 18,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

    // On desktop each card is a separate DropTarget — files can be dropped onto the card.
    if (isDesktop) {
      card = DropTarget(
        onDragEntered: (_) => setState(() => _isDropHovering = true),
        onDragExited: (_) => setState(() => _isDropHovering = false),
        onDragDone: (details) {
          setState(() => _isDropHovering = false);
          final paths = details.files.map((f) => f.path).toList();
          if (paths.isNotEmpty) {
            widget.onFilesDropped(paths);
          }
        },
        child: card,
      );
    }

    return card;
  }
}

// =============================================================================
// Transfer Card — Premium design
// =============================================================================

class _TransferCard extends StatelessWidget {
  const _TransferCard({
    required this.transfer,
    required this.isDark,
    required this.locale,
  });

  final Transfer transfer;
  final bool isDark;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final isActive = transfer.status == TransferStatus.transferring;
    final isCompleted = transfer.status == TransferStatus.completed;
    final isFailed = transfer.status == TransferStatus.failed;

    final progressColor = isCompleted
        ? AppColors.neonGreen
        : (isFailed ? Colors.redAccent : AppColors.neonBlue);

    return GlassmorphismCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // File icon
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: progressColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isCompleted
                      ? Icons.check_circle_rounded
                      : (isFailed
                          ? Icons.error_outline_rounded
                          : Icons.description_outlined),
                  color: progressColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),

              // Device name + file name
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transfer.deviceName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.textPrimary
                            : Colors.black87,
                      ),
                    ),
                    Text(
                      '${transfer.isSending ? AppLocalizations.get("sending", locale) : AppLocalizations.get("receiving", locale)} "${transfer.fileName}"',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondary
                            : Colors.grey.shade600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Cancel / completed
              if (isActive)
                OutlinedButton.icon(
                  onPressed: () {
                    // Cancel transfer
                  },
                  icon: const Icon(Icons.close, size: 14),
                  label: Text(
                    AppLocalizations.get('cancel', locale),
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    side: BorderSide(
                      color: isDark
                          ? AppColors.glassBorder
                          : Colors.grey.shade300,
                    ),
                  ),
                )
              else if (isCompleted)
                Icon(Icons.check, color: AppColors.neonGreen, size: 22),
            ],
          ),
          const SizedBox(height: 10),

          // Progress bar
          NeonProgressBar(
            progress: transfer.progress,
            color: progressColor,
          ),
          const SizedBox(height: 6),

          // Bottom row: size info + status
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${transfer.formattedTransferredSize} / ${transfer.formattedFileSize}${transfer.speed != null ? ' · ${_formatSpeed(transfer.speed!)}' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textTertiary
                      : Colors.grey.shade500,
                ),
              ),
              Text(
                isCompleted
                    ? AppLocalizations.get('completed', locale)
                    : (isFailed
                        ? AppLocalizations.get('failed', locale)
                        : (transfer.estimatedTimeLeft != null
                            ? _formatDuration(transfer.estimatedTimeLeft!)
                            : '')),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isCompleted
                      ? AppColors.neonGreen
                      : (isFailed
                          ? Colors.redAccent
                          : AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes > 0) {
      return AppLocalizations.format('timeMinSec', locale, {
        'min': d.inMinutes.toString(),
        'sec': (d.inSeconds % 60).toString(),
      });
    }
    return AppLocalizations.format('timeSec', locale, {
      'sec': d.inSeconds.toString(),
    });
  }
}

// =============================================================================
// Empty state widgets
// =============================================================================

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.locale, required this.isDark});
  final String locale;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.devices_other,
            size: 48,
            color: isDark ? AppColors.textTertiary : Colors.grey.shade400,
          ),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.get('noDevices', locale),
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppColors.textSecondary : Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            AppLocalizations.get('scanning', locale),
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppColors.textTertiary : Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTransfers extends StatelessWidget {
  const _EmptyTransfers({required this.locale, required this.isDark});
  final String locale;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(
              Icons.swap_horiz_rounded,
              size: 48,
              color: isDark ? AppColors.textTertiary : Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.get('noTransfers', locale),
              style: TextStyle(
                fontSize: 14,
                color:
                    isDark ? AppColors.textSecondary : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              AppLocalizations.get('noTransfersDesc', locale),
              style: TextStyle(
                fontSize: 12,
                color:
                    isDark ? AppColors.textTertiary : Colors.grey.shade400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Latency Chip
// =============================================================================

class _LatencyChip extends StatelessWidget {
  const _LatencyChip({required this.ms});
  final int ms;

  @override
  Widget build(BuildContext context) {
    final quality = latencyQuality(ms);
    final Color color;
    switch (quality) {
      case LatencyQuality.excellent:
        color = AppColors.neonGreen;
      case LatencyQuality.good:
        color = AppColors.neonGreen;
      case LatencyQuality.fair:
        color = Colors.orange;
      case LatencyQuality.poor:
        color = Colors.redAccent;
      case LatencyQuality.offline:
        color = Colors.grey;
      case LatencyQuality.unknown:
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        formatLatency(ms),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// =============================================================================
// Utility
// =============================================================================

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
