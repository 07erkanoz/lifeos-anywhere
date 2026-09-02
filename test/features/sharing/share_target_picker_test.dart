import 'package:anyware/features/discovery/domain/device.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/sharing/presentation/share_target_picker.dart';
import 'package:anyware/i18n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final device = Device(
    id: 'device-1',
    name: 'Salon bilgisayarı için uzun cihaz adı',
    ip: '192.168.1.42',
    port: 53317,
    platform: 'windows',
    version: '1.0.0',
    lastSeen: DateTime(2026),
  );
  final account = SyncAccount(
    id: 'account-1',
    name: 'Kişisel Google Drive hesabı',
    providerType: SyncProviderType.gdrive,
    createdAt: DateTime(2026),
    email: 'uzunhesapadi@example.com',
  );

  Future<void> pumpLauncher(
    WidgetTester tester, {
    required double width,
    double textScale = 1,
    String locale = 'tr',
    ValueChanged<ShareQueueResult?>? onResult,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Directionality(
          textDirection: AppLocalizations.textDirectionFor(locale),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  final result = await showShareTargetPicker(
                    context: context,
                    devices: [device],
                    accounts: [account],
                    filePaths: const ['/tmp/uzun-dosya-adi.pdf'],
                    locale: locale,
                  );
                  onResult?.call(result);
                },
                child: const Text('Paylaş'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('uses an accessible bottom sheet on compact screens', (
    tester,
  ) async {
    await pumpLauncher(tester, width: 360, textScale: 2);
    await tester.tap(find.text('Paylaş'));
    await tester.pumpAndSettle();

    expect(find.text('Göndermek için cihaz seçin'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('uzun-dosya-adi.pdf'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('uzun-dosya-adi.pdf'), findsOneWidget);
    expect(find.text('Cihazlar · 1'), findsOneWidget);
    expect(find.text(device.name), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.text(account.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returns the edited queue and selected target', (tester) async {
    ShareQueueResult? submitted;
    await pumpLauncher(
      tester,
      width: 720,
      onResult: (result) => submitted = result,
    );
    await tester.tap(find.text('Paylaş'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(device.name));
    await tester.pump();
    await tester.tap(find.text('Dosyaları Gönder'));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.target, isA<DeviceShareTarget>());
    expect(submitted!.filePaths, ['/tmp/uzun-dosya-adi.pdf']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('share_queue_recent_targets')?.first,
      'device:device-1',
    );
  });

  testWidgets('removing every file disables sending', (tester) async {
    await pumpLauncher(tester, width: 720);
    await tester.tap(find.text('Paylaş'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('0 dosya'), findsOneWidget);
    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Dosyaları Gönder'),
    );
    expect(sendButton.onPressed, isNull);
  });

  testWidgets('uses a constrained dialog on desktop widths', (tester) async {
    await pumpLauncher(tester, width: 720);
    await tester.tap(find.text('Paylaş'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(device.name), findsOneWidget);
    expect(find.text(account.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows recent targets as desktop quick choices', (tester) async {
    SharedPreferences.setMockInitialValues({
      'share_queue_recent_targets': ['device:device-1'],
    });
    await pumpLauncher(tester, width: 720);
    await tester.tap(find.text('Paylaş'));
    await tester.pumpAndSettle();

    expect(find.text('Son kullanılan hedefler · 1'), findsOneWidget);
    expect(find.text(device.name), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys select a target without a pointer', (tester) async {
    ShareQueueResult? submitted;
    await pumpLauncher(
      tester,
      width: 720,
      onResult: (result) => submitted = result,
    );
    await tester.tap(find.text('Paylaş'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final deviceTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text(device.name),
        matching: find.byType(ListTile),
      ),
    );
    expect(deviceTile.selected, isTrue);

    await tester.tap(find.text('Dosyaları Gönder'));
    await tester.pumpAndSettle();
    expect(submitted?.target, isA<DeviceShareTarget>());
  });

  for (final locale in ['de', 'ar']) {
    testWidgets('does not overflow for $locale localization', (tester) async {
      await pumpLauncher(tester, width: 360, textScale: 1.3, locale: locale);
      await tester.tap(find.text('Paylaş'));
      await tester.pumpAndSettle();

      expect(find.text(device.name), findsOneWidget);
      expect(find.text(account.name), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
