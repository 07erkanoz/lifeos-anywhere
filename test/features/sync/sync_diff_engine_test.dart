import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/sync/data/sync_diff_engine.dart';
import 'package:anyware/features/sync/domain/sync_manifest.dart';
import 'package:anyware/features/sync/domain/sync_state.dart';

final _t0 = DateTime.utc(2026, 1, 1, 12);
final _t1 = DateTime.utc(2026, 1, 2, 12);
final _t2 = DateTime.utc(2026, 1, 3, 12);

SyncManifestEntry e(String path, {int size = 10, DateTime? at, String? hash}) =>
    SyncManifestEntry(
        relativePath: path, size: size, lastModified: at ?? _t0, hash: hash);

SyncManifest m(List<SyncManifestEntry> entries) => SyncManifest(
    deviceId: 'd', basePath: '/', createdAt: _t0, entries: entries);

SyncActionType? only(SyncPlan plan, String path) {
  final a = plan.actions.where((a) => a.relativePath == path).toList();
  expect(a.length, lessThanOrEqualTo(1));
  return a.isEmpty ? null : a.single.type;
}

void main() {
  group('one-sided change', () {
    test('local edit is sent', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt', size: 11, at: _t1)]),
        remote: m([e('a.txt')]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(only(plan, 'a.txt'), SyncActionType.sendToRemote);
    });

    test('remote edit is pulled', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt')]),
        remote: m([e('a.txt', size: 12, at: _t1)]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(only(plan, 'a.txt'), SyncActionType.pullFromRemote);
    });

    test('unchanged files produce no action', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt')]),
        remote: m([e('a.txt')]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(plan.isEmpty, isTrue);
    });

    test('local delete of an untouched file is mirrored', () {
      final plan = computeSyncPlan(
        local: m([]),
        remote: m([e('a.txt')]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(only(plan, 'a.txt'), SyncActionType.deleteRemote);
    });

    test('remote delete of an untouched file is mirrored', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt')]),
        remote: m([]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(only(plan, 'a.txt'), SyncActionType.deleteLocal);
    });

    test('mirrorDeletions=false never deletes', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt')]),
        remote: m([e('b.txt')]),
        previousLocal: m([e('a.txt'), e('b.txt')]),
        previousRemote: m([e('a.txt'), e('b.txt')]),
        mirrorDeletions: false,
      );
      expect(plan.localDeletes, isEmpty);
      expect(plan.remoteDeletes, isEmpty);
      expect(only(plan, 'a.txt'), SyncActionType.sendToRemote);
      expect(only(plan, 'b.txt'), SyncActionType.pullFromRemote);
    });
  });

  group('both changed', () {
    final prev = m([e('a.txt')]);
    SyncPlan run(ConflictStrategy s, {DateTime? localAt, DateTime? remoteAt}) =>
        computeSyncPlan(
          local: m([e('a.txt', size: 20, at: localAt ?? _t2)]),
          remote: m([e('a.txt', size: 30, at: remoteAt ?? _t1)]),
          previousLocal: prev,
          previousRemote: prev,
          conflictStrategy: s,
        );

    test('newerWins: newer local is sent', () {
      expect(only(run(ConflictStrategy.newerWins), 'a.txt'),
          SyncActionType.sendToRemote);
    });

    test('newerWins: newer remote is pulled', () {
      expect(
          only(run(ConflictStrategy.newerWins, localAt: _t1, remoteAt: _t2),
              'a.txt'),
          SyncActionType.pullFromRemote);
    });

    test('keepBoth yields a conflict action carrying both versions', () {
      final plan = run(ConflictStrategy.keepBoth);
      expect(only(plan, 'a.txt'), SyncActionType.conflict);
      final a = plan.conflicts.single;
      expect(a.localEntry!.size, 20);
      expect(a.remoteEntry!.size, 30);
    });

    test('askUser yields a conflict action', () {
      expect(only(run(ConflictStrategy.askUser), 'a.txt'),
          SyncActionType.conflict);
    });

    test('keepBoth conflict copy name', () {
      final when = DateTime(2026, 3, 4, 5, 6);
      expect(conflictCopyPath('docs/report.pdf', 'My NAS', when),
          'docs/report (conflict My NAS 2026-03-04 0506).pdf');
      expect(conflictCopyPath('README', 'srv/x', when),
          'README (conflict srv_x 2026-03-04 0506)');
      expect(conflictCopyPath('.bashrc', 'a', when),
          '.bashrc (conflict a 2026-03-04 0506)');
    });
  });

  group('delete vs edit', () {
    test('remote edit beats local delete (file restored locally)', () {
      final plan = computeSyncPlan(
        local: m([]),
        remote: m([e('a.txt', size: 99, at: _t1)]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(only(plan, 'a.txt'), SyncActionType.pullFromRemote);
    });

    test('local edit beats remote delete (file restored remotely)', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt', size: 99, at: _t1)]),
        remote: m([]),
        previousLocal: m([e('a.txt')]),
        previousRemote: m([e('a.txt')]),
      );
      expect(only(plan, 'a.txt'), SyncActionType.sendToRemote);
    });
  });

  group('first sync without base', () {
    test('files only on one side are copied, nothing deleted', () {
      final plan = computeSyncPlan(
        local: m([e('l.txt')]),
        remote: m([e('r.txt')]),
      );
      expect(only(plan, 'l.txt'), SyncActionType.sendToRemote);
      expect(only(plan, 'r.txt'), SyncActionType.pullFromRemote);
      expect(plan.localDeletes, isEmpty);
      expect(plan.remoteDeletes, isEmpty);
    });

    test('identical files on both sides need nothing', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt', hash: 'a' * 64)]),
        remote: m([e('a.txt', hash: 'a' * 64, at: _t1)]),
      );
      expect(plan.isEmpty, isTrue);
    });

    test('differing files on both sides are a conflict (keepBoth)', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt', size: 1)]),
        remote: m([e('a.txt', size: 2)]),
        conflictStrategy: ConflictStrategy.keepBoth,
      );
      expect(only(plan, 'a.txt'), SyncActionType.conflict);
    });
  });

  group('comparison', () {
    test('unknown remote mtime compares by size only', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt', at: _t2)]),
        remote: m([e('a.txt', at: kUnknownMtime)]),
        previousLocal: m([e('a.txt', at: _t2)]),
        previousRemote: m([e('a.txt', at: kUnknownMtime)]),
      );
      expect(plan.isEmpty, isTrue);
    });

    test('hashes of different algorithms are not compared', () {
      // Local SHA-256 vs Drive MD5: same size + mtime means equal.
      expect(
          entriesEqual(e('a', hash: 'a' * 64), e('a', hash: 'b' * 32)), isTrue);
      expect(
          entriesEqual(e('a', hash: 'a' * 64), e('a', hash: 'b' * 64)), isFalse);
    });

    test('temp files are ignored', () {
      final plan = computeSyncPlan(
        local: m([e('a.txt.sync_tmp'), e('b.sync_dl')]),
        remote: m([e('c.txt.sync_tmp.meta'), e('d.sync_bak')]),
      );
      expect(plan.isEmpty, isTrue);
    });

    test('unknown (unreadable) local paths produce no actions', () {
      final plan = computeSyncPlan(
        local: m([e('ok.txt')]),
        remote: m([e('ok.txt'), e('locked/x.txt'), e('locked/y/z.txt')]),
        previousLocal: m([e('ok.txt'), e('locked/x.txt'), e('locked/y/z.txt')]),
        previousRemote:
            m([e('ok.txt'), e('locked/x.txt'), e('locked/y/z.txt')]),
        localUnknownPaths: ['locked'],
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('empty-scan / mass-deletion guard', () {
    final many = [for (var i = 0; i < 50; i++) e('f$i.txt')];

    test('suddenly empty source would delete everything → refused', () {
      final plan = computeSyncPlan(
        local: m([]),
        remote: m(many),
        previousLocal: m(many),
        previousRemote: m(many),
      );
      expect(plan.remoteDeletes.length, 50);
      expect(
          massDeletionReason(
              plan: plan, previousLocal: m(many), previousRemote: m(many)),
          isNotNull);
    });

    test('empty remote listing would delete all local → refused', () {
      final plan = computeSyncPlan(
        local: m(many),
        remote: m([]),
        previousLocal: m(many),
        previousRemote: m(many),
      );
      expect(plan.localDeletes.length, 50);
      expect(
          massDeletionReason(
              plan: plan, previousLocal: m(many), previousRemote: m(many)),
          isNotNull);
    });

    test('more than half and more than 20 → refused', () {
      final local = many.sublist(0, 20); // 30 of 50 deleted
      final plan = computeSyncPlan(
        local: m(local),
        remote: m(many),
        previousLocal: m(many),
        previousRemote: m(many),
      );
      expect(plan.remoteDeletes.length, 30);
      expect(
          massDeletionReason(
              plan: plan, previousLocal: m(many), previousRemote: m(many)),
          isNotNull);
    });

    test('a few deletions are allowed', () {
      final local = many.sublist(0, 45);
      final plan = computeSyncPlan(
        local: m(local),
        remote: m(many),
        previousLocal: m(many),
        previousRemote: m(many),
      );
      expect(plan.remoteDeletes.length, 5);
      expect(
          massDeletionReason(
              plan: plan, previousLocal: m(many), previousRemote: m(many)),
          isNull);
    });
  });

  group('oneWay', () {
    void expectNoLocalChanges(SyncPlan plan) {
      for (final a in plan.actions) {
        expect(a.type, isNot(SyncActionType.pullFromRemote), reason: '$a');
        expect(a.type, isNot(SyncActionType.deleteLocal), reason: '$a');
        expect(a.type, isNot(SyncActionType.conflict), reason: '$a');
      }
    }

    test('never pulls, deletes locally or conflicts', () {
      final plan = computeSyncPlan(
        local: m([
          e('both-changed.txt', size: 2, at: _t2),
          e('remote-deleted.txt'),
          e('local-new.txt'),
        ]),
        remote: m([
          e('both-changed.txt', size: 3, at: _t1),
          e('remote-new.txt'),
          e('remote-edited.txt', size: 5, at: _t1),
        ]),
        previousLocal: m([e('both-changed.txt'), e('remote-deleted.txt')]),
        previousRemote: m([
          e('both-changed.txt'),
          e('remote-deleted.txt'),
          e('remote-edited.txt'),
        ]),
        direction: SyncDirection.oneWay,
        conflictStrategy: ConflictStrategy.keepBoth,
      );
      expectNoLocalChanges(plan);
      expect(only(plan, 'both-changed.txt'), SyncActionType.sendToRemote);
      expect(only(plan, 'remote-deleted.txt'), SyncActionType.sendToRemote);
      expect(only(plan, 'local-new.txt'), SyncActionType.sendToRemote);
      expect(only(plan, 'remote-new.txt'), isNull);
    });

    test('mirrors local deletes only when mirrorDeletions is set', () {
      SyncPlan run(bool mirror) => computeSyncPlan(
            local: m([]),
            remote: m([e('a.txt')]),
            previousLocal: m([e('a.txt')]),
            previousRemote: m([e('a.txt')]),
            direction: SyncDirection.oneWay,
            mirrorDeletions: mirror,
          );
      expect(only(run(true), 'a.txt'), SyncActionType.deleteRemote);
      expect(run(false).isEmpty, isTrue);
      expectNoLocalChanges(run(true));
    });
  });
}
