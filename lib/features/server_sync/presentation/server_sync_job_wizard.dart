import 'dart:io';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:anyware/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/data/ftp_cloud_transport.dart';
import 'package:anyware/features/server_sync/data/sftp_cloud_transport.dart';
import 'package:anyware/features/server_sync/data/onedrive_transport.dart';
import 'package:anyware/features/server_sync/data/webdav_cloud_transport.dart';
import 'package:anyware/features/server_sync/data/cloud_transport.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/server_sync/presentation/remote_folder_browser.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// 3-step wizard for creating a new server sync job.
class ServerSyncJobWizard extends ConsumerStatefulWidget {
  const ServerSyncJobWizard({super.key, this.preselectedAccount});

  /// When non-null the wizard pre-selects this account as the target server,
  /// so the user coming from "Add Server" doesn't have to pick it again.
  final SyncAccount? preselectedAccount;

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
  SyncAccount? _targetAccount;
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
  void initState() {
    super.initState();
    if (widget.preselectedAccount != null) {
      _targetAccount = widget.preselectedAccount;
    }
  }

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
            _targetAccount != null;
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
    final result = await FilePickerHelper.getDirectoryPath();
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

  /// Build WebDAV URL — accepts full URL in host field.
  static String _buildWebDavUrl(SyncAccount account) {
    final host = account.host ?? '';
    if (host.startsWith('http://') || host.startsWith('https://')) {
      return host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    }
    final port = account.port ?? 443;
    final scheme = port == 443 ? 'https' : 'http';
    return '$scheme://$host:$port';
  }

  Future<void> _browseRemoteFolder(String locale) async {
    final account = _targetAccount;
    if (account == null) return;

    RemoteBrowser? browser;
    try {
      switch (account.providerType) {
        case SyncProviderType.sftp:
          final transport = SftpCloudTransport(
            transport: ref.read(sftpTransportProvider),
            config: account.toSftpConfig(),
          );
          await transport.connect();
          browser = transport;
          break;
        case SyncProviderType.ftp:
          final ftpTransport = FtpCloudTransport(
            host: account.host ?? '',
            port: account.port ?? 21,
            username: account.username ?? '',
            password: account.password ?? '',
            basePath: account.remotePath,
          );
          await ftpTransport.connect();
          browser = ftpTransport;
          break;
        case SyncProviderType.gdrive:
          // drive.file scope — folder browser cannot list existing Drive
          // folders. Users type the path manually; the app creates it.
          return;
        case SyncProviderType.webdav:
          final transport = WebDavCloudTransport(
            url: _buildWebDavUrl(account),
            username: account.username ?? '',
            password: account.password ?? '',
            basePath: account.remotePath,
          );
          await transport.connect();
          browser = transport;
          break;
        case SyncProviderType.onedrive:
          final transport = OneDriveTransport(
            oauth: ref.read(oauthServiceProvider),
            accountId: account.id,
          );
          await transport.connect();
          browser = transport;
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
      return;
    }

    if (!mounted) return;

    final result = await showRemoteFolderPicker(
      context,
      browser: browser,
      title: AppLocalizations.get('browseRemoteFolder', locale),
      accentColor: account.providerType == SyncProviderType.gdrive
          ? const Color(0xFF34A853)
          : account.providerType == SyncProviderType.onedrive
              ? const Color(0xFF0078D4)
              : Theme.of(context).colorScheme.primary,
      locale: locale,
    );

    if (result != null && mounted) {
      setState(() {
        _remoteSubPathController.text = result;
      });
    }

    // Disconnect if the browser is also a CloudTransport
    if (browser is CloudTransport) {
      await (browser as CloudTransport).disconnect();
    }
  }

  Future<void> _createJob() async {
    final service = ref.read(serverSyncServiceProvider.notifier);
    await service.createJob(
      name: _nameController.text.trim(),
      sourceDirectory: _sourceDirectory!,
      serverId: _targetAccount!.id,
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
                _buildStep1Basics(locale, serverState.accounts),
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
      String locale, List<SyncAccount> accounts) {
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
          if (accounts.isEmpty)
            Text(
                AppLocalizations.get('noServersConfigured', locale),
                style: TextStyle(color: Colors.grey.shade500))
          else
            ...accounts.map((a) => RadioListTile<SyncAccount>(
                  title: Text(a.name),
                  subtitle: Text(a.subtitle),
                  value: a,
                  groupValue: _targetAccount,
                  onChanged: (v) => setState(() => _targetAccount = v),
                  dense: true,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  secondary: Icon(
                    a.isSftp
                        ? Icons.dns_rounded
                        : a.isFtp
                            ? Icons.folder_shared_rounded
                            : a.isWebDav
                                ? Icons.language_rounded
                                : a.providerType == SyncProviderType.gdrive
                                    ? Icons.cloud_rounded
                                    : Icons.cloud_queue_rounded,
                    size: 20,
                    color: a.isSftp || a.isFtp
                        ? null
                        : a.isWebDav
                            ? const Color(0xFF00897B)
                            : a.providerType == SyncProviderType.gdrive
                                ? const Color(0xFF34A853)
                                : const Color(0xFF0078D4),
                  ),
                )),
          const SizedBox(height: 16),

          // Remote folder
          Text(AppLocalizations.get('serverSyncRemoteSubfolder', locale),
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),

          // Google Drive → text field (drive.file scope can't browse)
          // SFTP / OneDrive → browse button
          if (_targetAccount?.providerType == SyncProviderType.gdrive) ...[
            TextField(
              controller: _remoteSubPathController,
              decoration: InputDecoration(
                hintText: AppLocalizations.get('gdrivePathHint', locale),
                prefixIcon: const Icon(Icons.cloud_rounded,
                    size: 20, color: Color(0xFF34A853)),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Builder(builder: (context) {
              final isDark = Theme.of(context).brightness == Brightness.dark;
              final bgColor = isDark
                  ? AppColors.neonBlue.withValues(alpha: 0.12)
                  : AppColors.lightPrimary.withValues(alpha: 0.08);
              final borderColor = isDark
                  ? AppColors.neonBlue.withValues(alpha: 0.3)
                  : AppColors.lightPrimary.withValues(alpha: 0.2);
              final iconColor = isDark
                  ? AppColors.neonBlue
                  : AppColors.lightPrimary;
              final textColor = isDark
                  ? AppColors.neonBlue
                  : AppColors.lightPrimary;
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: iconColor),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        AppLocalizations.get('gdrivePathInfo', locale),
                        style: TextStyle(
                            fontSize: 12.5, color: textColor),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ] else ...[
            InkWell(
              onTap: _targetAccount != null
                  ? () => _browseRemoteFolder(locale)
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _targetAccount != null
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                        : Colors.grey.shade700,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: _targetAccount != null
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.05)
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(Icons.cloud_rounded,
                        size: 20,
                        color: _targetAccount != null
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _remoteSubPathController.text.isNotEmpty
                            ? _remoteSubPathController.text
                            : AppLocalizations.get(
                                'browseRemoteFolder', locale),
                        style: TextStyle(
                          fontSize: 14,
                          color: _remoteSubPathController.text.isNotEmpty
                              ? null
                              : Colors.grey,
                        ),
                      ),
                    ),
                    if (_targetAccount != null)
                      Icon(Icons.folder_open_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary),
                  ],
                ),
              ),
            ),
            if (_targetAccount == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  AppLocalizations.get('selectServerFirst', locale),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
          ],
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
            onSelectionChanged: (s) {
              setState(() => _syncDirection = s.first);
            },
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
            onChanged: (v) {
              setState(() => _liveWatch = v);
            },
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
