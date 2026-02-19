import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

final sharingServiceProvider = Provider((ref) => SharingService());

class SharingService {
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
}
