import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as native_picker;

/// Platform-aware file & folder picker.
///
/// On Linux, [file_picker] shells out to zenity / kdialog which may not be
/// installed — causing dialogs to silently fail.  This helper transparently
/// uses [file_selector] (native GTK) on Linux and keeps [file_picker] for
/// every other platform where it works reliably.
class FilePickerHelper {
  // ── Directory picker ──────────────────────────────────────────────────────

  /// Pick a single directory.  Returns `null` when the user cancels.
  static Future<String?> getDirectoryPath() async {
    if (Platform.isLinux) {
      return native_picker.getDirectoryPath();
    }
    return FilePicker.platform.getDirectoryPath();
  }

  // ── File picker ───────────────────────────────────────────────────────────

  /// Pick one or more files.  Returns `null` when the user cancels.
  ///
  /// The result is always a [FilePickerResult] so callers don't need to
  /// change their existing code.
  static Future<FilePickerResult?> pickFiles({
    bool allowMultiple = false,
    FileType type = FileType.any,
  }) async {
    if (Platform.isLinux) {
      return _pickFilesLinux(allowMultiple: allowMultiple);
    }
    return FilePicker.platform.pickFiles(
      allowMultiple: allowMultiple,
      type: type,
    );
  }

  /// Linux-only: use [file_selector] and wrap the result in
  /// [FilePickerResult] so the rest of the app stays unchanged.
  static Future<FilePickerResult?> _pickFilesLinux({
    required bool allowMultiple,
  }) async {
    final List<native_picker.XFile> xfiles;

    if (allowMultiple) {
      xfiles = await native_picker.openFiles();
    } else {
      final single = await native_picker.openFile();
      xfiles = single == null ? [] : [single];
    }

    if (xfiles.isEmpty) return null;

    final platformFiles = <PlatformFile>[];
    for (final xf in xfiles) {
      final stat = await File(xf.path).stat();
      platformFiles.add(PlatformFile(
        name: xf.name,
        path: xf.path,
        size: stat.size,
      ));
    }

    return FilePickerResult(platformFiles);
  }
}
