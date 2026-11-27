import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/voice_message.dart';

/// Voice-message recording (v0.6.29) — WhatsApp-style hold to
/// record, release to send.
///
/// One [AudioRecorder] per recording (created on start, stopped on
/// stop/cancel), so there is no long-lived native recorder to
/// dispose. Every failure returns a plain-words error string
/// instead of throwing — the UI shows it in a SnackBar, and a
/// widget test (no mic plugin) hits the same path.
///
/// The microphone permission is requested by the recorder itself
/// ([AudioRecorder.hasPermission]); RECORD_AUDIO is already in
/// AndroidManifest.xml (added for calls in v0.6.21).
class VoiceMessageService {
  AudioRecorder? _recorder;
  String? _currentPath;
  int? _startedAtMs;

  /// Start recording to a temp .m4a file. Returns (file, null) on
  /// success, (null, error) when the mic is unavailable or the
  /// permission is denied. The file only exists after [stopRecording].
  Future<(File?, String?)> startRecording() async {
    try {
      final recorder = AudioRecorder();
      final ok = await recorder.hasPermission();
      if (!ok) {
        await recorder.dispose();
        return (
          null,
          'Mic ki permission nahi mili — Settings se mic ON karo.',
        );
      }
      final dir = await getTemporaryDirectory();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/${voiceMessageFileName(nowMs)}';
      await recorder.start(const RecordConfig(), path: path);
      _recorder = recorder;
      _currentPath = path;
      _startedAtMs = nowMs;
      return (File(path), null);
    } catch (e) {
      return (null, 'Recording nahi ho saki ($e).');
    }
  }

  /// Stop and return the recorded file, or (null, error). A
  /// recording shorter than [minVoiceMessageMs] is discarded as an
  /// accidental tap — the file is deleted and the caller gets the
  /// plain-words reason.
  Future<(File?, String?)> stopRecording() async {
    final recorder = _recorder;
    final path = _currentPath;
    final startedAtMs = _startedAtMs;
    _recorder = null;
    _currentPath = null;
    _startedAtMs = null;
    if (recorder == null || path == null) {
      return (null, 'Recording nahi ho saki.');
    }
    try {
      await recorder.stop();
    } catch (e) {
      await recorder.dispose();
      return (null, 'Recording nahi ho saki ($e).');
    } finally {
      await recorder.dispose();
    }
    final file = File(path);
    final durationMs = startedAtMs == null
        ? 0
        : DateTime.now().millisecondsSinceEpoch - startedAtMs;
    if (isVoiceMessageTooShort(durationMs: durationMs)) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return (null, 'Bohat chhoti recording — dobara dabayein.');
    }
    if (!await file.exists()) {
      return (null, 'Recording save nahi hui.');
    }
    return (file, null);
  }

  /// Discard the in-progress recording (user cancelled).
  Future<void> cancelRecording() async {
    final recorder = _recorder;
    final path = _currentPath;
    _recorder = null;
    _currentPath = null;
    _startedAtMs = null;
    if (recorder == null) return;
    try {
      await recorder.stop();
    } catch (_) {}
    await recorder.dispose();
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}
