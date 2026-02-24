import 'dart:io' show Platform;

/// Cloud provider API credentials.
///
/// Values are injected at build time via `--dart-define-from-file`:
/// ```
/// flutter run --dart-define-from-file=.env
/// ```
///
/// Never hardcode credentials in source code.
class CloudCredentials {
  CloudCredentials._();

  // ── Google Drive (Desktop — Windows / macOS / Linux) ──
  static const googleClientId =
      String.fromEnvironment('GDRIVE_CLIENT_ID');
  static const googleClientSecret =
      String.fromEnvironment('GDRIVE_CLIENT_SECRET');

  // ── Google Drive (Android — SHA-1 auth, no secret needed) ──
  static const googleAndroidClientId =
      String.fromEnvironment('GDRIVE_ANDROID_CLIENT_ID');

  // ── Microsoft OneDrive ──
  static const msClientId =
      String.fromEnvironment('MS_CLIENT_ID');
  static const msClientSecret =
      String.fromEnvironment('MS_CLIENT_SECRET');

  // ── Google OAuth endpoints ──
  static const googleAuthUri =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const googleTokenUri =
      'https://oauth2.googleapis.com/token';
  static const googleDriveScope =
      'https://www.googleapis.com/auth/drive.file';

  // ── Microsoft OAuth endpoints ──
  static const msAuthUri =
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const msTokenUri =
      'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const msScopes = 'Files.ReadWrite User.Read offline_access';

  /// The Client ID to use for the current platform.
  ///
  /// Android → [googleAndroidClientId] (SHA-1 verified, no secret).
  /// Desktop → [googleClientId] (uses client secret).
  static String get googleActiveClientId =>
      Platform.isAndroid ? googleAndroidClientId : googleClientId;

  /// Whether Google Drive credentials are configured for the current platform.
  ///
  /// Android only needs a Client ID (SHA-1 handles verification).
  /// Desktop needs both Client ID and Client Secret.
  static bool get hasGoogleCredentials {
    if (Platform.isAndroid) {
      return googleAndroidClientId.isNotEmpty;
    }
    return googleClientId.isNotEmpty && googleClientSecret.isNotEmpty;
  }

  /// Whether OneDrive credentials are configured.
  static bool get hasMsCredentials =>
      msClientId.isNotEmpty && msClientSecret.isNotEmpty;
}
