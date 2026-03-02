class AppConstants {
  static const String appName = 'LifeOS AnyWhere';
  static const String appVersion = '1.0.0';
  static const String protocolVersion = '1.0';
  static const String websiteUrl = 'https://lifeos.com.tr';
  static const String githubUrl = 'https://github.com/07erkanoz/lifeos-anywhere';

  // Network ports
  static const int defaultPort = 48739;
  static const int discoveryPort = 48740;
  static const int singleInstancePort = 48799;
  static const String multicastGroup = '224.0.0.167';

  // Discovery timing
  static const int discoveryIntervalSeconds = 3;
  static const int deviceTimeoutSeconds = 30;
  static const int deviceOnlineThresholdSeconds = 15;
  static const int healthCheckSilenceSeconds = 60;

  // Transfer
  static const int fileChunkSize = 65536; // 64KB
  static const int maxRetries = 3;
  static const int transferRequestTimeoutSeconds = 60;
  static const int connectionTimeoutSeconds = 5;

  // History limits
  static const int maxTransferHistory = 100;
  static const int maxClipboardHistory = 50;

  // Debounce
  static const int shareDebounceMs = 300;

  // Cleanup intervals
  static const int transferCleanupMinutes = 10;
  static const int transferStaleMinutes = 30;
  static const int dedupeExpirySeconds = 60;

  // API Gateway (relay signaling, etc.)
  static const String aiGatewayUrl = 'https://api.sbyazilim.info';
}
