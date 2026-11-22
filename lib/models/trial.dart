/// 7-day free trial of the Family plan (user order, 22 Nov 2026
/// ~23:56 PKT: "1 week ka Free trial rakhna hai ... ta k log check
/// kr skay" — so people can try everything before paying).
///
/// ONCE PER DEVICE (user correction, 23 Nov 2026 ~23:58 PKT:
/// "AK mobile pay ak bar trail mily bus" — one phone gets the
/// trial only once). The trial is keyed by the SHA-256 hash of the
/// Android ID — NOT by account or circle — and stored in the
/// Realtime Database under `trials/{deviceHash}` (plus a local
/// cache). Reinstalling, or signing in with a different account on
/// the SAME phone, can NOT restart it. A different phone gets its
/// own one trial. The raw device id is never stored (see
/// DeviceIdService).
///
/// HONEST LIMIT: a factory reset changes the Android ID, so a
/// reset phone could get a new trial. Accepted and documented,
/// not hidden.
enum TrialStatus { notStarted, active, expired }

class TrialState {
  /// Trial length: 7 full days.
  static const int trialLengthDays = 7;
  static const Duration trialLength = Duration(days: trialLengthDays);

  final bool trialUsed;
  final DateTime? startedAt;
  final DateTime? endsAt;

  /// SHA-256 of the Android ID this trial belongs to (null for a
  /// trial recorded before the device was known). Stored only so a
  /// cached copy can be matched to its device.
  final String? deviceHash;

  const TrialState({
    this.trialUsed = false,
    this.startedAt,
    this.endsAt,
    this.deviceHash,
  });

  factory TrialState.notStarted() => const TrialState();

  /// A fresh trial starting right now, on one device.
  factory TrialState.start(DateTime now, {String? deviceHash}) =>
      TrialState(
        trialUsed: true,
        startedAt: now,
        endsAt: now.add(trialLength),
        deviceHash: deviceHash,
      );

  TrialStatus statusAt(DateTime now) {
    if (!trialUsed || startedAt == null || endsAt == null) {
      return TrialStatus.notStarted;
    }
    return now.isBefore(endsAt!) ? TrialStatus.active : TrialStatus.expired;
  }

  bool get isUsed => trialUsed;

  /// Whole days left, rounded UP: the first day shows 7, the last
  /// partial day still shows 1. Returns 0 unless the trial is active.
  int daysRemainingAt(DateTime now) {
    if (statusAt(now) != TrialStatus.active) return 0;
    final remaining = endsAt!.difference(now);
    return (remaining.inSeconds / Duration.secondsPerDay).ceil();
  }

  /// RTDB / SharedPreferences payload. Epoch ms (not ISO strings)
  /// so the server can compare them without parsing dates.
  Map<String, dynamic> toJson() => {
        'trialUsed': trialUsed,
        'trialStartedAt': startedAt?.millisecondsSinceEpoch,
        'trialEndsAt': endsAt?.millisecondsSinceEpoch,
        if (deviceHash != null) 'deviceHash': deviceHash,
      };

  factory TrialState.fromJson(Map<String, dynamic> j) {
    final startMs = j['trialStartedAt'];
    final endMs = j['trialEndsAt'];
    return TrialState(
      trialUsed: j['trialUsed'] == true,
      startedAt: startMs is num
          ? DateTime.fromMillisecondsSinceEpoch(startMs.toInt(), isUtc: true)
          : null,
      endsAt: endMs is num
          ? DateTime.fromMillisecondsSinceEpoch(endMs.toInt(), isUtc: true)
          : null,
      deviceHash: j['deviceHash'] as String?,
    );
  }
}
