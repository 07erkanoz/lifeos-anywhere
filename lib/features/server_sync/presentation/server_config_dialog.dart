import 'dart:io';

import 'package:anyware/core/file_picker_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import 'package:anyware/core/cloud_credentials.dart';
import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/data/ftp_cloud_transport.dart';
import 'package:anyware/features/server_sync/data/webdav_cloud_transport.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Dialog for adding or editing a sync account (SFTP, Google Drive, OneDrive).
class ServerConfigDialog extends ConsumerStatefulWidget {
  const ServerConfigDialog({super.key, this.account});

  /// If non-null, we are editing an existing account.
  final SyncAccount? account;

  @override
  ConsumerState<ServerConfigDialog> createState() => _ServerConfigDialogState();
}

class _ServerConfigDialogState extends ConsumerState<ServerConfigDialog> {
  // ── Provider selection ──
  SyncProviderType _providerType = SyncProviderType.sftp;

  // ── Common fields ──
  final _nameCtrl = TextEditingController();
  final _remotePathCtrl = TextEditingController(text: '/');

  // ── SFTP fields ──
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _privateKeyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  String _authMethod = 'password';

  // ── Cloud OAuth state ──
  bool _isAuthenticating = false;
  String? _cloudEmail;

  // ── Testing ──
  bool _isTesting = false;
  String? _testResult;
  String? _testErrorMsg;

  /// Stable ID for this account — generated once so the OAuth token and
  /// the persisted [SyncAccount] always share the same identifier.
  late final String _accountId;

  bool get _isEditing => widget.account != null;

