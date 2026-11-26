import '../core/media_share.dart';

class ChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime at;

  /// Read receipts (v0.6.21): member uid → ms since epoch when
  /// they opened the chat with this message on screen. The sender
  /// is never in here.
  final Map<String, int> seenBy;

  /// Media sharing (v0.6.23): null for a plain text message.
  /// [mediaUrl] is the Storage download URL; [storagePath] is the
  /// Storage path (needed to delete the file); [downloadedBy] is
  /// member uid → ms when they downloaded it to their own phone.
  /// [mediaUploadedAtMs] starts the 24-hour server lifetime.
  final MediaType? mediaType;
  final String? mediaUrl;
  final String? storagePath;
  final String? fileName;
  final int? fileSize;
  final Map<String, int> downloadedBy;
  final int? mediaUploadedAtMs;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.at,
    this.seenBy = const {},
    this.mediaType,
    this.mediaUrl,
    this.storagePath,
    this.fileName,
    this.fileSize,
    this.downloadedBy = const {},
    this.mediaUploadedAtMs,
  });

  /// True for a media message (photo / video / audio / document).
  bool get hasMedia => mediaType != null && mediaUrl != null;

  /// Milliseconds since epoch — written with every new message
  /// (v0.6.21) so the 2-week retention rule can compare numbers.
  /// Older messages have no atMs; it is derived from [at] here.
  int get atMs => at.millisecondsSinceEpoch;

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'at': at.toIso8601String(),
      'atMs': atMs,
    };
    if (seenBy.isNotEmpty) j['seenBy'] = seenBy;
    if (hasMedia) {
      j['mediaType'] = mediaType!.name;
      j['mediaUrl'] = mediaUrl;
      j['storagePath'] = storagePath;
      j['fileName'] = fileName;
      j['fileSize'] = fileSize;
      j['mediaUploadedAtMs'] = mediaUploadedAtMs;
      if (downloadedBy.isNotEmpty) j['downloadedBy'] = downloadedBy;
    }
    return j;
  }

  static Map<String, int> _uidMsMap(dynamic raw) {
    final out = <String, int>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final v = e.value;
        if (v is int) {
          out[e.key.toString()] = v;
        } else if (v is num) {
          out[e.key.toString()] = v.toInt();
        }
      }
    }
    return out;
  }

  /// [id] is the RTDB push key (not stored inside the node).
  factory ChatMessage.fromJson(Map<String, dynamic> j, {String? id}) {
    return ChatMessage(
      id: id ?? j['id'] as String? ?? '',
      senderId: j['senderId'] as String? ?? '',
      senderName: j['senderName'] as String? ?? '',
      text: j['text'] as String? ?? '',
      at: j['at'] == null ? DateTime.now() : DateTime.parse(j['at'] as String),
      seenBy: _uidMsMap(j['seenBy']),
      mediaType: MediaType.fromName(j['mediaType'] as String?),
      mediaUrl: j['mediaUrl'] as String?,
      storagePath: j['storagePath'] as String?,
      fileName: j['fileName'] as String?,
      fileSize: (j['fileSize'] as num?)?.toInt(),
      downloadedBy: _uidMsMap(j['downloadedBy']),
      mediaUploadedAtMs: (j['mediaUploadedAtMs'] as num?)?.toInt(),
    );
  }
}

class Place {
  final String id;
  final String name; // e.g. 'Home', 'School'
  final double lat;
  final double lon;
  final double radiusMeters;
  const Place({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    this.radiusMeters = 150,
  });
}
