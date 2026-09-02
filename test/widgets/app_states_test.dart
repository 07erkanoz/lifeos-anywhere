import 'package:anyware/core/theme.dart';
import 'package:anyware/widgets/app_states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty state remains usable in a compact high-text layout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 420),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: AppEmptyState(
              icon: Icons.cloud_outlined,
              title: 'Henüz bağlantı yapılandırılmadı',
              description:
                  'Başlamak için yeni bir sunucu veya bulut hesabı ekleyin.',
              actionLabel: 'Yeni bağlantı ekle',
              actionIcon: Icons.add_rounded,
              onAction: () {},
              secondaryActionLabel: 'Daha fazla bilgi',
              onSecondaryAction: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Yeni bağlantı ekle'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('section header protects long localized titles from overflow',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: AppSectionHeader(
                  icon: Icons.sync_rounded,
                  title: 'Çok uzun senkronizasyon işlemleri başlığı',
                  count: '128',
                  actions: const [IconButton(onPressed: null, icon: Icon(Icons.add))],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('drop overlay wraps its message on a narrow desktop window',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(
            body: SizedBox(
              width: 280,
              height: 360,
              child: AppDropOverlay(
                label: 'Dosyaları göndermek için bu alana bırakın',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
