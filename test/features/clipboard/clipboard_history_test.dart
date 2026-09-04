import 'package:anyware/features/clipboard/data/clipboard_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ClipboardEntry entry(
    int index, {
    String text = 'sample',
    String senderDeviceId = 'phone',
    DateTime? timestamp,
  }) {
    return ClipboardEntry(
      text: '$text-$index',
      senderName: 'Phone',
      senderDeviceId: senderDeviceId,
      timestamp: timestamp ?? DateTime(2026, 9, 4, 10, 0, index),
    );
  }

  test('persists clipboard history and restores newest first', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = ClipboardHistoryNotifier(prefs);

    notifier.addEntry(entry(1));
    notifier.addEntry(entry(2));
    await Future<void>.delayed(Duration.zero);

    final restored = ClipboardHistoryNotifier(prefs);
    expect(restored.state.map((item) => item.text), ['sample-2', 'sample-1']);

    notifier.dispose();
    restored.dispose();
  });

  test('keeps at most fifty clipboard entries', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = ClipboardHistoryNotifier(prefs);

    for (var index = 0; index < 55; index++) {
      notifier.addEntry(entry(index));
    }

    expect(notifier.state, hasLength(50));
    expect(notifier.state.first.text, 'sample-54');
    expect(notifier.state.last.text, 'sample-5');
    notifier.dispose();
  });

  test(
    'filters accidental repeat from same sender within ten seconds',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = ClipboardHistoryNotifier(prefs);
      final firstTime = DateTime(2026, 9, 4, 10);

      notifier.addEntry(entry(0, text: 'same', timestamp: firstTime));
      notifier.addEntry(
        entry(
          0,
          text: 'same',
          timestamp: firstTime.add(const Duration(seconds: 7)),
        ),
      );
      notifier.addEntry(
        entry(
          0,
          text: 'same',
          senderDeviceId: 'tablet',
          timestamp: firstTime.add(const Duration(seconds: 8)),
        ),
      );

      expect(notifier.state, hasLength(2));
      expect(notifier.state.first.senderDeviceId, 'tablet');
      notifier.dispose();
    },
  );
}
