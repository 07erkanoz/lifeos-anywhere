import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:anyware/core/logger.dart';
import 'package:anyware/features/server_sync/data/oauth_token.dart';

final _log = AppLogger('TokenStore');

/// Securely stores and retrieves OAuth tokens using platform key-chain
/// (iOS Keychain, Android EncryptedSharedPreferences, Windows DPAPI, etc.).
class TokenStore {
  final FlutterSecureStorage _storage;

  /// Key prefix used in the secure storage.
  static const _prefix = 'oauth_token_';

  TokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  /// Persist a [token] for the given [accountId].
  Future<void> saveToken(String accountId, OAuthToken token) async {
    try {
      final json = jsonEncode(token.toJson());
      await _storage.write(key: '$_prefix$accountId', value: json);
      _log.info('Token saved for account $accountId');
    } catch (e) {
      _log.error('Failed to save token for $accountId: $e', error: e);
      rethrow;
    }
  }

  /// Load a previously saved token for [accountId].
  ///
  /// Returns `null` if no token exists or it cannot be decoded.
  Future<OAuthToken?> loadToken(String accountId) async {
    try {
      final json = await _storage.read(key: '$_prefix$accountId');
      if (json == null) return null;
      return OAuthToken.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      _log.error('Failed to load token for $accountId: $e', error: e);
      return null;
    }
  }

  /// Delete the token for [accountId].
  Future<void> deleteToken(String accountId) async {
    try {
      await _storage.delete(key: '$_prefix$accountId');
      _log.info('Token deleted for account $accountId');
    } catch (e) {
      _log.error('Failed to delete token for $accountId: $e', error: e);
    }
  }

  /// Check whether a token exists for [accountId] without decoding it.
  Future<bool> hasToken(String accountId) async {
    final value = await _storage.read(key: '$_prefix$accountId');
    return value != null;
  }
}
