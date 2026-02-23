import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Dialog for adding or editing an SFTP server configuration.
class ServerConfigDialog extends ConsumerStatefulWidget {
  const ServerConfigDialog({super.key, this.server});

  /// If non-null, we are editing an existing server.
  final SftpServerConfig? server;

  @override
  ConsumerState<ServerConfigDialog> createState() => _ServerConfigDialogState();
}

class _ServerConfigDialogState extends ConsumerState<ServerConfigDialog> {
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '22');
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _privateKeyCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  final _remotePathCtrl = TextEditingController(text: '/');

  String _authMethod = 'password';
  bool _isTesting = false;
  String? _testResult;

  bool get _isEditing => widget.server != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final s = widget.server!;
      _nameCtrl.text = s.name;
      _hostCtrl.text = s.host;
      _portCtrl.text = s.port.toString();
      _usernameCtrl.text = s.username;
      _passwordCtrl.text = s.password;
      _privateKeyCtrl.text = s.privateKey ?? '';
      _passphraseCtrl.text = s.passphrase ?? '';
      _remotePathCtrl.text = s.remotePath;
      _authMethod = s.authMethod;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _privateKeyCtrl.dispose();
    _passphraseCtrl.dispose();
    _remotePathCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    final config = _buildConfig();
    final ok =
        await ref.read(sftpTransportProvider).testConnection(config);

    if (!mounted) return;
    setState(() {
      _isTesting = false;
      _testResult = ok ? 'ok' : 'fail';
    });
  }

  SftpServerConfig _buildConfig() {
    return SftpServerConfig(
      id: widget.server?.id ?? const Uuid().v4(),
      name: _nameCtrl.text.trim(),
      host: _hostCtrl.text.trim(),
      port: int.tryParse(_portCtrl.text.trim()) ?? 22,
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
      privateKey:
          _authMethod == 'key' ? _privateKeyCtrl.text : null,
      passphrase:
          _authMethod == 'key' ? _passphraseCtrl.text : null,
      remotePath: _remotePathCtrl.text.trim().isEmpty
          ? '/'
          : _remotePathCtrl.text.trim(),
      authMethod: _authMethod,
      createdAt: widget.server?.createdAt ?? DateTime.now(),
      lastConnectedAt: widget.server?.lastConnectedAt,
    );
  }

  Future<void> _importKeyFile() async {
    // Request storage permission on Android.
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) return;
    }

    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    try {
      final content = await File(path).readAsString();
      _privateKeyCtrl.text = content;
    } catch (_) {
      // Ignore – invalid file selection.
    }
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty || _hostCtrl.text.trim().isEmpty) return;

    final config = _buildConfig();
    final service = ref.read(serverSyncServiceProvider.notifier);

    if (_isEditing) {
      await service.updateServer(config);
    } else {
      await service.addServer(config);
    }

    if (mounted) Navigator.of(context).pop(true);
  }

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
              // Server name
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: AppLocalizations.get('serverName', locale),
                  hintText: 'My NAS',
                  prefixIcon: const Icon(Icons.label_rounded, size: 20),
                ),
              ),
              const SizedBox(height: 12),

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
                        prefixIcon:
                            const Icon(Icons.dns_rounded, size: 20),
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
                    label: Text(
                        AppLocalizations.get('serverAuthKey', locale)),
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
                    prefixIcon:
                        const Icon(Icons.lock_rounded, size: 20),
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
                        icon: const Icon(Icons.upload_file_rounded, size: 20),
                        tooltip: AppLocalizations.get('importKeyFile', locale),
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
                    prefixIcon:
                        const Icon(Icons.lock_rounded, size: 20),
                  ),
                  obscureText: true,
                ),
              ],
              const SizedBox(height: 12),

              // Remote path
              TextField(
                controller: _remotePathCtrl,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizations.get('serverRemotePath', locale),
                  hintText: '/home/user/sync',
                  prefixIcon:
                      const Icon(Icons.folder_rounded, size: 20),
                ),
              ),
              const SizedBox(height: 16),

              // Test connection button
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
          onPressed: _save,
          icon: const Icon(Icons.save_rounded, size: 18),
          label: Text(AppLocalizations.get('confirm', locale)),
        ),
      ],
    );
  }
}
