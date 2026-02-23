import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// 3-step wizard for creating a new server sync job.
class ServerSyncJobWizard extends ConsumerStatefulWidget {
  const ServerSyncJobWizard({super.key});

  @override
  ConsumerState<ServerSyncJobWizard> createState() =>
      _ServerSyncJobWizardState();
}

class _ServerSyncJobWizardState extends ConsumerState<ServerSyncJobWizard> {
  final _pageController = PageController();
  int _currentStep = 0;

  // Step 1: Basics
  final _nameController = TextEditingController();
  String? _sourceDirectory;
  SftpServerConfig? _targetServer;
  final _remoteSubPathController = TextEditingController();

  // Step 2: Options
  SyncDirection _syncDirection = SyncDirection.oneWay;
  ConflictStrategy _conflictStrategy = ConflictStrategy.newerWins;
  bool _mirrorDeletions = true;
  bool _liveWatch = false;

  // Step 3: Filters
  final List<String> _includePatterns = [];
  final List<String> _excludePatterns = [
    '.DS_Store',
    'Thumbs.db',
    '*.tmp',
    'desktop.ini',
  ];
  final _filterController = TextEditingController();

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _remoteSubPathController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  bool get _canProceed {
    switch (_currentStep) {
      case 0:
        return _nameController.text.trim().isNotEmpty &&
            _sourceDirectory != null &&
            _targetServer != null;
      default:
        return true;
    }
  }

