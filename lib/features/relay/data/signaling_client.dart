import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:anyware/core/constants.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/relay/domain/relay_room.dart';

final _log = AppLogger('SignalingClient');

/// Client for the Rust relay signaling server.
///
/// Handles room creation/joining via REST and real-time signaling via WebSocket.
/// Uses a non-broadcast StreamController that buffers messages until a listener
/// subscribes, preventing message loss during initialisation.
class SignalingClient {
  final String baseUrl;
  final http.Client _httpClient;
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;

  /// Non-broadcast controller — buffers events until the single listener
  /// subscribes.  This prevents the SDP offer being lost when the server
  /// flushes buffered messages before WebRTCTransfer has subscribed.
  StreamController<Map<String, dynamic>>? _messageController;

  /// Returns the message stream.  A new controller is created lazily so that
  /// each connection cycle starts with a fresh buffer.
  Stream<Map<String, dynamic>> get messages {
    _messageController ??= StreamController<Map<String, dynamic>>();
    return _messageController!.stream;
  }

  SignalingClient({
    String? baseUrl,
    http.Client? client,
  })  : baseUrl = baseUrl ?? AppConstants.aiGatewayUrl,
        _httpClient = client ?? http.Client();

  /// Creates a new relay room on the server.
  Future<RelayRoom> createRoom() async {
    final uri = Uri.parse('$baseUrl/v1/relay/create-room');
    final response = await _httpClient.post(uri).timeout(
          const Duration(seconds: 10),
        );

    if (response.statusCode != 200) {
      throw SignalingException('Failed to create room: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _log.info('Room created: ${json['room_id']}');
    return RelayRoom.fromJson(json);
  }

  /// Joins a room using only a 6-digit PIN.
  /// Returns the room ID on success so the client can connect to signaling.
  Future<String> joinByPin(String pin) async {
    final uri = Uri.parse('$baseUrl/v1/relay/join-by-pin');
    final response = await _httpClient
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'pin': pin}),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      throw SignalingException('Room not found');
    }
    if (response.statusCode != 200) {
      throw SignalingException('Failed to join room: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final roomId = json['room_id'] as String;
    _log.info('Joined room $roomId via PIN (peers: ${json['peer_count']})');
    return roomId;
  }

  /// Connects to the signaling WebSocket for a room.
  ///
  /// **Important**: The message controller is created fresh here so that
  /// messages start buffering from the moment the WebSocket connects.
  /// Subscribe via [messages] before or after this call — either way
  /// no messages are lost.
  Future<void> connectSignaling(String roomId) async {
    // Create a fresh non-broadcast controller for this connection.
    // If there is an old one that was never closed, close it first.
    if (_messageController != null && !_messageController!.isClosed) {
      await _messageController!.close();
    }
    _messageController = StreamController<Map<String, dynamic>>();

    // Convert HTTP URL to WebSocket URL.
    final wsUrl = baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    final uri = Uri.parse('$wsUrl/v1/relay/signal/$roomId');

    _log.info('Connecting WebSocket: $uri');

    _wsChannel = WebSocketChannel.connect(uri);

    // Wait for the WebSocket to be ready.
    try {
      await _wsChannel!.ready;
      _log.info('WebSocket connected');
    } catch (e) {
      _log.error('WebSocket connection failed: $e');
      _messageController!.addError(e);
      return;
    }

    _wsSub = _wsChannel!.stream.listen(
      (data) {
        try {
          final json = jsonDecode(data as String) as Map<String, dynamic>;
          _log.debug('Signaling message received: ${json['data']?['type'] ?? 'unknown'}');
          if (_messageController != null && !_messageController!.isClosed) {
            _messageController!.add(json);
          }
        } catch (e) {
          _log.warning('Failed to parse signaling message: $e');
        }
      },
      onError: (error) {
        _log.error('WebSocket error: $error');
        if (_messageController != null && !_messageController!.isClosed) {
          _messageController!.addError(error);
        }
      },
      onDone: () {
        _log.info('WebSocket closed');
      },
    );
  }

  /// Sends a signaling message through the WebSocket.
  void sendSignal(Map<String, dynamic> data) {
    if (_wsChannel == null) {
      _log.warning('Cannot send signal — WebSocket not connected');
      return;
    }
    _log.debug('Sending signal: ${data['type']}');
    _wsChannel!.sink.add(jsonEncode(data));
  }

  /// Disconnects the WebSocket.
  Future<void> disconnect() async {
    await _wsSub?.cancel();
    _wsSub = null;
    await _wsChannel?.sink.close();
    _wsChannel = null;
    if (_messageController != null && !_messageController!.isClosed) {
      await _messageController!.close();
    }
    _messageController = null;
  }

  Future<void> dispose() async {
    await disconnect();
    _httpClient.close();
  }
}

class SignalingException implements Exception {
  final String message;
  SignalingException(this.message);

  @override
  String toString() => 'SignalingException: $message';
}
