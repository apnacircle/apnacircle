import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/chat_delete.dart';
import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../core/chat_paging.dart';
import '../core/chat_receipts.dart';
import '../core/media_share.dart';
import '../models/chat_message.dart';
import '../services/auth_service.dart';
import '../services/chat_delete_service.dart';
import '../services/family_service.dart';
import '../services/media_service.dart';
import '../services/notification_service.dart';
import '../services/sync_service.dart';
import '../services/voice_message_service.dart';

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
      text: '__DEMO_SEED_REACHED_HOME__', // localised in build() (demo seed)
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
  // v0.6.23 media sharing: message ids currently downloading
  // (their button shows a spinner instead), and whether a media
  // send (pick → compress → upload) is in flight.
  final Set<String> _downloadingIds = {};
  bool _sendingMedia = false;
  // v0.6.29 voice messages: hold-to-record state + the timer
  // shown while recording, and in-chat audio playback (one player:
  // tapping another voice note stops the one playing).
  bool _recordingVoice = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  final _audioPlayer = AudioPlayer();
  String? _playingAudioId;

  @override
  void initState() {
    super.initState();
    _notifications = context.read<NotificationService>();
    // v0.6.29: when a voice note finishes playing, its row goes
    // back to the play icon.
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingAudioId = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sync = context.read<SyncService>();
      if (!sync.isAvailable || sync.activeCircleId == null) return;
      // v0.6.11: this chat is open now — suppress its notifications.
      _notifications?.openChatCircleId = sync.activeCircleId;
      // v0.6.21: 1-week retention — prune expired messages from the
      // server (at most once a day per phone, inside the call).
      unawaited(sync.pruneOldChatMessages(sync.activeCircleId!));
      // v0.6.23: media prune — delete expired / fully-downloaded
      // files from Storage (at most once a day per phone).
      final family = context.read<FamilyService>();
      unawaited(context.read<MediaService>().pruneExpiredMedia(
            circleId: sync.activeCircleId!,
            memberIds: family.members.map((m) => m.id).toList(),
          ));
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
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(isUrdu, key, args);
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
              Text(
                t('scr_chatMessageInfo'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                      ? Text(
                          t('scr_chatNotReadYet'),
                          style: const TextStyle(color: Colors.grey),
                        )
                      : Text(
                          tf('scr_chatReadAt', {
                            'time': formatReadTime(
                              row.readAt!,
                              isUrdu: isUrdu,
                            ),
                          }),
                          style: const TextStyle(color: Colors.green),
                        ),
                ),
              if (rows.isEmpty)
                Text(
                  t('scr_chatNoOneElse'),
                  style: const TextStyle(color: Colors.grey),
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
    _recordTimer?.cancel();
    _audioPlayer.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
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
              t('scr_chatMe'),
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

  /// Media sharing (v0.6.23): the attach sheet — Photo / Video /
  /// Audio / Document. Demo mode (no sync) refuses with a plain
  /// message: there is no server to upload to.
  Future<void> _showAttachSheet() async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final sync = context.read<SyncService>();
    if (!sync.isAvailable || sync.activeCircleId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('scr_chatMediaNeedsInternet')),
        ),
      );
      return;
    }
    final choice = await showModalBottomSheet<MediaType>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo),
              title: Text(mediaTypeLabel(MediaType.photo, isUrdu: isUrdu)),
              subtitle: Text(t('scr_chatPhotoCompressed')),
              onTap: () => Navigator.pop(ctx, MediaType.photo),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: Text(mediaTypeLabel(MediaType.video, isUrdu: isUrdu)),
              subtitle: Text(t('scr_chatVideoSmaller')),
              onTap: () => Navigator.pop(ctx, MediaType.video),
            ),
            ListTile(
              leading: const Icon(Icons.audiotrack),
              title: Text(mediaTypeLabel(MediaType.audio, isUrdu: isUrdu)),
              onTap: () => Navigator.pop(ctx, MediaType.audio),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: Text(mediaTypeLabel(MediaType.document, isUrdu: isUrdu)),
              onTap: () => Navigator.pop(ctx, MediaType.document),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text(t('cancel')),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    unawaited(_sendMedia(choice));
  }

  /// Media sharing (v0.6.23): pick → compress → upload → send
  /// the chat message. The message appears on every phone through
  /// the normal live subscription.
  Future<void> _sendMedia(MediaType type) async {
    if (_sendingMedia) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final sync = context.read<SyncService>();
    final media = context.read<MediaService>();
    final circleId = sync.activeCircleId;
    if (circleId == null) return;
    setState(() => _sendingMedia = true);
    _snack(t('scr_chatSending'));
    final (file, pickError) =
        await media.pickAndCompress(type, isUrdu: isUrdu);
    if (!mounted) return;
    if (pickError != null) {
      setState(() => _sendingMedia = false);
      _snack(pickError);
      return;
    }
    if (file == null) {
      // User cancelled the picker.
      setState(() => _sendingMedia = false);
      return;
    }
    final fileName = file.path.split('/').last;
    await _uploadAndSendMediaFile(
      file: file,
      type: type,
      fileName: fileName,
    );
  }

  /// Upload one file and send it as a media message. Called by
  /// [_sendMedia] (after picking/compressing) and by
  /// [_sendVoiceMessage] (after recording). Assumes [_sendingMedia]
  /// is already true; clears it on every path out.
  Future<void> _uploadAndSendMediaFile({
    required File file,
    required MediaType type,
    required String fileName,
  }) async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final sync = context.read<SyncService>();
    final family = context.read<FamilyService>();
    final auth = context.read<AuthService>();
    final media = context.read<MediaService>();
    final circleId = sync.activeCircleId;
    if (circleId == null) {
      if (mounted) setState(() => _sendingMedia = false);
      return;
    }
    final messageId = sync.newChatMessageKey(circleId);
    final (url, uploadError) = await media.uploadMedia(
      circleId: circleId,
      messageId: messageId,
      file: file,
      fileName: fileName,
      isUrdu: isUrdu,
    );
    if (!mounted) return;
    if (uploadError != null || url == null) {
      setState(() => _sendingMedia = false);
      _snack(uploadError ?? t('scr_chatUploadFailed'));
      return;
    }
    final size = await file.length();
    final mine = family.myMember;
    final ok = await sync.sendMediaMessage(
      circleId,
      ChatMessage(
        id: messageId,
        senderId: sync.uid ?? 'me',
        senderName: mine?.name ??
            auth.displayName ??
            auth.phoneNumber ??
            t('scr_chatMe'),
        text: fileName,
        at: DateTime.now(),
        mediaType: type,
        mediaUrl: url,
        storagePath: MediaService.storagePath(
          circleId: circleId,
          senderUid: sync.uid ?? 'me',
          messageId: messageId,
          fileName: fileName,
        ),
        fileName: fileName,
        fileSize: size,
        mediaUploadedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!mounted) return;
    setState(() => _sendingMedia = false);
    _snack(ok ? t('scr_chatSent') : t('scr_chatSendFailed'));
  }

  /// Voice message (v0.6.29) — hold the mic to start recording.
  /// Demo mode / no circle: refuse with the plain-words reason
  /// (same as the attach button).
  Future<void> _startVoiceRecording() async {
    if (_recordingVoice || _sendingMedia) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final sync = context.read<SyncService>();
    if (!sync.isAvailable || sync.activeCircleId == null) {
      _snack(t('scr_chatVoiceNeedsInternet'));
      return;
    }
    final voice = context.read<VoiceMessageService>();
    final (_, error) = await voice.startRecording(isUrdu: isUrdu);
    if (!mounted) return;
    if (error != null) {
      _snack(error);
      return;
    }
    setState(() {
      _recordingVoice = true;
      _recordSeconds = 0;
    });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordSeconds++);
    });
  }

  /// Release the mic: stop and send the recording. A too-short
  /// recording is discarded with the plain-words reason.
  Future<void> _finishVoiceRecording() async {
    if (!_recordingVoice) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    _recordTimer?.cancel();
    setState(() => _recordingVoice = false);
    final voice = context.read<VoiceMessageService>();
    final (file, error) = await voice.stopRecording(isUrdu: isUrdu);
    if (!mounted) return;
    if (error != null || file == null) {
      _snack(error ?? t('scr_chatRecordingFailed'));
      return;
    }
    await _sendVoiceMessage(file);
  }

  /// Cancel a recording in progress (the Cancel button on the
  /// recording banner, or the long-press cancelled).
  Future<void> _cancelVoiceRecording() async {
    if (!_recordingVoice) return;
    _recordTimer?.cancel();
    setState(() => _recordingVoice = false);
    await context.read<VoiceMessageService>().cancelRecording();
  }

  /// Send a finished recording as an audio media message.
  Future<void> _sendVoiceMessage(File file) async {
    if (_sendingMedia) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    setState(() => _sendingMedia = true);
    _snack(t('scr_chatSending'));
    await _uploadAndSendMediaFile(
      file: file,
      type: MediaType.audio,
      fileName: file.path.split('/').last,
    );
  }

  /// Voice-note playback (v0.6.29): stream the audio from its
  /// media URL. Tapping again (or another note) stops it. A
  /// removed note has no URL and shows the removed line instead.
  Future<void> _toggleAudio(ChatMessage m) async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    if (_playingAudioId == m.id) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _playingAudioId = null);
      return;
    }
    if (m.mediaUrl == null) return;
    await _audioPlayer.stop();
    try {
      await _audioPlayer.play(UrlSource(m.mediaUrl!));
      if (!mounted) return;
      setState(() => _playingAudioId = m.id);
    } catch (_) {
      _snack(t('scr_chatPlayFailed'));
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Media sharing (v0.6.23): download one shared file to this
  /// phone. Photos/videos land in the gallery; audio/documents
  /// open the share sheet (the user picks where they go).
  Future<void> _downloadMedia(ChatMessage m) async {
    if (_downloadingIds.contains(m.id)) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    final family = context.read<FamilyService>();
    setState(() => _downloadingIds.add(m.id));
    final (ok, message) = await context.read<MediaService>().downloadMedia(
          m: m,
          memberIds: family.members.map((e) => e.id).toList(),
          isUrdu: isUrdu,
        );
    if (!mounted) return;
    setState(() => _downloadingIds.remove(m.id));
    _snack(message);
    if (ok) setState(() {});
  }

  /// Media sharing (v0.6.23): one shared file's row — thumbnail
  /// (photo), play tile (video), or file line (audio/document),
  /// with Download / Downloaded / Removed states. "Removed"
  /// means the server file is gone: 24 hours passed, or every
  /// member already downloaded it. The chat message itself stays
  /// until the 1-week chat rule.
  Widget _mediaRow(ChatMessage m, {required bool isUrdu}) {
    String t(String key) => tr(isUrdu, key);
    final sync = context.read<SyncService>();
    final family = context.read<FamilyService>();
    final memberIds = family.members.map((e) => e.id).toList();
    final myUid = sync.isAvailable ? (sync.uid ?? '') : 'me';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final uploadedAt = m.mediaUploadedAtMs ?? m.atMs;
    final expired = isMediaExpired(uploadedAtMs: uploadedAt, nowMs: nowMs);
    final allDownloaded = allMembersDownloaded(
      downloadedBy: m.downloadedBy,
      memberIds: memberIds,
      senderId: m.senderId,
    );
    final iDownloaded = m.downloadedBy.containsKey(myUid);
    final removed = expired || allDownloaded;
    final type = m.mediaType ?? MediaType.document;
    final sizeLabel = m.fileSize == null
        ? ''
        : ' · ${formatMediaSize(m.fileSize!)}';
    final downloading = _downloadingIds.contains(m.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (type == MediaType.photo && !removed && m.mediaUrl != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              m.mediaUrl!,
              height: 180,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const SizedBox(
                height: 120,
                child: Center(child: Icon(Icons.broken_image)),
              ),
            ),
          )
        else if (type == MediaType.video && !removed)
          Container(
            height: 120,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.play_circle_fill,
                    color: Colors.white, size: 44),
                const SizedBox(height: 4),
                Text(
                  '${mediaTypeLabel(MediaType.video, isUrdu: isUrdu)}$sizeLabel',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          )
        else
          Row(
            children: [
              // v0.6.29: voice notes play in the chat — tap to
              // listen, tap again to stop. (Documents keep the
              // file line; photos/videos use the tiles above.)
              if (type == MediaType.audio && !removed && m.mediaUrl != null)
                IconButton(
                  icon: Icon(
                    _playingAudioId == m.id
                        ? Icons.stop_circle
                        : Icons.play_circle_fill,
                  ),
                  tooltip: _playingAudioId == m.id
                      ? t('scr_chatStop')
                      : t('scr_chatPlay'),
                  onPressed: () => _toggleAudio(m),
                ),
              Icon(
                type == MediaType.audio
                    ? Icons.audiotrack
                    : Icons.insert_drive_file,
                size: 20,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${mediaTypeLabel(type, isUrdu: isUrdu)}: ${m.fileName ?? m.text}$sizeLabel',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        const SizedBox(height: 6),
        if (removed)
          Text(
            t('scr_chatMediaRemoved'),
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          )
        else if (downloading)
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(t('scr_chatDownloading'),
                  style: const TextStyle(fontSize: 12)),
            ],
          )
        else if (iDownloaded)
          Text(
            t('scr_chatDownloaded'),
            style: const TextStyle(fontSize: 12, color: Colors.green),
          )
        else
          FilledButton.tonal(
            onPressed: () => _downloadMedia(m),
            child: Text(t('scr_chatDownload')),
          ),
      ],
    );
  }

  /// Long-press a message (v0.6.21): delete it for me (any
  /// message, this phone only) or for everyone (my own messages
  /// only — the server rules enforce the same). Demo mode (no
  /// sync) has no "for everyone": there is no server to delete
  /// from.
  Future<void> _showMessageMenu(ChatMessage m) async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
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
              title: Text(t('scr_chatDeleteForMe')),
              subtitle: Text(t('scr_chatDeleteForMeHint')),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: Text(t('scr_chatDeleteForEveryone')),
                subtitle: Text(t('scr_chatDeleteForEveryoneHint')),
                onTap: () => Navigator.pop(ctx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text(t('cancel')),
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
        SnackBar(content: Text(t('scr_chatDeletedForYou'))),
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
        SnackBar(content: Text(t('scr_chatDeletedForEveryone'))),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('scr_chatDeleteFailed')),
        ),
      );
    }
  }

  /// Clear the WHOLE chat on this phone (v0.6.21): everything
  /// sent up to now is hidden here; new messages still arrive.
  /// Other phones are untouched.
  Future<void> _confirmClearChat() async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('scr_chatClearTitle')),
        content: Text(t('scr_chatClearBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('scr_chatClear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<ChatDeleteService>().clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('scr_chatCleared'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(lang.isUrdu, key, args);
    // v0.6.32: the demo seed message is localised at display time
    // (it is created in the field initialiser, before context
    // exists, so it cannot call tr() there).
    final demoSeed = _messages
        .where((m) => m.id == '1' && m.senderId == 'ali')
        .firstOrNull;
    if (demoSeed != null && demoSeed.text == '__DEMO_SEED_REACHED_HOME__') {
      final i = _messages.indexOf(demoSeed);
      _messages[i] = ChatMessage(
        id: demoSeed.id,
        senderId: demoSeed.senderId,
        senderName: demoSeed.senderName,
        text: t('scr_chatDemoSeed'),
        at: demoSeed.at,
      );
    }
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
              Text(
                t('scr_chatFamilyChat'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('scr_chatAutoDelete'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                tooltip: t('scr_chatOptions'),
                onSelected: (value) {
                  if (value == 'clear') {
                    unawaited(_confirmClearChat());
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem<String>(
                    value: 'clear',
                    child: Text(t('scr_chatClearChat')),
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
                        _loadingOlder
                            ? t('scr_chatLoading')
                            : t('scr_chatLoadOlder'),
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
                            if (m.hasMedia)
                              _mediaRow(m, isUrdu: lang.isUrdu)
                            else
                              Text(m.text),
                            if (mine && readN > 0)
                              Text(
                                tf('scr_chatReadBy', {'count': readN}),
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
        // v0.6.29 recording banner: while the mic is held, the
        // input row becomes a timer + Cancel — release to send.
        if (_recordingVoice)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.mic, color: Colors.red),
                const SizedBox(width: 8),
                Text(tf('scr_chatRecordingBanner',
                    {'seconds': _recordSeconds})),
                const Spacer(),
                TextButton(
                  onPressed: _cancelVoiceRecording,
                  child: Text(t('cancel')),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // v0.6.29: WhatsApp-style input — the attach button
              // sits INSIDE the round text box (suffixIcon), not
              // outside it.
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: InputDecoration(
                    hintText: t('scr_chatMessageHint'),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.attach_file),
                      tooltip: t('scr_chatAttachTooltip'),
                      onPressed:
                          _sendingMedia ? null : _showAttachSheet,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // v0.6.29: WhatsApp-style trailing button — mic while
              // the box is empty (HOLD to record, release to
              // send), send circle once text is typed.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _ctrl,
                builder: (context, value, _) {
                  if (value.text.trim().isNotEmpty) {
                    return CircleAvatar(
                      child: IconButton(
                        icon: const Icon(Icons.send),
                        tooltip: t('scr_chatSend'),
                        onPressed: _send,
                      ),
                    );
                  }
                  return GestureDetector(
                    onLongPressStart: (_) => _startVoiceRecording(),
                    onLongPressEnd: (_) => _finishVoiceRecording(),
                    onLongPressCancel: _cancelVoiceRecording,
                    child: CircleAvatar(
                      backgroundColor:
                          _recordingVoice ? Colors.red : null,
                      child: Icon(
                        _recordingVoice ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
