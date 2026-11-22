import 'package:flutter/material.dart';

import '../models/chat_message.dart';

/// Family chat (text). Voice/video calls are a v0.2 item:
/// they need a calling SDK (e.g. Agora / Firebase + WebRTC) and a
/// separate Play Store declaration — the UI slot is here.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messages = <ChatMessage>[
    ChatMessage(
      id: '1',
      senderId: 'ali',
      senderName: 'Ali',
      text: 'Ghar pahunch gaya.',
      at: DateTime.now().subtract(const Duration(minutes: 12)),
    ),
  ];
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: 'me',
        senderName: 'Mujahid',
        text: text,
        at: DateTime.now(),
      ));
      _ctrl.clear();
    });
    // TODO(v0.2): send via Firebase Realtime Database to the circle.
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final m in _messages)
                ListTile(
                  title: Text(m.senderName),
                  subtitle: Text(m.text),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'Message family…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _send, child: const Text('Send')),
            ],
          ),
        ),
      ],
    );
  }
}
