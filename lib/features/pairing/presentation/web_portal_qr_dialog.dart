import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Displays a QR code containing the web portal URL so any device with a
/// camera and browser can open the file sharing panel instantly.
class WebPortalQrDialog extends ConsumerWidget {
  const WebPortalQrDialog({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;

    if (discoveryService == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final device = discoveryService.localDevice;
    final portalUrl =
        'http://${device.ip}:${AppConstants.defaultPort}/portal';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      backgroundColor: isDark ? AppColors.darkBg : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: isDark ? AppColors.glassBorder : Colors.transparent,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Title ──
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.language_rounded,
                    color: AppColors.neonBlue, size: 24),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.get('qrWebPortal', locale),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? AppColors.textPrimary : Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── QR Code ──
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: portalUrl,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 20),

            // ── Info text ──
            Text(
              AppLocalizations.get('webPortalScanInfo', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppColors.textSecondary : Colors.grey[600],
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),

            // ── URL display + copy ──
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: portalUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        AppLocalizations.get('copiedToClipboard', locale)),
                    backgroundColor: AppColors.neonGreen,
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: SelectableText(
                        portalUrl,
                        style: TextStyle(
                          fontFamily: 'Courier',
                          fontWeight: FontWeight.bold,
                          color: AppColors.neonBlue,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.copy_rounded,
                        size: 18, color: AppColors.neonBlue),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Close button ──
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.neonBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(AppLocalizations.get('close', locale)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
