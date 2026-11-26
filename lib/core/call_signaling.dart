// Call signaling model + pure helpers (v0.6.21) — no Firebase, no
// WebRTC here, so all of it is unit-testable.
//
// HOW CALLS WORK (one paragraph): a call is a node under
// `circles/{circleId}/calls/{callId}` in the Realtime Database.
// The caller creates the node (from, type, state 'ringing',
// participants all 'invited' except themselves 'joined'), then
// every participant builds a WebRTC peer connection to every
// OTHER participant (a mesh — no server media, the phones talk
// directly to each other). Offers, answers and ICE candidates
// travel through the same node:
//   offers:   {toUid: {sdp, type}}        — one offer per callee
//   answers:  {fromUid: {sdp, type}}      — each callee's answer
//   candidates: {fromUid: {pushId: {...}}} — trickle ICE per sender
// Anyone in the call can set state to 'ended'; the caller deletes
// the node afterwards. Signaling needs internet on BOTH phones —
// a call cannot start or ring while a phone is offline (same
// honest limit as every live feature; the SMS fallback covers
// location only, not calls).
//
// COST: a call uses mobile data / Wi-Fi, never SIM call balance —
// there is no per-minute charge. A video call uses much more
// data than an audio call (roughly 5–10x); on a small data pack,
// audio is the cheap choice.
//
// HONEST LIMITS (v1):
// * No TURN relay server — only Google's free public STUN server
//   (stun:stun.l.google.com:19302). Two phones on the same Wi-Fi
//   or the same carrier usually connect directly; two phones
//   behind strict NATs (some mobile networks) may fail to connect
//   — a TURN server is the fix, and it is NOT in this version.
// * A call rings only while the receiver's app is running (open
//   or background with the location service alive). A fully
//   killed app cannot be woken — that needs the Cloud Function
//   (Blaze-blocked, same as closed-app SOS).
// * The incoming-call ringtone is the same 3-second siren as SOS
//   (v0.6.17) — there is no separate ringtone file yet.
// * A group call is a mesh: every phone connects to every other
//   phone. Small family groups (2–4) are fine; 10 simultaneous
//   video streams would strain a phone.

/// Audio or video call.
enum CallType { audio, video }

/// Lifecycle of a call node.
enum CallState {
  /// Waiting for the callees to answer (or decline).
  ringing,

  /// At least one callee joined; the call is live.
  active,

  /// Someone ended it — every phone closes its peer connections.
  ended,
}

/// One call node, as stored under
/// `circles/{circleId}/calls/{callId}`.
class CallInfo {
  const CallInfo({
    required this.id,
    required this.circleId,
    required this.from,
    required this.fromName,
    required this.type,
    required this.state,
    required this.participants,
    required this.createdAt,
  });

  /// The RTDB push key of the call node.
  final String id;

  final String circleId;

  /// Firebase uid of the caller.
  final String from;

  /// Display name of the caller (shown on the incoming screen).
  final String fromName;

  final CallType type;
  final CallState state;

  /// uid -> 'invited' | 'joined' | 'declined' | 'left'.
  final Map<String, String> participants;

  /// Epoch milliseconds when the call node was created.
  final int createdAt;

  /// My uid is a participant and the call is still ringing.
  bool isRingingFor(String myUid) =>
      state == CallState.ringing && participants.containsKey(myUid);

  /// Uids of everyone except me.
  List<String> othersThan(String myUid) =>
      participants.keys.where((uid) => uid != myUid).toList();

  /// Uids that joined (are in the call right now).
  List<String> get joinedUids => participants.entries
      .where((e) => e.value == 'joined')
      .map((e) => e.key)
      .toList();

  CallInfo copyWith({CallState? state, Map<String, String>? participants}) {
    return CallInfo(
      id: id,
      circleId: circleId,
      from: from,
      fromName: fromName,
      type: type,
      state: state ?? this.state,
      participants: participants ?? this.participants,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'from': from,
      'fromName': fromName,
      'type': type.name,
      'state': state.name,
      'participants': participants,
      'createdAt': createdAt,
    };
  }

  static CallInfo fromMap(
    String id,
    String circleId,
    Map<String, dynamic> map,
  ) {
    final rawParticipants = map['participants'];
    final participants = <String, String>{};
    if (rawParticipants is Map) {
      for (final e in rawParticipants.entries) {
        participants[e.key.toString()] = e.value.toString();
      }
    }
    return CallInfo(
      id: id,
      circleId: circleId,
      from: (map['from'] ?? '').toString(),
      fromName: (map['fromName'] ?? 'Family').toString(),
      type:
          (map['type'] ?? 'audio') == 'video' ? CallType.video : CallType.audio,
      state: switch ((map['state'] ?? 'ringing').toString()) {
        'active' => CallState.active,
        'ended' => CallState.ended,
        _ => CallState.ringing,
      },
      participants: participants,
      createdAt: map['createdAt'] is int
          ? map['createdAt'] as int
          : int.tryParse('${map['createdAt']}') ?? 0,
    );
  }
}

/// A call ringing for longer than this is treated as missed — the
/// caller auto-ends it, and a late callee ignores it instead of
/// ringing a dead call.
const int callRingTimeoutMs = 60000;

/// True when this ringing call is too old to answer anymore.
bool isCallStale(CallInfo call, {required int nowMs}) =>
    call.state == CallState.ringing &&
    nowMs - call.createdAt > callRingTimeoutMs;

/// SDP payload stored under offers/{toUid} and answers/{fromUid}.
/// `from` is the uid that WROTE the offer (the mesh needs it:
/// an offer addressed to me can come from any participant, not
/// just the caller — see call_service.dart). Answers carry no
/// `from` (their key IS the answerer).
Map<String, dynamic> sdpPayload({
  required String sdp,
  required String type,
  String? from,
}) =>
    {
      'sdp': sdp,
      'type': type,
      if (from != null) 'from': from,
    };

/// Parse an SDP payload back out; null when the shape is wrong
/// (a partial/corrupt node must never crash the call).
({String sdp, String type, String? from})? parseSdpPayload(dynamic value) {
  if (value is! Map) return null;
  final sdp = value['sdp'];
  final type = value['type'];
  if (sdp is! String || sdp.isEmpty) return null;
  if (type is! String || type.isEmpty) return null;
  final from = value['from'];
  return (sdp: sdp, type: type, from: from is String ? from : null);
}

/// ICE candidate payload stored under candidates/{fromUid}/{pushId}.
Map<String, dynamic> iceCandidatePayload({
  required String candidate,
  required String? sdpMid,
  required int? sdpMLineIndex,
}) =>
    {
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    };

/// Parse an ICE candidate payload; null when the shape is wrong.
({String candidate, String? sdpMid, int? sdpMLineIndex})?
    parseIceCandidatePayload(dynamic value) {
  if (value is! Map) return null;
  final candidate = value['candidate'];
  if (candidate is! String || candidate.isEmpty) return null;
  final sdpMid = value['sdpMid'];
  final sdpMLineIndex = value['sdpMLineIndex'];
  return (
    candidate: candidate,
    sdpMid: sdpMid is String ? sdpMid : null,
    sdpMLineIndex:
        sdpMLineIndex is int ? sdpMLineIndex : int.tryParse('$sdpMLineIndex'),
  );
}

/// WebRTC configuration: Google's free public STUN server only
/// (see the honest limits at the top — no TURN in v1).
Map<String, dynamic> get callRtcConfiguration => {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
