/// What the user answered to a pairing prompt.
enum PairingDecision {
  /// Not allowed. The device stays unknown.
  reject,

  /// Allowed for this one request only; nothing is remembered.
  allowOnce,

  /// Allowed and remembered: the device is trusted from now on.
  trust,
}

/// Why an unknown device contacted us — shown in the pairing prompt.
enum PairingReason { file, clipboard, sync, pair }

/// A first contact from a device that is not paired yet.
class PairingRequest {
  const PairingRequest({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.ip,
    required this.reason,
    required this.tokenCapable,
    this.allowOnceOption = false,
    this.detail,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String ip;
  final PairingReason reason;

  /// The sender runs protocol 1.1+ and can keep a pairing token. When
  /// `false` (old 1.0.x app) trust falls back to device id + IP.
  final bool tokenCapable;

  /// Whether "allow only this time" makes sense (a single file transfer).
  final bool allowOnceOption;

  /// Optional extra text, e.g. the file name.
  final String? detail;

  /// Human-readable platform label for the prompt.
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
      case 'macos':
        return 'macOS';
      default:
        return platform;
    }
  }
}
