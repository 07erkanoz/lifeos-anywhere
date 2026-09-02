import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anyware/features/sharing/data/dropped_file_expander.dart';

void main() {
  test(
    'expands folders recursively and de-duplicates direct file drops',
    () async {
      final root = await Directory.systemTemp.createTemp('lifeos_drop_test_');
      addTearDown(() => root.deleteSync(recursive: true));

      final nested = Directory('${root.path}/folder/nested')
        ..createSync(recursive: true);
      final first = File('${root.path}/folder/first.txt')
        ..writeAsStringSync('first');
      final second = File('${nested.path}/second.txt')
        ..writeAsStringSync('second');

      final files = await expandDroppedPaths([
        '${root.path}/folder',
        first.path,
        '/path/that/does/not/exist',
      ]);

      expect(files.toSet(), {first.path, second.path});
    },
  );
}
