import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;

import 'package:anyware/core/cloud_credentials.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/oauth_token.dart';
import 'package:anyware/features/server_sync/data/token_store.dart';

final _log = AppLogger('OAuthService');

/// Platform-aware OAuth 2.0 authentication service.
///
/// On mobile (Android/iOS) uses native AppAuth (in-app browser tab).
/// On desktop (Windows/macOS/Linux) uses a localhost loopback redirect.
class OAuthService {
  final TokenStore _tokenStore;
  final http.Client _http;

  OAuthService(this._tokenStore, [http.Client? client])
      : _http = client ?? http.Client();

  // ═══════════════════════════════════════════════════════════════════════════
  // Public API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Authenticate with Google and return an [OAuthToken].
  ///
  /// Opens the Google sign-in flow and stores the resulting token securely.
  Future<OAuthToken> authenticateGoogle(String accountId) async {
    _log.info('Starting Google OAuth for account $accountId');

    final OAuthToken token;
    if (_isMobile) {
      token = await _mobileGoogleAuth();
    } else {
      token = await _desktopGoogleAuth();
    }

    await _tokenStore.saveToken(accountId, token);
    return token;
  }

  /// Authenticate with Microsoft and return an [OAuthToken].
  ///
  /// Opens the Microsoft sign-in flow and stores the resulting token securely.
  Future<OAuthToken> authenticateMicrosoft(String accountId) async {
    _log.info('Starting Microsoft OAuth for account $accountId');

    final OAuthToken token;
    if (_isMobile) {
      token = await _mobileMsAuth();
    } else {
      token = await _desktopMsAuth();
    }

    await _tokenStore.saveToken(accountId, token);
    return token;
  }

  /// Get a valid (non-expired) token for the given [accountId].
  ///
  /// Automatically refreshes the token if it has expired.
  /// Returns `null` if no token exists or refresh fails.
  Future<OAuthToken?> getValidToken(String accountId) async {
    var token = await _tokenStore.loadToken(accountId);
    if (token == null) return null;

    if (token.isExpired && token.canRefresh) {
      try {
        token = await refreshToken(accountId, token);
      } catch (e) {
        _log.error('Token refresh failed for $accountId: $e');
        return null;
      }
    }

    return token.isExpired ? null : token;
  }

  /// Refresh an expired token and persist the new one.
  Future<OAuthToken> refreshToken(String accountId, OAuthToken expired) async {
    _log.info('Refreshing token for $accountId (provider: ${expired.provider})');

    if (!expired.canRefresh) {
      throw StateError('Token has no refresh token');
    }

    final OAuthToken newToken;
    switch (expired.provider) {
      case 'gdrive':
        newToken = await _refreshGoogleToken(expired);
        break;
      case 'onedrive':
        newToken = await _refreshMsToken(expired);
        break;
      default:
        throw ArgumentError('Unknown provider: ${expired.provider}');
    }

    await _tokenStore.saveToken(accountId, newToken);
    return newToken;
  }

  /// Revoke a token and delete it from secure storage.
  Future<void> revokeToken(String accountId) async {
    final token = await _tokenStore.loadToken(accountId);
    if (token != null) {
      try {
        if (token.provider == 'gdrive') {
          await _revokeGoogleToken(token);
        }
        // Microsoft tokens don't have a simple revocation endpoint.
      } catch (e) {
        _log.error('Token revocation failed: $e');
      }
    }
    await _tokenStore.deleteToken(accountId);
  }

