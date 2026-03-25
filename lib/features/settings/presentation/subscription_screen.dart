import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

import 'package:anyware/core/licensing/license_models.dart';
import 'package:anyware/core/licensing/license_service.dart';
import 'package:anyware/core/licensing/purchase_service.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/features/settings/presentation/activate_code_dialog.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';

/// Full-screen subscription management page.
///
/// Shows: current plan, activation code (if Pro), device list,
/// upgrade button (if Free), and restore purchase option.
class SubscriptionScreen extends ConsumerWidget {
  const SubscriptionScreen({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final licenseInfo = ref.watch(licenseServiceProvider);

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Plan card ──
        _PlanCard(licenseInfo: licenseInfo, locale: locale),

        const SizedBox(height: 16),

        // ── Activation code (Pro only) ──
        if (licenseInfo.isPro && licenseInfo.activationCode.isNotEmpty) ...[
          _ActivationCodeCard(
            code: licenseInfo.activationCode,
            locale: locale,
          ),
          const SizedBox(height: 16),
        ],

        // ── Device list (Pro only) ──
        if (licenseInfo.isPro) ...[
          _DeviceListCard(
            licenseInfo: licenseInfo,
            locale: locale,
          ),
          const SizedBox(height: 16),
        ],

        // ── Actions ──
        if (!licenseInfo.isPro) ...[
          // Free user: upgrade or enter code
          _FreeActionsCard(locale: locale),
        ] else ...[
          // Pro user: manage subscription
          _ProActionsCard(locale: locale),
        ],
      ],
    );

    if (DesktopShellScope.of(context)) {
      return DesktopContentShell(
        title: AppLocalizations.get('subscription', locale),
        maxWidth: 600,
        child: body,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.get('subscription', locale)),
      ),
      body: body,
    );
  }
}

// ── Plan card ──

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.licenseInfo, required this.locale});

  final LicenseInfo licenseInfo;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPro = licenseInfo.isPro;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isPro ? Icons.workspace_premium : Icons.card_membership,
                  color: isPro ? AppColors.neonGreen : theme.colorScheme.onSurfaceVariant,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPro
                            ? 'Pro ${_planLabel(licenseInfo.plan)}'
                            : AppLocalizations.get('freePlan', locale),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isPro
                            ? AppLocalizations.format(
                                'planDeviceCount',
                                locale,
                                {
                                  'current': '${licenseInfo.activeDeviceCount}',
                                  'max': '${licenseInfo.maxDevices}',
                                },
                              )
                            : AppLocalizations.get('freePlanDesc', locale),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isPro)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.neonGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      AppLocalizations.get('active', locale),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.neonGreen,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _planLabel(LicensePlan plan) {
    switch (plan) {
      case LicensePlan.pro3:
        return '3';
      case LicensePlan.pro5:
        return '5';
      case LicensePlan.pro10:
        return '10';
      case LicensePlan.lifetime:
        return 'Lifetime';
      default:
        return '';
    }
  }
}

// ── Activation code card ──

class _ActivationCodeCard extends StatelessWidget {
  const _ActivationCodeCard({required this.code, required this.locale});

  final String code;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.get('activationCode', locale),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      code,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 20,
                        letterSpacing: 3,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: AppLocalizations.get('copiedToClipboard', locale),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            AppLocalizations.get('copiedToClipboard', locale)),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('activationCodeHint', locale),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Device list card ──

class _DeviceListCard extends ConsumerWidget {
  const _DeviceListCard({required this.licenseInfo, required this.locale});

