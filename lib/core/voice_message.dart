// Voice messages (v0.6.29) — WhatsApp-style hold-to-record.
//
// A voice message is an audio media message: the recording is an
// .m4a file (AAC), uploaded through the same media pipeline as a
// photo or video (MediaService.uploadMedia) and shown with the same
// 24-hour / all-downloaded server removal. That means voice notes
// share the Storage situation: they cannot reach the other phone
// until a file host exists (Cloudinary free or Firebase Blaze —
// the user's decision is still pending). Recording itself works
// offline; the send fails with the plain upload error until then.

/// Voice recordings are saved as `voice_<epoch-ms>.m4a`.
String voiceMessageFileName(int nowMs) => 'voice_$nowMs.m4a';

/// Recordings shorter than this are accidental taps, not messages
/// — discard them instead of sending a 0-second voice note.
const int minVoiceMessageMs = 1000;

/// True when the recording is too short to send.
bool isVoiceMessageTooShort({required int durationMs}) =>
    durationMs < minVoiceMessageMs;
