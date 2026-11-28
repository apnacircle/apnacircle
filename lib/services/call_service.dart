import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/call_signaling.dart';
import '../l10n/strings.dart';
import '../models/member.dart';
import 'family_service.dart';
import 'firebase_config.dart';
import 'sync_service.dart';

/// Audio + video calls between circle members (v0.6.21).
///
/// Tap a member's picture to call them (audio or video); a group
/// call invites several members at once (conference); ANY member
/// can call ANY member — calls are not a parent-only feature.
///
/// Transport: WebRTC peer-to-peer media (phones talk directly),
/// signaling through the Realtime Database node
/// `circles/{circleId}/calls/{callId}` (see call_signaling.dart
/// for the node shape). Group calls are a mesh: every phone
/// connects to every other phone in the call.
///
/// What this service does NOT do (honest limits, v1):
/// * No TURN relay — Google's free public STUN only. Phones
///   behind strict NATs may fail to connect.
/// * No ringing while the receiver's app is fully killed — the
///   incoming call is only heard while the app runs (open or
///   background with the location service alive).
/// * A call needs internet on BOTH phones; offline, startCall
///   returns an error string instead of starting.
///
/// The UI ([CallScreen]) reads this service through Provider and
/// rebuilds on [notifyListeners]; the Home screen subscribes to
/// [incomingCalls] and opens the incoming-call screen.
enum CallUiState { idle, outgoing, incoming, inCall }

class CallService extends ChangeNotifier {
  CallService({
    required FamilyService family,
    this.onIncomingCall,
  }) : _family = family {
    _family.addListener(_onFamilyChanged);
    _listenToCalls();
  }

  final FamilyService _family;

  /// Fired (once per call) when a ringing call arrives for me —
  /// main.dart wires it to the loud incoming-call notification.
  final Future<void> Function(CallInfo call)? onIncomingCall;