  @override
  void initState() {
    super.initState();
    _accountId = widget.account?.id ?? const Uuid().v4();
    if (_isEditing) {
      final a = widget.account!;
      _providerType = a.providerType;
      _nameCtrl.text = a.name;
      _remotePathCtrl.text = a.remotePath;
      _hostCtrl.text = a.host ?? '';
      final defaultPort = a.isFtp ? 21 : (a.isWebDav ? 443 : 22);
      _portCtrl.text = (a.port ?? defaultPort).toString();
      _usernameCtrl.text = a.username ?? '';
      _passwordCtrl.text = a.password ?? '';
      _privateKeyCtrl.text = a.privateKey ?? '';
      _passphraseCtrl.text = a.passphrase ?? '';
      _authMethod = a.authMethod ?? 'password';
      _cloudEmail = a.email;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _remotePathCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _privateKeyCtrl.dispose();
    _passphraseCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // OAuth
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _authenticateCloud() async {
    setState(() => _isAuthenticating = true);

    try {
      final oauth = ref.read(oauthServiceProvider);
      final tempId = _accountId;

      if (_providerType == SyncProviderType.gdrive) {
        final token = await oauth.authenticateGoogle(tempId);
        final email = await oauth.getGoogleEmail(token);
        if (mounted) {
          setState(() {
            _cloudEmail = email ?? 'Google Account';
            if (_nameCtrl.text.trim().isEmpty) {
              _nameCtrl.text = 'Google Drive ($_cloudEmail)';
            }
          });
        }
      } else if (_providerType == SyncProviderType.onedrive) {
        final token = await oauth.authenticateMicrosoft(tempId);
        final email = await oauth.getMicrosoftEmail(token);
        if (mounted) {
          setState(() {
            _cloudEmail = email ?? 'OneDrive Account';
            if (_nameCtrl.text.trim().isEmpty) {
              _nameCtrl.text = 'OneDrive ($_cloudEmail)';
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Authentication failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isAuthenticating = false);
    }
  }

  Future<void> _disconnectCloud() async {
    final accountId = widget.account?.id;
    if (accountId != null) {
      await ref.read(oauthServiceProvider).revokeToken(accountId);
    }
    setState(() => _cloudEmail = null);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WebDAV URL helper
  // ═══════════════════════════════════════════════════════════════════════════

  /// Build WebDAV URL — accepts full URL in host field (e.g. https://seafile.com/seafdav/).
  static String _buildWebDavUrl(SyncAccount account) {
    final host = account.host ?? '';
    if (host.startsWith('http://') || host.startsWith('https://')) {
      return host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    }
    final port = account.port ?? 443;
    final scheme = port == 443 ? 'https' : 'http';
    return '$scheme://$host:$port';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Test connection
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
      _testErrorMsg = null;
    });

    bool ok = false;
    String? errorMsg;
    try {
      if (_providerType == SyncProviderType.sftp) {
        final sftpConfig = _buildAccount().toSftpConfig();
        ok = await ref.read(sftpTransportProvider).testConnection(sftpConfig);
      } else if (_providerType == SyncProviderType.ftp) {
        final account = _buildAccount();
        final transport = FtpCloudTransport(
          host: account.host ?? '',
          port: account.port ?? 21,
          username: account.username ?? '',
          password: account.password ?? '',
          basePath: account.remotePath,
        );
        ok = await transport.testConnection();
      } else if (_providerType == SyncProviderType.webdav) {
        final account = _buildAccount();
        final transport = WebDavCloudTransport(
          url: _buildWebDavUrl(account),
          username: account.username ?? '',
          password: account.password ?? '',
          basePath: account.remotePath,
        );
        ok = await transport.testConnection();
      } else {
        // For cloud, we check if we have a valid email (== authenticated)
        ok = _cloudEmail != null && _cloudEmail!.isNotEmpty;
      }
    } catch (e) {
      ok = false;
      errorMsg = e.toString();
    }

    if (!mounted) return;
    setState(() {
      _isTesting = false;
      _testResult = ok ? 'ok' : 'fail';
      _testErrorMsg = errorMsg;
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build account & save
  // ═══════════════════════════════════════════════════════════════════════════

  SyncAccount _buildAccount() {
    final isHostBased = _providerType == SyncProviderType.sftp ||
        _providerType == SyncProviderType.ftp ||
        _providerType == SyncProviderType.webdav;
    final isSftp = _providerType == SyncProviderType.sftp;
    final isFtp = _providerType == SyncProviderType.ftp;
    final defaultPort = isSftp ? 22 : (isFtp ? 21 : 443);
    return SyncAccount(
      id: _accountId,
      name: _nameCtrl.text.trim(),
      providerType: _providerType,
      createdAt: widget.account?.createdAt ?? DateTime.now(),
      lastConnectedAt: widget.account?.lastConnectedAt,
      host: isHostBased ? _hostCtrl.text.trim() : null,
      port: isHostBased
          ? (int.tryParse(_portCtrl.text.trim()) ?? defaultPort)
          : null,
      username: isHostBased ? _usernameCtrl.text.trim() : null,
      password: isHostBased ? _passwordCtrl.text : null,
      privateKey: isSftp && _authMethod == 'key'
          ? _privateKeyCtrl.text
          : null,
      passphrase: isSftp && _authMethod == 'key'
          ? _passphraseCtrl.text
          : null,
      remotePath: _remotePathCtrl.text.trim().isEmpty
          ? '/'
          : _remotePathCtrl.text.trim(),
      authMethod: isSftp ? _authMethod : null,
      email: _cloudEmail,
    );
  }

  Future<void> _importKeyFile() async {
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) return;
    }

    final result = await FilePickerHelper.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    try {
      final content = await File(path).readAsString();
      _privateKeyCtrl.text = content;
    } catch (_) {}
  }

  bool get _canSave {
    if (_nameCtrl.text.trim().isEmpty) return false;
    if (_providerType == SyncProviderType.sftp ||
        _providerType == SyncProviderType.ftp ||
        _providerType == SyncProviderType.webdav) {
      return _hostCtrl.text.trim().isNotEmpty;
    }
    // Cloud providers require authentication
    return _cloudEmail != null && _cloudEmail!.isNotEmpty;
  }

  Future<void> _save() async {
    if (!_canSave) return;

    final account = _buildAccount();
    final service = ref.read(serverSyncServiceProvider.notifier);

    if (_isEditing) {
      await service.updateAccount(account);
    } else {
      await service.addAccount(account);
    }

    if (mounted) Navigator.of(context).pop(account);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final locale = settings.locale;

    return AlertDialog(
      title: Text(_isEditing
          ? AppLocalizations.get('editServer', locale)
          : AppLocalizations.get('addServer', locale)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Provider selector (only when creating new) ──
              if (!_isEditing) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _providerChip(SyncProviderType.sftp, Icons.dns_rounded, 'SFTP'),
                    _providerChip(SyncProviderType.ftp, Icons.folder_shared_rounded, 'FTP'),
                    _providerChip(SyncProviderType.webdav, Icons.language_rounded, 'WebDAV'),
                    if (CloudCredentials.hasGoogleCredentials)
                      _providerChip(SyncProviderType.gdrive, Icons.cloud_rounded, 'Google Drive'),
                    if (CloudCredentials.hasMsCredentials)
                      _providerChip(SyncProviderType.onedrive, Icons.cloud_queue_rounded, 'OneDrive'),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // ── Account name ──
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverName', locale),
                  hintText: _providerType == SyncProviderType.sftp
                      ? 'My NAS'
                      : _providerType == SyncProviderType.ftp
                          ? 'My FTP Server'
                          : _providerType == SyncProviderType.webdav
                              ? 'My Nextcloud'
                              : _providerType == SyncProviderType.gdrive
                                  ? 'Google Drive'
                                  : 'OneDrive',
                  prefixIcon: const Icon(Icons.label_rounded, size: 20),
                ),
              ),
              const SizedBox(height: 12),

              // ── Provider-specific fields ──
              if (_providerType == SyncProviderType.sftp)
                _buildSftpFields(locale)
              else if (_providerType == SyncProviderType.ftp)
                _buildFtpFields(locale)
              else if (_providerType == SyncProviderType.webdav)
                _buildWebDavFields(locale)
              else
                _buildCloudFields(locale),

              const SizedBox(height: 12),

              // ── Remote path (for SFTP, FTP & WebDAV; cloud folder is chosen per job) ──
              if (_providerType == SyncProviderType.sftp ||
                  _providerType == SyncProviderType.ftp ||
                  _providerType == SyncProviderType.webdav) ...[
                TextField(
                  controller: _remotePathCtrl,
                  decoration: InputDecoration(
                    labelText:
                        AppLocalizations.get('serverRemotePath', locale),
                    hintText: _providerType == SyncProviderType.webdav
                        ? '/dav/files/user  or  /'
                        : _providerType == SyncProviderType.ftp
                            ? '/upload'
                            : '/home/user/sync',
                    prefixIcon:
                        const Icon(Icons.folder_rounded, size: 20),
                  ),
                ),
                const SizedBox(height: 16),
              ] else
                const SizedBox(height: 16),

              // ── Test connection ──
              OutlinedButton.icon(
                onPressed: _isTesting ? null : _testConnection,
                icon: _isTesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _testResult == 'ok'
                            ? Icons.check_circle_rounded
                            : _testResult == 'fail'
                                ? Icons.error_rounded
                                : Icons.wifi_tethering_rounded,
                        size: 18,
                        color: _testResult == 'ok'
                            ? Colors.green
                            : _testResult == 'fail'
                                ? Colors.red
                                : null,
                      ),
                label: Text(_isTesting
                    ? AppLocalizations.get('connecting', locale)
                    : _testResult == 'ok'
                        ? AppLocalizations.get('connectionSuccess', locale)
                        : _testResult == 'fail'
                            ? AppLocalizations.get(
                                'serverConnectionFailed', locale)
                            : AppLocalizations.get(
                                'testConnection', locale)),
              ),
              // Show error details when test fails
              if (_testResult == 'fail' && _testErrorMsg != null) ...[
                const SizedBox(height: 6),
                Text(
                  _testErrorMsg!,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(AppLocalizations.get('cancel', locale)),
        ),
        FilledButton.icon(
          onPressed: _canSave ? _save : null,
          icon: const Icon(Icons.save_rounded, size: 18),
          label: Text(AppLocalizations.get('confirm', locale)),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SFTP form fields
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildSftpFields(String locale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Host + Port
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverHost', locale),
                  hintText: '192.168.1.100',
                  prefixIcon: const Icon(Icons.dns_rounded, size: 20),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverPort', locale),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Username
        TextField(
          controller: _usernameCtrl,
          decoration: InputDecoration(
            labelText: AppLocalizations.get('serverUsername', locale),
            prefixIcon: const Icon(Icons.person_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 12),

        // Auth method selector
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'password',
              label: Text(
                  AppLocalizations.get('serverAuthPassword', locale)),
              icon: const Icon(Icons.key_rounded, size: 18),
            ),
            ButtonSegment(
              value: 'key',
              label:
                  Text(AppLocalizations.get('serverAuthKey', locale)),
              icon: const Icon(Icons.vpn_key_rounded, size: 18),
            ),
          ],
          selected: {_authMethod},
          onSelectionChanged: (s) =>
              setState(() => _authMethod = s.first),
        ),
        const SizedBox(height: 12),

        // Password or Key fields
        if (_authMethod == 'password')
          TextField(
            controller: _passwordCtrl,
            decoration: InputDecoration(
              labelText:
                  AppLocalizations.get('serverPassword', locale),
              prefixIcon: const Icon(Icons.lock_rounded, size: 20),
            ),
            obscureText: true,
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _privateKeyCtrl,
                  decoration: InputDecoration(
                    labelText:
                        AppLocalizations.get('serverPrivateKey', locale),
                    hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                    prefixIcon:
                        const Icon(Icons.vpn_key_rounded, size: 20),
                  ),
                  maxLines: 3,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: IconButton.filledTonal(
                  onPressed: _importKeyFile,
                  icon:
                      const Icon(Icons.upload_file_rounded, size: 20),
                  tooltip:
                      AppLocalizations.get('importKeyFile', locale),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passphraseCtrl,
            decoration: InputDecoration(
              labelText:
                  AppLocalizations.get('serverPassphrase', locale),
              prefixIcon: const Icon(Icons.lock_rounded, size: 20),
            ),
            obscureText: true,
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // FTP form fields (host, port, username, password — no key auth)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFtpFields(String locale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Host + Port
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverHost', locale),
                  hintText: '192.168.1.100',
                  prefixIcon: const Icon(Icons.folder_shared_rounded, size: 20),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverPort', locale),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Username
        TextField(
          controller: _usernameCtrl,
          decoration: InputDecoration(
            labelText: AppLocalizations.get('serverUsername', locale),
            prefixIcon: const Icon(Icons.person_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 12),

        // Password
        TextField(
          controller: _passwordCtrl,
          decoration: InputDecoration(
            labelText: AppLocalizations.get('serverPassword', locale),
            prefixIcon: const Icon(Icons.lock_rounded, size: 20),
          ),
          obscureText: true,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WebDAV form fields
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildWebDavFields(String locale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Host + Port
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverHost', locale),
                  hintText: 'nas.example.com or https://seafile.com/seafdav/',
                  prefixIcon: const Icon(Icons.language_rounded, size: 20),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverPort', locale),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Username
        TextField(
          controller: _usernameCtrl,
          decoration: InputDecoration(
            labelText: AppLocalizations.get('serverUsername', locale),
            prefixIcon: const Icon(Icons.person_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 12),

        // Password
        TextField(
          controller: _passwordCtrl,
          decoration: InputDecoration(
            labelText: AppLocalizations.get('serverPassword', locale),
            prefixIcon: const Icon(Icons.lock_rounded, size: 20),
          ),
          obscureText: true,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Provider chip for the selector
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _providerChip(SyncProviderType type, IconData icon, String label) {
    final selected = _providerType == type;
    return ChoiceChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() {
        _providerType = type;
        if (type == SyncProviderType.sftp) {
          _portCtrl.text = '22';
        } else if (type == SyncProviderType.ftp) {
          _portCtrl.text = '21';
        } else if (type == SyncProviderType.webdav) {
          _portCtrl.text = '443';
        }
      }),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Cloud OAuth fields (Google Drive / OneDrive)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildCloudFields(String locale) {
    final isGoogle = _providerType == SyncProviderType.gdrive;
    final providerName = isGoogle ? 'Google' : 'Microsoft';
    final providerColor =
        isGoogle ? const Color(0xFF34A853) : const Color(0xFF0078D4);
    final providerIcon = isGoogle ? Icons.cloud_rounded : Icons.cloud_queue_rounded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_cloudEmail != null) ...[
          // Connected state
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: providerColor.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
              color: providerColor.withValues(alpha: 0.05),
            ),
            child: Row(
              children: [
                Icon(providerIcon, color: providerColor, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connected to $providerName',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _cloudEmail!,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _disconnectCloud,
                  child: Text(
                    'Disconnect',
                    style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          // Not connected state
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isAuthenticating ? null : _authenticateCloud,
              icon: _isAuthenticating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(providerIcon, size: 20),
              label: Text(_isAuthenticating
                  ? 'Connecting...'
                  : 'Sign in with $providerName'),
              style: ElevatedButton.styleFrom(
                backgroundColor: providerColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
