import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:anyware/features/pairing/presentation/qr_display_dialog.dart';
import 'package:anyware/features/pairing/presentation/qr_scan_screen.dart';
import 'package:anyware/features/pairing/presentation/web_portal_qr_dialog.dart';
import 'package:anyware/features/pairing/presentation/hotspot_host_screen.dart';

/// Three-option QR dialog: Web Portal, Device Pairing, Hotspot.
class QrOptionsDialog extends ConsumerWidget {
  const QrOptionsDialog({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    return Dialog(
      backgroundColor: isDark ? AppColors.darkBg : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isDark ? AppColors.glassBorder : Colors.transparent,
          width: 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.get('qrOptions', locale),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isDark ? AppColors.textPrimary : Colors.black87,
                ),
              ),
              const SizedBox(height: 20),

              // ── Option 1: Web Portal ──
              _OptionTile(
                icon: Icons.language_rounded,
                iconColor: AppColors.neonBlue,
                title: AppLocalizations.get('qrWebPortal', locale),
                subtitle: AppLocalizations.get('qrWebPortalDesc', locale),
                onTap: () {
                  Navigator.of(context).pop();
                  showDialog(
                    context: context,
                    builder: (_) => WebPortalQrDialog(locale: locale),
                  );
                },
              ),
              const SizedBox(height: 12),

              // ── Option 2: Device Pairing (existing QR) ──
              _OptionTile(
                icon: isMobile
                    ? Icons.qr_code_scanner_rounded
                    : Icons.qr_code_rounded,
                iconColor: AppColors.neonGreen,
                title: AppLocalizations.get('qrDevicePairing', locale),
                subtitle: AppLocalizations.get('qrDevicePairingDesc', locale),
                onTap: () {
                  Navigator.of(context).pop();
                  if (isMobile) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => QrScanScreen(locale: locale),
                      ),
                    );
                  } else {
                    showDialog(
                      context: context,
                      builder: (_) => QrDisplayDialog(locale: locale),
                    );
                  }
                },
              ),
              const SizedBox(height: 12),

              // ── Option 3: Hotspot — Create ──
              _OptionTile(
                icon: Icons.wifi_tethering_rounded,
                iconColor: Colors.orangeAccent,
                title: AppLocalizations.get('hotspotCreate', locale),
                subtitle: AppLocalizations.get('hotspotCreateDesc', locale),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => HotspotHostScreen(locale: locale),
                    ),
                  );
                },
                visible: Platform.isAndroid ||
                    Platform.isWindows ||
                    Platform.isLinux,
              ),
              if (Platform.isAndroid ||
                  Platform.isWindows ||
                  Platform.isLinux)
                const SizedBox(height: 12),

              // ── Option 4: Hotspot — Join (scan QR) ──
              _OptionTile(
                icon: Icons.qr_code_scanner_rounded,
                iconColor: Colors.orangeAccent,
                title: AppLocalizations.get('hotspotJoin', locale),
                subtitle: AppLocalizations.get('hotspotJoinDesc', locale),
                onTap: () {
                  Navigator.of(context).pop();
                  if (isMobile) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => QrScanScreen(locale: locale),
                      ),
                    );
                  } else {
                    // Desktop can't scan QR; show instructions
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(AppLocalizations.get(
                            'hotspotJoinDesktopHint', locale)),
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                },
              ),

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        isDark ? AppColors.textSecondary : Colors.grey[600],
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(AppLocalizations.get('close', locale)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.visible = true,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.grey.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: isDark ? AppColors.textPrimary : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondary
                            : Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: isDark ? AppColors.textSecondary : Colors.grey[400],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
