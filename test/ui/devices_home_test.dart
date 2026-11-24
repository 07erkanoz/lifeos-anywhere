import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/esitleme/data/esitleme_service.dart';
import 'package:anyware/features/esitleme/presentation/providers.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/ui/devices_home.dart';

void main() {
  for (final width in [360.0, 1000.0, 1400.0]) {
    testWidgets('devices with a conversation and synced folders (${width.toInt()}px)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = TrustStore(prefs);
      await store.trust(id: 'pc', name: 'Çok uzun adlı ofis bilgisayarı', platform: 'linux', token: 't', ip: '10.0.0.2', fingerprint: 'a' * 64);
      await store.trust(id: 'tel', name: 'Annemin telefonu', platform: 'android', token: 'u', ip: '10.0.0.3');
      final now = DateTime.now();
      tester.view
        ..physicalSize = Size(width, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          trustStoreProvider.overrideWith((ref) => store),
          localDeviceProvider.overrideWith((ref) async => Device(
              id: 'me', name: 'Nubia', ip: '10.0.0.9', port: 48739, platform: 'android', version: '1.1', lastSeen: now)),
          devicesProvider.overrideWith((ref) => Stream.value([
                Device(id: 'pc', name: 'pc', ip: '10.0.0.2', port: 48739, platform: 'linux', version: '1.1', lastSeen: now),
                Device(id: 'yeni', name: 'Toplantı-Odası', ip: '10.0.0.47', port: 48739, platform: 'linux', version: '1.1', lastSeen: now),
              ])),
          iletiProvider.overrideWith((ref) => IletiNotifier(initial: {
                'pc': [
                  IletiMessage(id: '1', device: 'pc', outgoing: false, time: now, text: 'Akşam eşitlenince bakarım ' * 4, status: IletiStatus.unread),
                ],
              })),
          syncedFoldersProvider.overrideWith((ref) => Stream.value([
                const SyncedFolder(id: 'lifeos-000000000001', path: '/storage/emulated/0/Belgeler', device: 'pc', label: 'Belgeler', state: 'eşitleniyor', needBytes: 5 << 20),
              ])),
        ],
        child: MaterialApp(theme: AppTheme.dark, home: const DevicesHome()),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('Toplantı-Odası'), findsOneWidget);
      if (width < 900) {
        await tester.tap(find.text('Annemin telefonu'));
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
      } else {
        expect(find.byType(DeviceDetail), width >= 1250 ? findsOneWidget : findsNothing);
        if (width >= 1250) {
          await tester.dragUntilVisible(find.text('Belgeler'), find.byType(ListView).last, const Offset(0, -200));
        }
      }
    });
  }
}
