import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/chat_delete.dart';
import '../core/chat_paging.dart';
import '../core/chat_receipts.dart';
import '../models/chat_message.dart';
import '../services/auth_service.dart';
import '../services/chat_delete_service.dart';
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
  // v0.6.21 read receipts: message ids already marked seen by me
  // this session, so we never write the same mark twice.
  final Set<String> _seenMarked = {};

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
      // v0.6.21: 1-week retention — prune expired messages from the
      // server (at most once a day per phone, inside the call).
      unawaited(sync.pruneOldChatMessages(sync.activeCircleId!));
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
            // v0.6.21: the LIVE merge also drops messages deleted
            // for everyone (they vanish from the live page).
            _messages = mergeLiveChatPage(_messages, remote);
          }
          // A full page means there may be older messages to load.
          _hasMoreOlder = remote.length >= chatPageSize;
        });
        // v0.6.21 read receipts: what is on my screen now counts
        // as read by me.
        _markSeen();
      });
    });
  }

  /// Read receipts (v0.6.21): mark every visible message I have
  /// not marked yet as read by me. No-op offline / in demo mode.
  void _markSeen() {
    final sync = context.read<SyncService>();
    if (!sync.isAvailable || sync.activeCircleId == null) return;
    final myUid = sync.uid;
    if (myUid == null) return;
    final fresh = _messages
        .where((m) => !_seenMarked.contains(m.id) && !isSeenBy(m, myUid))
        .map((m) => m.id)
        .toList();
    if (fresh.isEmpty) return;
    _seenMarked.addAll(fresh);
    unawaited(sync.markMessagesSeen(sync.activeCircleId!, fresh));
  }

  /// Message info (v0.6.21): who read my message, and when —
  /// WhatsApp-style. Only for my own messages.
  Future<void> _showMessageInfo(ChatMessage m) async {
    final family = context.read<FamilyService>();
    final rows = readersOf(m, family.members);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Message info',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '"${m.text}"',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              for (final row in rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    child: Text(row.member.name[0]),
                  ),
                  title: Text(row.member.name),
                  trailing: row.readAt == null
                      ? const Text(
                          'Not read yet',
                          style: TextStyle(color: Colors.grey),
                        )
                      : Text(
                          'Read · ${formatReadTime(row.readAt!)}',
                          style: const TextStyle(color: Colors.green),
                        ),
                ),
              if (rows.isEmpty)
                const Text(
                  'No one else in the circle yet.',
                  style: TextStyle(color: Colors.grey),
                ),
            ],
          ),
        ),
      ),
    );
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
          senderName:
              mine?.name ?? auth.displayName ?? auth.phoneNumber ?? 'Me',
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

  /// Long-press a message (v0.6.21): delete it for me (any
  /// message, this phone only) or for everyone (my own messages
  /// only — the server rules enforce the same). Demo mode (no
  /// sync) has no "for everyone": there is no server to delete
  /// from.
  Future<void> _showMessageMenu(ChatMessage m) async {
    final sync = context.read<SyncService>();
    final isMine = sync.isAvailable && m.senderId == sync.uid;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              subtitle: const Text('Only on this phone.'),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Delete for everyone'),
                subtitle: const Text('Removed from every phone.'),
                onTap: () => Navigator.pop(ctx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final deletes = context.read<ChatDeleteService>();
    if (choice == 'me') {
      await deletes.deleteForMe(m);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted for you.')),
      );
      return;
    }
    // Delete for everyone: server first, then hide locally at
    // once (the live subscription drops it everywhere anyway).
    final ok = await sync.deleteChatMessage(sync.activeCircleId!, m.id);
    if (!mounted) return;
    if (ok) {
      await deletes.hideLocally(m);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deleted for everyone.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not delete — check internet and try again.'),
        ),
      );
    }
  }

  /// Clear the WHOLE chat on this phone (v0.6.21): everything
  /// sent up to now is hidden here; new messages still arrive.
  /// Other phones are untouched.
  Future<void> _confirmClearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'Hide all messages on THIS phone? They stay on the '
          'other phones, and new messages will still arrive.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<ChatDeleteService>().clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Chat cleared on this phone.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // v0.6.21: hide locally-deleted / cleared messages.
    final deletes = context.watch<ChatDeleteService>();
    final visible = _messages.where(deletes.isVisible).toList();
    return Column(
      children: [
        // v0.6.21: slim header — the clear-chat action lives here
        // (the chat tab has no AppBar of its own). Clear chat is
        // LOCAL ONLY: it clears the chat on this phone, never on
        // anyone else's. The retention line tells everyone the
        // 1-week rule at a glance.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              const Text(
                'Family chat',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Messages auto-delete after 1 week.',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                tooltip: 'Chat options',
                onSelected: (value) {
                  if (value == 'clear') {
                    unawaited(_confirmClearChat());
                  }
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem<String>(
                    value: 'clear',
                    child: Text('Clear chat'),
                  ),
                ],
              ),
            ],
          ),
        ),
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
                        _loadingOlder ? 'Loading…' : 'Load older messages',
                      ),
                    ),
                  ),
                ),
              for (final m in visible)
                Builder(
                  builder: (ctx) {
                    final sync = context.read<SyncService>();
                    final mine = sync.isAvailable
                        ? m.senderId == sync.uid
                        : m.senderId == 'me';
                    final readN = readCount(m);
                    return GestureDetector(
                      // v0.6.21: long-press for the delete menu;
                      // tap on MY message shows who read it, when.
                      onLongPress: () => _showMessageMenu(m),
                      onTap: mine ? () => _showMessageInfo(m) : null,
                      child: ListTile(
                        title: Text(m.senderName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.text),
                            if (mine && readN > 0)
                              Text(
                                'Read by $readN',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.green,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
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
