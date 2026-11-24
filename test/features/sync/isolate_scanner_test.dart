import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:anyware/features/sync/data/isolate_scanner.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('scanner_test_');
  });

  tearDown(() async {
    // Restore permissions so the temp tree can be removed.
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', root.path]);
    }
    root.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  test('lists nested files, skips sync temp files', () {
    write('a.txt', 'a');
    write('sub/b.txt', 'bb');
    write('sub/deep/c.txt', 'ccc');
    write('sub/c.txt.sync_tmp', 'partial');
    write('sub/c.txt.sync_tmp.meta', 'v1');
    write('x.sync_dl', 'staging');

    final r = scanDirectorySync(
        ScanParams(dirPath: root.path, hashThresholdBytes: 1024));
    final paths = r.entries.map((e) => e.relativePath).toSet();
    expect(paths, {'a.txt', 'sub/b.txt', 'sub/deep/c.txt'});
    expect(r.isPartial, isFalse);
    expect(r.entries.firstWhere((e) => e.relativePath == 'a.txt').hash,
        isNotNull);
  });

  test('unreadable subfolder is skipped and reported, rest is scanned', () {
    write('ok.txt', 'ok');
    write('other/fine.txt', 'fine');
    write('locked/secret.txt', 's');
    final locked = p.join(root.path, 'locked');
    Process.runSync('chmod', ['000', locked]);

    // Root can read anything; the scenario cannot be reproduced then.
    final canStillRead = () {
      try {
        Directory(locked).listSync();
        return true;
      } catch (_) {
        return false;
      }
    }();
    if (canStillRead) {
      markTestSkipped('running with permissions that bypass chmod 000');
      return;
    }

    final r = scanDirectorySync(ScanParams(dirPath: root.path));
    final paths = r.entries.map((e) => e.relativePath).toSet();
    expect(paths, {'ok.txt', 'other/fine.txt'});
    expect(r.skippedDirs, ['locked']);
    expect(r.isPartial, isTrue);
  }, skip: Platform.isWindows ? 'POSIX permissions only' : false);

  test('missing root throws instead of returning an empty manifest', () {
    expect(
      () => scanDirectorySync(
          ScanParams(dirPath: p.join(root.path, 'does-not-exist'))),
      throwsA(isA<ScanException>()),
    );
  });

  test('unreadable root throws instead of returning an empty manifest', () {
    write('a.txt', 'a');
    final dir = p.join(root.path, 'r');
    Directory(dir).createSync();
    File(p.join(dir, 'f.txt')).writeAsStringSync('f');
    Process.runSync('chmod', ['000', dir]);
    try {
      Directory(dir).listSync();
      markTestSkipped('running with permissions that bypass chmod 000');
      return;
    } catch (_) {}
    expect(() => scanDirectorySync(ScanParams(dirPath: dir)),
        throwsA(isA<ScanException>()));
  }, skip: Platform.isWindows ? 'POSIX permissions only' : false);
}
