import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/data/sync_service.dart';
import 'package:anyware/features/sync/data/camera_folder_detector.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// 3-step wizard for creating a new sync job.
///
/// Step 1: Name, source folder, target device.
/// Step 2: Sync direction, conflict strategy, mode, mirror deletions.
/// Step 3: Include/exclude filters (optional, collapsible).
class SyncJobWizard extends ConsumerStatefulWidget {
  const SyncJobWizard({super.key});

  @override
  ConsumerState<SyncJobWizard> createState() => _SyncJobWizardState();
}

class _SyncJobWizardState extends ConsumerState<SyncJobWizard> {
  final _pageController = PageController();
  int _currentStep = 0;

  // Step 1: Basics
  final _nameController = TextEditingController();
  String? _sourceDirectory;
  Device? _targetDevice;

  // Step 2: Options
  SyncDirection _syncDirection = SyncDirection.oneWay;
  ConflictStrategy _conflictStrategy = ConflictStrategy.newerWins;
  SyncMode _syncMode = SyncMode.general;
  bool _mirrorDeletions = true;
  bool _convertHeicToJpg = false;
  String _dateSubfolderFormat = 'YYYY/MM';

  // Step 3: Filters
  final List<String> _includePatterns = [];
  final List<String> _excludePatterns = [];
  final _filterController = TextEditingController();
  bool _addingInclude = true;

  static const _defaultExcludes = [
    '.DS_Store',
    'Thumbs.db',
    '*.tmp',
    'desktop.ini',
  ];

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(settingsProvider).locale;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('newSyncJob', locale)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          // Step indicator
          _buildStepIndicator(theme, locale),
          const Divider(height: 1),

