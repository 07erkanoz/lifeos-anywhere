import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';

import 'package:anyware/core/logger.dart';

const _platform = MethodChannel('com.lifeos.anyware/platform');

/// Opens [path] with the system's default app. Android: a native intent (the
/// open_file package fails silently on modern Android); elsewhere open_file.
Future<bool> openAnyFile(String path) async {
  try {
    if (Platform.isAndroid) {
      return await _platform.invokeMethod<bool>('openFile', {
            'path': path,
            'mimeType': lookupMimeType(path) ?? '*/*',
          }) ??
          false;
    }
    final result = await OpenFile.open(path, type: lookupMimeType(path) ?? 'application/octet-stream');
    return result.type == ResultType.done;
  } catch (e) {
    AppLogger('OpenFile').warning('Failed to open $path: $e');
    return false;
  }
}

/// Shows the folder holding [path] in the system's file manager (the file
/// selected where the platform can).
Future<bool> showInFolder(String path) async {
  try {
    if (Platform.isAndroid) {
      return await _platform.invokeMethod<bool>('openFolder', {'path': path}) ?? false;
    }
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      // the file selected where the desktop offers it (KDE, GNOME), else its folder
      final r = await Process.run('dbus-send', [
        '--session', '--print-reply', '--dest=org.freedesktop.FileManager1',
        '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1.ShowItems',
        'array:string:${Uri.file(path)}', 'string:',
      ]);
      if (r.exitCode != 0) await Process.run('xdg-open', [File(path).parent.path]);
    }
    return true;
  } catch (e) {
    AppLogger('OpenFile').warning('Failed to show $path: $e');
    return false;
  }
}
