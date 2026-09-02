import 'dart:ui';

import 'package:anyware/widgets/tv_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collapsed sidebar expands from its own toggle', (tester) async {
    var collapsed = true;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Align(
            alignment: Alignment.centerLeft,
            child: TvSidebar(
              selectedIndex: 0,
              onIndexChanged: (_) {},
              locale: 'tr',
              isCollapsed: collapsed,
              onToggleCollapse: () {
                setState(() => collapsed = !collapsed);
              },
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(TvSidebar)).width, 76);
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(TvSidebar)).width, 228);
    expect(find.text('Cihazlar'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
  });

  testWidgets('collapsed navigation icons expose fast hover labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.centerLeft,
          child: TvSidebar(
            selectedIndex: 0,
            onIndexChanged: (_) {},
            locale: 'tr',
            isCollapsed: true,
            onToggleCollapse: () {},
          ),
        ),
      ),
    );

    expect(find.text('Cihazlar'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.dashboard_rounded)));
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('Cihazlar'), findsOneWidget);
  });
}