  DatabaseReference get _root => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: FirebaseConfig.databaseUrl,
      ).ref();

  String? get _circleId => _family.activeCircleId;
  String? get _myUid => _family.myId;
  String _myName({bool isUrdu = false}) =>
      _family.myMember?.name ?? tr(isUrdu, 'family');

  final List<StreamSubscription<DatabaseEvent>> _subs = [];
  final _incomingController = StreamController<CallInfo>.broadcast();

  /// A ringing call for me, not yet answered/declined.
  Stream<CallInfo> get incomingCalls => _incomingController.stream;

  CallInfo? _incomingCall;
  CallInfo? get incomingCall => _incomingCall;

  CallInfo? _activeCall;
  CallInfo? get activeCall => _activeCall;

  CallUiState get state {
    if (_incomingCall != null) return CallUiState.incoming;
    if (_activeCall == null) return CallUiState.idle;
    if (_activeCall!.state == CallState.active) return CallUiState.inCall;
    return CallUiState.outgoing;
  }

  /// My local camera/mic stream (null until a call starts).
  MediaStream? _localStream;
  MediaStream? get localStream => _localStream;

  /// Remote streams by peer uid.
  final Map<String, MediaStream> _remoteStreams = {};
  Map<String, MediaStream> get remoteStreams =>
      Map.unmodifiable(_remoteStreams);

  /// Display names of the remote peers (from the members list).
  String nameFor(String uid, {bool isUrdu = false}) {
    for (final m in _family.members) {
      if (m.id == uid) return m.name;
    }
    return tr(isUrdu, 'family');
  }

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _isCameraOff = false;
  bool get isCameraOff => _isCameraOff;

  bool _isSpeakerOn = false;
  bool get isSpeakerOn => _isSpeakerOn;

  DateTime? _activeSince;
  Duration get callDuration => _activeSince == null
      ? Duration.zero
      : DateTime.now().difference(_activeSince!);

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Set<String> _appliedAnswers = {};
  final Map<String, Set<String>> _addedCandidates = {};
  Timer? _ringTimer;

  // --- Listening -------------------------------------------------

  void _onFamilyChanged() {
    // A new circle (or a fresh sign-in) means a new calls node.
    _listenToCalls();
  }

  void _listenToCalls() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final circleId = _circleId;
    if (circleId == null || !_family.isSynced) return;
    final callsRef = _root.child(FirebaseConfig.circleCallsPath(circleId));
    _subs.add(
      callsRef.onChildAdded.listen((event) {
        _onCallAdded(event.snapshot);
      }),
    );
    _subs.add(
      callsRef.onChildChanged.listen((event) {
        _onCallChanged(event.snapshot);
      }),
    );
  }

  void _onCallAdded(DataSnapshot snapshot) {
    final call = _parseCall(snapshot);
    if (call == null) return;
    final myUid = _myUid;
    if (myUid == null) return;
    // My own outgoing call: tracked by startCall, not as incoming.
    if (call.from == myUid) return;
    // A ringing call for me, fresh enough, while I am free.
    if (!call.isRingingFor(myUid)) return;
    if (isCallStale(call, nowMs: DateTime.now().millisecondsSinceEpoch)) {
      return;
    }
    if (_activeCall != null || _incomingCall != null) return;
    _incomingCall = call;
    _incomingController.add(call);
    unawaited(onIncomingCall?.call(call));
    notifyListeners();
  }

  void _onCallChanged(DataSnapshot snapshot) {
    final call = _parseCall(snapshot);
    if (call == null) return;
    final myUid = _myUid;
    if (myUid == null) return;
    // A call that ended: close everything on my side.
    if (call.state == CallState.ended) {
      if (_activeCall?.id == call.id || _incomingCall?.id == call.id) {
        unawaited(_closeCallLocally());
      }
      return;
    }
    // Not my call — ignore.
    if (_activeCall?.id != call.id) return;
    _activeCall = call;
    // The call went live when the first callee joined.
    if (call.state == CallState.active && _activeSince == null) {
      _activeSince = DateTime.now();
    }
    // Mesh: a new participant joined — the SMALLER uid offers
    // the connection (one offer per pair, never two: if I offered
    // and they offered too, we would build two connections).
    for (final uid in call.joinedUids) {
      if (uid == myUid) continue;
      if (myUid.compareTo(uid) >= 0) continue;
      if (_peerConnections.containsKey(uid)) continue;
      unawaited(_offerTo(uid));
    }
    // Offers / answers / candidates arrive inside the same node
    // snapshot — reconcile them below.
    unawaited(_reconcileSignaling(call, snapshot));
    notifyListeners();
  }

  CallInfo? _parseCall(DataSnapshot snapshot) {
    final key = snapshot.key;
    if (key == null) return null;
    final value = snapshot.value;
    if (value is! Map) return null;
    try {
      return CallInfo.fromMap(
        key,
        _circleId ?? '',
        SyncService.asMap(value),
      );
    } catch (_) {
      return null;
    }
  }

  /// Apply offers / answers / ICE candidates carried by a fresh
  /// snapshot of my active call. Each item is applied once —
  /// _appliedAnswers / _addedCandidates remember what is done,
  /// because onChildChanged fires again for every small change.
  Future<void> _reconcileSignaling(
    CallInfo call,
    DataSnapshot snapshot,
  ) async {
    final myUid = _myUid;
    if (myUid == null) return;
    final value = snapshot.value;
    if (value is! Map) return;
    final map = SyncService.asMap(value);

    // An offer addressed to me: answer it. The sender is in the
    // payload (any participant can offer me in a mesh, not just
    // the caller); fall back to the caller for old nodes.
    final offers = map['offers'];
    if (offers is Map) {
      final mine = parseSdpPayload(offers[myUid]);
      if (mine != null) {
        final sender = mine.from ?? call.from;
        if (sender != myUid && !_peerConnections.containsKey(sender)) {
          await _answerOffer(call, mine, sender);
        }
      }
    }

    // Answers from peers I offered to: complete those connections.
    final answers = map['answers'];
    if (answers is Map) {
      for (final e in answers.entries) {
        final uid = e.key.toString();
        if (uid == myUid) continue;
        if (_appliedAnswers.contains(uid)) continue;
        final answer = parseSdpPayload(e.value);
        if (answer == null) continue;
        final pc = _peerConnections[uid];
        if (pc == null) continue;
        try {
          await pc.setRemoteDescription(
            RTCSessionDescription(answer.sdp, answer.type),
          );
          _appliedAnswers.add(uid);
        } catch (_) {
          // A late/duplicate answer is harmless — ignore it.
        }
      }
    }

    // ICE candidates from every other peer, per sender.
    final candidates = map['candidates'];
    if (candidates is Map) {
      for (final e in candidates.entries) {
        final uid = e.key.toString();
        if (uid == myUid) continue;
        final pc = _peerConnections[uid];
        if (pc == null) continue;
        final perSender = e.value;
        if (perSender is! Map) continue;
        final seen = _addedCandidates.putIfAbsent(uid, () => <String>{});
        for (final c in perSender.entries) {
          final key = c.key.toString();
          if (seen.contains(key)) continue;
          final parsed = parseIceCandidatePayload(c.value);
          if (parsed == null) continue;
          try {
            await pc.addCandidate(
              RTCIceCandidate(
                parsed.candidate,
                parsed.sdpMid,
                parsed.sdpMLineIndex,
              ),
            );
            seen.add(key);
          } catch (_) {
            // A candidate for a closed connection — ignore it.
          }
        }
      }
    }
  }

  // --- Starting / answering / ending ------------------------------

  /// Start a call to [callees]. Returns null on success, or a
  /// plain-words error when the call cannot start (offline, no
  /// permission, already in a call).
  Future<String?> startCall({
    required List<Member> callees,
    required CallType type,
    bool isUrdu = false,
  }) async {
    if (_activeCall != null || _incomingCall != null) {
      return tr(isUrdu, 'svc_callAlreadyInCall');
    }
    final circleId = _circleId;
    final myUid = _myUid;
    if (!_family.isSynced || circleId == null || myUid == null) {
      return tr(isUrdu, 'svc_callNeedSync');
    }
    final others = callees.where((m) => m.id != myUid).toList();
    if (others.isEmpty) {
      return tr(isUrdu, 'svc_callPickSomeone');
    }
    final permError = await _ensureMediaPermissions(type, isUrdu: isUrdu);
    if (permError != null) return permError;

    final callsRef = _root.child(FirebaseConfig.circleCallsPath(circleId));
    final callRef = callsRef.push();
    final callId = callRef.key;
    if (callId == null) return tr(isUrdu, 'svc_callStartFailed');
    final participants = <String, String>{myUid: 'joined'};
    for (final m in others) {
      participants[m.id] = 'invited';
    }
    final call = CallInfo(
      id: callId,
      circleId: circleId,
      from: myUid,
      fromName: _myName(isUrdu: isUrdu),
      type: type,
      state: CallState.ringing,
      participants: participants,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await callRef.set(call.toMap());
    } catch (_) {
      return tr(isUrdu, 'svc_callNoInternet');
    }
    _activeCall = call;
    final mediaError = await _openLocalMedia(type, isUrdu: isUrdu);
    if (mediaError != null) {
      await callRef.remove().catchError((_) {});
      _activeCall = null;
      return mediaError;
    }
    // Offer a connection to every callee with a LARGER uid than
    // mine (the smaller uid offers — see _onCallChanged; a callee
    // with a smaller uid offers to ME when they join).
    for (final m in others) {
      if (myUid.compareTo(m.id) < 0) {
        await _offerTo(m.id);
      }
    }
    notifyListeners();
    // Nobody answered in 60 seconds: end it (missed call).
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(milliseconds: callRingTimeoutMs), () {
      if (_activeCall?.id == callId &&
          _activeCall?.state == CallState.ringing) {
        unawaited(endCall());
      }
    });
    return null;
  }

  /// Answer the ringing incoming call. Returns an error string
  /// when answering fails (no permission, no camera/mic).
  Future<String?> answerCall({bool isUrdu = false}) async {
    final call = _incomingCall;
    if (call == null) return tr(isUrdu, 'svc_callNoIncoming');
    final myUid = _myUid;
    if (myUid == null) return tr(isUrdu, 'svc_callNotSignedIn');
    final permError = await _ensureMediaPermissions(call.type, isUrdu: isUrdu);
    if (permError != null) return permError;
    final mediaError = await _openLocalMedia(call.type, isUrdu: isUrdu);
    if (mediaError != null) return mediaError;
    _incomingCall = null;
    _activeCall = call.copyWith(state: CallState.active);
    _activeSince = DateTime.now();
    try {
      final callRef = _callRef(call);
      await callRef.child('participants').child(myUid).set('joined');
      await callRef.child('state').set('active');
      // The offer addressed to me is already in the node (the
      // caller wrote it) — _reconcileSignaling picks it up from
      // the next snapshot; read it once directly too, in case the
      // snapshot already passed.
      final offerSnap = await callRef.child('offers').child(myUid).get();
      final offer = parseSdpPayload(offerSnap.value);
      if (offer != null) {
        final sender = offer.from ?? call.from;
        if (sender != myUid) {
          await _answerOffer(call, offer, sender);
        }
      }
    } catch (_) {
      // Signaling hiccup — the call may still connect via the
      // listener path; if not, the user ends it from the screen.
    }
    // Mesh: offer connections to the already-joined participants
    // with a LARGER uid than mine (smaller uid offers — the
    // others offer to me when they see me join).
    for (final uid in call.joinedUids) {
      if (uid == myUid) continue;
      if (myUid.compareTo(uid) >= 0) continue;
      if (_peerConnections.containsKey(uid)) continue;
      unawaited(_offerTo(uid));
    }
    notifyListeners();
    return null;
  }

  /// Decline the ringing incoming call (the caller sees me as
  /// 'declined' and their phone stops ringing for me).
  Future<void> declineCall() async {
    final call = _incomingCall;
    if (call == null) return;
    final myUid = _myUid;
    _incomingCall = null;
    notifyListeners();
    if (myUid == null) return;
    try {
      await _callRef(call).child('participants').child(myUid).set('declined');
    } catch (_) {
      // Best effort — declining locally is what matters.
    }
  }

  /// End the active call (or the outgoing ring). Sets state to
  /// 'ended' so every phone closes, then the caller deletes the
  /// node a moment later so nobody is left on a dead call.
  Future<void> endCall() async {
    final call = _activeCall ?? _incomingCall;
    if (call == null) return;
    final wasCaller = call.from == _myUid;
    try {
      await _callRef(call).child('state').set('ended');
    } catch (_) {
      // Best effort — closing locally is what matters.
    }
    if (wasCaller) {
      final ref = _callRef(call);
      unawaited(
        Future.delayed(const Duration(seconds: 2), () {
          ref.remove().catchError((_) {});
        }),
      );
    }
    await _closeCallLocally();
  }

  Future<void> _closeCallLocally() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    _incomingCall = null;
    _activeCall = null;
    _activeSince = null;
    _isMuted = false;
    _isCameraOff = false;
    _isSpeakerOn = false;
    for (final pc in _peerConnections.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _peerConnections.clear();
    _appliedAnswers.clear();
    _addedCandidates.clear();
    _remoteStreams.clear();
    await _closeLocalMedia();
    notifyListeners();
  }

  // --- Peer connections --------------------------------------------

  Future<void> _offerTo(String peerUid) async {
    final call = _activeCall;
    if (call == null) return;
    if (_peerConnections.containsKey(peerUid)) return;
    try {
      final pc = await _createPeerConnection(peerUid);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _callRef(call).child('offers').child(peerUid).set(
            sdpPayload(
              sdp: offer.sdp ?? '',
              type: offer.type ?? 'offer',
              from: _myUid,
            ),
          );
    } catch (_) {
      // The peer may have left already — ignore.
    }
  }

  Future<void> _answerOffer(
    CallInfo call,
    ({String sdp, String type, String? from}) offer,
    String senderUid,
  ) async {
    if (_peerConnections.containsKey(senderUid)) return;
    try {
      final pc = await _createPeerConnection(senderUid);
      await pc.setRemoteDescription(
        RTCSessionDescription(offer.sdp, offer.type),
      );
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _callRef(call).child('answers').child(_myUid!).set(
            sdpPayload(sdp: answer.sdp ?? '', type: answer.type ?? 'answer'),
          );
    } catch (_) {
      // The caller may have hung up — ignore.
    }
  }

  Future<RTCPeerConnection> _createPeerConnection(String peerUid) async {
    final pc = await createPeerConnection(callRtcConfiguration);
    final local = _localStream;
    if (local != null) {
      for (final track in local.getTracks()) {
        await pc.addTrack(track, local);
      }
    }
    pc.onIceCandidate = (candidate) {
      final call = _activeCall;
      final myUid = _myUid;
      if (call == null || myUid == null) return;
      if (candidate.candidate == null) return;
      unawaited(
        _callRef(call)
            .child('candidates')
            .child(myUid)
            .push()
            .set(
              iceCandidatePayload(
                candidate: candidate.candidate!,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex,
              ),
            )
            .catchError((_) {}),
      );
    };
    pc.onTrack = (event) {
      final stream = event.streams.isNotEmpty ? event.streams.first : null;
      if (stream != null) {
        _remoteStreams[peerUid] = stream;
        notifyListeners();
      }
    };
    pc.onAddStream = (stream) {
      _remoteStreams[peerUid] = stream;
      notifyListeners();
    };
    _peerConnections[peerUid] = pc;
    return pc;
  }

  // --- Local media ---------------------------------------------------

  Future<String?> _ensureMediaPermissions(
    CallType type, {
    bool isUrdu = false,
  }) async {
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        return tr(isUrdu, 'svc_callMicPermission');
      }
      if (type == CallType.video) {
        final cam = await Permission.camera.request();
        if (!cam.isGranted) {
          return tr(isUrdu, 'svc_callCameraPermission');
        }
      }
    } catch (_) {
      // The permission plugin itself failed (no plugin in tests,
      // a system error on a real phone) — never crash the call.
      return tr(isUrdu, 'svc_callMicCheckFailed');
    }
    return null;
  }

  Future<String?> _openLocalMedia(
    CallType type, {
    bool isUrdu = false,
  }) async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': type == CallType.video
            ? {'facingMode': 'user', 'width': 640, 'height': 480}
            : false,
      });
      _localStream = stream;
      return null;
    } catch (_) {
      return tr(
        isUrdu,
        type == CallType.video
            ? 'svc_callOpenMicCamFailed'
            : 'svc_callOpenMicFailed',
      );
    }
  }

  Future<void> _closeLocalMedia() async {
    final stream = _localStream;
    _localStream = null;
    if (stream == null) return;
    try {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    } catch (_) {}
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    final track = _localStream?.getAudioTracks().firstOrNull;
    if (track != null) track.enabled = !_isMuted;
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track != null) track.enabled = !_isCameraOff;
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
    } catch (_) {
      // Some devices have no speakerphone toggle — ignore.
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
    } catch (_) {
      // Single-camera device — nothing to switch.
    }
  }

  // --- Helpers ---------------------------------------------------------

  DatabaseReference _callRef(CallInfo call) =>
      _root.child(FirebaseConfig.circleCallsPath(call.circleId)).child(call.id);

  @override
  void dispose() {
    _family.removeListener(_onFamilyChanged);
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _ringTimer?.cancel();
    unawaited(_incomingController.close());
    unawaited(_closeCallLocally());
    super.dispose();
  }
}
