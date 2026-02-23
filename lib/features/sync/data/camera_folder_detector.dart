import 'dart:io';

import 'package:anyware/core/logger.dart';

// Detects common camera/photo directories per platform.
//
// Used by the photo/video sync mode to auto-suggest the source folder.
class CameraFolderDetector {
  CameraFolderDetector._();

  static final _log = AppLogger('CameraFolderDetector');

  /// Returns the most likely camera folder for the current platform,
  /// or `null` if none is found.
  static String? detect() {
    final candidates = getCandidates();
    for (final path in candidates) {
      if (Directory(path).existsSync()) {
        _log.info('Detected camera folder: $path');
        return path;
      }
    }
    _log.info('No camera folder detected');
    return null;
  }

  /// Returns a list of all candidate camera folder paths for the current
  /// platform, ordered from most to least likely.
  static List<String> getCandidates() {
    if (Platform.isAndroid) {
      return _androidCandidates();
    } else if (Platform.isIOS) {
      return _iosCandidates();
    } else if (Platform.isWindows) {
      return _windowsCandidates();
    } else if (Platform.isMacOS) {
      return _macOsCandidates();
    } else if (Platform.isLinux) {
      return _linuxCandidates();
    }
    return [];
  }

  /// Returns a user-friendly description of what the photo sync source
  /// folder typically is on this platform.
  static String get platformHint {
    if (Platform.isAndroid) return 'DCIM/Camera';
    if (Platform.isIOS) return 'Photo Library';
    if (Platform.isWindows) return 'Pictures / Camera Roll';
    if (Platform.isMacOS) return '~/Pictures';
    if (Platform.isLinux) return '~/Pictures';
    return 'Pictures';
  }

  // ─── Android ────────────────────────────────────────────────────

  static List<String> _androidCandidates() {
    return [
      '/storage/emulated/0/DCIM/Camera',
      '/storage/emulated/0/DCIM',
      '/sdcard/DCIM/Camera',
      '/sdcard/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Pictures/Screenshots',
    ];
  }

  // ─── iOS ────────────────────────────────────────────────────────

  static List<String> _iosCandidates() {
    // On iOS, direct file system access to the photo library is
    // limited. These paths are used when the app has appropriate
    // file access through the documents picker or share extension.
    final home = Platform.environment['HOME'] ?? '';
    return [
      '$home/Documents/Photos',
      '$home/Documents/DCIM',
      '$home/Documents',
    ];
  }

  // ─── Windows ────────────────────────────────────────────────────

  static List<String> _windowsCandidates() {
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    if (userProfile.isEmpty) return [];
    return [
      '$userProfile\\Pictures\\Camera Roll',
      '$userProfile\\Pictures\\Screenshots',
      '$userProfile\\Pictures',
      '$userProfile\\OneDrive\\Pictures\\Camera Roll',
      '$userProfile\\OneDrive\\Pictures',
    ];
  }

  // ─── macOS ──────────────────────────────────────────────────────

  static List<String> _macOsCandidates() {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return [];
    return [
      '$home/Pictures/Photos Library.photoslibrary',
      '$home/Pictures',
      '$home/Desktop',
    ];
  }

  // ─── Linux ──────────────────────────────────────────────────────

  static List<String> _linuxCandidates() {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return [];
    return [
      '$home/Pictures',
      '$home/Photos',
      '$home/DCIM',
    ];
  }

  /// Returns a list of well-known image/video extensions for filtering.
  static const photoVideoExtensions = [
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
    '.heic', '.heif',
    '.mp4', '.mov', '.avi', '.mkv', '.3gp', '.wmv',
    '.raw', '.cr2', '.nef', '.arw', '.dng',
  ];

  /// Returns `true` if the given file path looks like a photo or video.
  static bool isPhotoOrVideo(String filePath) {
    final lower = filePath.toLowerCase();
    return photoVideoExtensions.any((ext) => lower.endsWith(ext));
  }
}
