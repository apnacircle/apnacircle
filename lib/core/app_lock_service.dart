import 'package:flutter/services.dart';

import 'constants.dart';
import 'time_lock.dart';

/// App Lock — parent locks ANY app from the parent phone.
///
/// The lock list is NOT a fixed list. It starts with presets
/// (YouTube, Facebook, WhatsApp, WhatsApp Business, Play Store,
/// Chrome, TikTok, games) and the parent can ADD ANY app by name
/// (custom app add, 21 Nov 2026).
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

/// Everything the parent sets for ONE member on the Locks screen
/// (v0.6.9): the app list PLUS the two switches. Before v0.6.9 the
/// locks node held only `{'apps': [...]}` and the two switches
/// (Location Lock, Internet-off alert) lived only in the screen's
/// local state — they were never saved or sent anywhere, so they
/// did nothing at all and reset whenever the screen was rebuilt.
/// The node now holds the whole object; old nodes (apps only) read
/// back with both switches ON, matching the old screen defaults.
class LockSettings {
  final List<LockedApp> apps;

  /// Member cannot turn location off themselves (parent PIN only).
  final bool locationLocked;

  /// Alert the parent when this member's internet is turned off.
  final bool internetAlert;

  const LockSettings({
    this.apps = const [],
    this.locationLocked = true,
    this.internetAlert = true,
  });

  LockSettings copyWith({
    List<LockedApp>? apps,
    bool? locationLocked,
    bool? internetAlert,
  }) =>
      LockSettings(
        apps: apps ?? this.apps,
        locationLocked: locationLocked ?? this.locationLocked,
        internetAlert: internetAlert ?? this.internetAlert,
      );

  Map<String, dynamic> toJson() => {
        'apps': apps.map((a) => a.toJson()).toList(),
        'locationLocked': locationLocked,
        'internetAlert': internetAlert,
      };

  factory LockSettings.fromJson(Map<String, dynamic> json) {
    final apps = <LockedApp>[];
    final appsRaw = json['apps'];
    if (appsRaw is List) {
      for (final a in appsRaw) {
        if (a is! Map) continue;
        try {
          apps.add(
            LockedApp.fromJson(Map<String, dynamic>.from(a)),
          );
        } catch (_) {
          // One bad entry must not drop the whole list.
        }
      }
    }
    return LockSettings(
      apps: apps,
      locationLocked: json['locationLocked'] as bool? ?? true,
      internetAlert: json['internetAlert'] as bool? ?? true,
    );
  }
}

class AppLockService {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.appLockChannel);

  /// Preset list — the parent can lock/unlock any of these, and add more.
  /// PUBG is the company example: time-locked Mon–Fri 08:00–14:00,
  /// set once, repeats every working day.
  /// v0.6.8: Play Store + WhatsApp Business added — both were
  /// reported NOT locking on 24 Nov 2026 because they were not in
  /// this list, so they could only be added by name, and the name
  /// match failed ("WA Business" is not the real label
  /// "WhatsApp Business"). With exact package names here, they lock
  /// like every other preset, no name matching needed.
  static const List<LockedApp> presets = [
    LockedApp(name: 'YouTube', packageName: 'com.google.android.youtube'),
    LockedApp(name: 'Facebook', packageName: 'com.facebook.katana'),
    LockedApp(name: 'WhatsApp', packageName: 'com.whatsapp'),
    LockedApp(name: 'WhatsApp Business', packageName: 'com.whatsapp.w4b'),
    LockedApp(name: 'Play Store', packageName: 'com.android.vending'),
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

  /// v0.6.26 — WHO may apply a lock list LOCALLY on this phone.
  /// Only the phone whose OWN locks these are (a child/member).
  /// The parent's phone only PUBLISHES the child's list to RTDB —
  /// it must never apply it locally. Before this fix the Locks
  /// screen called applyLocks with the target child's list on the
  /// parent's own phone, so the ADMIN's own apps got locked and
  /// the parent had to enter the PIN to open them (reported
  /// 27 Nov 2026: "meri apni hi saari apps lock ho jati hain"),
  /// while the child's phone enforced nothing extra. The child's
  /// phone enforces its own locks via its Home subscription.
  static bool mayApplyLocally({required bool isAdmin}) => !isAdmin;

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

  /// Well-known short forms (v0.6.8) — the parent types these, the
  /// real label differs, and no normalization can bridge them:
  /// "WA Business" is not "WhatsApp Business" with the spaces
  /// removed, so plain label matching can never find it. Returns
  /// the real package, or null when the name is not a known alias.
  /// The child's phone runs the same map natively (MainActivity),
  /// so entries the parent already added by name heal there too.
  static String? knownPackageForName(String name) {
    switch (_normalizeAppName(name)) {
      case 'wabusiness':
      case 'whatsappbusiness':
        return 'com.whatsapp.w4b';
      case 'playstore':
      case 'googleplaystore':
        return 'com.android.vending';
    }
    return null;
  }

  /// Lowercase, letters/digits only: "Play Store" -> "playstore".
  /// Used only for matching — display names keep their spaces.
  static String _normalizeAppName(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Custom app: parent types a name (e.g. "Snapchat"). The package
  /// name is resolved on the child's phone from installed apps;
  /// until then the entry is stored by name and matched by name.
  /// v0.6.8: a known short form resolves IMMEDIATELY to the real
  /// package here, so it locks without waiting for the child's
  /// phone to resolve it.
  static LockedApp customApp(String name) {
    final trimmed = name.trim();
    return LockedApp(
      name: trimmed,
      packageName:
          knownPackageForName(trimmed) ?? 'custom:${trimmed.toLowerCase()}',
      isCustom: true,
    );
  }

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