  /// Get the email address associated with a Google account token.
  Future<String?> getGoogleEmail(OAuthToken token) async {
    try {
      final resp = await _http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
        headers: {'Authorization': 'Bearer ${token.accessToken}'},
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data['email'] as String?;
      }
    } catch (e) {
      _log.error('Failed to get Google email: $e');
    }
    return null;
  }

  /// Get the email address associated with a Microsoft account token.
  Future<String?> getMicrosoftEmail(OAuthToken token) async {
    try {
      final resp = await _http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me'),
        headers: {'Authorization': 'Bearer ${token.accessToken}'},
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['mail'] as String?) ??
            (data['userPrincipalName'] as String?);
      }
    } catch (e) {
      _log.error('Failed to get Microsoft email: $e');
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Mobile flows (AppAuth)
  // ═══════════════════════════════════════════════════════════════════════════

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<OAuthToken> _mobileGoogleAuth() async {
    const appAuth = FlutterAppAuth();
    final result = await appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        CloudCredentials.googleAndroidClientId,
        'com.lifeos.anyware://oauth2redirect',
        serviceConfiguration: const AuthorizationServiceConfiguration(
          authorizationEndpoint: CloudCredentials.googleAuthUri,
          tokenEndpoint: CloudCredentials.googleTokenUri,
        ),
        scopes: [CloudCredentials.googleDriveScope, 'email'],
        promptValues: ['consent'],
      ),
    );

    return OAuthToken(
      accessToken: result.accessToken!,
      refreshToken: result.refreshToken,
      expiresAt: result.accessTokenExpirationDateTime ??
          DateTime.now().add(const Duration(hours: 1)),
      provider: 'gdrive',
    );
  }

  Future<OAuthToken> _mobileMsAuth() async {
    const appAuth = FlutterAppAuth();
    final result = await appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        CloudCredentials.msClientId,
        'com.lifeos.anyware://oauth2redirect',
        serviceConfiguration: const AuthorizationServiceConfiguration(
          authorizationEndpoint: CloudCredentials.msAuthUri,
          tokenEndpoint: CloudCredentials.msTokenUri,
        ),
        scopes: CloudCredentials.msScopes.split(' '),
        promptValues: ['consent'],
      ),
    );

    return OAuthToken(
      accessToken: result.accessToken!,
      refreshToken: result.refreshToken,
      expiresAt: result.accessTokenExpirationDateTime ??
          DateTime.now().add(const Duration(hours: 1)),
      provider: 'onedrive',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Desktop flows (localhost loopback)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Finds an available localhost port in the range 49152–65535.
  Future<int> _findAvailablePort() async {
    final rng = Random();
    for (var i = 0; i < 20; i++) {
      final port = 49152 + rng.nextInt(65535 - 49152);
      try {
        final server =
            await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        await server.close();
        return port;
      } catch (_) {
        continue;
      }
    }
    throw Exception('Could not find available port for OAuth callback');
  }

  Future<OAuthToken> _desktopGoogleAuth() async {
    final port = await _findAvailablePort();
    final redirectUri = 'http://127.0.0.1:$port/oauth/callback';
    final state = _randomString(32);

    final authUrl = Uri.parse(CloudCredentials.googleAuthUri).replace(
      queryParameters: {
        'client_id': CloudCredentials.googleClientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': '${CloudCredentials.googleDriveScope} email',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
      },
    );

    final code = await _launchOAuthAndWaitForCode(
      authUrl: authUrl,
      port: port,
      expectedState: state,
    );

    // Exchange code for tokens
    final resp = await _http.post(
      Uri.parse(CloudCredentials.googleTokenUri),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': CloudCredentials.googleClientId,
        'client_secret': CloudCredentials.googleClientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('Google token exchange failed: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return OAuthToken(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
      expiresAt: DateTime.now().add(
          Duration(seconds: (data['expires_in'] as int?) ?? 3600)),
      provider: 'gdrive',
    );
  }

  Future<OAuthToken> _desktopMsAuth() async {
    final port = await _findAvailablePort();
    final redirectUri = 'http://127.0.0.1:$port/oauth/callback';
    final state = _randomString(32);

    final authUrl = Uri.parse(CloudCredentials.msAuthUri).replace(
      queryParameters: {
        'client_id': CloudCredentials.msClientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': CloudCredentials.msScopes,
        'response_mode': 'query',
        'state': state,
      },
    );

    final code = await _launchOAuthAndWaitForCode(
      authUrl: authUrl,
      port: port,
      expectedState: state,
    );

    // Exchange code for tokens
    final resp = await _http.post(
      Uri.parse(CloudCredentials.msTokenUri),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': CloudCredentials.msClientId,
        'client_secret': CloudCredentials.msClientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'scope': CloudCredentials.msScopes,
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('Microsoft token exchange failed: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return OAuthToken(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
      expiresAt: DateTime.now().add(
          Duration(seconds: (data['expires_in'] as int?) ?? 3600)),
      provider: 'onedrive',
    );
  }

  /// Launches the system browser with [authUrl] and listens on [port] for the
  /// OAuth callback with the authorization code.
  Future<String> _launchOAuthAndWaitForCode({
    required Uri authUrl,
    required int port,
    required String expectedState,
  }) async {
    final completer = Completer<String>();

    // Start temporary HTTP server for callback
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _log.info('OAuth callback server listening on port $port');

    // Auto-close after 5 minutes (timeout)
    final timeout = Timer(const Duration(minutes: 5), () {
      if (!completer.isCompleted) {
        completer.completeError(
            TimeoutException('OAuth flow timed out after 5 minutes'));
        server.close();
      }
    });

    server.listen((request) async {
      if (request.uri.path == '/oauth/callback') {
        final params = request.uri.queryParameters;
        final code = params['code'];
        final state = params['state'];
        final error = params['error'];

        if (error != null) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(_callbackHtml(false, 'Authentication error: $error'))
            ..close();
          if (!completer.isCompleted) {
            completer.completeError(Exception('OAuth error: $error'));
          }
        } else if (code != null && state == expectedState) {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(_callbackHtml(true, 'Authentication successful!'))
            ..close();
          if (!completer.isCompleted) {
            completer.complete(code);
          }
        } else {
          request.response
            ..statusCode = 400
            ..write('Invalid callback')
            ..close();
        }
      } else {
        request.response
          ..statusCode = 404
          ..close();
      }
    });

    // Open system browser
    _log.info('Opening browser for OAuth...');
    await _openUrl(authUrl.toString());

    try {
      return await completer.future;
    } finally {
      timeout.cancel();
      await server.close();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Token refresh
  // ═══════════════════════════════════════════════════════════════════════════

  Future<OAuthToken> _refreshGoogleToken(OAuthToken expired) async {
    final resp = await _http.post(
      Uri.parse(CloudCredentials.googleTokenUri),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': CloudCredentials.googleClientId,
        'client_secret': CloudCredentials.googleClientSecret,
        'refresh_token': expired.refreshToken!,
        'grant_type': 'refresh_token',
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('Google token refresh failed: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return OAuthToken(
      accessToken: data['access_token'] as String,
      // Google may not return a new refresh token on every refresh
      refreshToken:
          (data['refresh_token'] as String?) ?? expired.refreshToken,
      expiresAt: DateTime.now().add(
          Duration(seconds: (data['expires_in'] as int?) ?? 3600)),
      provider: 'gdrive',
    );
  }

  Future<OAuthToken> _refreshMsToken(OAuthToken expired) async {
    final resp = await _http.post(
      Uri.parse(CloudCredentials.msTokenUri),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': CloudCredentials.msClientId,
        'client_secret': CloudCredentials.msClientSecret,
        'refresh_token': expired.refreshToken!,
        'grant_type': 'refresh_token',
        'scope': CloudCredentials.msScopes,
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('Microsoft token refresh failed: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return OAuthToken(
      accessToken: data['access_token'] as String,
      refreshToken:
          (data['refresh_token'] as String?) ?? expired.refreshToken,
      expiresAt: DateTime.now().add(
          Duration(seconds: (data['expires_in'] as int?) ?? 3600)),
      provider: 'onedrive',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Token revocation
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _revokeGoogleToken(OAuthToken token) async {
    await _http.post(
      Uri.parse(
          'https://oauth2.googleapis.com/revoke?token=${token.accessToken}'),
    );
    _log.info('Google token revoked');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  String _randomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)])
        .join();
  }

  /// Open a URL in the system browser.
  Future<void> _openUrl(String url) async {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    }
    // On mobile, flutter_appauth handles browser launch.
  }

  /// HTML page returned to the browser after OAuth callback.
  String _callbackHtml(bool success, String message) {
    final icon = success ? '&#10003;' : '&#10007;';
    final color = success ? '#00C853' : '#FF1744';
    return '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>LifeOS AnyWhere</title></head>
<body style="display:flex;justify-content:center;align-items:center;height:100vh;
  font-family:system-ui;background:#1a1a2e;color:white;margin:0;">
  <div style="text-align:center;">
    <div style="font-size:64px;color:$color;">$icon</div>
    <h2>$message</h2>
    <p style="color:#888;">You can close this tab and return to the app.</p>
  </div>
</body>
</html>
''';
  }
}
