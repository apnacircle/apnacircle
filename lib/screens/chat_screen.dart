import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/sync_service.dart';

/// Family chat (text). Voice/video calls are a v0.2 item:
/// they need a calling SDK (e.g. Agora / Firebase + WebRTC) and a
/// separate Play Store declaration — the UI slot is here.
///
/// v0.3: when synced, messages go through the circle's RTDB node
/// and arrive on the other phone live. In demo mode the chat stays
/// local (the seed message below).
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
  bool _subscribed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sync = context.read<SyncService>();
      if (!sync.isAvailable || sync.activeCircleId == null) return;
      if (_subscribed) return;
      _subscribed = true;
      sync.subscribeChat(sync.activeCircleId!, (remote) {
        if (!mounted) return;
        setState(() {
          _messages
            ..clear()
            ..addAll(remote);
        });
      });
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    final sync = context.read<SyncService>();
    final family = context.read<FamilyService>();
    final auth = context.read<AuthService>();
    _ctrl.clear();
    if (sync.isAvailable && sync.activeCircleId != null) {
      final mine = family.myMember;
      sync.sendChatMessage(
        sync.activeCircleId!,
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          senderId: sync.uid ?? 'me',
          senderName: mine?.name ??
              auth.displayName ??
              auth.phoneNumber ??
              'Me',
          text: text,
          at: DateTime.now(),
        ),
      );
      return;
    }
    setState(() {
      _messages.add(ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        senderId: 'me',
        senderName: 'Mujahid',
        text: text,
        at: DateTime.now(),
      ));
    });
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
