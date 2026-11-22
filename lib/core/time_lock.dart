/// Time Lock — two lock modes per app (matches the web demo, 22 Nov 2026).
///
/// * [LockMode.always]: the app stays locked all the time, until the
///   parent unlocks it with the parent PIN.
/// * [LockMode.time]: the owner (parent / company owner) sets a start
///   time and an end time ONCE, plus the days of the week. The app then
///   auto-locks at the start time and auto-unlocks at the end time,
///   every scheduled day, WITHOUT setting it again daily.
///   Example: PUBG, Mon–Fri, 08:00–14:00 — a company whose workers
///   work 8 to 2 can set it once and it repeats daily.
///
/// Days use [DateTime] weekday numbers: Monday = 1 … Sunday = 7.
/// Overnight windows (e.g. 22:00–06:00) are supported: the lock runs
/// from the start time on a scheduled day until the end time the
/// next morning.
enum LockMode { always, time }

/// A recurring daily time window. Pure logic — no UI, fully unit-tested.
class TimeWindow {
  /// Minutes since midnight, 0–1439 (e.g. 08:00 = 480).
  final int startMinutes;
  final int endMinutes;

  /// Scheduled weekdays, Monday = 1 … Sunday = 7. At least one day.
  final Set<int> days;

  // NOTE: no assert on days here — a const constructor cannot read
  // Set.length in a constant expression. Callers must pass at least
  // one day (an empty set simply never activates, by design).
  const TimeWindow({
    required this.startMinutes,
    required this.endMinutes,
    this.days = const {1, 2, 3, 4, 5, 6, 7},
  }) : assert(startMinutes >= 0 && startMinutes < 1440),
       assert(endMinutes >= 0 && endMinutes < 1440);

  /// Company example from Mujahid: Mon–Fri, 08:00–14:00.
  static const TimeWindow workday8to2 = TimeWindow(
    startMinutes: 8 * 60,
    endMinutes: 14 * 60,
    days: {1, 2, 3, 4, 5},
  );

  bool get isOvernight => endMinutes <= startMinutes;

  static int minutesOf(DateTime t) => t.hour * 60 + t.minute;

  static int _prevWeekday(int weekday) => weekday == 1 ? 7 : weekday - 1;

  /// Is the window active right now?
  bool isActiveAt(DateTime now) {
    final mins = minutesOf(now);
    if (!isOvernight) {
      return days.contains(now.weekday) &&
          mins >= startMinutes &&
          mins < endMinutes;
    }
    // Overnight: active after start on a scheduled day, or before
    // end in the morning after a scheduled day.
    return (days.contains(now.weekday) && mins >= startMinutes) ||
        (days.contains(_prevWeekday(now.weekday)) && mins < endMinutes);
  }

  /// Next scheduled lock start strictly after [now], or null if the
  /// window has no days (cannot happen — constructor requires >= 1).
  DateTime? nextStartAfter(DateTime now) {
    for (var i = 0; i < 8; i++) {
      final day = now.add(Duration(days: i));
      if (!days.contains(day.weekday)) continue;
      final start = DateTime(
        day.year,
        day.month,
        day.day,
        startMinutes ~/ 60,
        startMinutes % 60,
      );
      if (start.isAfter(now)) return start;
    }
    return null;
  }

  /// "08:00" from minutes since midnight.
  static String formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static const _dayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// "Every day" / "Mon–Fri" / "Mon, Wed, Fri".
  String daysSummary() {
    if (days.length == 7) return 'Every day';
    final sorted = days.toList()..sort();
    final contiguous = sorted.last - sorted.first == sorted.length - 1;
    if (contiguous && sorted.length > 1) {
      return '${_dayShort[sorted.first - 1]}–${_dayShort[sorted.last - 1]}';
    }
    return sorted.map((d) => _dayShort[d - 1]).join(', ');
  }

  /// "Mon–Fri · 08:00 – 14:00 · set once — repeats automatically"
  String summary() =>
      '${daysSummary()} · ${formatMinutes(startMinutes)} – '
      '${formatMinutes(endMinutes)} · set once — repeats automatically';

  Map<String, dynamic> toJson() => {
        'start': startMinutes,
        'end': endMinutes,
        'days': days.toList()..sort(),
      };

  factory TimeWindow.fromJson(Map<String, dynamic> json) => TimeWindow(
        startMinutes: (json['start'] as num).toInt(),
        endMinutes: (json['end'] as num).toInt(),
        days: ((json['days'] as List?) ?? [1, 2, 3, 4, 5, 6, 7])
            .map((d) => (d as num).toInt())
            .toSet(),
      );
}
