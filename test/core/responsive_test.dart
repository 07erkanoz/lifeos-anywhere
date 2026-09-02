import 'package:anyware/core/responsive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('classifies available width at shared breakpoints', (tester) async {
    Future<AppWindowClass> windowClassAt(double width) async {
      late AppWindowClass result;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(width, 700)),
            child: Builder(
              builder: (context) {
                result = context.windowClass;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return result;
    }

    expect(await windowClassAt(599), AppWindowClass.compact);
    expect(await windowClassAt(600), AppWindowClass.medium);
    expect(await windowClassAt(899), AppWindowClass.medium);
    expect(await windowClassAt(900), AppWindowClass.expanded);
  });

  testWidgets('removes motion when the platform requests reduced animations',
      (tester) async {
    late Duration result;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              result = context.motionDuration(AppMotion.emphasized);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(result, Duration.zero);
  });
}
