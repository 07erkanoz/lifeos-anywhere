import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/relay/domain/relay_room.dart';
import 'package:anyware/features/relay/presentation/providers.dart';
import 'package:anyware/features/settings/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

class RelayScreen extends ConsumerStatefulWidget {
  const RelayScreen({super.key});

  @override
  ConsumerState<RelayScreen> createState() => _RelayScreenState();
}

class _RelayScreenState extends ConsumerState<RelayScreen> {
  final TextEditingController _pinController = TextEditingController();

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final relayState = ref.watch(relayProvider);
    final locale = ref.watch(settingsProvider).locale;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('magicLink', locale)),
        actions: [
          if (relayState.connectionState != RelayConnectionState.idle)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: AppLocalizations.get('disconnect', locale),
              onPressed: () => ref.read(relayProvider.notifier).disconnect(),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _buildBody(relayState, locale, theme),
      ),
    );
  }

  Widget _buildBody(RelayState state, String locale, ThemeData theme) {
    switch (state.connectionState) {
      case RelayConnectionState.idle:
        return _buildIdleView(locale, theme);
      case RelayConnectionState.creatingRoom:
      case RelayConnectionState.joiningRoom:
      case RelayConnectionState.connecting:
        return _buildConnectingView(state, locale, theme);
      case RelayConnectionState.waitingForPeer:
        return _buildWaitingView(state, locale, theme);
      case RelayConnectionState.connected:
        return _buildConnectedView(state, locale, theme);
      case RelayConnectionState.transferring:
        return _buildTransferringView(state, locale, theme);
      case RelayConnectionState.error:
        return _buildErrorView(state, locale, theme);
    }
  }

  Widget _buildIdleView(String locale, ThemeData theme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.link,
              size: 64,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.get('magicLink', locale),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('magicLinkDesc', locale),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.add_circle_outline),
                label: Text(AppLocalizations.get('createRoom', locale)),
                onPressed: _createRoom,
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 24),
            TextField(
              controller: _pinController,
              decoration: InputDecoration(
                labelText: 'PIN',
                hintText: '000000',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.dialpad),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                letterSpacing: 8,
                fontWeight: FontWeight.bold,
              ),
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _joinRoom(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.login),
                label: Text(AppLocalizations.get('joinRoom', locale)),
                onPressed: _joinRoom,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaitingView(RelayState state, String locale, ThemeData theme) {
    final room = state.room;
    if (room == null) return const SizedBox.shrink();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.dialpad,
              size: 48,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.get('waitingForPeer', locale),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('magicLinkDesc', locale),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 32),
            // Big PIN display
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: room.pin));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.get('copiedToClipboard', locale)),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  room.pin.splitMapJoin(
                    RegExp(r'.{3}'),
                    onMatch: (m) => '${m.group(0)} ',
                    onNonMatch: (s) => s,
                  ).trim(),
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 12,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.get('copiedToClipboard', locale).replaceAll(
                RegExp(r'.*'),
                '',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 4),
                Text(
                  'PIN',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectingView(
      RelayState state, String locale, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.get('connecting', locale),
            style: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedView(
      RelayState state, String locale, ThemeData theme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle,
              size: 64,
              color: AppColors.statusConnected,
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.get('connected', locale),
              style: theme.textTheme.headlineSmall,
            ),
            if (state.peerName != null) ...[
              const SizedBox(height: 8),
              Text(
                state.peerName!,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
            if (state.transferProgress >= 1.0) ...[
              const SizedBox(height: 16),
              Icon(Icons.done_all, color: AppColors.statusConnected, size: 32),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.get('transferComplete', locale),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.upload_file),
                label: Text(AppLocalizations.get('sendFile', locale)),
                onPressed: _pickAndSendFile,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferringView(
      RelayState state, String locale, ThemeData theme) {
    final pct = (state.transferProgress * 100).toStringAsFixed(0);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 100,
              height: 100,
              child: CircularProgressIndicator(
                value: state.transferProgress,
                strokeWidth: 6,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '$pct%',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            if (state.transferFileName != null)
              Text(
                state.transferFileName!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView(RelayState state, String locale, ThemeData theme) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.get('error', locale),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              state.error ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.get('retry', locale)),
              onPressed: () => ref.read(relayProvider.notifier).disconnect(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createRoom() async {
    final deviceAsync = ref.read(localDeviceProvider);
    final deviceName = deviceAsync.value?.name ?? 'Unknown';
    ref.read(relayProvider.notifier).createRoom(deviceName);
  }

  Future<void> _joinRoom() async {
    final roomId = _pinController.text.trim();
    if (roomId.isEmpty) return;

    final deviceAsync = ref.read(localDeviceProvider);
    final deviceName = deviceAsync.value?.name ?? 'Unknown';
    ref.read(relayProvider.notifier).joinRoom(roomId, deviceName);
  }

  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.path == null) return;

    ref.read(relayProvider.notifier).sendFile(file.path!, file.name);
  }
}
