import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/theme.dart';
import 'package:anyware/core/wifi_hotspot_service.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/i18n/app_localizations.dart';

/// Screen that creates a WiFi hotspot and shows a QR code for connecting.
///
/// Flow:
///  1. Start hotspot (platform-specific)
///  2. Display QR with WiFi credentials + shelf server info
///  3. Wait for peer to connect
class HotspotHostScreen extends ConsumerStatefulWidget {
  const HotspotHostScreen({super.key, required this.locale});

  final String locale;

  @override
  ConsumerState<HotspotHostScreen> createState() => _HotspotHostScreenState();
}

enum _HotspotState { checking, starting, ready, error, unsupported }

class _HotspotHostScreenState extends ConsumerState<HotspotHostScreen> {
  _HotspotState _state = _HotspotState.checking;
  HotspotInfo? _hotspotInfo;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initHotspot();
  }

  Future<void> _initHotspot() async {
    final service = WifiHotspotService.instance;

    if (!service.canCreateHotspot) {
      setState(() => _state = _HotspotState.unsupported);
      return;
    }

    setState(() => _state = _HotspotState.starting);

    try {
      // Android requires location permission for startLocalOnlyHotspot.
      if (Platform.isAndroid) {
        final locationStatus = await Permission.locationWhenInUse.request();
        if (!locationStatus.isGranted) {
          if (mounted) {
            setState(() {
              _state = _HotspotState.error;
              _errorMessage = 'Location permission required for hotspot';
            });
          }
          return;
        }

        // Android 13+ also needs NEARBY_WIFI_DEVICES
        if (await Permission.nearbyWifiDevices.status.isDenied) {
          await Permission.nearbyWifiDevices.request();
        }
      }

      final info = await service.startHotspot();
      if (info != null && mounted) {
        setState(() {
          _hotspotInfo = info;
          _state = _HotspotState.ready;
        });
      } else if (mounted) {
        setState(() {
          _state = _HotspotState.error;
          _errorMessage = 'Failed to start hotspot';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _HotspotState.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    // Stop hotspot when leaving the screen.
    WifiHotspotService.instance.stopHotspot();
    super.dispose();
  }

  String _buildQrData() {
    final discoveryService = ref.read(discoveryServiceProvider).valueOrNull;
    final localDevice = discoveryService?.localDevice;
    final info = _hotspotInfo!;

    // JSON format that the scanner recognises as hotspot connection data.
    return '{'
        '"type":"lifeos_hotspot",'
        '"ssid":"${info.ssid}",'
        '"password":"${info.password}",'
        '"serverIp":"${info.ip}",'
        '"serverPort":${AppConstants.defaultPort},'
        '"deviceId":"${localDevice?.id ?? ""}",'
        '"deviceName":"${localDevice?.name ?? Platform.localHostname}"'
        '}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final locale = widget.locale;

    return Scaffold(
      backgroundColor: isDark ? AppColors.darkBg : Colors.grey[50],
      appBar: AppBar(
        title: Text(AppLocalizations.get('qrHotspot', locale)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildBody(isDark, locale),
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, String locale) {
    switch (_state) {
      case _HotspotState.checking:
      case _HotspotState.starting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              AppLocalizations.get('hotspotStarting', locale),
              style: TextStyle(
                fontSize: 16,
                color: isDark ? AppColors.textSecondary : Colors.grey[600],
              ),
            ),
          ],
        );

      case _HotspotState.ready:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // QR Code
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrImageView(
                data: _buildQrData(),
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),

            // WiFi info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? AppColors.glassBorder : Colors.grey[200]!,
                ),
              ),
              child: Column(
                children: [
                  _infoRow(Icons.wifi_rounded, 'SSID',
                      _hotspotInfo!.ssid, isDark),
                  const Divider(height: 16),
                  _infoRow(Icons.lock_rounded, 'Password',
                      _hotspotInfo!.password, isDark),
                  const Divider(height: 16),
                  _infoRow(Icons.router_rounded, 'IP',
                      _hotspotInfo!.ip, isDark),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Instructions
            Text(
              AppLocalizations.get('hotspotReady', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? AppColors.textSecondary : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.hourglass_top_rounded,
                    size: 16, color: Colors.orangeAccent),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.get('hotspotWaitingPeer', locale),
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.orangeAccent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        );

      case _HotspotState.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 64, color: Colors.red[300]),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppColors.textSecondary : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                setState(() => _state = _HotspotState.checking);
                _initHotspot();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(AppLocalizations.get('retry', locale)),
            ),
          ],
        );

      case _HotspotState.unsupported:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.get('hotspotNotSupported', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? AppColors.textPrimary : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.get('hotspotUseOtherDevice', locale),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? AppColors.textSecondary : Colors.grey[600],
              ),
            ),
          ],
        );
    }
  }

  Widget _infoRow(IconData icon, String label, String value, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 20,
            color: isDark ? AppColors.textSecondary : Colors.grey[600]),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppColors.textSecondary : Colors.grey[600],
            )),
        const Spacer(),
        SelectableText(
          value,
          style: TextStyle(
            fontFamily: 'Courier',
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: isDark ? AppColors.textPrimary : Colors.black87,
          ),
        ),
      ],
    );
  }
}
