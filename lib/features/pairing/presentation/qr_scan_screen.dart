import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/core/logger.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

final _log = AppLogger('QrScan');

class QrScanScreen extends ConsumerStatefulWidget {
  const QrScanScreen({super.key, required this.locale});

  final String locale;

  @override
  ConsumerState<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends ConsumerState<QrScanScreen> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _isProcessing = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue == null) continue;

      try {
        _isProcessing = true;
        
        // Titreşim geri bildirimi
        final hasVibrator = await Vibration.hasVibrator();
        if (hasVibrator == true) {
          Vibration.vibrate(duration: 50);
        }

        final jsonString = barcode.rawValue!;
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        
        // Basit doğrulama: id ve name var mı?
        if (!json.containsKey('id') || !json.containsKey('name')) {
          throw const FormatException('Invalid QR code format');
        }

        final device = Device.fromJson(json);
        
        // Servise ekle
        final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
        if (discoveryService != null) {
          discoveryService.addManualDevice(device);
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.format('pairedWith', widget.locale, {'name': device.name})),
                backgroundColor: AppColors.neonGreen,
              ),
            );
            Navigator.of(context).pop();
          }
        }
      } catch (e) {
        _log.error('QR Scan Error: $e', error: e);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.get('invalidCode', widget.locale)),
              backgroundColor: Colors.red,
            ),
          );
          // Hata sonrası tekrar taramaya izin ver
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _isProcessing = false);
          });
        }
      }
      // İlk geçerli barkodda dur
      break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(AppLocalizations.get('scanQrTitle', widget.locale)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _onDetect,
          ),
          // Tarama Çerçevesi Overlay
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(
                  color: AppColors.neonBlue,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.neonBlue.withValues(alpha: 0.3),
                    spreadRadius: 2,
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
          ),
          // Alt Açıklama
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Text(
              AppLocalizations.get('alignQr', widget.locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                shadows: [
                  Shadow(
                    blurRadius: 4,
                    color: Colors.black,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
