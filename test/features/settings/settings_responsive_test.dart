import 'dart:convert';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/features/settings/domain/settings.dart';
import 'package:anyware/features/settings/presentation/settings_screen.dart';
import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpSettings(
    WidgetTester tester, {
    required double width,
    required bool desktopShell,
  }) async {
    final settings = AppSettings.defaults().copyWith(
      deviceName: 'Test cihazı',
      downloadPath: '/tmp',
      locale: 'tr',
    );
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(settings.toJson()),
    });
    final prefs = await SharedPreferences.getInstance();
    final device = Device(
      id: 'local',
      name: 'Test cihazı',
      ip: '192.168.1.10',
      port: 53317,
      platform: 'android',
      version: '1.0.0',
      lastSeen: DateTime(2026),
    );

    await tester.binding.setSurfaceSize(Size(width, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          localDeviceProvider.overrideWith((ref) async => device),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: desktopShell
              ? const Scaffold(
                  body: DesktopShellScope(child: SettingsScreen()),
                )
              : const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('uses a dropdown theme selector on compact screens',
      (tester) async {
    await pumpSettings(tester, width: 320, desktopShell: false);
    await tester.scrollUntilVisible(find.text('Sistem'), 250);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(DropdownButton<String>, 'Sistem'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the segmented theme selector on wide desktop content',
      (tester) async {
    await pumpSettings(tester, width: 720, desktopShell: true);
    await tester.scrollUntilVisible(find.text('Sistem'), 250);
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
