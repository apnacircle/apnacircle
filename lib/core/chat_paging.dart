import '../models/chat_message.dart';

/// Chat pagination (v0.6.7, 23 Nov 2026).
///
/// Invisible performance work: the live chat subscription used to
/// download the WHOLE history on every new message. Now it loads
/// only the newest [chatPageSize] messages, and older pages are
/// fetched on demand ("Load older messages"). The newest messages
/// look exactly the same as before — same order, same content.
///
/// This file is pure Dart (no Firebase) so the merge logic is unit
/// testable: the RTDB queries themselves live in SyncService.
///
/// Accuracy rule (standing): pagination never hides a message the
/// user already saw — a live update merges into the loaded list,
/// it never replaces it (except the very first page, which drops
/// the local demo seed message, as before).
const int chatPageSize = 50;

/// Union of two message lists, oldest first, de-duplicated by id.
///
/// Used both ways:
/// * a fresh live page arrives -> merge into what is already shown,
///   so older pages the user loaded stay visible;
/// * an older page is fetched -> merge into the list, so the newest
///   messages stay where they are.
List<ChatMessage> mergeChatMessages(
  List<ChatMessage> existing,
  List<ChatMessage> incoming,
) {
  final byId = <String, ChatMessage>{};
  for (final m in existing) {
    byId[m.id] = m;
  }
  for (final m in incoming) {
    byId[m.id] = m;
  }
  final out = byId.values.toList();
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}
