import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Dialog that lets the user manually enter an IP address to connect
/// to a device on a different network (e.g., via hotspot).
class ManualIpDialog extends ConsumerStatefulWidget {
  const ManualIpDialog({super.key, required this.locale});

  final String locale;

  @override
  ConsumerState<ManualIpDialog> createState() => _ManualIpDialogState();
}

class _ManualIpDialogState extends ConsumerState<ManualIpDialog> {
  final _controller = TextEditingController();
  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      // Parse IP and optional port
      String ip;
      int port = AppConstants.defaultPort;

      if (input.contains(':')) {
        final parts = input.split(':');
        ip = parts[0];
        port = int.tryParse(parts[1]) ?? AppConstants.defaultPort;
      } else {
        ip = input;
      }

      // Try to reach the device's /api/info endpoint
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);

      final request = await httpClient.getUrl(
        Uri.http('$ip:$port', '/api/info'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      httpClient.close();

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final device = Device.fromJson(json).copyWith(
        ip: ip,
        port: port,
        lastSeen: DateTime.now(),
      );

      // Add to discovery service
      final discoveryService =
          ref.read(discoveryServiceProvider).valueOrNull;
      if (discoveryService != null) {
        discoveryService.addManualDevice(device);
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.format(
              'deviceAdded',
              widget.locale,
              {'name': device.name},
            )),
            backgroundColor: AppColors.neonGreen,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage =
              AppLocalizations.get('connectionFailed', widget.locale);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.locale;

    return AlertDialog(
      title: Text(AppLocalizations.get('addManually', locale)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_isConnecting,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: AppLocalizations.get('enterIpAddress', locale),
              hintText: AppLocalizations.get('ipAddressHint', locale),
              prefixIcon: const Icon(Icons.lan_outlined),
              errorText: _errorMessage,
            ),
            onSubmitted: (_) => _connect(),
          ),
          if (_isConnecting) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(AppLocalizations.get('connecting', locale)),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isConnecting ? null : () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.get('cancel', locale)),
        ),
        FilledButton(
          onPressed: _isConnecting ? null : _connect,
          child: Text(AppLocalizations.get('addManually', locale)),
        ),
      ],
    );
  }
}
