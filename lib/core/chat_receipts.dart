// Read receipts (v0.6.21) — WhatsApp-style "who read it, when".
//
// HOW IT WORKS: when a member opens the chat and a message is on
// their screen, their app writes `seenBy/{theirUid} = <ms>` under
// that message (SyncService.markMessagesSeen). The sender taps
// their own message to see "Message info": every circle member
// with "Read · 26 Nov, 21:05" or "Not read yet".
//
// HONEST LIMITS:
// * A read mark appears only when the member actually OPENS the
//   chat (the message on their screen). A closed app, or a phone
//   that only got the notification, shows "Not read yet" until
//   they open the chat. Offline reads sync when the phone is
//   back online.
// * Only the READER writes their own mark (rules v3: a member
//   may write only seenBy/{ownUid}); nobody can fake someone
//   else's read.
// * The sender themself is never counted as a reader.
// * Read marks are tiny (one number per member per message), so
//   they cost almost no storage.

import '../models/chat_message.dart';
import '../models/member.dart';

/// How many members (other than the sender) have read [msg].
int readCount(ChatMessage msg) {
  var n = 0;
  for (final uid in msg.seenBy.keys) {
    if (uid != msg.senderId) n++;
  }
  return n;
}

/// True when [uid] has read [msg].
bool isSeenBy(ChatMessage msg, String uid) => msg.seenBy.containsKey(uid);

/// One row of the Message info sheet: a member + when they read
/// (null = not read yet). Readers first (earliest first), then
/// members who have not read, in circle order.
List<({Member member, DateTime? readAt})> readersOf(
  ChatMessage msg,
  List<Member> members,
) {
  final rows = <({Member member, DateTime? readAt})>[];
  for (final m in members) {
    if (m.id == msg.senderId) continue;
    final ms = msg.seenBy[m.id];
    rows.add((
      member: m,
      readAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    ));
  }
  rows.sort((a, b) {
    if (a.readAt == null && b.readAt == null) return 0;
    if (a.readAt == null) return 1;
    if (b.readAt == null) return -1;
    return a.readAt!.compareTo(b.readAt!);
  });
  return rows;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "26 Nov, 21:05" — the same plain format as the alerts centre.
String formatReadTime(DateTime at) {
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return '${at.day} ${_months[at.month - 1]}, $hh:$mm';
}
