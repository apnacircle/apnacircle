import 'package:flutter/services.dart';

import 'constants.dart';
import 'time_lock.dart';

/// App Lock — parent locks ANY app from the parent phone.
///
/// The lock list is NOT a fixed list. It starts with presets
/// (YouTube, Facebook, WhatsApp, Chrome, games) and the parent can
/// ADD ANY app by name (custom app add, 21 Nov 2026).
/// A locked app cannot be opened on the child's phone without the
/// parent PIN. Unlocking / removing is parent-only, from the parent
/// phone (remote control).
///
/// TWO lock modes per app (22 Nov 2026, matches the web demo):
/// * [LockMode.always] — locked all the time until the parent unlocks.
/// * [LockMode.time] — owner sets a start/end time + days ONCE; the
///   app auto-locks at the start and auto-unlocks at the end, every
///   scheduled day, without setting it again daily. For a company:
///   set 08:00–14:00 once and workers cannot use the app in work
///   hours, every working day.
///
/// ANDROID REALITY (honest note, see README): a normal Flutter app
/// cannot block other apps by itself. The real enforcement is native
/// — an AccessibilityService detects a locked app coming to the
/// foreground and shows the PIN screen (LockActivity), plus Device
/// Admin so the child cannot uninstall ApnaCircle easily. That
/// native layer lives in android/app/src/main/kotlin/.../:
/// AppLockService.kt (declared in AndroidManifest.xml + res/xml/
/// accessibility_service_config.xml since v0.6.3 — before that the
/// service was never declared, so nothing was ever blocked) and
/// LockActivity.kt (the PIN screen; correct PIN = 5-minute grant).
/// The user MUST enable the service once in Settings →
/// Accessibility → ApnaCircle App Lock; [isServiceEnabled] reports
/// it and [openAccessibilitySettings] opens those settings. The
/// Dart side below is the UI + list + PIN gate + schedule logic;
/// it talks to native code over the `apnacircle/applock` channel.
class LockedApp {
  final String name;
  final String packageName;
  final bool isCustom;
  final bool locked;

  /// Which mode this app uses. Defaults to always-locked.
  final LockMode mode;

  /// Only used when [mode] is [LockMode.time]. Null for always-lock.
  final TimeWindow? window;

  const LockedApp({
    required this.name,
    required this.packageName,
    this.isCustom = false,
    this.locked = true,
    this.mode = LockMode.always,
    this.window,
  });

  /// Is this app actually blocked right now? Always-mode: yes while
  /// [locked] is true. Time-mode: only inside its scheduled window.
  bool isLockedAt(DateTime now) {
    if (!locked) return false;
    if (mode == LockMode.always) return true;
    return window?.isActiveAt(now) ?? false;
  }

  /// Human schedule line, e.g. "Mon–Fri · 08:00 – 14:00 · set once…"
  /// or "Locked all the time" for always-mode.
  String scheduleSummary() {
    if (mode == LockMode.time && window != null) return window!.summary();
    return 'Locked all the time';
  }

  LockedApp copyWith({
    bool? locked,
    LockMode? mode,
    TimeWindow? window,
    bool clearWindow = false,
  }) =>
      LockedApp(
        name: name,
        packageName: packageName,
        isCustom: isCustom,
        locked: locked ?? this.locked,
        mode: mode ?? this.mode,
        window: clearWindow ? null : (window ?? this.window),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'package': packageName,
        'custom': isCustom,
        'locked': locked,
        'mode': mode.name,
        'window': window?.toJson(),
      };

  factory LockedApp.fromJson(Map<String, dynamic> json) => LockedApp(
        name: json['name'] as String,
        packageName: json['package'] as String,
        isCustom: json['custom'] as bool? ?? false,
        locked: json['locked'] as bool? ?? true,
        mode: LockMode.values.firstWhere(
          (m) => m.name == (json['mode'] as String? ?? 'always'),
          orElse: () => LockMode.always,
        ),
        window: json['window'] == null
            ? null
            : TimeWindow.fromJson(json['window'] as Map<String, dynamic>),
      );
}

class AppLockService {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.appLockChannel);

  /// Preset list — the parent can lock/unlock any of these, and add more.
  /// PUBG is the company example: time-locked Mon–Fri 08:00–14:00,
  /// set once, repeats every working day.
  static const List<LockedApp> presets = [
    LockedApp(name: 'YouTube', packageName: 'com.google.android.youtube'),
    LockedApp(name: 'Facebook', packageName: 'com.facebook.katana'),
    LockedApp(name: 'WhatsApp', packageName: 'com.whatsapp'),
    LockedApp(name: 'Chrome', packageName: 'com.android.chrome'),
    LockedApp(name: 'TikTok', packageName: 'com.zhiliaoapp.musically'),
    LockedApp(
      name: 'PUBG',
      packageName: 'com.tencent.ig',
      mode: LockMode.time,
      window: TimeWindow.workday8to2,
    ),
  ];

  /// Packages that are actually blocked RIGHT NOW (time windows
  /// evaluated against [now]). This is what native enforcement uses.
  static List<String> lockedPackagesNow(List<LockedApp> apps,
          [DateTime? now]) =>
      apps
          .where((a) => a.isLockedAt(now ?? DateTime.now()))
          .map((a) => a.packageName)
          .toList();

  /// Tell native code to enforce this list on the CHILD phone.
  /// Sends both the currently-blocked packages and the full
  /// schedule, so native code can re-evaluate time windows itself.
  /// Returns false when the native lock service is not active
  /// (e.g. Accessibility permission not granted yet).
  static Future<bool> applyLocks(List<LockedApp> apps) async {
    try {
      final result = await _channel.invokeMethod<bool>('applyLocks', {
        'packages': lockedPackagesNow(apps),
        'schedule': apps.map((a) => a.toJson()).toList(),
      });
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Custom app: parent types a name (e.g. "Snapchat"). The package
  /// name is resolved on the child's phone from installed apps;
  /// until then the entry is stored by name and matched by name.
  static LockedApp customApp(String name) => LockedApp(
        name: name.trim(),
        packageName: 'custom:${name.trim().toLowerCase()}',
        isCustom: true,
      );

  /// Is the native AccessibilityService enabled on THIS phone?
  /// False until the user turns it on in Settings → Accessibility.
  /// Locks cannot work on this phone while this is false.
  static Future<bool> isServiceEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isLockServiceEnabled') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Open Android Settings → Accessibility so the user can enable
  /// ApnaCircle App Lock. Only the user's own tap there enables
  /// it — no app can enable an AccessibilityService by itself.
  static Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod<void>('openAccessibilitySettings');
    } on PlatformException {
      // No-op: the button just does nothing on a phone without it.
    }
  }
}
