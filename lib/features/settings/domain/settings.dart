class AppSettings {
  final String deviceName;
  final String downloadPath;
  final bool autoAcceptFiles;
  final bool overwriteFiles;
  final int maxFileSize;
  final String theme;
  final String locale;
  final bool launchAtStartup;
  final bool minimizeToTray;
  final bool showInExplorerMenu;

  /// Maximum upload speed in KB/s. 0 means unlimited.
  final int maxUploadSpeedKBps;

  const AppSettings({
    required this.deviceName,
    required this.downloadPath,
    this.autoAcceptFiles = false,
    this.overwriteFiles = false,
    this.maxFileSize = 0,
    this.theme = 'system',
    this.locale = 'en',
    this.launchAtStartup = false,
    this.minimizeToTray = true,
    this.showInExplorerMenu = true,
    this.maxUploadSpeedKBps = 0,
  });

  factory AppSettings.defaults() {
    return const AppSettings(
      deviceName: '',
      downloadPath: '',
      autoAcceptFiles: false,
      overwriteFiles: false,
      maxFileSize: 0,
      theme: 'system',
      locale: 'en',
      launchAtStartup: false,
      minimizeToTray: true,
      showInExplorerMenu: true,
      maxUploadSpeedKBps: 0,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      deviceName: json['deviceName'] as String? ?? '',
      downloadPath: json['downloadPath'] as String? ?? '',
      autoAcceptFiles: json['autoAcceptFiles'] as bool? ?? false,
      overwriteFiles: json['overwriteFiles'] as bool? ?? false,
      maxFileSize: json['maxFileSize'] as int? ?? 0,
      theme: json['theme'] as String? ?? 'system',
      locale: json['locale'] as String? ?? 'en',
      launchAtStartup: json['launchAtStartup'] as bool? ?? false,
      minimizeToTray: json['minimizeToTray'] as bool? ?? true,
      showInExplorerMenu: json['showInExplorerMenu'] as bool? ?? true,
      maxUploadSpeedKBps: json['maxUploadSpeedKBps'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceName': deviceName,
      'downloadPath': downloadPath,
      'autoAcceptFiles': autoAcceptFiles,
      'overwriteFiles': overwriteFiles,
      'maxFileSize': maxFileSize,
      'theme': theme,
      'locale': locale,
      'launchAtStartup': launchAtStartup,
      'minimizeToTray': minimizeToTray,
      'showInExplorerMenu': showInExplorerMenu,
      'maxUploadSpeedKBps': maxUploadSpeedKBps,
    };
  }

  AppSettings copyWith({
    String? deviceName,
    String? downloadPath,
    bool? autoAcceptFiles,
    bool? overwriteFiles,
    int? maxFileSize,
    String? theme,
    String? locale,
    bool? launchAtStartup,
    bool? minimizeToTray,
    bool? showInExplorerMenu,
    int? maxUploadSpeedKBps,
  }) {
    return AppSettings(
      deviceName: deviceName ?? this.deviceName,
      downloadPath: downloadPath ?? this.downloadPath,
      autoAcceptFiles: autoAcceptFiles ?? this.autoAcceptFiles,
      overwriteFiles: overwriteFiles ?? this.overwriteFiles,
      maxFileSize: maxFileSize ?? this.maxFileSize,
      theme: theme ?? this.theme,
      locale: locale ?? this.locale,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      showInExplorerMenu: showInExplorerMenu ?? this.showInExplorerMenu,
      maxUploadSpeedKBps: maxUploadSpeedKBps ?? this.maxUploadSpeedKBps,
    );
  }

  /// Returns the formatted max file size, or 'Unlimited' if 0.
  String get formattedMaxFileSize {
    if (maxFileSize == 0) return 'Unlimited';
    if (maxFileSize < 1024) return '$maxFileSize B';
    if (maxFileSize < 1024 * 1024) {
      return '${(maxFileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (maxFileSize < 1024 * 1024 * 1024) {
      return '${(maxFileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(maxFileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings &&
          runtimeType == other.runtimeType &&
          deviceName == other.deviceName &&
          downloadPath == other.downloadPath &&
          autoAcceptFiles == other.autoAcceptFiles &&
          overwriteFiles == other.overwriteFiles &&
          maxFileSize == other.maxFileSize &&
          theme == other.theme &&
          locale == other.locale &&
          launchAtStartup == other.launchAtStartup &&
          minimizeToTray == other.minimizeToTray &&
          showInExplorerMenu == other.showInExplorerMenu &&
          maxUploadSpeedKBps == other.maxUploadSpeedKBps;

  @override
  int get hashCode => Object.hash(
        deviceName,
        downloadPath,
        autoAcceptFiles,
        overwriteFiles,
        maxFileSize,
        theme,
        locale,
        launchAtStartup,
        minimizeToTray,
        showInExplorerMenu,
        maxUploadSpeedKBps,
      );

  @override
  String toString() => 'AppSettings(deviceName: $deviceName, theme: $theme, locale: $locale)';
}
