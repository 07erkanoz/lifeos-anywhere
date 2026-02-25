import 'package:anyware/features/server_sync/domain/sftp_server_config.dart';

/// Supported sync provider types.
enum SyncProviderType {
  sftp,
  gdrive,
  onedrive,
  webdav;

  /// Human-readable display name.
  String get displayName {
    switch (this) {
      case SyncProviderType.sftp:
        return 'SFTP';
      case SyncProviderType.gdrive:
        return 'Google Drive';
      case SyncProviderType.onedrive:
        return 'OneDrive';
      case SyncProviderType.webdav:
        return 'WebDAV';
    }
  }

  /// Short label for badges / chips.
  String get shortLabel {
    switch (this) {
      case SyncProviderType.sftp:
        return 'SFTP';
      case SyncProviderType.gdrive:
        return 'GDrive';
      case SyncProviderType.onedrive:
        return 'OneDrive';
      case SyncProviderType.webdav:
        return 'WebDAV';
    }
  }
}

/// Unified account model for all sync providers.
///
/// Replaces [SftpServerConfig] as the top-level entity in the Server Sync
/// feature. SFTP-specific fields are nullable and only populated when
/// [providerType] is [SyncProviderType.sftp].
class SyncAccount {
  /// Unique identifier (UUID).
  final String id;

  /// User-friendly display name, e.g. "My NAS", "Work Google Drive".
  final String name;

  /// Which provider this account uses.
  final SyncProviderType providerType;

  /// When this account was created.
  final DateTime createdAt;

  /// Last successful connection timestamp.
  final DateTime? lastConnectedAt;

  // ── SFTP-specific fields ──

  /// Hostname or IP address (SFTP only).
  final String? host;

  /// SSH port (SFTP only, default 22).
  final int? port;

  /// SSH username (SFTP only).
  final String? username;

  /// SSH password (SFTP only, when authMethod == 'password').
  final String? password;

  /// PEM-encoded private key (SFTP only, when authMethod == 'key').
  final String? privateKey;

  /// Passphrase for the private key (SFTP only).
  final String? passphrase;

  /// Authentication method: 'password' or 'key' (SFTP only).
  final String? authMethod;

  // ── Cloud-specific fields ──

  /// Email address of the connected cloud account (Google/Microsoft).
  final String? email;

  // ── Common fields ──

  /// Default remote base path.
  final String remotePath;

  const SyncAccount({
    required this.id,
    required this.name,
    required this.providerType,
    required this.createdAt,
    this.lastConnectedAt,
    this.host,
    this.port,
    this.username,
    this.password,
    this.privateKey,
    this.passphrase,
    this.authMethod,
    this.email,
    this.remotePath = '/',
  });

  // ── Computed ──

  bool get isSftp => providerType == SyncProviderType.sftp;
  bool get isWebDav => providerType == SyncProviderType.webdav;
  bool get isCloud =>
      providerType == SyncProviderType.gdrive ||
      providerType == SyncProviderType.onedrive;

  /// Whether this provider uses host/port/user/password (not OAuth).
  bool get isHostBased => isSftp || isWebDav;

  /// A subtitle string for list tiles: host:port for SFTP/WebDAV, email for cloud.
  String get subtitle {
    if (isHostBased) return '${host ?? ''}:${port ?? (isWebDav ? 443 : 22)}';
    return email ?? providerType.displayName;
  }

  // ── Migration from SftpServerConfig ──

  /// Convert an old [SftpServerConfig] to a [SyncAccount].
  factory SyncAccount.fromSftpConfig(SftpServerConfig old) {
    return SyncAccount(
      id: old.id,
      name: old.name,
      providerType: SyncProviderType.sftp,
      createdAt: old.createdAt,
      lastConnectedAt: old.lastConnectedAt,
      host: old.host,
      port: old.port,
      username: old.username,
      password: old.password,
      privateKey: old.privateKey,
      passphrase: old.passphrase,
      authMethod: old.authMethod,
      remotePath: old.remotePath,
    );
  }

  /// Convert back to [SftpServerConfig] for the existing [SftpTransport].
  SftpServerConfig toSftpConfig() {
    assert(isSftp, 'toSftpConfig() can only be called on SFTP accounts');
    return SftpServerConfig(
      id: id,
      name: name,
      host: host ?? '',
      port: port ?? 22,
      username: username ?? '',
      password: password ?? '',
      privateKey: privateKey,
      passphrase: passphrase,
      remotePath: remotePath,
      authMethod: authMethod ?? 'password',
      createdAt: createdAt,
      lastConnectedAt: lastConnectedAt,
    );
  }

  // ── Copy ──

  SyncAccount copyWith({
    String? name,
    SyncProviderType? providerType,
    DateTime? lastConnectedAt,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKey,
    String? passphrase,
    String? authMethod,
    String? email,
    String? remotePath,
  }) =>
      SyncAccount(
        id: id,
        name: name ?? this.name,
        providerType: providerType ?? this.providerType,
        createdAt: createdAt,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        privateKey: privateKey ?? this.privateKey,
        passphrase: passphrase ?? this.passphrase,
        authMethod: authMethod ?? this.authMethod,
        email: email ?? this.email,
        remotePath: remotePath ?? this.remotePath,
      );

  // ── JSON ──

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'providerType': providerType.name,
        'createdAt': createdAt.toIso8601String(),
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKey': privateKey,
        'passphrase': passphrase,
        'authMethod': authMethod,
        'email': email,
        'remotePath': remotePath,
      };

  factory SyncAccount.fromJson(Map<String, dynamic> json) {
    return SyncAccount(
      id: json['id'] as String,
      name: json['name'] as String,
      providerType: _providerFromName(json['providerType'] as String?),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastConnectedAt: json['lastConnectedAt'] != null
          ? DateTime.tryParse(json['lastConnectedAt'] as String)
          : null,
      host: json['host'] as String?,
      port: json['port'] as int?,
      username: json['username'] as String?,
      password: json['password'] as String?,
      privateKey: json['privateKey'] as String?,
      passphrase: json['passphrase'] as String?,
      authMethod: json['authMethod'] as String?,
      email: json['email'] as String?,
      remotePath: json['remotePath'] as String? ?? '/',
    );
  }

  static SyncProviderType _providerFromName(String? name) {
    if (name == null) return SyncProviderType.sftp;
    return SyncProviderType.values.firstWhere(
      (v) => v.name == name,
      orElse: () => SyncProviderType.sftp,
    );
  }
}
