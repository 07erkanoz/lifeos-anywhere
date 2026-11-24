/// One message in a conversation with a paired device (LifeOS İleti).
class IletiMessage {
  const IletiMessage({
    required this.id,
    required this.device,
    required this.outgoing,
    required this.time,
    this.text = '',
    this.fileName,
    this.fileSize,
    this.filePath,
    this.status = IletiStatus.pending,
    this.via = IletiVia.lan,
    this.progress,
    this.error,
  });

  /// Unique, the same on both sides (the sender's id).
  final String id;

  /// The paired device (its Yakındakiler id).
  final String device;
  final bool outgoing;
  final DateTime time;
  final String text;

  /// A file sent in the conversation.
  final String? fileName;
  final int? fileSize;

  /// Where the file is on this device (sent from, or landed at).
  final String? filePath;
  final IletiStatus status;

  /// How it went (or came).
  final IletiVia via;

  /// 0..1 while a file moves.
  final double? progress;
  final String? error;

  bool get isFile => fileName != null;

  IletiMessage copyWith({
    IletiStatus? status,
    IletiVia? via,
    String? filePath,
    double? progress,
    String? error,
    bool clearProgress = false,
  }) =>
      IletiMessage(
        id: id,
        device: device,
        outgoing: outgoing,
        time: time,
        text: text,
        fileName: fileName,
        fileSize: fileSize,
        filePath: filePath ?? this.filePath,
        status: status ?? this.status,
        via: via ?? this.via,
        progress: clearProgress ? null : progress ?? this.progress,
        error: error ?? this.error,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'device': device,
        'out': outgoing,
        'time': time.toIso8601String(),
        if (text.isNotEmpty) 'text': text,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (filePath != null) 'filePath': filePath,
        'status': status.name,
        'via': via.name,
        if (error != null) 'error': error,
      };

  factory IletiMessage.fromJson(Map<String, dynamic> j) => IletiMessage(
        id: j['id'] as String,
        device: j['device'] as String,
        outgoing: j['out'] as bool? ?? false,
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
        text: j['text'] as String? ?? '',
        fileName: j['fileName'] as String?,
        fileSize: (j['fileSize'] as num?)?.toInt(),
        filePath: j['filePath'] as String?,
        status: IletiStatus.values.asNameMap()[j['status']] ?? IletiStatus.sent,
        via: IletiVia.values.asNameMap()[j['via']] ?? IletiVia.lan,
        error: j['error'] as String?,
      );
}

enum IletiStatus {
  /// Waiting for the device (kept and sent when it is reachable).
  pending,
  sending,

  /// Left in the other device's mailbox on the server (it was off).
  onServer,
  sent,
  read,
  failed,

  /// Came in, not yet seen here.
  unread,

  /// Came in and seen.
  seen,
}

enum IletiVia {
  /// Directly on the local network (pinned TLS).
  lan,

  /// Through the LifeOS server's mailbox (sealed; the server cannot read it).
  internet,

  /// A file the server passed on when no direct path opened.
  relay,

  /// Text put on the device's clipboard (a peer without İleti).
  clipboard,
}
