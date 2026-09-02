import 'dart:io';
import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:anyware/core/file_picker_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/core/responsive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/core/tv_detector.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/data/latency_service.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/discovery/presentation/device_list_screen.dart';
import 'package:anyware/features/pairing/presentation/manual_ip_dialog.dart';
import 'package:anyware/features/pairing/presentation/qr_options_dialog.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/sharing/presentation/share_target_picker.dart';
import 'package:anyware/features/transfer/domain/transfer.dart';
import 'package:anyware/features/transfer/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/widgets/glassmorphism.dart';
import 'package:anyware/widgets/app_states.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:anyware/features/sharing/data/sharing_service.dart';
import 'package:anyware/features/sharing/data/dropped_file_expander.dart';
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
      _intentSub = service.getMediaStream().listen(
        (List<SharedMediaFile> value) {
          if (value.isNotEmpty) {
            final paths = value.map((f) => f.path).toList();
            _showDevicePickerDialog(paths, AppLocalizations.detectLocale());
          }
        },
        onError: (err) {
          _log.warning("getIntentDataStream error: $err");
        },
      );

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
    final result = await FilePickerHelper.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;

    await _sendFilesToDevice(target, paths);
  }

  /// Picks files first, then opens the unified LAN/cloud share target picker.
  Future<void> _pickAndShareFiles(String locale) async {
    final result = await FilePickerHelper.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty || !mounted) return;

    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;

    await _showDevicePickerDialog(paths, locale);
  }

  /// Opens a folder picker dialog and sends all files in the folder to the target device.
  Future<void> _pickAndSendFolder(Device target) async {
    final folderPath = await FilePickerHelper.getDirectoryPath();
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
        SnackBar(
          content: Text(
            '${AppLocalizations.get('sendFolderFailed', AppLocalizations.detectLocale())}: $e',
          ),
        ),
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
        SnackBar(
          content: Text(
            '${AppLocalizations.get('sendFileFailed', AppLocalizations.detectLocale())}: $e',
          ),
        ),
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
          SnackBar(
            content: Text(AppLocalizations.get('clipboardEmpty', locale)),
          ),
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
      ref
          .read(clipboardHistoryProvider.notifier)
          .addEntry(
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
        SnackBar(
          content: Text(
            '${AppLocalizations.get('sendClipboardFailed', AppLocalizations.detectLocale())}: $e',
          ),
        ),
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
    final accounts = ref.read(serverSyncServiceProvider).accounts;
    if (devices.isEmpty && accounts.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.get('noDevices', locale))),
        );
      }
      return;
    }

    if (!mounted) return;
    final selection = await showShareTargetPicker(
      context: context,
      devices: devices,
      accounts: accounts,
      filePaths: filePaths,
      locale: locale,
    );

    if (selection == null || !mounted) return;
    final selected = selection.target;
    final queuedPaths = selection.filePaths;
    if (selected is DeviceShareTarget) {
      await _sendFilesToDevice(selected.device, queuedPaths);
    } else if (selected is AccountShareTarget) {
      await _sendFilesToServer(selected.account, queuedPaths, locale);
    }
  }

  Future<void> _sendFilesToServer(
    SyncAccount account,
    List<String> filePaths,
    String locale,
  ) async {
    final service = ref.read(serverSyncServiceProvider.notifier);
    final remoteDir = account.remotePath.isEmpty ? '/' : account.remotePath;

    if (!mounted) return;
    await showDialog<void>(
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
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

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
      if (isDesktopShell)
        FilledButton.icon(
          onPressed: () => _pickAndShareFiles(locale),
          icon: const Icon(Icons.file_upload_outlined, size: 18),
          label: Text(AppLocalizations.get('sendFiles', locale)),
        )
      else
        IconButton(
          icon: const Icon(Icons.file_upload_outlined, size: 20),
          tooltip: AppLocalizations.get('sendFiles', locale),
          onPressed: () => _pickAndShareFiles(locale),
        ),
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
                  Row(mainAxisSize: MainAxisSize.min, children: headerActions),
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
                  return _EmptyDevices(
                    locale: locale,
                    isDark: isDark,
                    onRefresh: () => ref.read(refreshDiscoveryProvider)(),
                    onConnectionOptions: () {
                      showDialog<void>(
                        context: context,
                        builder: (_) => QrOptionsDialog(locale: locale),
                      );
                    },
                    onAddManually: () {
                      showDialog<void>(
                        context: context,
                        builder: (_) => ManualIpDialog(locale: locale),
                      );
                    },
                  );
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
                    onFilesDropped: (rawPaths) async {
                      _dropHandledByCard = true;
                      // Debounce: ignore if another drop just happened (<500ms).
                      final now = DateTime.now();
                      if (_lastDropSendTime != null &&
                          now.difference(_lastDropSendTime!).inMilliseconds <
                              500) {
                        return;
                      }
                      _lastDropSendTime = now;
                      final paths = await expandDroppedPaths(rawPaths);
                      if (!mounted || paths.isEmpty) return;
                      _sendFilesToDevice(devices[index], paths);
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
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
                      label: Text(AppLocalizations.get('retry', locale)),
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
              children: [
                Expanded(
                  child: Text(
                    AppLocalizations.get('recentTransfers', locale),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isTV ? 22 : 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.textPrimary : Colors.black87,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.timeline_rounded, size: 20),
                  tooltip: AppLocalizations.get('timeline', locale),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TimelineScreen()),
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
                    child: Text(AppLocalizations.get('clearCompleted', locale)),
                  ),
              ],
            ),
          ),
        ),

        // ─── Transfer List ───
        if (transfers.isEmpty)
          SliverToBoxAdapter(
            child: _EmptyTransfers(
              locale: locale,
              onSendFiles: () => _pickAndShareFiles(locale),
              onOpenTimeline: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TimelineScreen()),
                );
              },
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final transfer = transfers[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TransferCard(
                    transfer: transfer,
                    isDark: isDark,
                    locale: locale,
                  ),
                );
              }, childCount: transfers.length > 5 ? 5 : transfers.length),
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
          final rawPaths = details.files.map((f) => f.path).toList();
          if (rawPaths.isEmpty) return;
          Future.microtask(() async {
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
            final paths = await expandDroppedPaths(rawPaths);
            if (!mounted || paths.isEmpty) return;
            _showDevicePickerDialog(paths, locale);
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
          duration: context.motionDuration(AppMotion.standard),
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
                    StatusBadge(label: _statusLabel, color: _statusColor),
                  ],
                ),
                const Spacer(),

                // Device name + Pro badge
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.device.name,
                        style: TextStyle(
                          fontSize: widget.isTV ? 16 : 14,
                          fontWeight: FontWeight.w700,
                          color: widget.isDark
                              ? AppColors.textPrimary
                              : Colors.black87,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
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

class _TransferCard extends ConsumerWidget {
  const _TransferCard({
    required this.transfer,
    required this.isDark,
    required this.locale,
  });

  final Transfer transfer;
  final bool isDark;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive =
        transfer.status == TransferStatus.transferring ||
        transfer.status == TransferStatus.paused;
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
                        color: isDark ? AppColors.textPrimary : Colors.black87,
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
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(
                          AppLocalizations.get('cancelTransfer', locale),
                        ),
                        content: Text(
                          AppLocalizations.get('cancelTransferConfirm', locale),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: Text(AppLocalizations.get('no', locale)),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: Text(AppLocalizations.get('yes', locale)),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !context.mounted) return;

                    if (transfer.isSending) {
                      ref
                          .read(fileSenderProvider)
                          .whenData((sender) => sender.cancel());
                    }
                    ref
                        .read(activeTransfersProvider.notifier)
                        .addOrUpdate(
                          transfer.copyWith(status: TransferStatus.cancelled),
                        );
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
          NeonProgressBar(progress: transfer.progress, color: progressColor),
          const SizedBox(height: 6),

          // Bottom row: size info + status
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 4,
            spacing: 12,
            children: [
              Text(
                '${transfer.formattedTransferredSize} / ${transfer.formattedFileSize}${transfer.speed != null ? ' · ${_formatSpeed(transfer.speed!)}' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? AppColors.textTertiary : Colors.grey.shade500,
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
                      : (isFailed ? Colors.redAccent : AppColors.textSecondary),
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

class _EmptyDevices extends ConsumerWidget {
  const _EmptyDevices({
    required this.locale,
    required this.isDark,
    required this.onRefresh,
    required this.onConnectionOptions,
    required this.onAddManually,
  });

  final String locale;
  final bool isDark;
  final VoidCallback onRefresh;
  final VoidCallback onConnectionOptions;
  final VoidCallback onAddManually;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final diagnostics = ref.watch(networkDiagnosticsProvider);
    final hasNetworkIssue = diagnostics.valueOrNull?.hasIssues ?? false;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final visual = _ScanningDeviceVisual(
          color: colors.onSurfaceVariant,
          compact: compact,
        );

        final copyAndActions = Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: hasNetworkIssue
                          ? colors.error
                          : AppColors.statusConnected,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color:
                              (hasNetworkIssue
                                      ? colors.error
                                      : AppColors.statusConnected)
                                  .withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      hasNetworkIssue
                          ? AppLocalizations.get(
                              'networkTroubleshooting',
                              locale,
                            )
                          : AppLocalizations.get('scanning', locale),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: hasNetworkIssue
                            ? colors.error
                            : colors.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                AppLocalizations.get('noDevices', locale),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                AppLocalizations.get('diagSameNetwork', locale),
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              if (compact)
                Row(
                  children: [
                    IconButton.outlined(
                      tooltip: AppLocalizations.get('addManually', locale),
                      onPressed: onAddManually,
                      icon: const Icon(Icons.add_link_rounded, size: 19),
                    ),
                    const SizedBox(width: 6),
                    IconButton.outlined(
                      tooltip: AppLocalizations.get('qrOptions', locale),
                      onPressed: onConnectionOptions,
                      icon: const Icon(Icons.qr_code_rounded, size: 19),
                    ),
                    const SizedBox(width: 6),
                    IconButton.outlined(
                      tooltip: AppLocalizations.get('retry', locale),
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh_rounded, size: 19),
                    ),
                  ],
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onAddManually,
                      icon: const Icon(Icons.add_link_rounded, size: 18),
                      label: Text(AppLocalizations.get('addManually', locale)),
                    ),
                    OutlinedButton.icon(
                      onPressed: onConnectionOptions,
                      icon: const Icon(Icons.qr_code_rounded, size: 18),
                      label: Text(AppLocalizations.get('qrOptions', locale)),
                    ),
                    IconButton.outlined(
                      tooltip: AppLocalizations.get('retry', locale),
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh_rounded, size: 19),
                    ),
                  ],
                ),
            ],
          ),
        );

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : AppColors.lightCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isDark
                    ? AppColors.glassBorder
                    : AppColors.lightCardBorder,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 14 : 22,
                vertical: 12,
              ),
              child: Row(
                children: [
                  copyAndActions,
                  SizedBox(width: compact ? 8 : 20),
                  visual,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ScanningDeviceVisual extends StatefulWidget {
  const _ScanningDeviceVisual({required this.color, required this.compact});

  final Color color;
  final bool compact;

  @override
  State<_ScanningDeviceVisual> createState() => _ScanningDeviceVisualState();
}

class _ScanningDeviceVisualState extends State<_ScanningDeviceVisual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _controller.stop();
      _controller.value = 0.35;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.compact ? 68.0 : 104.0;
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final value = Curves.easeOut.transform(_controller.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 0.72 + (value * 0.38),
                child: Opacity(
                  opacity: (1 - value).clamp(0.0, 1.0),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.color.withValues(alpha: 0.42),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: size * 0.68,
                height: size * 0.68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      widget.color.withValues(alpha: 0.24),
                      widget.color.withValues(alpha: 0.08),
                    ],
                  ),
                  border: Border.all(
                    color: widget.color.withValues(alpha: 0.24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.devices_other_rounded,
                  size: size * 0.32,
                  color: widget.color,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyTransfers extends StatelessWidget {
  const _EmptyTransfers({
    required this.locale,
    required this.onSendFiles,
    required this.onOpenTimeline,
  });

  final String locale;
  final VoidCallback onSendFiles;
  final VoidCallback onOpenTimeline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 250),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkCard : AppColors.lightCard,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isDark ? AppColors.glassBorder : AppColors.lightCardBorder,
          ),
        ),
        child: AppEmptyState(
          icon: Icons.rocket_launch_rounded,
          title: AppLocalizations.get('noTransfers', locale),
          description: AppLocalizations.get('noTransfersDesc', locale),
          actionLabel: AppLocalizations.get('sendFiles', locale),
          actionIcon: Icons.file_upload_outlined,
          onAction: onSendFiles,
          secondaryActionLabel: AppLocalizations.get('timeline', locale),
          onSecondaryAction: onOpenTimeline,
          accentColor: colors.onSurfaceVariant,
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
