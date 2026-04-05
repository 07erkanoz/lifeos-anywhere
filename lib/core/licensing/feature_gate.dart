/// Pro-only features — now all unlocked for free.
enum ProFeature {
  unlimitedSync,
  serverSync,
  cloudSync,
  relayTransfer,
  quickSendToServer,
  liveWatch,
  bidirectionalSync,
  scheduledSync,
  unlimitedFileSize,
}

/// All features are always available (app is completely free).
class FeatureGate {
  FeatureGate._();

  /// Whether [feature] is available — always true.
  static bool isAvailable(ProFeature feature, dynamic plan) => true;

  /// Whether the user can create another sync job — always true.
  static bool canCreateSyncJob(dynamic plan, int currentJobCount) => true;

  /// Whether the file size is allowed — always true.
  static bool canTransferFile(dynamic plan, int fileSizeBytes) => true;
}
