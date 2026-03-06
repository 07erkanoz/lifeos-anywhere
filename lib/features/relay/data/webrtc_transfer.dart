import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:anyware/core/cloud_credentials.dart';
import 'package:anyware/core/logger.dart';
import 'package:anyware/features/relay/data/signaling_client.dart';

final _log = AppLogger('WebRTCTransfer');

/// Chunk size for DataChannel file transfers (16 KB).
const int _chunkSize = 16 * 1024;

/// Maximum buffered amount before we pause sending (256 KB).
const int _maxBufferedAmount = 256 * 1024;

/// Timeout for ICE connection to reach 'connected' state.
const Duration _iceTimeout = Duration(seconds: 45);

/// Grace period to wait after 'disconnected' before reporting error.
const Duration _disconnectGrace = Duration(seconds: 8);

/// Manages WebRTC peer connection and DataChannel-based file transfer.
class WebRTCTransfer {
  final SignalingClient _signaling;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  StreamSubscription? _sigSub;
  Timer? _iceTimer;
  Timer? _disconnectTimer;
  bool _disposed = false;

  /// Called when the P2P connection is fully established.
  void Function()? onConnected;

  /// Called when file metadata is received (receiver side).
  void Function(String fileName, int fileSize)? onFileMetadata;

  /// Called with progress updates during transfer.
  void Function(double progress)? onProgress;

  /// Called when a file transfer completes (receiver side, with saved path).
  void Function(String savedPath)? onTransferComplete;

  /// Called on error.
  void Function(String error)? onError;

  /// Called when peer identity is received.
  void Function(String peerName)? onPeerIdentity;

  // Receiver-side state.
  String? _receivingFileName;
  int _receivingFileSize = 0;
  int _receivedBytes = 0;
  IOSink? _fileSink;
  String? _tempFilePath;

  // ICE candidates received before remote description is set.
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescSet = false;

  // Track whether DataChannel has opened at least once.
  bool _dataChannelOpened = false;

  WebRTCTransfer(this._signaling);

