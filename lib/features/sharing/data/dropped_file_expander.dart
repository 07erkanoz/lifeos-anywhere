import 'dart:io';

import 'package:anyware/core/logger.dart';

final _log = AppLogger('DroppedFiles');

/// Converts desktop drop paths into a de-duplicated list of real files.
/// Directories are expanded recursively while symbolic links are ignored.
Future<List<String>> expandDroppedPaths(Iterable<String> paths) async {
  final files = <String>{};
  for (final path in paths) {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        files.add(path);
      } else if (type == FileSystemEntityType.directory) {
        await for (final entity in Directory(
          path,
        ).list(recursive: true, followLinks: false)) {
          if (entity is File) files.add(entity.path);
        }
      }
    } on FileSystemException catch (error) {
      _log.warning('Could not read dropped path $path: $error');
    }
  }
  return files.toList(growable: false);
}
