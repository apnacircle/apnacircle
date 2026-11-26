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
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.at,
    this.seenBy = const {},
  });

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
    return j;
  }

  /// [id] is the RTDB push key (not stored inside the node).
  factory ChatMessage.fromJson(Map<String, dynamic> j, {String? id}) {
    final seenRaw = j['seenBy'];
    final seen = <String, int>{};
    if (seenRaw is Map) {
      for (final e in seenRaw.entries) {
        final v = e.value;
        if (v is int) {
          seen[e.key.toString()] = v;
        } else if (v is num) {
          seen[e.key.toString()] = v.toInt();
        }
      }
    }
    return ChatMessage(
      id: id ?? j['id'] as String? ?? '',
      senderId: j['senderId'] as String? ?? '',
      senderName: j['senderName'] as String? ?? '',
      text: j['text'] as String? ?? '',
      at: j['at'] == null ? DateTime.now() : DateTime.parse(j['at'] as String),
      seenBy: seen,
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
