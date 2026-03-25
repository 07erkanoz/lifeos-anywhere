import 'package:anyware/core/licensing/license_models.dart';

/// Pro-only features that require a paid plan.
enum ProFeature {
  /// More than 1 folder sync job.
  unlimitedSync,

  /// SFTP / FTP / WebDAV server sync.
  serverSync,

  /// Google Drive / OneDrive cloud sync.
  cloudSync,

  /// Internet file transfer via relay (WebRTC).
  relayTransfer,

  /// Quick-send files to a saved server.
  quickSendToServer,

  /// Live file watching for auto-sync.
  liveWatch,

  /// Bidirectional (two-way) sync.
  bidirectionalSync,

  /// Scheduled/timed sync jobs.
  scheduledSync,

  /// Transfer files larger than 500 MB.
  unlimitedFileSize,
}

/// Checks whether a Pro feature is available for the current plan.
class FeatureGate {
  FeatureGate._();

  /// Free-tier file size limit in bytes (500 MB).
  static const int freeFileSizeLimit = 500 * 1024 * 1024;

  /// Free-tier sync job limit.
  static const int freeSyncJobLimit = 1;

  /// Whether [feature] is available on the given [plan].
  static bool isAvailable(ProFeature feature, LicensePlan plan) {
    if (plan.isPro) return true;

    // Free plan only gets basic LAN features.
    switch (feature) {
      case ProFeature.unlimitedSync:
      case ProFeature.serverSync:
      case ProFeature.cloudSync:
      case ProFeature.relayTransfer:
      case ProFeature.quickSendToServer:
      case ProFeature.liveWatch:
      case ProFeature.bidirectionalSync:
      case ProFeature.scheduledSync:
      case ProFeature.unlimitedFileSize:
        return false;
    }
  }

  /// Whether the user can create another sync job given their current count.
  static bool canCreateSyncJob(LicensePlan plan, int currentJobCount) {
    if (plan.isPro) return true;
    return currentJobCount < freeSyncJobLimit;
  }

  /// Whether the file size is within the free-tier limit.
  static bool canTransferFile(LicensePlan plan, int fileSizeBytes) {
    if (plan.isPro) return true;
    return fileSizeBytes <= freeFileSizeLimit;
  }
}