  /// ICE servers configuration with STUN + TURN for reliable NAT traversal.
  static final Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      if (CloudCredentials.turnUsername.isNotEmpty) {
        'urls': [
          'turn:141.98.112.130:3479?transport=udp',
          'turn:141.98.112.130:3479?transport=tcp',
        ],
        'username': CloudCredentials.turnUsername,
        'credential': CloudCredentials.turnCredential,
      },
    ],
    'iceTransportPolicy': 'all',
  };

  /// Creates a peer connection and sets up the DataChannel (offerer side).
  /// Call this on the device that creates the room.
  Future<void> initAsOfferer() async {
    _pc = await createPeerConnection(_iceConfig);
    _setupIceHandling();

    // Create a reliable, ordered data channel for file transfer.
    _dataChannel = await _pc!.createDataChannel(
      'file-transfer',
      RTCDataChannelInit()..ordered = true,
    );
    _setupDataChannel(_dataChannel!);

    // Subscribe to signaling messages — the stream buffers events until we
    // subscribe, so no messages are lost even if they arrived before this line.
    _sigSub = _signaling.messages.listen(
      _handleSignalingMessage,
      onError: (e) => _log.error('Signaling stream error: $e'),
    );

    _log.info('Initialized as offerer');
  }

  /// Creates a peer connection (answerer side).
  /// Call this on the device that joins the room.
  Future<void> initAsAnswerer() async {
    _pc = await createPeerConnection(_iceConfig);
    _setupIceHandling();

    // Listen for incoming data channels.
    _pc!.onDataChannel = (RTCDataChannel channel) {
      _dataChannel = channel;
      _setupDataChannel(channel);
      _log.info('Received data channel from offerer');
    };

    // Subscribe to signaling messages — the stream buffers events so even
    // the SDP offer flushed by the server upon WebSocket connect will be
    // captured here (non-broadcast StreamController).
    _sigSub = _signaling.messages.listen(
      _handleSignalingMessage,
      onError: (e) => _log.error('Signaling stream error: $e'),
    );

    _log.info('Initialized as answerer');
  }

  /// Creates and sends an SDP offer (call after initAsOfferer).
  Future<void> createOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);

    _signaling.sendSignal({
      'type': 'offer',
      'sdp': offer.sdp,
    });

    _log.info('SDP offer sent');

    // Start ICE timeout — if we don't connect within _iceTimeout, report error.
    _startIceTimeout();
  }

  /// Sends a file over the DataChannel with proper backpressure handling.
  Future<void> sendFile(String filePath, String fileName) async {
    if (_dataChannel == null ||
        _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      onError?.call('DataChannel not open');
      return;
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      onError?.call('File not found: $filePath');
      return;
    }

    final fileSize = await file.length();

    // Send file metadata first.
    _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
      'type': 'file-meta',
      'name': fileName,
      'size': fileSize,
    })));

    _log.info('Sending file: $fileName ($fileSize bytes)');

    // Stream file in chunks with backpressure control.
    int bytesSent = 0;
    final stream = file.openRead();
    double lastReportedProgress = 0.0;

    try {
      await for (final chunk in stream) {
        if (_disposed) return;

        // Check DataChannel is still open.
        if (_dataChannel == null ||
            _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
          _log.error('DataChannel closed mid-transfer');
          onError?.call('Connection lost during transfer');
          return;
        }

        // Split into _chunkSize pieces.
        for (int i = 0; i < chunk.length; i += _chunkSize) {
          final end =
              (i + _chunkSize > chunk.length) ? chunk.length : i + _chunkSize;
          final piece = Uint8List.fromList(chunk.sublist(i, end));

          // Backpressure: wait if the buffer is full.
          final drained = await _waitForBufferDrain();
          if (!drained) return;

          _dataChannel!.send(RTCDataChannelMessage.fromBinary(piece));
          bytesSent += piece.length;

          // Throttle progress callbacks to avoid excessive UI updates.
          final progress =
              fileSize > 0 ? (bytesSent / fileSize).clamp(0.0, 1.0) : 0.0;
          if (progress - lastReportedProgress >= 0.01 || progress >= 1.0) {
            lastReportedProgress = progress;
            onProgress?.call(progress);
          }
        }
      }
    } catch (e) {
      _log.error('Error sending file: $e');
      onError?.call('Send error: $e');
      return;
    }

    // Send completion marker.
    _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
      'type': 'file-done',
    })));

    _log.info('File sent: $fileName ($bytesSent bytes)');
    onProgress?.call(1.0);
  }

  /// Waits until the DataChannel buffer has drained below the threshold.
  /// Returns false if drain timed out or channel closed.
  Future<bool> _waitForBufferDrain() async {
    if (_dataChannel == null) return false;
    int waitCount = 0;
    while (_dataChannel!.bufferedAmount != null &&
        _dataChannel!.bufferedAmount! > _maxBufferedAmount) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waitCount++;

      // Check channel still open.
      if (_dataChannel == null ||
          _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
        _log.warning('DataChannel closed while waiting for buffer drain');
        onError?.call('Connection lost during transfer');
        return false;
      }

      if (waitCount > 3000) {
        // 30 seconds max wait — something is stuck.
        _log.warning('Buffer drain timeout — aborting send');
        onError?.call('Transfer stalled');
        return false;
      }
    }
    return true;
  }

  /// Sends local device identity to the peer.
  void sendIdentity(String deviceName) {
    if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
        'type': 'identity',
        'name': deviceName,
      })));
    }
  }

  /// Cleans up all resources.
  Future<void> dispose() async {
    _disposed = true;
    _iceTimer?.cancel();
    _iceTimer = null;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    await _sigSub?.cancel();
    _sigSub = null;
    await _fileSink?.close();
    _fileSink = null;
    _dataChannel?.close();
    _dataChannel = null;
    await _pc?.close();
    _pc = null;
    _pendingCandidates.clear();
    _remoteDescSet = false;
  }

  // --- Private methods ---

  /// Starts a timer that fires an error if ICE does not connect in time.
  void _startIceTimeout() {
    _iceTimer?.cancel();
    _iceTimer = Timer(_iceTimeout, () {
      if (!_dataChannelOpened && !_disposed) {
        _log.error('ICE connection timeout after ${_iceTimeout.inSeconds}s');
        onError?.call('Connection timed out — could not establish P2P link');
      }
    });
  }

  void _setupIceHandling() {
    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      final c = candidate.candidate ?? '';
      // Log candidate type for debugging relay issues.
      final type = c.contains('relay') ? 'RELAY' : c.contains('srflx') ? 'SRFLX' : c.contains('host') ? 'HOST' : 'OTHER';
      _log.info('Local ICE [$type]: $c');
      _signaling.sendSignal({
        'type': 'ice-candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _pc!.onIceGatheringState = (RTCIceGatheringState gatheringState) {
      _log.info('ICE gathering state: $gatheringState');
    };

    _pc!.onIceConnectionState = (RTCIceConnectionState iceState) {
      _log.info('ICE connection state: $iceState');

      if (iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        // Cancel the ICE timeout — we successfully connected.
        _iceTimer?.cancel();
        _iceTimer = null;
        _log.info('ICE connected successfully');
      } else if (iceState ==
          RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _iceTimer?.cancel();
        _iceTimer = null;
        _log.error('ICE connection failed');
        if (!_dataChannelOpened) {
          onError?.call('P2P connection failed — could not traverse NAT');
        }
      }
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      _log.info('Peer connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        // Cancel any disconnect grace timer — we recovered.
        _disconnectTimer?.cancel();
        _disconnectTimer = null;
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _disconnectTimer?.cancel();
        _disconnectTimer = null;
        if (!_dataChannelOpened) {
          onError?.call('P2P connection failed');
        } else {
          onError?.call('Connection lost during transfer');
        }
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _log.warning('Peer connection disconnected — waiting for recovery');
        // Start grace timer: if not recovered within _disconnectGrace, fire error.
        _disconnectTimer?.cancel();
        _disconnectTimer = Timer(_disconnectGrace, () {
          if (!_disposed && _dataChannelOpened) {
            _log.error('Peer connection did not recover from disconnected');
            onError?.call('Connection lost during transfer');
          }
        });
      }
    };
  }

  void _setupDataChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (RTCDataChannelState state) {
      _log.info('DataChannel state: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _dataChannelOpened = true;
        _iceTimer?.cancel();
        _iceTimer = null;
        // Small delay to let the channel stabilise before sending data.
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          if (!_disposed) onConnected?.call();
        });
      } else if (state == RTCDataChannelState.RTCDataChannelClosing ||
          state == RTCDataChannelState.RTCDataChannelClosed) {
        if (_dataChannelOpened) {
          _log.warning('DataChannel closed after being open');
        }
      }
    };

    channel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) {
        _handleBinaryData(message.binary);
      } else {
        _handleTextMessage(message.text);
      }
    };
  }

  void _handleTextMessage(String text) {
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final type = json['type'] as String?;

      switch (type) {
        case 'file-meta':
          _receivingFileName = json['name'] as String;
          _receivingFileSize = json['size'] as int;
          _receivedBytes = 0;

          // Open temp file for writing.
          final tempDir = Directory.systemTemp.path;
          _tempFilePath =
              '$tempDir/relay_${DateTime.now().millisecondsSinceEpoch}.tmp';
          _fileSink = File(_tempFilePath!).openWrite();

          onFileMetadata?.call(_receivingFileName!, _receivingFileSize);
          _log.info(
              'Receiving file: $_receivingFileName ($_receivingFileSize bytes)');
          break;

        case 'file-done':
          _finalizeReceive();
          break;

        case 'identity':
          final name = json['name'] as String?;
          if (name != null) onPeerIdentity?.call(name);
          break;
      }
    } catch (e) {
      _log.warning('Failed to parse DataChannel text message: $e');
    }
  }

  void _handleBinaryData(Uint8List data) {
    if (_fileSink == null) return;

    _fileSink!.add(data);
    _receivedBytes += data.length;

    // Throttle progress callbacks — report every ~1%.
    final progress = _receivingFileSize > 0
        ? (_receivedBytes / _receivingFileSize).clamp(0.0, 1.0)
        : 0.0;
    onProgress?.call(progress);
  }

  void _finalizeReceive() {
    _fileSink?.close();
    _fileSink = null;

    if (_tempFilePath != null && _receivingFileName != null) {
      _log.info(
          'File received: $_receivingFileName ($_receivedBytes bytes)');
      onTransferComplete?.call(_tempFilePath!);
    }

    _receivingFileName = null;
    _receivingFileSize = 0;
    _receivedBytes = 0;
    _tempFilePath = null;
  }

  Future<void> _handleSignalingMessage(Map<String, dynamic> msg) async {
    // The server wraps the payload in a SignalMessage with 'from' and 'data' fields.
    final data = msg['data'] as Map<String, dynamic>?;
    if (data == null) {
      _log.debug('Signaling message without data: $msg');
      return;
    }

    final type = data['type'] as String?;
    _log.info('Processing signaling message: $type');

    try {
      switch (type) {
        case 'offer':
          await _handleOffer(data);
          break;
        case 'answer':
          await _handleAnswer(data);
          break;
        case 'ice-candidate':
          await _handleIceCandidate(data);
          break;
        default:
          _log.debug('Unknown signaling type: $type');
      }
    } catch (e, st) {
      _log.error('Error handling signaling message ($type): $e\n$st');
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    if (_pc == null) return;

    final sdp = data['sdp'] as String;
    _log.info('Setting remote description (offer), SDP length: ${sdp.length}');

    await _pc!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    _remoteDescSet = true;
    await _drainPendingCandidates();

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    _signaling.sendSignal({
      'type': 'answer',
      'sdp': answer.sdp,
    });

    _log.info('SDP answer sent, answer SDP length: ${answer.sdp?.length}');

    // Start ICE timeout for the answerer side too.
    _startIceTimeout();
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    if (_pc == null) return;

    final sdp = data['sdp'] as String;
    _log.info('Setting remote description (answer), SDP length: ${sdp.length}');

    await _pc!.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    _remoteDescSet = true;
    await _drainPendingCandidates();

    _log.info('SDP answer applied');
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    if (_pc == null) return;

    final candidateStr = data['candidate'] as String?;
    final candidate = RTCIceCandidate(
      candidateStr,
      data['sdpMid'] as String?,
      data['sdpMLineIndex'] as int?,
    );

    if (candidateStr != null) {
      final type = candidateStr.contains('relay') ? 'RELAY' : candidateStr.contains('srflx') ? 'SRFLX' : candidateStr.contains('host') ? 'HOST' : 'OTHER';
      _log.info('Remote ICE [$type]: $candidateStr');
    }

    if (!_remoteDescSet) {
      // Queue ICE candidates that arrive before remote description.
      _pendingCandidates.add(candidate);
      _log.debug(
          'Queued ICE candidate (remote desc not set yet, ${_pendingCandidates.length} queued)');
      return;
    }

    try {
      await _pc!.addCandidate(candidate);
    } catch (e) {
      _log.warning('Failed to add ICE candidate: $e');
    }
  }

  /// Drains queued ICE candidates after remote description is set.
  Future<void> _drainPendingCandidates() async {
    if (_pendingCandidates.isEmpty) return;
    _log.info(
        'Draining ${_pendingCandidates.length} pending ICE candidates');
    for (final c in _pendingCandidates) {
      try {
        await _pc!.addCandidate(c);
      } catch (e) {
        _log.warning('Failed to add queued ICE candidate: $e');
      }
    }
    _pendingCandidates.clear();
  }
}
