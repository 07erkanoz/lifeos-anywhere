import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:anyware/core/constants.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

class QrDisplayDialog extends ConsumerWidget {
  const QrDisplayDialog({super.key, required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;

    if (discoveryService == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final device = discoveryService.localDevice;
    final jsonString = jsonEncode(device.toJson());
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
            Text(
              AppLocalizations.get('pairDevice', locale),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isDark ? AppColors.textPrimary : Colors.black87,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: jsonString,
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocalizations.get('scanQr', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppColors.textSecondary : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              '${device.ip}:${AppConstants.discoveryPort}',
              style: TextStyle(
                fontFamily: 'Courier',
                fontWeight: FontWeight.bold,
                color: AppColors.neonBlue,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.neonBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
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
