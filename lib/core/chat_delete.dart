import '../models/chat_message.dart';
import 'chat_paging.dart';

/// Chat delete (v0.6.21) — pure helpers. Three ways to delete:
///
/// 1. **Delete for me** — any message, any sender: the message
///    id goes into a per-circle hidden set stored on THIS phone
///    only (SharedPreferences). It stays for everyone else.
/// 2. **Delete for everyone** — my OWN messages only: the node
///    is removed from RTDB (`circles/{id}/chat/{msgId}`), so it
///    disappears from every phone (rules v3 allows the sender —
///    and only the sender — to delete their own message).
/// 3. **Clear chat** — everything older than now is hidden on
///    THIS phone only (a per-circle "cleared at" timestamp).
///    New messages still arrive afterwards.
///
/// Pure here so the rules are unit-testable; the persistence
/// lives in ChatDeleteService, the server delete in SyncService.
bool isChatMessageVisible({
  required ChatMessage msg,
  required Set<String> hiddenIds,
  required DateTime? clearedAt,
}) {
  if (hiddenIds.contains(msg.id)) return false;
  if (clearedAt != null && !msg.at.isAfter(clearedAt)) return false;
  return true;
}

/// Merge a fresh LIVE page into the shown list, DROPPING messages
/// that were deleted for everyone (v0.6.21).
///
/// The plain [mergeChatMessages] union never removes anything —
/// that is right for older pages, but wrong for the live page:
/// a message deleted for everyone vanishes from the live page,
/// so a union would keep showing it forever. The live page is
/// the newest [chatPageSize] messages (RTDB push keys sort in
/// chronological order), so: a shown message is dropped exactly
/// when its key is inside the live page's range (key >= the
/// page's oldest key) but it is NOT in the page anymore. Older
/// pages are untouched — a message deleted long after it was
/// loaded may linger there until the chat is reopened (the first
/// page then replaces the whole list).
List<ChatMessage> mergeLiveChatPage(
  List<ChatMessage> existing,
  List<ChatMessage> livePage,
) {
  if (livePage.isEmpty) return List.of(existing);
  final liveIds = livePage.map((m) => m.id).toSet();
  final oldestLiveId = livePage.first.id;
  final kept = existing.where((m) {
    if (liveIds.contains(m.id)) return true;
    // Older than the live page's range: an older page — keep.
    if (m.id.compareTo(oldestLiveId) < 0) return true;
    // Inside the live range but gone from the page: deleted.
    return false;
  }).toList();
  return mergeChatMessages(kept, livePage);
}