  final LicenseInfo licenseInfo;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final currentUuid =
        ref.read(licenseServiceProvider.notifier).currentDeviceUuid;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.format('activeDevices', locale, {
                'current': '${licenseInfo.activeDeviceCount}',
                'max': '${licenseInfo.maxDevices}',
              }),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ...licenseInfo.devices.map((device) {
              final isCurrent = device.deviceUuid == currentUuid;
              return ListTile(
                leading: Icon(_platformIcon(device.platform)),
                title: Text(device.deviceName.isEmpty
                    ? device.deviceUuid.substring(0, 8)
                    : device.deviceName),
                subtitle: isCurrent
                    ? Text(
                        AppLocalizations.get('thisDevice', locale),
                        style: TextStyle(color: AppColors.neonGreen),
                      )
                    : Text(_formatLastSeen(device.lastSeenAt, locale)),
                trailing: isCurrent
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: AppLocalizations.get('removeDevice', locale),
                        onPressed: () => _confirmRemove(
                          context,
                          ref,
                          device.deviceUuid,
                          device.deviceName,
                        ),
                      ),
              );
            }),
          ],
        ),
      ),
    );
  }

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'windows':
        return Icons.desktop_windows;
      case 'android':
        return Icons.phone_android;
      case 'linux':
        return Icons.computer;
      case 'macos':
        return Icons.laptop_mac;
      case 'ios':
        return Icons.phone_iphone;
      default:
        return Icons.devices;
    }
  }

  String _formatLastSeen(DateTime lastSeen, String locale) {
    final diff = DateTime.now().difference(lastSeen);
    if (diff.inMinutes < 5) {
      return AppLocalizations.get('justNow', locale);
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h';
    }
    return '${diff.inDays}d';
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    String uuid,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.get('removeDevice', locale)),
        content: Text(AppLocalizations.format(
          'removeDeviceConfirm',
          locale,
          {'name': name.isNotEmpty ? name : uuid.substring(0, 8)},
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppLocalizations.get('cancel', locale)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(AppLocalizations.get('remove', locale)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(licenseServiceProvider.notifier).removeDevice(uuid);
    }
  }
}

// ── Free user actions ──

class _FreeActionsCard extends ConsumerWidget {
  const _FreeActionsCard({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final purchaseService = ref.read(purchaseServiceProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (purchaseService.isAvailable) ...[
              FilledButton.icon(
                icon: const Icon(Icons.workspace_premium),
                label: Text(AppLocalizations.get('upgradeToPro', locale)),
                onPressed: () async {
                  try {
                    final result = await RevenueCatUI.presentPaywall();
                    if (result == PaywallResult.purchased ||
                        result == PaywallResult.restored) {
                      // Refresh license from Supabase after purchase
                      await ref
                          .read(licenseServiceProvider.notifier)
                          .refresh();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(AppLocalizations.get(
                                'upgradeSuccess', locale)),
                            backgroundColor: AppColors.neonGreen,
                          ),
                        );
                      }
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(AppLocalizations.get(
                              'storeNotReady', locale)),
                        ),
                      );
                    }
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              icon: const Icon(Icons.vpn_key_outlined),
              label: Text(AppLocalizations.get('iHaveACode', locale)),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (_) => ActivateCodeDialog(locale: locale),
                );
              },
            ),
            if (purchaseService.isAvailable) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _restorePurchase(context, ref),
                child: Text(AppLocalizations.get('restorePurchase', locale)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _restorePurchase(BuildContext context, WidgetRef ref) async {
    final appUserId =
        await ref.read(purchaseServiceProvider).restorePurchases();

    if (!context.mounted) return;

    if (appUserId != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.get('restoreSuccess', locale)),
          backgroundColor: AppColors.neonGreen,
        ),
      );
      // Refresh license from Supabase (webhook should have created it).
      await ref.read(licenseServiceProvider.notifier).refresh();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.get('restoreNoResult', locale)),
        ),
      );
    }
  }
}

// ── Pro user actions ──

class _ProActionsCard extends ConsumerWidget {
  const _ProActionsCard({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.get('refreshLicense', locale)),
              onPressed: () async {
                await ref.read(licenseServiceProvider.notifier).refresh();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          AppLocalizations.get('licenseRefreshed', locale)),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
