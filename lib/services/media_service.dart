import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';

import '../core/media_share.dart';
import '../l10n/strings.dart';
import '../models/chat_message.dart';
import 'sync_service.dart';

/// Media sharing (v0.6.23) — pick, compress, upload, download,
/// prune. The server parts live in [SyncService] (chat nodes);
/// this owns the file parts (pickers, compression, Storage, the
/// phone's gallery / share sheet).
///
/// Flow: pick → compress → upload to Storage → send the chat
/// message with the download URL (SyncService.sendMediaMessage).
/// Download: Storage → temp file → gallery (photo/video) or the
/// share sheet (audio/document — the user picks where it goes) →
/// mark downloaded → when every member has it, delete the
/// Storage file. Expired (24 h) files are pruned when any member
/// opens the chat (throttled to once a day per phone).
class MediaService {
  MediaService(this.sync);

  final SyncService sync;

  /// Storage path for a file: circles/{circle}/media/{sender}/
  /// {messageId}/{fileName}. The sender uid in the path is what
  /// the Storage rules check for uploads (see storage.rules).
  static String storagePath({
    required String circleId,
    required String senderUid,
    required String messageId,
    required String fileName,
  }) =>
      'circles/$circleId/media/$senderUid/$messageId/$fileName';

  /// Pick a file and compress it. Returns (file, error): the file
  /// is null when the user cancelled (error is then null too) or
  /// when something failed (error names it). Photos are shrunk
  /// to 1280 px / quality 80; videos are re-encoded to medium
  /// quality; audio and documents go as-is. Files over 100 MB
  /// are refused before upload.
  Future<(File?, String?)> pickAndCompress(
    MediaType type, {
    bool fromCamera = false,
    bool isUrdu = false,
  }) async {
    try {
      File? picked;
      switch (type) {
        case MediaType.photo:
          final x = await ImagePicker().pickImage(
            source: fromCamera ? ImageSource.camera : ImageSource.gallery,
          );
          if (x == null) return (null, null);
          picked = File(x.path);
          final dir = await getTemporaryDirectory();
          final target =
              '${dir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.jpg';
          final compressed = await FlutterImageCompress.compressAndGetFile(
            picked.path,
            target,
            minWidth: photoMaxDimension,
            minHeight: photoMaxDimension,
            quality: photoQuality,
          );
          picked = compressed == null ? picked : File(compressed.path);
        case MediaType.video:
          final x = await ImagePicker().pickVideo(
            source: fromCamera ? ImageSource.camera : ImageSource.gallery,
          );
          if (x == null) return (null, null);
          final info = await VideoCompress.compressVideo(
            x.path,
            quality: VideoQuality.MediumQuality,
          );
          picked = info?.file;
          if (picked == null) {
            return (null, tr(isUrdu, 'svc_mediaVideoCompressFailed'));
          }
        case MediaType.audio:
          final r = await FilePicker.pickFiles(
            type: FileType.audio,
            allowMultiple: false,
          );
          final p = r?.files.single.path;
          if (p == null) return (null, null);
          picked = File(p);
        case MediaType.document:
          final r = await FilePicker.pickFiles(
            type: FileType.any,
            allowMultiple: false,
          );
          final p = r?.files.single.path;
          if (p == null) return (null, null);
          picked = File(p);
      }
      final size = await picked.length();
      if (size > maxMediaBytes) {
        return (null, tr(isUrdu, 'svc_mediaFileTooLarge'));
      }
      return (picked, null);
    } catch (e) {
      return (null, trf(isUrdu, 'svc_mediaFileNotFound', {'e': e.toString()}));
    }
  }

  /// Upload [file] to Firebase Storage. Returns (downloadUrl,
  /// error). The caller writes the chat message afterwards with
  /// the URL + [storagePath].
  Future<(String?, String?)> uploadMedia({
    required String circleId,
    required String messageId,
    required File file,
    required String fileName,
    bool isUrdu = false,
  }) async {
    final uid = sync.uid;
    if (!sync.isAvailable || uid == null) {
      return (null, tr(isUrdu, 'svc_mediaNoInternetSend'));
    }
    try {
      final path = storagePath(
        circleId: circleId,
        senderUid: uid,
        messageId: messageId,
        fileName: fileName,
      );
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      return (url, null);
    } catch (e) {
      return (null, trf(isUrdu, 'svc_mediaUploadFailed', {'e': e.toString()}));
    }
  }

