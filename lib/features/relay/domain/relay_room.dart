/// Represents a relay room for WebRTC P2P signaling.
class RelayRoom {
  final String roomId;
  final String pin;
  final int peerCount;
  final DateTime? createdAt;

  const RelayRoom({
    required this.roomId,
    required this.pin,
    this.peerCount = 0,
    this.createdAt,
  });

  factory RelayRoom.fromJson(Map<String, dynamic> json) => RelayRoom(
        roomId: json['room_id'] as String? ?? '',
        pin: json['pin'] as String? ?? '',
        peerCount: json['peer_count'] as int? ?? 0,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
      );
}

/// Connection state for the relay feature.
enum RelayConnectionState {
  /// No room created or joined.
  idle,

  /// Creating a room on the server.
  creatingRoom,

  /// Room created, waiting for peer to join.
  waitingForPeer,

  /// Joining an existing room.
  joiningRoom,

  /// Both peers connected, establishing WebRTC.
  connecting,

  /// P2P connection established, ready to transfer.
  connected,

  /// Transfer in progress.
  transferring,

  /// An error occurred.
  error,
}

/// State of the relay feature.
class RelayState {
  final RelayConnectionState connectionState;
  final RelayRoom? room;
  final String? error;
  final double transferProgress;
  final String? transferFileName;
  final String? peerName;

  const RelayState({
    this.connectionState = RelayConnectionState.idle,
    this.room,
    this.error,
    this.transferProgress = 0.0,
    this.transferFileName,
    this.peerName,
  });

  RelayState copyWith({
    RelayConnectionState? connectionState,
    RelayRoom? room,
    String? error,
    double? transferProgress,
    String? transferFileName,
    String? peerName,
  }) =>
      RelayState(
        connectionState: connectionState ?? this.connectionState,
        room: room ?? this.room,
        error: error,
        transferProgress: transferProgress ?? this.transferProgress,
        transferFileName: transferFileName ?? this.transferFileName,
        peerName: peerName ?? this.peerName,
      );
}
