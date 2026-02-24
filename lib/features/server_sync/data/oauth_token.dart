/// Represents an OAuth 2.0 access/refresh token pair for a cloud provider.
class OAuthToken {
  /// Bearer access token.
  final String accessToken;

  /// Refresh token (used to obtain a new access token after expiry).
  final String? refreshToken;

  /// When the [accessToken] expires.
  final DateTime expiresAt;

  /// Provider identifier: `'gdrive'` or `'onedrive'`.
  final String provider;

  const OAuthToken({
    required this.accessToken,
    this.refreshToken,
    required this.expiresAt,
    required this.provider,
  });

  /// Whether the access token has expired (with a 5-minute safety buffer).
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 5)));

  /// Whether a refresh token is available for automatic renewal.
  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  // ── JSON ──

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toIso8601String(),
        'provider': provider,
      };

  factory OAuthToken.fromJson(Map<String, dynamic> json) {
    return OAuthToken(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      provider: json['provider'] as String,
    );
  }

  OAuthToken copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) =>
      OAuthToken(
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
        provider: provider,
      );

  @override
  String toString() =>
      'OAuthToken(provider=$provider, expired=$isExpired, expiresAt=$expiresAt)';
}