          // Page content
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildStep1Basics(locale, theme),
                _buildStep2Options(locale, theme),
                _buildStep3Filters(locale, theme),
              ],
            ),
          ),

          // Navigation buttons
          _buildNavigationBar(locale, theme),
        ],
      ),
    );
  }

  // ─── Step indicator ──────────────────────────────────────────────

  Widget _buildStepIndicator(ThemeData theme, String locale) {
    final steps = [
      AppLocalizations.get('syncStep1', locale),
      AppLocalizations.get('syncStep2', locale),
      AppLocalizations.get('syncStep3', locale),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: List.generate(steps.length, (i) {
          final isActive = i == _currentStep;
          final isDone = i < _currentStep;
          return Expanded(
            child: Row(
              children: [
                if (i > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: isDone
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                CircleAvatar(
                  radius: 14,
                  backgroundColor: isActive || isDone
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  child: isDone
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isActive
                                ? Colors.white
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    steps[i],
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                      color: isActive
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ─── Step 1: Basics ──────────────────────────────────────────────

  Widget _buildStep1Basics(String locale, ThemeData theme) {
    final devicesAsync = ref.watch(devicesProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Job name
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: AppLocalizations.get('syncJobName', locale),
              hintText: 'Documents Sync',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 20),

          // Source folder
          Text(
            AppLocalizations.get('syncSourceFolder', locale),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickSourceFolder,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_open,
                      color: _sourceDirectory != null
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _sourceDirectory ??
                          AppLocalizations.get('syncSelectFolder', locale),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _sourceDirectory != null
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Target device
          Text(
            AppLocalizations.get('syncTargetDevice', locale),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          devicesAsync.when(
            data: (devices) {
              if (devices.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.devices,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Text(
                        AppLocalizations.get('noDevicesFound', locale),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return DropdownButtonFormField<String>(
                initialValue: _targetDevice?.id,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.devices),
                  hintText: AppLocalizations.get('syncSelectDevice', locale),
                ),
                items: devices.map((d) {
                  return DropdownMenuItem(
                    value: d.id,
                    child: Row(
                      children: [
                        Icon(_platformIcon(d.platform), size: 18),
                        const SizedBox(width: 8),
                        Text(d.name),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (id) {
                  setState(() {
                    _targetDevice = devices.firstWhere((d) => d.id == id);
                  });
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  // ─── Step 2: Options ──────────────────────────────────────────────

  Widget _buildStep2Options(String locale, ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sync direction
          Text(
            AppLocalizations.get('syncDirection', locale),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<SyncDirection>(
            segments: [
              ButtonSegment(
                value: SyncDirection.oneWay,
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: Text(AppLocalizations.get('syncOneWay', locale)),
              ),
              ButtonSegment(
                value: SyncDirection.bidirectional,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: Text(AppLocalizations.get('syncBidirectional', locale)),
              ),
            ],
            selected: {_syncDirection},
            onSelectionChanged: (v) =>
                setState(() => _syncDirection = v.first),
          ),
          const SizedBox(height: 8),
          Text(
            _syncDirection == SyncDirection.oneWay
                ? AppLocalizations.get('syncOneWayDesc', locale)
                : AppLocalizations.get('syncBidirectionalDesc', locale),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),

          // Conflict strategy
          Text(
            AppLocalizations.get('conflictStrategy', locale),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<ConflictStrategy>(
            segments: [
              ButtonSegment(
                value: ConflictStrategy.newerWins,
                label: Text(AppLocalizations.get('conflictNewerWins', locale)),
              ),
              ButtonSegment(
                value: ConflictStrategy.askUser,
                label: Text(AppLocalizations.get('conflictAskUser', locale)),
              ),
              ButtonSegment(
                value: ConflictStrategy.keepBoth,
                label: Text(AppLocalizations.get('conflictKeepBoth', locale)),
              ),
            ],
            selected: {_conflictStrategy},
            onSelectionChanged: (v) =>
                setState(() => _conflictStrategy = v.first),
          ),
          const SizedBox(height: 20),

          // Sync mode
          Text(
            AppLocalizations.get('syncMode', locale),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SegmentedButton<SyncMode>(
            segments: [
              ButtonSegment(
                value: SyncMode.general,
                icon: const Icon(Icons.folder, size: 18),
                label: Text(AppLocalizations.get('syncModeGeneral', locale)),
              ),
              ButtonSegment(
                value: SyncMode.photoVideo,
                icon: const Icon(Icons.photo_camera, size: 18),
                label: Text(AppLocalizations.get('syncModePhotoVideo', locale)),
              ),
            ],
            selected: {_syncMode},
            onSelectionChanged: (v) => setState(() {
              _syncMode = v.first;
              // Auto-suggest camera path for photo mode (all platforms).
              if (_syncMode == SyncMode.photoVideo &&
                  _sourceDirectory == null) {
                final detected = CameraFolderDetector.detect();
                if (detected != null) {
                  _sourceDirectory = detected;
                }
                if (_nameController.text.trim().isEmpty) {
                  _nameController.text = 'Photo Sync';
                }
              }
            }),
          ),
          const SizedBox(height: 16),

          // Photo mode options (only visible in photo mode).
          if (_syncMode == SyncMode.photoVideo) ...[
            // Camera folder hint
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${AppLocalizations.get("syncCameraHint", locale)}: '
                      '${CameraFolderDetector.platformHint}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: Text(AppLocalizations.get('convertHeicToJpg', locale)),
              subtitle: Text(
                AppLocalizations.get('convertHeicToJpgDesc', locale),
                style: theme.textTheme.bodySmall,
              ),
              secondary: const Icon(Icons.image),
              value: _convertHeicToJpg,
              onChanged: (v) => setState(() => _convertHeicToJpg = v),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: Text(AppLocalizations.get('dateSubfolders', locale)),
              trailing: DropdownButton<String>(
                value: _dateSubfolderFormat,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'YYYY/MM', child: Text('2026/02')),
                  DropdownMenuItem(
                      value: 'YYYY-MM-DD', child: Text('2026-02-22')),
                  DropdownMenuItem(value: 'YYYY', child: Text('2026')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _dateSubfolderFormat = v);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Mirror deletions
          SwitchListTile(
            title: Text(AppLocalizations.get('mirrorDeletions', locale)),
            subtitle: Text(
              AppLocalizations.get('mirrorDeletionsDesc', locale),
              style: theme.textTheme.bodySmall,
            ),
            secondary: const Icon(Icons.delete_sweep),
            value: _mirrorDeletions,
            onChanged: (v) => setState(() => _mirrorDeletions = v),
          ),
        ],
      ),
    );
  }

  // ─── Step 3: Filters ──────────────────────────────────────────────

  Widget _buildStep3Filters(String locale, ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.get('syncFilters', locale),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            AppLocalizations.get('syncFiltersDesc', locale),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),

          // Toggle: Include / Exclude
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: true,
                label: Text(AppLocalizations.get('includePatterns', locale)),
              ),
              ButtonSegment(
                value: false,
                label: Text(AppLocalizations.get('excludePatterns', locale)),
              ),
            ],
            selected: {_addingInclude},
            onSelectionChanged: (v) =>
                setState(() => _addingInclude = v.first),
          ),
          const SizedBox(height: 12),

          // Add pattern input
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _filterController,
                  decoration: InputDecoration(
                    hintText: '*.jpg, node_modules/**',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addPattern(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.add),
                onPressed: _addPattern,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Quick add presets for exclude
          if (!_addingInclude)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _defaultExcludes
                  .where((p) => !_excludePatterns.contains(p))
                  .map((p) => ActionChip(
                        label: Text(p),
                        avatar: const Icon(Icons.add, size: 16),
                        onPressed: () => setState(() => _excludePatterns.add(p)),
                      ))
                  .toList(),
            ),
          const SizedBox(height: 16),

          // Include patterns chips
          if (_includePatterns.isNotEmpty) ...[
            Text(
              AppLocalizations.get('includePatterns', locale),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _includePatterns
                  .map((p) => Chip(
                        label: Text(p),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () =>
                            setState(() => _includePatterns.remove(p)),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
          ],

          // Exclude patterns chips
          if (_excludePatterns.isNotEmpty) ...[
            Text(
              AppLocalizations.get('excludePatterns', locale),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _excludePatterns
                  .map((p) => Chip(
                        label: Text(p),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () =>
                            setState(() => _excludePatterns.remove(p)),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Navigation bar ──────────────────────────────────────────────

  Widget _buildNavigationBar(String locale, ThemeData theme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (_currentStep > 0)
              OutlinedButton.icon(
                icon: const Icon(Icons.arrow_back, size: 18),
                label: Text(AppLocalizations.get('back', locale)),
                onPressed: _goBack,
              ),
            const Spacer(),
            if (_currentStep < 2)
              FilledButton.icon(
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: Text(AppLocalizations.get('next', locale)),
                onPressed: _canProceed() ? _goNext : null,
              ),
            if (_currentStep == 2)
              FilledButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: Text(AppLocalizations.get('createSyncJob', locale)),
                onPressed: _canProceed() ? _createJob : null,
              ),
          ],
        ),
      ),
    );
  }

  // ─── Actions ──────────────────────────────────────────────────────

  bool _canProceed() {
    if (_currentStep == 0) {
      return _nameController.text.trim().isNotEmpty &&
          _sourceDirectory != null &&
          _targetDevice != null;
    }
    return true; // Steps 2 and 3 have defaults.
  }

  void _goNext() {
    if (_currentStep >= 2) return;
    setState(() => _currentStep++);
    _pageController.animateToPage(
      _currentStep,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _goBack() {
    if (_currentStep <= 0) return;
    setState(() => _currentStep--);
    _pageController.animateToPage(
      _currentStep,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _pickSourceFolder() async {
    if (Platform.isAndroid) {
      await Permission.manageExternalStorage.request();
    }
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _sourceDirectory = result;
        if (_nameController.text.trim().isEmpty) {
          // Auto-suggest name from folder name.
          final folderName = result.split(Platform.pathSeparator).last;
          _nameController.text = '$folderName Sync';
        }
      });
    }
  }

  void _addPattern() {
    final pattern = _filterController.text.trim();
    if (pattern.isEmpty) return;
    setState(() {
      if (_addingInclude) {
        if (!_includePatterns.contains(pattern)) {
          _includePatterns.add(pattern);
        }
      } else {
        if (!_excludePatterns.contains(pattern)) {
          _excludePatterns.add(pattern);
        }
      }
      _filterController.clear();
    });
  }

  Future<void> _createJob() async {
    if (_targetDevice == null || _sourceDirectory == null) return;

    final syncService = ref.read(syncServiceProvider.notifier);
    final jobId = await syncService.createJob(
      name: _nameController.text.trim(),
      sourceDirectory: _sourceDirectory!,
      target: _targetDevice!,
      syncDirection: _syncDirection,
      conflictStrategy: _conflictStrategy,
      syncMode: _syncMode,
      includePatterns: _includePatterns,
      excludePatterns: _excludePatterns,
      mirrorDeletions: _mirrorDeletions,
      convertHeicToJpg: _convertHeicToJpg,
      dateSubfolderFormat: _dateSubfolderFormat,
    );

    // Automatically start the job (sends setup request to receiver).
    syncService.startJob(jobId);

    if (mounted) Navigator.of(context).pop();
  }

  IconData _platformIcon(String platform) {
    switch (platform.toLowerCase()) {
      case 'windows':
        return Icons.desktop_windows;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }
}
