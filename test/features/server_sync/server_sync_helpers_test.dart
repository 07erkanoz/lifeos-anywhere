import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/server_sync/data/server_sync_service.dart';
import 'package:anyware/features/server_sync/domain/sync_account.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

void main() {
  group('path traversal', () {
    test('rejects escaping and absolute paths', () {
      for (final bad in [
        '../x',
        'a/../../x',
        '/etc/passwd',
        r'..\x',
        'C:/x',
        'a//b',
        './a',
        '',
      ]) {
        expect(safeLocalPath('/home/u/sync', bad), isNull, reason: bad);
      }
    });

    test('accepts normal relative paths', () {
      expect(safeLocalPath('/home/u/sync', 'a/b.txt'), '/home/u/sync/a/b.txt');
      expect(safeLocalPath('/home/u/sync', '..hidden'),
          '/home/u/sync/..hidden');
    });
  });

  group('schedule due since last run', () {
    const daily = SyncSchedule(
        type: ScheduleType.daily, time: TimeOfDay(hour: 9, minute: 0));

    test('late tick still runs today', () {
      final now = DateTime(2026, 5, 10, 9, 3); // tick 3 minutes late
      expect(
          isScheduleDue(daily,
              since: DateTime(2026, 5, 9, 9, 0, 30), now: now),
          isTrue);
    });

    test('not due again after it ran', () {
      final now = DateTime(2026, 5, 10, 15, 0);
      expect(
          isScheduleDue(daily,
              since: DateTime(2026, 5, 10, 9, 1), now: now),
          isFalse);
    });

    test('not due before the time of day', () {
      final now = DateTime(2026, 5, 10, 8, 59);
      expect(
          isScheduleDue(daily,
              since: DateTime(2026, 5, 9, 9, 1), now: now),
          isFalse);
    });

    test('weekly honours weekdays and catches up a missed day', () {
      // 2026-05-11 is a Monday.
      const weekly = SyncSchedule(
          type: ScheduleType.weekly,
          time: TimeOfDay(hour: 22, minute: 0),
          weekDays: [1]);
      expect(
          isScheduleDue(weekly,
              since: DateTime(2026, 5, 5), now: DateTime(2026, 5, 12, 8)),
          isTrue); // app was closed Monday night
      expect(
          isScheduleDue(weekly,
              since: DateTime(2026, 5, 11, 22, 5),
              now: DateTime(2026, 5, 14, 23)),
          isFalse);
    });
  });

  group('account secrets', () {
    test('toJson leaves credentials out by default', () {
      final a = SyncAccount(
        id: '1',
        name: 'n',
        providerType: SyncProviderType.sftp,
        createdAt: DateTime(2026),
        password: 'pw',
        privateKey: 'key',
        passphrase: 'pp',
      );
      final json = a.toJson();
      expect(json.containsKey('password'), isFalse);
      expect(json.containsKey('privateKey'), isFalse);
      expect(json.containsKey('passphrase'), isFalse);
      final back = SyncAccount.fromJson(json).withSecrets(a.secrets);
      expect(back.password, 'pw');
      expect(back.privateKey, 'key');
      expect(back.passphrase, 'pp');
    });
  });
}
