import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:anyware/core/android_platform_service.dart';
import 'package:anyware/core/constants.dart';
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
  String? _statusMessage;

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

        // Vibration feedback
        final hasVibrator = await Vibration.hasVibrator();
        if (hasVibrator == true) {
          Vibration.vibrate(duration: 50);
        }

        final rawValue = barcode.rawValue!;

        // ── Type 1: URL (Web Portal or generic URL) ──
        if (rawValue.startsWith('http://') || rawValue.startsWith('https://')) {
          _log.info('QR contains URL: $rawValue');
          await _handleUrl(rawValue);
          return;
        }

        // ── Type 2: WiFi QR (WIFI:T:WPA;S:ssid;P:password;;) ──
        if (rawValue.startsWith('WIFI:')) {
          _log.info('QR contains WiFi credentials');
          await _handleWifiQr(rawValue);
          return;
        }

        // ── Type 3: JSON ──
        final dynamic decoded;
        try {
          decoded = jsonDecode(rawValue);
        } on FormatException {
          throw const FormatException('QR code is not a valid format');
        }
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid QR code format');
        }
        final json = decoded;

        // ── Type 3a: Hotspot connection data ──
        if (json['type'] == 'lifeos_hotspot') {
          _log.info('QR contains hotspot connection data');
          await _handleHotspotQr(json);
          return;
        }

        // ── Type 3b: Device pairing (existing format) ──
        if (!json.containsKey('id') || !json.containsKey('name')) {
          throw const FormatException('Invalid QR code format');
        }

        final device = Device.fromJson(json);

        // Add to service
        final discoveryService =
            ref.read(discoveryServiceProvider).valueOrNull;
        if (discoveryService != null) {
          discoveryService.addManualDevice(device);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.format(
                    'pairedWith', widget.locale, {'name': device.name})),
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
              content:
                  Text(AppLocalizations.get('invalidCode', widget.locale)),
              backgroundColor: Colors.red,
            ),
          );
          // Allow re-scanning after error
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _isProcessing = false);
          });
        }
      }
      // Stop at the first valid barcode
      break;
    }
  }

  /// Handle a URL QR code — open in browser.
  Future<void> _handleUrl(String url) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Web portal açılıyor...'),
          backgroundColor: AppColors.neonBlue,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    if (mounted) Navigator.of(context).pop();
  }

  /// Handle a WiFi QR code (WIFI:T:WPA;S:ssid;P:password;;).
  Future<void> _handleWifiQr(String wifiString) async {
    // Parse WIFI:T:WPA;S:MyNetwork;P:MyPassword;;
    final ssidMatch = RegExp(r'S:([^;]+)').firstMatch(wifiString);
    final passMatch = RegExp(r'P:([^;]+)').firstMatch(wifiString);

    if (ssidMatch == null) {
      _showError('Invalid WiFi QR format');
      return;
    }

    final ssid = ssidMatch.group(1)!;
    final password = passMatch?.group(1) ?? '';

    _log.info('WiFi QR: SSID=$ssid');
    await _connectToWifi(ssid, password);
  }

  /// Handle a LifeOS hotspot QR (JSON with type: "lifeos_hotspot").
  Future<void> _handleHotspotQr(Map<String, dynamic> json) async {
    final ssid = json['ssid'] as String? ?? '';
    final password = json['password'] as String? ?? '';
    final serverIp = json['serverIp'] as String? ?? '';
    final serverPort = json['serverPort'] as int? ?? AppConstants.defaultPort;
    final deviceId = json['deviceId'] as String? ?? '';
    final deviceName = json['deviceName'] as String? ?? 'Unknown';

    if (ssid.isEmpty) {
      _showError('Invalid hotspot QR: missing SSID');
      return;
    }

    setState(() {
      _statusMessage =
          AppLocalizations.get('hotspotConnecting', widget.locale);
    });

    // Step 1: Connect to WiFi
    final connected = await _connectToWifi(ssid, password);
    if (!connected) return;

    // Step 2: Wait a moment for network to stabilise
    await Future.delayed(const Duration(seconds: 2));

    // Step 3: Add device to discovery
    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    if (discoveryService != null && deviceId.isNotEmpty) {
      final device = Device(
        id: deviceId,
        name: deviceName,
        ip: serverIp,
        port: serverPort,
        lastSeen: DateTime.now(),
        platform: 'unknown',
        version: '0.0.0',
      );
      discoveryService.addManualDevice(device);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${AppLocalizations.get("hotspotConnected", widget.locale)} — $deviceName'),
          backgroundColor: AppColors.neonGreen,
        ),
      );
      Navigator.of(context).pop();
    }
  }

  static const _channel = MethodChannel('com.lifeos.anyware/platform');

  /// Attempt to connect to a WiFi network via platform-specific API.
  Future<bool> _connectToWifi(String ssid, String password) async {
    setState(() {
      _statusMessage =
          AppLocalizations.get('hotspotConnecting', widget.locale);
    });

    try {
      _log.info('Attempting to connect to WiFi: SSID=$ssid');

      if (Platform.isAndroid) {
        // Request location permission (required for WiFi operations on Android)
        final locationStatus = await Permission.locationWhenInUse.request();
        if (!locationStatus.isGranted) {
          _log.warning('Location permission denied — cannot connect to WiFi');
          _showError('Location permission required for WiFi connection');
          return false;
        }

        // Android: native WifiNetworkSpecifier (10+) or WifiManager (9-)
        // This shows a system dialog for the user to approve the connection.
        final connected = await _channel.invokeMethod<bool>('connectToWifi', {
          'ssid': ssid,
          'password': password,
        });
        if (connected == true) {
          _log.info('WiFi connected to $ssid');
          // Schedule network unbind so discovery uses the default route
          // after the hotspot data exchange completes.
          Future<void>.delayed(const Duration(seconds: 5), () {
            AndroidPlatformService.instance.unbindNetwork();
          });
          return true;
        } else {
          _log.warning('WiFi connection to $ssid was rejected or failed');
          _showError('WiFi connection failed');
          return false;
        }
      } else {
        // Desktop platforms (Windows/Linux) — show info for manual connect.
        // The user already has the hotspot running on their device; they need
        // to connect from the OS WiFi picker.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('WiFi: $ssid — '
                  'Connect from system WiFi settings (password: $password)'),
              backgroundColor: Colors.orangeAccent,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        // Return true to let the flow continue — the user should manually connect.
        return true;
      }
    } on PlatformException catch (e) {
      _log.warning('WiFi connect platform error: ${e.message}');
      _showError('WiFi: ${e.message}');
      return false;
    } catch (e) {
      _log.warning('WiFi connect failed: $e');
      _showError('WiFi connection failed: $e');
      return false;
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _statusMessage = null;
          });
        }
      });
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
          // Scan Frame Overlay
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
          // Status message (shown during hotspot connection)
          if (_statusMessage != null)
            Positioned(
              top: 120,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _statusMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Bottom Description
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
