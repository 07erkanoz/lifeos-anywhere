/// SFTP server connection configuration.
class SftpServerConfig {
  /// Unique identifier (UUID).
  final String id;

  /// User-friendly label, e.g. "My NAS", "VPS Backup".
  final String name;

  /// Hostname or IP address of the SFTP server.
  final String host;

  /// SSH port (default 22).
  final int port;

  /// SSH username.
  final String username;

  /// SSH password (used when [authMethod] is `password`).
  final String password;

  /// PEM-encoded private key (used when [authMethod] is `key`).
  final String? privateKey;

  /// Passphrase for the private key (optional).
  final String? passphrase;

  /// Base path on the remote server, e.g. "/home/user/sync".
  final String remotePath;

  /// Authentication method: `password` or `key`.
  final String authMethod;

  /// When this server config was created.
  final DateTime createdAt;

  /// Last time a successful connection was established.
  final DateTime? lastConnectedAt;

  const SftpServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.password = '',
    this.privateKey,
    this.passphrase,
    this.remotePath = '/',
    this.authMethod = 'password',
    required this.createdAt,
    this.lastConnectedAt,
  });

  SftpServerConfig copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKey,
    String? passphrase,
    String? remotePath,
    String? authMethod,
    DateTime? lastConnectedAt,
  }) =>
      SftpServerConfig(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        privateKey: privateKey ?? this.privateKey,
        passphrase: passphrase ?? this.passphrase,
        remotePath: remotePath ?? this.remotePath,
        authMethod: authMethod ?? this.authMethod,
        createdAt: createdAt,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'privateKey': privateKey,
        'passphrase': passphrase,
        'remotePath': remotePath,
        'authMethod': authMethod,
        'createdAt': createdAt.toIso8601String(),
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
      };

  factory SftpServerConfig.fromJson(Map<String, dynamic> json) {
    return SftpServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      username: json['username'] as String,
      password: json['password'] as String? ?? '',
      privateKey: json['privateKey'] as String?,
      passphrase: json['passphrase'] as String?,
      remotePath: json['remotePath'] as String? ?? '/',
      authMethod: json['authMethod'] as String? ?? 'password',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastConnectedAt: json['lastConnectedAt'] != null
          ? DateTime.tryParse(json['lastConnectedAt'] as String)
          : null,
    );
  }
}
