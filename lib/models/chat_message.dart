class ChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime at;
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'senderId': senderId,
        'senderName': senderName,
        'text': text,
        'at': at.toIso8601String(),
      };

  /// [id] is the RTDB push key (not stored inside the node).
  factory ChatMessage.fromJson(Map<String, dynamic> j, {String? id}) =>
      ChatMessage(
        id: id ?? j['id'] as String? ?? '',
        senderId: j['senderId'] as String? ?? '',
        senderName: j['senderName'] as String? ?? '',
        text: j['text'] as String? ?? '',
        at: j['at'] == null
            ? DateTime.now()
            : DateTime.parse(j['at'] as String),
      );
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
