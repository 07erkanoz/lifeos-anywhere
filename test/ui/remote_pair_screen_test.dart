import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:anyware/core/theme.dart';
import 'package:anyware/features/settings/data/settings_repository.dart';
import 'package:anyware/ui/remote_pair_screen.dart';

void main() {
  for (final width in [320.0, 412.0, 1000.0]) {
    testWidgets('remote pairing screen fits (${width.toInt()}px)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view
        ..physicalSize = Size(width, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(theme: AppTheme.dark, home: const RemotePairScreen()),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('I have a code'), findsOneWidget);
    });
  }
}
