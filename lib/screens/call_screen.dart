import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../core/call_signaling.dart';
import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/call_service.dart';

/// The call screen (v0.6.21) — one screen for all three call
/// moments: incoming (accept / decline), outgoing (ringing,
/// cancel) and in-call (video grid or audio list + controls).
///
/// The screen reads [CallService] through Provider and rebuilds
/// on its notifications. When the call ends (the service goes
/// back to idle), the screen pops itself.
///
/// Video renderers are created here (never in the service):
/// one [RTCVideoRenderer] per remote stream, one for the local
/// preview. A renderer is created the first time its stream
/// appears and disposed when the stream goes away or the screen
/// closes.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  RTCVideoRenderer? _localRenderer;
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _initLocalRenderer();
  }

  Future<void> _initLocalRenderer() async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    if (!mounted) {
      await renderer.dispose();
      return;
    }
    setState(() => _localRenderer = renderer);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _localRenderer?.dispose();
    for (final r in _remoteRenderers.values) {
      unawaited(r.dispose());
    }
    _remoteRenderers.clear();
    super.dispose();
  }

  /// Create (once) and attach renderers for every remote stream
  /// the service currently holds; drop renderers whose stream
  /// went away. Called from build — the async work finishes
  /// with a setState when the renderer is ready.
  void _syncRenderers(CallService calls) {
    final streams = calls.remoteStreams;
    for (final uid in _remoteRenderers.keys.toList()) {
      if (!streams.containsKey(uid)) {
        unawaited(_remoteRenderers.remove(uid)?.dispose());
      }
    }
    for (final e in streams.entries) {
      if (_remoteRenderers.containsKey(e.key)) continue;
      final renderer = RTCVideoRenderer();
      _remoteRenderers[e.key] = renderer;
      unawaited(
        renderer.initialize().then((_) {
          if (!mounted) return;
          renderer.srcObject = e.value;
          setState(() {});
        }),
      );
    }
    final local = _localRenderer;
    if (local != null && calls.localStream != null) {
      local.srcObject = calls.localStream;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(lang.isUrdu, key, args);
    final calls = context.watch<CallService>();
    _syncRenderers(calls);

    // The call ended under us (caller hung up, everyone left):
    // close this screen.
    if (calls.state == CallUiState.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (calls.state == CallUiState.incoming) {
      return _incomingView(context, calls, t, tf);
    }
    if (calls.state == CallUiState.outgoing) {
      return _outgoingView(context, calls, t, tf);
    }
    return _inCallView(context, calls, t, tf);
  }

  Widget _incomingView(
    BuildContext context,
    CallService calls,
    String Function(String) t,
    String Function(String, [Map<String, Object>]) tf,
  ) {
    final call = calls.incomingCall!;
    final isVideo = call.type == CallType.video;
    return Scaffold(
      backgroundColor: Colors.black87,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 48,
              child: Text(
                call.fromName.isEmpty ? '?' : call.fromName[0],
                style: const TextStyle(fontSize: 40),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              call.fromName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isVideo ? t('scr_callIncomingVideo') : t('scr_callIncomingAudio'),
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _roundButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  label: t('scr_callDecline'),
                  onTap: () => unawaited(calls.declineCall()),
                ),
                _roundButton(
                  icon: isVideo ? Icons.videocam : Icons.call,
                  color: Colors.green,
                  label: t('scr_callAccept'),
                  onTap: () async {
                    final error = await calls.answerCall();
                    if (error != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(error)),
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _outgoingView(
    BuildContext context,
    CallService calls,
    String Function(String) t,
    String Function(String, [Map<String, Object>]) tf,
  ) {
    final call = calls.activeCall!;
    final others = call.othersThan(calls.incomingCall?.from ?? '');
    final names = others.map(calls.nameFor).join(', ');
    final isVideo = call.type == CallType.video;
    return Scaffold(
      backgroundColor: Colors.black87,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 48,
              child: Text(
                names.isEmpty ? '?' : names[0],
                style: const TextStyle(fontSize: 40),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              names,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isVideo ? t('scr_callCallingVideo') : t('scr_callCallingAudio'),
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 48),
            _roundButton(
              icon: Icons.call_end,
              color: Colors.red,
              label: t('cancel'),
              onTap: () => unawaited(calls.endCall()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inCallView(
    BuildContext context,
    CallService calls,
    String Function(String) t,
    String Function(String, [Map<String, Object>]) tf,
  ) {
    final call = calls.activeCall!;
    final isVideo = call.type == CallType.video;
    final duration = _formatDuration(calls.callDuration);
    final remoteUids = calls.remoteStreams.keys.toList();
    return Scaffold(
      backgroundColor: Colors.black87,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                isVideo
                    ? tf('scr_callVideoTitle', {'duration': duration})
                    : tf('scr_callAudioTitle', {'duration': duration}),
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ),
            Expanded(
              child: isVideo
                  ? _videoGrid(calls, remoteUids, t)
                  : _audioList(calls, remoteUids, t),
            ),
            _controls(context, calls, isVideo, t),
          ],
        ),
      ),
    );
  }

  Widget _videoGrid(
    CallService calls,
    List<String> remoteUids,
    String Function(String) t,
  ) {
    if (remoteUids.isEmpty) {
      return Center(
        child: Text(
          t('scr_callConnecting'),
          style: const TextStyle(color: Colors.white70, fontSize: 18),
        ),
      );
    }
    return Stack(
      children: [
        GridView.count(
          crossAxisCount: remoteUids.length == 1 ? 1 : 2,
          children: [
            for (final uid in remoteUids)
              Stack(
                fit: StackFit.expand,
                children: [
                  if (_remoteRenderers[uid] != null)
                    RTCVideoView(_remoteRenderers[uid]!),
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        calls.nameFor(uid),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        // My own preview, bottom-right.
        if (_localRenderer != null && calls.localStream != null)
          Positioned(
            right: 12,
            bottom: 12,
            width: 110,
            height: 150,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: RTCVideoView(_localRenderer!, mirror: true),
            ),
          ),
      ],
    );
  }

  Widget _audioList(
    CallService calls,
    List<String> remoteUids,
    String Function(String) t,
  ) {
    final call = calls.activeCall!;
    final allUids = <String>{
      ...call.joinedUids,
      ...remoteUids,
    }.toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final uid in allUids)
          ListTile(
            leading: CircleAvatar(
              child: Text(calls.nameFor(uid)[0]),
            ),
            title: Text(
              calls.nameFor(uid),
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              uid == calls.activeCall!.from
                  ? t('scr_callCaller')
                  : t('scr_callInCall'),
              style: const TextStyle(color: Colors.white70),
            ),
            trailing: const Icon(Icons.mic, color: Colors.green),
          ),
        if (allUids.isEmpty)
          Center(
            child: Text(
              t('scr_callConnecting'),
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ),
      ],
    );
  }

  Widget _controls(
    BuildContext context,
    CallService calls,
    bool isVideo,
    String Function(String) t,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _roundButton(
            icon: calls.isMuted ? Icons.mic_off : Icons.mic,
            color: calls.isMuted ? Colors.orange : Colors.white24,
            label: calls.isMuted ? t('scr_callUnmute') : t('scr_callMute'),
            onTap: calls.toggleMute,
          ),
          _roundButton(
            icon: calls.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
            color: calls.isSpeakerOn ? Colors.orange : Colors.white24,
            label: t('scr_callSpeaker'),
            onTap: () => unawaited(calls.toggleSpeaker()),
          ),
          if (isVideo) ...[
            _roundButton(
              icon: calls.isCameraOff ? Icons.videocam_off : Icons.videocam,
              color: calls.isCameraOff ? Colors.orange : Colors.white24,
              label: t('scr_callCamera'),
              onTap: calls.toggleCamera,
            ),
            _roundButton(
              icon: Icons.cameraswitch,
              color: Colors.white24,
              label: t('scr_callFlip'),
              onTap: () => unawaited(calls.switchCamera()),
            ),
          ],
          _roundButton(
            icon: Icons.call_end,
            color: Colors.red,
            label: t('scr_callEnd'),
            onTap: () => unawaited(calls.endCall()),
          ),
        ],
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: CircleAvatar(
            radius: 28,
            backgroundColor: color,
            child: Icon(icon, color: Colors.white),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
