import 'package:uuid/uuid.dart';

class Device {
  final String id;
  final String name;
  final String ip;
  final int port;
  final String platform;
  final String version;
  final DateTime lastSeen;

  const Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.platform,
    required this.version,
    required this.lastSeen,
  });

  factory Device.create({
    required String name,
    required String ip,
    required int port,
    required String platform,
    required String version,
  }) {
    return Device(
      id: const Uuid().v4(),
      name: name,
      ip: ip,
      port: port,
      platform: platform,
      version: version,
      lastSeen: DateTime.now(),
    );
  }

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] as String,
      name: json['name'] as String,
      ip: json['ip'] as String,
      port: json['port'] as int,
      platform: json['platform'] as String,
      version: json['version'] as String,
      lastSeen: DateTime.parse(json['lastSeen'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'ip': ip,
      'port': port,
      'platform': platform,
      'version': version,
      'lastSeen': lastSeen.toIso8601String(),
    };
  }

  Device copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    String? platform,
    String? version,
    DateTime? lastSeen,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      version: version ?? this.version,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// Returns the appropriate icon name for this device's platform.
  String get platformIcon {
    switch (platform) {
      case 'android':
        return 'phone_android';
      case 'android_tv':
        return 'tv';
      case 'windows':
        return 'desktop_windows';
      case 'ios':
        return 'phone_iphone';
      case 'linux':
        return 'computer';
      default:
        return 'devices';
    }
  }

  /// Returns a human-readable platform label.
  String get platformLabel {
    switch (platform) {
      case 'android':
        return 'Android';
      case 'android_tv':
        return 'Android TV';
      case 'windows':
        return 'Windows';
      case 'ios':
        return 'iOS';
      case 'linux':
        return 'Linux';
      default:
        return platform;
    }
  }

  /// Whether this device has been seen recently (within timeout).
  bool get isOnline {
    final now = DateTime.now();
    return now.difference(lastSeen).inSeconds < 10;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Device && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Device(id: $id, name: $name, ip: $ip, platform: $platform)';
}