  /// Download a shared file to THIS phone and record the
  /// download. Returns (true, message) on success. Photos and
  /// videos go straight into the gallery; audio and documents
  /// open the share sheet, so the user picks where they go
  /// (Files / Downloads) — a cancelled share is NOT counted as
  /// a download. After a successful download the file is marked
  /// downloaded, and when every member has it, the Storage file
  /// is deleted (best effort — the UI derives "removed" from
  /// downloadedBy anyway).
  Future<(bool, String)> downloadMedia({
    required ChatMessage m,
    required List<String> memberIds,
    bool isUrdu = false,
  }) async {
    final circleId = sync.activeCircleId;
    final url = m.mediaUrl;
    final path = m.storagePath;
    if (!sync.isAvailable || circleId == null || url == null || path == null) {
      return (false, tr(isUrdu, 'svc_mediaNoInternetDownload'));
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final uploadedAt = m.mediaUploadedAtMs ?? m.atMs;
    if (isMediaExpired(uploadedAtMs: uploadedAt, nowMs: nowMs)) {
      return (false, tr(isUrdu, 'svc_mediaExpired24h'));
    }
    try {
      final dir = await getTemporaryDirectory();
      final local = File(
        '${dir.path}/apnacircle_${m.id}_${m.fileName ?? 'file'}',
      );
      await FirebaseStorage.instance.ref(path).writeToFile(local);
      final type = m.mediaType ?? MediaType.document;
      if (type == MediaType.photo) {
        await Gal.putImage(local.path);
      } else if (type == MediaType.video) {
        await Gal.putVideo(local.path);
      } else {
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(local.path)],
            text: m.fileName ?? tr(isUrdu, 'svc_mediaShareFallback'),
          ),
        );
        if (result.status != ShareResultStatus.success) {
          return (false, tr(isUrdu, 'svc_mediaSaveCancelled'));
        }
      }
      await sync.markMediaDownloaded(circleId, m.id);
      // Everyone has it now — delete the server copy.
      final downloaded = Map<String, int>.from(m.downloadedBy)
        ..[sync.uid ?? ''] = nowMs;
      if (allMembersDownloaded(
        downloadedBy: downloaded,
        memberIds: memberIds,
        senderId: m.senderId,
      )) {
        try {
          await FirebaseStorage.instance.ref(path).delete();
        } catch (_) {
          // Best effort — the prune catches it on the next chat
          // open, and the UI already shows it as removed.
        }
      }
      final savedWhere = type == MediaType.photo || type == MediaType.video
          ? tr(isUrdu, 'svc_mediaSavedGallery')
          : tr(isUrdu, 'svc_mediaSaved');
      return (true, savedWhere);
    } catch (e) {
      return (false, trf(isUrdu, 'svc_mediaDownloadFailed', {'e': e.toString()}));
    }
  }

  /// Delete expired / fully-downloaded media files from Storage.
  /// Runs at most once a day per phone. Returns how many files
  /// were deleted. The chat messages themselves stay — only the
  /// files go (the message follows the 1-week chat rule).
  Future<int> pruneExpiredMedia({
    required String circleId,
    required List<String> memberIds,
  }) async {
    if (!sync.isAvailable) return 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastKey = 'media_prune_last_$circleId';
      final last = prefs.getInt(lastKey) ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - last < const Duration(days: 1).inMilliseconds) {
        return 0;
      }
      final messages = await sync.readChatMessages(circleId);
      int removed = 0;
      for (final m in messages) {
        if (removed >= 50) break;
        if (!m.hasMedia || m.storagePath == null) continue;
        final uploadedAt = m.mediaUploadedAtMs ?? m.atMs;
        if (!shouldDeleteMediaFromServer(
          uploadedAtMs: uploadedAt,
          nowMs: nowMs,
          downloadedBy: m.downloadedBy,
          memberIds: memberIds,
          senderId: m.senderId,
        )) {
          continue;
        }
        try {
          await FirebaseStorage.instance.ref(m.storagePath!).delete();
          removed++;
        } catch (_) {
          // Already gone (another phone deleted it first) — fine.
        }
      }
      await prefs.setInt(lastKey, nowMs);
      return removed;
    } catch (_) {
      return 0;
    }
  }
}
