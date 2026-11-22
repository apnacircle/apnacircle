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
