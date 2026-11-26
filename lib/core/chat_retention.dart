// Chat retention (v0.6.21) — messages auto-delete after 1 week.
//
// WHY: the free Firebase plan gives the WHOLE app 5 GB of storage
// (shared by every family, not per family). Text chat is tiny —
// 5 GB holds tens of millions of messages — but an automatic
// clean-up keeps storage from ever growing without bound, and it
// matches what the user asked for: chat stays 1 week, older
// messages disappear on their own.
//
// HOW IT WORKS (no server function, no Blaze):
// * Every message carries its send time. A message is "expired"
//   when it is older than [chatRetentionDays] (7 days).
// * Expired messages are hidden immediately on every phone
//   (ChatDeleteService.isVisible) — they never show, even before
//   the server copy is removed.
// * When anyone opens the chat, the app prunes the server copy:
//   any member may delete an expired message (RTDB rules v3 allow
//   delete when atMs is older than 7 days), and each member may
//   always delete their own messages. Pruning runs at most once a
//   day per phone, so it costs almost nothing.
// * HONEST LIMIT: without a Cloud Function there is no fixed daily
//   clock — the clean-up runs when a family member opens the chat.
//   In practice someone opens chat every day, so 14-day-old
//   messages vanish within about a day of expiring. An exact
//   midnight sweep would need the (Blaze-blocked) Cloud Function.

/// Chat lives this many days, then auto-deletes.
const int chatRetentionDays = 7;

/// The same window in milliseconds (for RTDB rules + queries).
const int chatRetentionMs = chatRetentionDays * 24 * 60 * 60 * 1000;

/// The cut-off for "expired" at [nowMs] (ms since epoch).
int retentionCutoffMs(int nowMs) => nowMs - chatRetentionMs;

/// True when a message sent at [at] is older than the retention
/// window. [now] defaults to DateTime.now() (tests pass their own).
bool isChatMessageExpired({required DateTime at, DateTime? now}) {
  final n = now ?? DateTime.now();
  return n.difference(at).inMilliseconds >= chatRetentionMs;
}

/// Same check on raw millisecond timestamps (for server data).
bool isChatMessageExpiredMs({required int atMs, int? nowMs}) {
  final n = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return n - atMs >= chatRetentionMs;
}
