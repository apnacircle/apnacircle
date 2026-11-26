/// Media sharing (v0.6.23) — photo / video / audio / document in
/// the family chat, with the user's own storage rules:
///
/// 1. COMPRESS FIRST: a photo is shrunk before upload (max 1280 px,
///    quality 80 — usually 60–80% smaller, and it still looks the
///    same); a video is re-encoded to medium quality (much smaller);
///    a document is sent as-is (a PDF barely shrinks).
/// 2. DOWNLOAD = the file leaves the server: it is deleted from
///    Firebase Storage once EVERY member of the circle has
///    downloaded it — deleting after the first download would
///    steal it from the members who had not downloaded yet.
/// 3. 24-HOUR RULE: if nobody downloads it within 24 hours of
///    upload, it is deleted from the server anyway, so storage
///    never fills up. The chat message itself stays (it follows
///    the 1-week chat rule) — only the file goes.
///
/// Honest limits, told to the user: the file DOES sit on the
/// server until it is downloaded or 24 hours pass — the storage
/// is temporary, not zero. The server copy is pruned when any
/// member opens the chat (no fixed daily clock without Cloud
/// Functions, same as the chat retention). Storage rules cannot
/// read the Realtime Database, so membership is NOT enforced by
/// the Storage rules themselves — the file path contains the
/// circle id + an unguessable message id, and only a signed-in
/// user who knows the exact path can read it (see storage.rules).
enum MediaType {
  photo,
  video,
  audio,
  document;

  static MediaType? fromName(String? name) {
    for (final t in MediaType.values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// A shared file lives on the server for at most 24 hours.
const int mediaRetentionHours = 24;
const int mediaRetentionMs = mediaRetentionHours * 60 * 60 * 1000;

/// Photo compression target (flutter_image_compress): longest side
/// 1280 px, JPEG quality 80. A phone photo (4032 px, ~4 MB) lands
/// around 300–600 KB — the 60–80% saving the user was promised.
const int photoMaxDimension = 1280;
const int photoQuality = 80;

/// A file larger than this is refused before upload (100 MB).
/// A video that big would take forever on a Pakistani mobile
/// connection, and the free Storage tier is only 5 GB for the
/// whole app.
const int maxMediaBytes = 100 * 1024 * 1024;

int mediaExpiresAtMs(int uploadedAtMs) => uploadedAtMs + mediaRetentionMs;

/// True when the 24 hours are up — the server file must go
/// (the chat message itself stays until the 1-week chat rule).
bool isMediaExpired({required int uploadedAtMs, required int nowMs}) =>
    nowMs >= mediaExpiresAtMs(uploadedAtMs);

/// True when every member EXCEPT the sender has downloaded the
/// file (recorded in downloadedBy, uid → ms). The sender never
/// needs to "download" their own file.
bool allMembersDownloaded({
  required Map<String, int> downloadedBy,
  required List<String> memberIds,
  required String senderId,
}) {
  for (final id in memberIds) {
    if (id == senderId) continue;
    if (!downloadedBy.containsKey(id)) return false;
  }
  return true;
}

/// True when the server file must be deleted: the 24 hours are
/// up, or every member already has it on their own phone.
bool shouldDeleteMediaFromServer({
  required int uploadedAtMs,
  required int nowMs,
  required Map<String, int> downloadedBy,
  required List<String> memberIds,
  required String senderId,
}) =>
    isMediaExpired(uploadedAtMs: uploadedAtMs, nowMs: nowMs) ||
    allMembersDownloaded(
      downloadedBy: downloadedBy,
      memberIds: memberIds,
      senderId: senderId,
    );

String mediaTypeLabel(MediaType type) {
  switch (type) {
    case MediaType.photo:
      return 'Photo';
    case MediaType.video:
      return 'Video';
    case MediaType.audio:
      return 'Audio';
    case MediaType.document:
      return 'Document';
  }
}

/// "2.4 MB" / "850 KB" / "300 B" — for the message row.
String formatMediaSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
