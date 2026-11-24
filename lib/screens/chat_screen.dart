import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/chat_paging.dart';
import '../models/chat_message.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/notification_service.dart';
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
  var _messages = <ChatMessage>[
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
  // v0.6.11: while this screen is open the user is LOOKING at the
  // chat — NotificationService suppresses chat notifications for
  // this circle (same as WhatsApp: no ping for the open chat).
  // Kept as a field so dispose() can clear it without context.
  NotificationService? _notifications;
  // v0.6.7 pagination: the live subscription only carries the
  // newest chatPageSize messages. Older pages are fetched on demand
  // and merged in — a live update must never drop them again.
  bool _livePageReceived = false;
  bool _hasMoreOlder = false;
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    _notifications = context.read<NotificationService>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sync = context.read<SyncService>();
      if (!sync.isAvailable || sync.activeCircleId == null) return;
      // v0.6.11: this chat is open now — suppress its notifications.
      _notifications?.openChatCircleId = sync.activeCircleId;
      if (_subscribed) return;
      _subscribed = true;
      sync.subscribeChat(sync.activeCircleId!, (remote) {
        if (!mounted) return;
        setState(() {
          if (!_livePageReceived) {
            // First live page replaces the local demo seed message,
            // exactly as before v0.6.7.
            _livePageReceived = true;
            _messages = List.of(remote);
          } else {
            // Later updates merge in — older pages the user loaded
            // stay visible, and a new message never wipes them.
            _messages = mergeChatMessages(_messages, remote);
          }
          // A full page means there may be older messages to load.
          _hasMoreOlder = remote.length >= chatPageSize;
        });
      });
    });
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || _messages.isEmpty) return;
    final sync = context.read<SyncService>();
    if (!sync.isAvailable || sync.activeCircleId == null) return;
    setState(() => _loadingOlder = true);
    final older = await sync.loadOlderChatMessages(
      sync.activeCircleId!,
      beforeId: _messages.first.id,
    );
    if (!mounted) return;
    setState(() {
      _loadingOlder = false;
      if (older.isEmpty) {
        _hasMoreOlder = false;
        return;
      }
      _messages = mergeChatMessages(_messages, older);
      _hasMoreOlder = older.length >= chatPageSize;
    });
  }

  @override
  void dispose() {
    // v0.6.11: chat no longer open — notifications resume.
    _notifications?.openChatCircleId = null;
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
              if (_hasMoreOlder)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Center(
                    child: TextButton(
                      onPressed: _loadingOlder ? null : _loadOlder,
                      child: Text(
                        _loadingOlder
                            ? 'Loading…'
                            : 'Load older messages',
                      ),
                    ),
                  ),
                ),
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
