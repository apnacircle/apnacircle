import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/chat_delete.dart';
import '../core/chat_retention.dart';
import '../models/chat_message.dart';
import 'family_service.dart';

/// Local chat deletes (v0.6.21) — "delete for me" and "clear
/// chat", both THIS PHONE ONLY. (Delete for everyone is a server
/// delete — SyncService.deleteChatMessage — and needs no local
/// state, because the live subscription stops delivering the
/// removed message; the screen also hides it locally at once so
/// it vanishes without waiting for the round-trip.)
///
/// Per circle, stored in SharedPreferences so a delete survives
/// a restart and works with the internet off:
///   `chat_hidden_{circleId}`  — message ids hidden on this phone
///   `chat_cleared_{circleId}` — epoch ms; everything at or
///     before it is hidden on this phone.
class ChatDeleteService extends ChangeNotifier {
  ChatDeleteService({
    required FamilyService family,
  }) : _family = family {
    _family.addListener(_onFamilyChanged);
    _load();
  }

  final FamilyService _family;

  Set<String> _hiddenIds = {};
  DateTime? _clearedAt;

  String get _hiddenKey => 'chat_hidden_${_family.activeCircleId ?? 'none'}';
  String get _clearedKey => 'chat_cleared_${_family.activeCircleId ?? 'none'}';

  /// A message shows unless it is hidden, cleared, or older than
  /// the 1-week retention window (v0.6.21) — expired messages
  /// vanish from view on every phone at once, even before the
  /// server copy is pruned.
  bool isVisible(ChatMessage msg) =>
      !isChatMessageExpired(at: msg.at) &&
      isChatMessageVisible(
        msg: msg,
        hiddenIds: _hiddenIds,
        clearedAt: _clearedAt,
      );

  /// Hide one message on this phone (any sender). Persists.
  Future<void> deleteForMe(ChatMessage msg) async {
    _hiddenIds = {..._hiddenIds, msg.id};
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_hiddenKey, _hiddenIds.toList());
    } catch (_) {
      // Best effort — the hide holds in memory regardless.
    }
  }

  /// Hide one message on this phone right now (used after a
  /// successful delete-for-everyone, so it vanishes at once).
  Future<void> hideLocally(ChatMessage msg) => deleteForMe(msg);

  /// Hide the WHOLE chat on this phone (everything sent up to
  /// now). New messages still arrive afterwards. Persists.
  Future<void> clearAll() async {
    _clearedAt = DateTime.now();
    _hiddenIds = {};
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_clearedKey, _clearedAt!.millisecondsSinceEpoch);
      await prefs.remove(_hiddenKey);
    } catch (_) {
      // Best effort — the clear holds in memory regardless.
    }
  }

  void _onFamilyChanged() {
    _load();
  }

  Future<void> _load() async {
    _hiddenIds = {};
    _clearedAt = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      _hiddenIds = prefs.getStringList(_hiddenKey)?.toSet() ?? {};
      final ms = prefs.getInt(_clearedKey);
      _clearedAt = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      // A corrupt store means "nothing hidden" — safe default.
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _family.removeListener(_onFamilyChanged);
    super.dispose();
  }
}
