import 'package:anyware/widgets/desktop_content_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    required double width,
    required double textScale,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 700),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 700,
                child: DesktopContentShell(
                  title: 'Uzun bir masaüstü sayfa başlığı',
                  subtitle: 'Pencere küçüldüğünde güvenli biçimde satıra geçer',
                  actions: const [
                    FilledButton(
                      onPressed: null,
                      child: Text('Tamamlananları temizle'),
                    ),
                  ],
                  child: ListView(
                    children: const [Text('Responsive içerik')],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final width in [320.0, 560.0, 720.0, 1024.0]) {
    testWidgets('does not overflow at ${width.toInt()} px', (tester) async {
      await pumpShell(tester, width: width, textScale: 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('supports large accessibility text on a compact window',
      (tester) async {
    await pumpShell(tester, width: 320, textScale: 2);
    expect(tester.takeException(), isNull);
  });
}
