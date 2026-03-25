// Licensing data models for the Pro/Free tier system.
// Mirrors the Supabase `licenses` and `device_activations` tables.

/// Available subscription plans.
enum LicensePlan {
  free('free', 2, 1),
  pro3('pro_3', 3, -1),
  pro5('pro_5', 5, -1),
  pro10('pro_10', 10, -1),
  lifetime('lifetime', 5, -1);

  const LicensePlan(this.id, this.maxDevices, this.maxSyncJobs);

  /// Identifier stored in Supabase.
  final String id;

  /// Maximum number of activated devices.
  final int maxDevices;

  /// Maximum sync jobs (-1 = unlimited).
  final int maxSyncJobs;

  /// Whether this plan grants Pro features.
  bool get isPro => this != free;

  /// Resolve a plan from its string ID.
  static LicensePlan fromId(String id) {
    return LicensePlan.values.firstWhere(
      (p) => p.id == id,
      orElse: () => LicensePlan.free,
    );
  }
}

/// License status.
enum LicenseStatus {
  active,
  expired,
  cancelled;

  static LicenseStatus fromString(String s) {
    return LicenseStatus.values.firstWhere(
      (v) => v.name == s,
      orElse: () => LicenseStatus.expired,
    );
  }
}

/// A user license record from Supabase.
class License {
  final String id;
  final String rcAppUserId;
  final String activationCode;
  final LicensePlan plan;
  final LicenseStatus status;
  final int maxDevices;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const License({
    required this.id,
    required this.rcAppUserId,
    required this.activationCode,
    required this.plan,
    required this.status,
    required this.maxDevices,
    this.expiresAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Whether the license grants Pro access right now.
  bool get isActivePro =>
      plan.isPro &&
      status == LicenseStatus.active &&
      (expiresAt == null || expiresAt!.isAfter(DateTime.now()));

  factory License.fromJson(Map<String, dynamic> json) {
    return License(
      id: json['id'] as String,
      rcAppUserId: json['rc_app_user_id'] as String? ?? '',
      activationCode: json['activation_code'] as String? ?? '',
      plan: LicensePlan.fromId(json['plan'] as String? ?? 'free'),
      status: LicenseStatus.fromString(json['status'] as String? ?? 'active'),
      maxDevices: json['max_devices'] as int? ?? 2,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'rc_app_user_id': rcAppUserId,
        'activation_code': activationCode,
        'plan': plan.id,
        'status': status.name,
        'max_devices': maxDevices,
        'expires_at': expiresAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  /// A placeholder representing the free tier (no Supabase record).
  static final free = License(
    id: '',
    rcAppUserId: '',
    activationCode: '',
    plan: LicensePlan.free,
    status: LicenseStatus.active,
    maxDevices: 2,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// A device activation record from Supabase.
class DeviceActivation {
  final String id;
  final String licenseId;
  final String deviceUuid;
  final String deviceName;
  final String platform;
  final String appVersion;
  final DateTime lastSeenAt;
  final DateTime createdAt;

  const DeviceActivation({
    required this.id,
    required this.licenseId,
    required this.deviceUuid,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.lastSeenAt,
    required this.createdAt,
  });

  factory DeviceActivation.fromJson(Map<String, dynamic> json) {
    return DeviceActivation(
      id: json['id'] as String,
      licenseId: json['license_id'] as String? ?? '',
      deviceUuid: json['device_uuid'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      appVersion: json['app_version'] as String? ?? '',
      lastSeenAt: DateTime.tryParse(json['last_seen_at'] as String? ?? '') ??
          DateTime.now(),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Aggregated licensing state used by the UI.
class LicenseInfo {
  final License license;
  final List<DeviceActivation> devices;
  final bool isOfflineCached;

  const LicenseInfo({
    required this.license,
    this.devices = const [],
    this.isOfflineCached = false,
  });

  LicensePlan get plan => license.plan;
  bool get isPro => license.isActivePro;
  int get activeDeviceCount => devices.length;
  int get maxDevices => license.maxDevices;
  bool get canAddDevice => activeDeviceCount < maxDevices;
  String get activationCode => license.activationCode;

  /// Default free-tier state.
  static final free = LicenseInfo(license: License.free);
}