  void _nextStep() {
    if (_currentStep < 2) {
      setState(() => _currentStep++);
      _pageController.animateToPage(_currentStep,
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      _createJob();
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _pageController.animateToPage(_currentStep,
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
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
          final folderName = result.split(Platform.pathSeparator).last;
          _nameController.text = '$folderName Sync';
        }
      });
    }
  }

  Future<void> _createJob() async {
    final service = ref.read(serverSyncServiceProvider.notifier);
    await service.createJob(
      name: _nameController.text.trim(),
      sourceDirectory: _sourceDirectory!,
      serverId: _targetServer!.id,
      remoteSubPath: _remoteSubPathController.text.trim(),
      syncDirection: _syncDirection,
      conflictStrategy: _conflictStrategy,
      includePatterns: _includePatterns,
      excludePatterns: _excludePatterns,
      mirrorDeletions: _mirrorDeletions,
      liveWatch: _liveWatch,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;
    final serverState = ref.watch(serverSyncServiceProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(AppLocalizations.get('newServerSyncJob', locale)),
      ),
      body: Column(
        children: [
          // Step indicator
          _buildStepIndicator(locale),
          const Divider(height: 1),

          // Pages
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildStep1Basics(locale, serverState.servers),
                _buildStep2Options(locale),
                _buildStep3Filters(locale),
              ],
            ),
          ),

          // Navigation bar
          _buildNavigationBar(locale),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(String locale) {
    final steps = [
      AppLocalizations.get('serverSyncStep1', locale),
      AppLocalizations.get('serverSyncStep2', locale),
      AppLocalizations.get('serverSyncStep3', locale),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: List.generate(steps.length, (i) {
          final isActive = i <= _currentStep;
          return Expanded(
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: isActive
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade600,
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white)),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(steps[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.normal,
                        color: isActive ? null : Colors.grey,
                      ),
                      overflow: TextOverflow.ellipsis),
                ),
                if (i < steps.length - 1) const SizedBox(width: 8),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ── Step 1: Basics ──

  Widget _buildStep1Basics(
      String locale, List<SftpServerConfig> servers) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Job name
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: AppLocalizations.get('serverSyncJobName', locale),
              hintText: 'Documents Sync',
              prefixIcon: const Icon(Icons.label_rounded, size: 20),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),

          // Source folder
          Text(AppLocalizations.get('serverSyncSourceFolder', locale),
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickSourceFolder,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade600),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_open_rounded, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _sourceDirectory ??
                          AppLocalizations.get(
                              'syncSelectFolder', locale),
                      style: TextStyle(
                        fontSize: 14,
                        color: _sourceDirectory != null
                            ? null
                            : Colors.grey,
                      ),
                    ),
                  ),
                  Icon(Icons.edit_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Target server
          Text(AppLocalizations.get('serverSyncTargetServer', locale),
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          if (servers.isEmpty)
            Text(
                AppLocalizations.get('noServersConfigured', locale),
                style: TextStyle(color: Colors.grey.shade500))
          else
            ...servers.map((s) => RadioListTile<SftpServerConfig>(
                  title: Text(s.name),
                  subtitle: Text('${s.host}:${s.port}'),
                  value: s,
                  groupValue: _targetServer,
                  onChanged: (v) => setState(() => _targetServer = v),
                  dense: true,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                )),
          const SizedBox(height: 16),

          // Remote subfolder (optional)
          TextField(
            controller: _remoteSubPathController,
            decoration: InputDecoration(
              labelText: AppLocalizations.get(
                  'serverSyncRemoteSubfolder', locale),
              hintText: 'Documents',
              prefixIcon: const Icon(Icons.subdirectory_arrow_right_rounded,
                  size: 20),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 2: Options ──

  Widget _buildStep2Options(String locale) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sync direction
          Text(AppLocalizations.get('syncDirection', locale),
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          SegmentedButton<SyncDirection>(
            segments: [
              ButtonSegment(
                value: SyncDirection.oneWay,
                label: Text(AppLocalizations.get('syncOneWay', locale)),
                icon: const Icon(Icons.arrow_upward_rounded, size: 18),
              ),
              ButtonSegment(
                value: SyncDirection.bidirectional,
                label:
                    Text(AppLocalizations.get('syncBidirectional', locale)),
                icon: const Icon(Icons.sync_rounded, size: 18),
              ),
            ],
            selected: {_syncDirection},
            onSelectionChanged: (s) =>
                setState(() => _syncDirection = s.first),
          ),
          const SizedBox(height: 16),

          // Conflict strategy (only for bidirectional)
          if (_syncDirection == SyncDirection.bidirectional) ...[
            Text(AppLocalizations.get('conflictStrategy', locale),
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 8),
            SegmentedButton<ConflictStrategy>(
              segments: [
                ButtonSegment(
                  value: ConflictStrategy.newerWins,
                  label: Text(AppLocalizations.get(
                      'conflictNewerWins', locale)),
                ),
                ButtonSegment(
                  value: ConflictStrategy.keepBoth,
                  label: Text(AppLocalizations.get(
                      'conflictKeepBoth', locale)),
                ),
              ],
              selected: {_conflictStrategy},
              onSelectionChanged: (s) =>
                  setState(() => _conflictStrategy = s.first),
            ),
            const SizedBox(height: 16),
          ],

          // Mirror deletions
          SwitchListTile(
            title: Text(AppLocalizations.get('mirrorDeletions', locale)),
            subtitle: Text(
                AppLocalizations.get('mirrorDeletionsDesc', locale)),
            value: _mirrorDeletions,
            onChanged: (v) => setState(() => _mirrorDeletions = v),
          ),

          // Live watch
          SwitchListTile(
            title:
                Text(AppLocalizations.get('serverSyncLiveWatch', locale)),
            subtitle: Text(AppLocalizations.get(
                'serverSyncLiveWatchDesc', locale)),
            value: _liveWatch,
            onChanged: (v) => setState(() => _liveWatch = v),
          ),
        ],
      ),
    );
  }

  // ── Step 3: Filters ──

  Widget _buildStep3Filters(String locale) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.get('includePatterns', locale),
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: _includePatterns
                .map((p) => Chip(
                      label: Text(p, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setState(
                          () => _includePatterns.remove(p)),
                    ))
                .toList(),
          ),
          if (_includePatterns.isEmpty)
            Text(AppLocalizations.get('syncFiltersDesc', locale),
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(height: 16),

          Text(AppLocalizations.get('excludePatterns', locale),
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: _excludePatterns
                .map((p) => Chip(
                      label: Text(p, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setState(
                          () => _excludePatterns.remove(p)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),

          // Add filter pattern
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _filterController,
                  decoration: const InputDecoration(
                    hintText: '*.log, node_modules/**, ...',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addExcludePattern(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _addExcludePattern,
                icon: const Icon(Icons.add_rounded),
                tooltip: 'Add exclude pattern',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addExcludePattern() {
    final pattern = _filterController.text.trim();
    if (pattern.isEmpty) return;
    setState(() {
      _excludePatterns.add(pattern);
      _filterController.clear();
    });
  }

  Widget _buildNavigationBar(String locale) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (_currentStep > 0)
            TextButton.icon(
              onPressed: _prevStep,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: Text(AppLocalizations.get('back', locale)),
            ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _canProceed ? _nextStep : null,
            icon: Icon(
              _currentStep == 2
                  ? Icons.check_rounded
                  : Icons.arrow_forward_rounded,
              size: 18,
            ),
            label: Text(_currentStep == 2
                ? AppLocalizations.get('createServerSyncJob', locale)
                : AppLocalizations.get('next', locale)),
          ),
        ],
      ),
    );
  }
}
