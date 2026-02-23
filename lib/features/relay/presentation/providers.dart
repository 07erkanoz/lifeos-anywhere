import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anyware/features/relay/data/signaling_client.dart';
import 'package:anyware/features/relay/data/webrtc_transfer.dart';
import 'package:anyware/features/relay/domain/relay_room.dart';

/// Singleton signaling client.
final signalingClientProvider = Provider<SignalingClient>((ref) {
  final client = SignalingClient();
  ref.onDispose(() => client.dispose());
  return client;
});

/// Main relay state provider.
final relayProvider =
    StateNotifierProvider.autoDispose<RelayNotifier, RelayState>((ref) {
  final signaling = ref.watch(signalingClientProvider);
  return RelayNotifier(signaling);
});

/// Manages the relay connection lifecycle.
class RelayNotifier extends StateNotifier<RelayState> {
  final SignalingClient _signaling;
  WebRTCTransfer? _transfer;

  RelayNotifier(this._signaling) : super(const RelayState());

  /// Creates a new room and waits for a peer.
  Future<void> createRoom(String localDeviceName) async {
    state = state.copyWith(connectionState: RelayConnectionState.creatingRoom);

    try {
      final room = await _signaling.createRoom();
      state = state.copyWith(
        connectionState: RelayConnectionState.waitingForPeer,
        room: room,
      );

      // Connect to signaling WebSocket.
      await _signaling.connectSignaling(room.roomId);

      // Initialize WebRTC as offerer.
      _transfer = WebRTCTransfer(_signaling);
      _setupTransferCallbacks(localDeviceName);
      await _transfer!.initAsOfferer();

      // Wait briefly then create the offer — the answerer needs to connect first.
      // In practice, the offer is sent immediately and buffered by the signaling server.
      await _transfer!.createOffer();
    } catch (e) {
      state = state.copyWith(
        connectionState: RelayConnectionState.error,
        error: e.toString(),
      );
    }
  }

  /// Joins an existing room using only a 6-digit PIN.
  Future<void> joinRoom(String pin, String localDeviceName) async {
    state = state.copyWith(connectionState: RelayConnectionState.joiningRoom);

    try {
      final roomId = await _signaling.joinByPin(pin);

      state = state.copyWith(
        connectionState: RelayConnectionState.connecting,
        room: RelayRoom(roomId: roomId, pin: pin),
      );

      // Connect to signaling WebSocket.
      await _signaling.connectSignaling(roomId);

      // Initialize WebRTC as answerer.
      _transfer = WebRTCTransfer(_signaling);
      _setupTransferCallbacks(localDeviceName);
      await _transfer!.initAsAnswerer();
    } catch (e) {
      state = state.copyWith(
        connectionState: RelayConnectionState.error,
        error: e.toString(),
      );
    }
  }

  /// Sends a file to the connected peer.
  Future<void> sendFile(String filePath, String fileName) async {
    if (_transfer == null) return;

    state = state.copyWith(
      connectionState: RelayConnectionState.transferring,
      transferFileName: fileName,
      transferProgress: 0.0,
    );

    await _transfer!.sendFile(filePath, fileName);

    // After sending completes, return to connected state so user can
    // send more files.  If an error occurred during send, onError will
    // have already updated the state to `error`, so we only change
    // back to `connected` if we're still in `transferring`.
    if (state.connectionState == RelayConnectionState.transferring) {
      state = state.copyWith(
        connectionState: RelayConnectionState.connected,
        transferProgress: 1.0,
      );
    }
  }

  /// Disconnects and resets state.
  Future<void> disconnect() async {
    await _transfer?.dispose();
    _transfer = null;
    await _signaling.disconnect();
    state = const RelayState();
  }

  void _setupTransferCallbacks(String localDeviceName) {
    _transfer!.onConnected = () {
      state = state.copyWith(connectionState: RelayConnectionState.connected);
      _transfer!.sendIdentity(localDeviceName);
    };

    _transfer!.onPeerIdentity = (name) {
      state = state.copyWith(peerName: name);
    };

    _transfer!.onFileMetadata = (fileName, fileSize) {
      state = state.copyWith(
        connectionState: RelayConnectionState.transferring,
        transferFileName: fileName,
        transferProgress: 0.0,
      );
    };

    _transfer!.onProgress = (progress) {
      state = state.copyWith(transferProgress: progress);
    };

    _transfer!.onTransferComplete = (savedPath) {
      state = state.copyWith(
        connectionState: RelayConnectionState.connected,
        transferProgress: 1.0,
      );
    };

    _transfer!.onError = (error) {
      state = state.copyWith(
        connectionState: RelayConnectionState.error,
        error: error,
      );
    };
  }

  @override
  void dispose() {
    _transfer?.dispose();
    _signaling.disconnect();
    super.dispose();
  }
}
