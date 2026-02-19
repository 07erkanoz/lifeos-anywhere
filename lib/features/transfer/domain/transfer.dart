import 'package:anyware/features/discovery/domain/device.dart';

enum TransferStatus {
  pending,
  accepted,
  rejected,
  transferring,
  completed,
  failed,
  cancelled,
}

class Transfer {
  final String id;
  final String fileName;
  final int fileSize;
  final Device senderDevice;
  final Device? receiverDevice;
  final TransferStatus status;
  final double progress;
  final String? filePath;
  final String? error;
  final DateTime createdAt;

  /// Transfer hızı (bayt/saniye). Null ise henüz hesaplanamadı.
  final double? speed;

  /// Tahmini kalan süre. Null ise henüz hesaplanamadı.
  final Duration? estimatedTimeLeft;

  /// Bu transfer gönderim mi yoksa alım mı?
  final bool isSending;

  const Transfer({
    required this.id,
    required this.fileName,
    required this.fileSize,
    required this.senderDevice,
    this.receiverDevice,
    required this.status,
    this.progress = 0.0,
    this.filePath,
    this.error,
    required this.createdAt,
    this.speed,
    this.estimatedTimeLeft,
    this.isSending = true,
  });

  factory Transfer.fromJson(Map<String, dynamic> json) {
    return Transfer(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      fileSize: json['fileSize'] as int,
      senderDevice: Device.fromJson(json['senderDevice'] as Map<String, dynamic>),
      receiverDevice: json['receiverDevice'] != null
          ? Device.fromJson(json['receiverDevice'] as Map<String, dynamic>)
          : null,
      status: TransferStatus.values.firstWhere(
        (e) => e.name == json['status'] as String,
        orElse: () => TransferStatus.pending,
      ),
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      filePath: json['filePath'] as String?,
      error: json['error'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fileName': fileName,
      'fileSize': fileSize,
      'senderDevice': senderDevice.toJson(),
      'receiverDevice': receiverDevice?.toJson(),
      'status': status.name,
      'progress': progress,
      'filePath': filePath,
      'error': error,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Transfer copyWith({
    String? id,
    String? fileName,
    int? fileSize,
    Device? senderDevice,
    Device? receiverDevice,
    TransferStatus? status,
    double? progress,
    String? filePath,
    String? error,
    DateTime? createdAt,
    double? speed,
    Duration? estimatedTimeLeft,
    bool? isSending,
  }) {
    return Transfer(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      senderDevice: senderDevice ?? this.senderDevice,
      receiverDevice: receiverDevice ?? this.receiverDevice,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      speed: speed ?? this.speed,
      estimatedTimeLeft: estimatedTimeLeft ?? this.estimatedTimeLeft,
      isSending: isSending ?? this.isSending,
    );
  }

  /// Returns a human-readable file size string (B, KB, MB, GB).
  String get formattedSize {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      final kb = fileSize / 1024;
      return '${kb.toStringAsFixed(1)} KB';
    } else if (fileSize < 1024 * 1024 * 1024) {
      final mb = fileSize / (1024 * 1024);
      return '${mb.toStringAsFixed(1)} MB';
    } else {
      final gb = fileSize / (1024 * 1024 * 1024);
      return '${gb.toStringAsFixed(2)} GB';
    }
  }

  /// Returns the transfer progress as an integer percentage (0-100).
  int get progressPercent => (progress * 100).round().clamp(0, 100);

  /// Whether the transfer is currently active (not in a terminal state).
  bool get isActive =>
      status == TransferStatus.pending ||
      status == TransferStatus.accepted ||
      status == TransferStatus.transferring;

  /// Whether the transfer has reached a terminal state.
  bool get isFinished =>
      status == TransferStatus.completed ||
      status == TransferStatus.failed ||
      status == TransferStatus.cancelled ||
      status == TransferStatus.rejected;

  /// Returns a human-readable status label.
  String get statusLabel {
    switch (status) {
      case TransferStatus.pending:
        return 'Pending';
      case TransferStatus.accepted:
        return 'Accepted';
      case TransferStatus.rejected:
        return 'Rejected';
      case TransferStatus.transferring:
        return 'Transferring';
      case TransferStatus.completed:
        return 'Completed';
      case TransferStatus.failed:
        return 'Failed';
      case TransferStatus.cancelled:
        return 'Cancelled';
    }
  }

  /// Cihaz adı — gönderimde alıcı, alımda gönderici.
  String get deviceName {
    if (isSending && receiverDevice != null) {
      return receiverDevice!.name;
    }
    return senderDevice.name;
  }

  /// Transfer edilen boyut (progress * fileSize).
  String get formattedTransferredSize {
    final transferred = (progress * fileSize).round();
    return _formatBytes(transferred);
  }

  /// Dosya boyutu formatlanmış.
  String get formattedFileSize => _formatBytes(fileSize);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Transfer && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Transfer(id: $id, fileName: $fileName, status: ${status.name}, progress: $progressPercent%)';
}
