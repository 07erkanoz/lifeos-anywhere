import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:anyware/features/platform/android/direct_share_service.dart';

final sharingServiceProvider = Provider((ref) => SharingService());

class SharingService {
  final DirectShareService _directShare = DirectShareService();

  /// Stream of shared files while the app is running.
  Stream<List<SharedMediaFile>> getMediaStream() {
    return ReceiveSharingIntent.instance.getMediaStream();
  }

  /// Initial shared files when the app was closed.
  Future<List<SharedMediaFile>> getInitialMedia() {
    return ReceiveSharingIntent.instance.getInitialMedia();
  }

  /// Resets the sharing intent so it doesn't trigger again on resume.
  void reset() {
    ReceiveSharingIntent.instance.reset();
  }

  Future<DirectShareTargetInfo?> consumeDirectShareTarget() {
    return _directShare.consumeSelectedTarget();
  }
}
