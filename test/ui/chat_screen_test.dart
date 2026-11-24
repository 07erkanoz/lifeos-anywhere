import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/discovery/presentation/providers.dart';
import 'package:anyware/features/ileti/domain/ileti_message.dart';
import 'package:anyware/features/ileti/presentation/providers.dart';
import 'package:anyware/features/pairing/data/trust_store.dart';
import 'package:anyware/features/pairing/presentation/providers.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/ui/chat_screen.dart';

void main() {
  for (final (width, dark) in [(390.0, true), (390.0, false), (900.0, true)]) {
    testWidgets('chat draws text, files, states (${width.toInt()}px, ${dark ? 'dark' : 'light'})', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = TrustStore(prefs);
      await store.trust(id: 'pc', name: 'Ofis-PC', platform: 'linux', token: 't', ip: '192.168.1.31');
      final now = DateTime.now();
      final messages = [
        IletiMessage(id: '1', device: 'pc', outgoing: false, time: now.subtract(const Duration(days: 1)), text: 'Günaydın', status: IletiStatus.seen),
        IletiMessage(id: '2', device: 'pc', outgoing: true, time: now, text: 'Sunumu atıyorum, ' * 8, status: IletiStatus.read),
        IletiMessage(id: '3', device: 'pc', outgoing: true, time: now, fileName: 'Sunum – kasım.pptx', fileSize: 64 << 20, status: IletiStatus.sending, progress: 0.62),
        IletiMessage(id: '4', device: 'pc', outgoing: false, time: now, fileName: 'Teklif.pdf', fileSize: 2400000, text: 'son hâli', via: IletiVia.relay, status: IletiStatus.unread),
        IletiMessage(id: '5', device: 'pc', outgoing: true, time: now, text: 'gitmedi', status: IletiStatus.failed),
        IletiMessage(id: '6', device: 'pc', outgoing: true, time: now, text: 'internetten', via: IletiVia.internet, status: IletiStatus.pending),
      ];
      tester.view
        ..physicalSize = Size(width, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          trustStoreProvider.overrideWith((ref) => store),
          devicesProvider.overrideWith((ref) => Stream.value([
                Device(id: 'pc', name: 'Ofis-PC', ip: '192.168.1.31', port: 48739, platform: 'linux', version: '1.1', lastSeen: now),
              ])),
          iletiProvider.overrideWith((ref) => IletiNotifier(initial: {'pc': messages})),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const ChatScreen(deviceId: 'pc'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Günaydın'), findsOneWidget);
      expect(find.text('Sunum – kasım.pptx'), findsOneWidget);
      expect(find.textContaining('sunucu aktardı'), findsNothing); // English by default
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // the unread one was marked seen on opening
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      expect(container.read(iletiProvider)['pc']!.where((m) => m.status == IletiStatus.unread), isEmpty);
    });
  }
}
