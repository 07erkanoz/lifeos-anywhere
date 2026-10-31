import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Settings list of paired devices with "Eşleşmeyi kaldır".
class PairedDevicesSection extends ConsumerWidget {
  const PairedDevicesSection({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(trustStoreProvider);
    final devices = store.devices;
    final theme = Theme.of(context);

    if (devices.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.verified_user_outlined),
        subtitle: Text(
          AppLocalizations.get('pairedDevicesEmpty', locale),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final device in devices)
          ListTile(
            leading: Icon(_iconFor(device.platform)),
            title: Text(device.name),
            subtitle: Text(
              device.isLegacy
                  ? AppLocalizations.get('pairedLegacy', locale)
                  : AppLocalizations.format('pairedSince', locale, {
                      'date': _formatDate(device.pairedAt),
                    }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.link_off_rounded),
              tooltip: AppLocalizations.get('unpair', locale),
              onPressed: () => _confirmRemove(context, store, device),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    TrustStore store,
    TrustedDevice device,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.get('unpair', locale)),
        content: Text(
          AppLocalizations.format('unpairConfirm', locale, {
            'name': device.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppLocalizations.get('unpair', locale)),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.remove(device.id);
  }

  static String _formatDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}';
  }

  static IconData _iconFor(String platform) {
    switch (platform) {
      case 'android':
        return Icons.phone_android;
      case 'android_tv':
        return Icons.tv;
      case 'windows':
        return Icons.desktop_windows;
      case 'ios':
        return Icons.phone_iphone;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }
}
