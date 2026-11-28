import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_lock_service.dart';
import '../core/language_service.dart';
import '../core/member_phone.dart';
import '../core/time_lock.dart';
import '../l10n/strings.dart';
import '../models/member.dart';
import '../services/family_service.dart';
import '../services/sync_service.dart';
import 'pin_gate_dialog.dart';

/// Locks — all parent-only (PIN):
/// * Location Lock: member cannot turn location off.
/// * Internet Lock: alert when internet is turned off (Android does
///   not let a normal app fully lock the data/Wi-Fi toggle — the app
///   alerts the parent + shows last location instead; see README).
/// * App Lock: preset apps + CUSTOM app add by name, each with TWO
///   modes (22 Nov 2026):
///   - Always lock: blocked all the time until the parent unlocks.
///   - Time lock: owner sets start/end time + days ONCE; the app
///     auto-locks at the start and auto-unlocks at the end, every
///     scheduled day, without setting it again daily.
///     Company example: 08:00–14:00, Mon–Fri — set once, workers
///     cannot use the app in work hours, every working day.
///
/// v0.6.9: the two switches are real now — they are saved per
/// target member in the locks node (with the app list) and loaded
/// back whenever this screen opens. Before, they only did a local
/// setState: they were never saved or sent anywhere, so they did
/// nothing and reset whenever the screen was rebuilt.
class LocksScreen extends StatefulWidget {
  const LocksScreen({super.key});
  @override
  State<LocksScreen> createState() => _LocksScreenState();
}

class _LocksScreenState extends State<LocksScreen>
    with WidgetsBindingObserver {
  final List<LockedApp> _apps = List.of(AppLockService.presets);
  final _customName = TextEditingController();
  // v0.6.14: the target member's mobile number (change-later
  // option). Prefilled from the member's stored number when it is
  // a real number; empty when it is an email (Gmail login).
  final _phoneController = TextEditingController();
  bool _locationLocked = true;
  bool _internetLockAlert = true;

  /// App Lock service on THIS phone (v0.6.3): null = still checking.
  /// The service must be ON here or locked apps are never blocked —
  /// before v0.6.3 nothing showed this, so a parent could set locks
  /// that silently did nothing.
  bool? _serviceOn;

  /// v0.3 remote locks: in synced mode the parent edits locks for
  /// ONE member (the child) — picked below. The child's phone
  /// subscribes to its own locks node and enforces them live.
  String? _targetMemberId;
  bool _remoteSubscribed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstFrame());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Settings → Accessibility: re-check immediately,
    // so the card flips to ON without reopening the screen.
    if (state == AppLifecycleState.resumed) _checkService();
  }

  /// Ask native code whether the AccessibilityService is enabled
  /// on this phone. Safe when the channel is missing (demo/web).
  Future<void> _checkService() async {
    final on = await AppLockService.isServiceEnabled();
    if (mounted) setState(() => _serviceOn = on);
  }

  Future<void> _afterFirstFrame() async {
    if (!mounted) return;
    _checkService();
    _maybeSetupRemote();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Retry the remote setup when the watched services change —
    // the circle list loads after the first frame.
    _maybeSetupRemote();
  }

  /// v0.6.28: remote lock setup, retried whenever the screen's
  /// dependencies change (the circle list loads AFTER the first
  /// frame — v0.6.26 ran this once in _afterFirstFrame, so when
  /// the circle was still loading the screen silently never set
  /// anything up). Runs once per screen instance. FAIL CLOSED:
  /// when the admin status is still unknown (activeCircle null)
  /// this returns without doing anything — the old `?? false`
  /// treated the parent as a child and subscribed + applied the
  /// parent's own locks on their own phone.
  bool _remoteSetupDone = false;

  Future<void> _maybeSetupRemote() async {
    if (_remoteSetupDone || !mounted) return;
    final sync = context.read<SyncService>();
    final family = context.read<FamilyService>();
    if (!sync.isAvailable || sync.activeCircleId == null) return;
    final amAdmin = sync.activeCircle?.isAdmin;
    if (amAdmin == null) return;
    _remoteSetupDone = true;
    final circleId = sync.activeCircleId!;
    if (!amAdmin) {
      // Child side: listen to MY locks and enforce them live.
      if (_remoteSubscribed) return;
      _remoteSubscribed = true;
      sync.subscribeLocks(circleId, sync.uid!, (incoming) {
        if (!mounted) return;
        setState(() {
          _apps
            ..clear()
            ..addAll(incoming.apps);
          // v0.6.9: the switches arrive with the app list now.
          _locationLocked = incoming.locationLocked;
          _internetLockAlert = incoming.internetAlert;
        });
        AppLockService.applyLocks(incoming.apps);
      });
      return;
    }
    // Parent side: default target = first non-parent member.
    final target = family.members
        .where((m) => !m.isParent && m.id != sync.uid)
        .map((m) => m.id)
        .firstOrNull;
    if (target != null) await _loadTargetLocks(target);
  }

  /// Local pending record for one member's lock settings (v0.6.9):
  /// the newest local intent, kept until its RTDB publish is
  /// confirmed — so a switch changed while offline does not flip
  /// back when this screen is reopened. A newer change overwrites
  /// the record; a confirmed publish clears it.
  static String _pendingLocksKey(String memberId) =>
      'locks_pending_$memberId';

  Future<void> _savePendingSettings(
    String memberId,
    LockSettings settings,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _pendingLocksKey(memberId),
      jsonEncode(settings.toJson()),
    );
  }

  Future<LockSettings?> _loadPendingSettings(String memberId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingLocksKey(memberId));
    if (raw == null) return null;
    try {
      return LockSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearPendingSettings(String memberId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingLocksKey(memberId));
  }

  Future<void> _loadTargetLocks(String memberId) async {
    final sync = context.read<SyncService>();
    setState(() => _targetMemberId = memberId);
    // v0.6.14: prefill the number field from the member's stored
    // number — only when it is a real number. An email (Gmail
    // login) leaves it empty, so the parent knows one is missing.
    final member = context
        .read<FamilyService>()
        .members
        .where((m) => m.id == memberId)
        .firstOrNull;
    _phoneController.text =
        (member != null && memberPhoneCanMatchCalls(member.phone))
            ? member.phone
            : '';
    if (sync.activeCircleId == null) return;
    final settings =
        await sync.getLocksOnce(sync.activeCircleId!, memberId);
    if (!mounted) return;
    // A newer local change whose publish never landed wins over
    // the server value (v0.6.9).
    final pending = await _loadPendingSettings(memberId);
    if (settings == null && pending == null) {
      // Fresh target, nothing saved yet: keep the preset list and
      // the default switches — do not wipe them with an empty node.
      return;
    }
    final apps = pending?.apps ?? settings?.apps ?? const <LockedApp>[];
    final locationLocked =
        pending?.locationLocked ?? settings?.locationLocked ?? true;
    final internetAlert =
        pending?.internetAlert ?? settings?.internetAlert ?? true;
    // v0.6.8: heal custom entries the parent already added by
    // name ("WA Business", "Playstore") — they were stored as
    // "custom:<name>" and never resolved, so they never locked.
    // Resolve known aliases to real packages now and push the
    // healed list, so the child's phone gets it on next sync.
    var healed = false;
    final fixed = apps.map((a) {
      if (a.packageName.startsWith('custom:')) {
        final known = AppLockService.knownPackageForName(a.name);
        if (known != null) {
          healed = true;
          return LockedApp(
            name: a.name,
            packageName: known,
            isCustom: true,
            locked: a.locked,
            mode: a.mode,
            window: a.window,
          );
        }
      }
      return a;
    }).toList();
    setState(() {
      _apps
        ..clear()
        ..addAll(fixed);
      _locationLocked = locationLocked;
      _internetLockAlert = internetAlert;
    });
    if (healed || pending != null) _publishLocks();
  }

  /// Push the current list + switches to the target child's phone
  /// (RTDB). v0.6.9: the whole [LockSettings] object is written —
  /// before, only the app list was written and the two switches
  /// were never saved anywhere.
  void _publishLocks() {
    final sync = context.read<SyncService>();
    final target = _targetMemberId;
    if (!sync.isAvailable ||
        sync.activeCircleId == null ||
        target == null) {
      return;
    }
    final settings = LockSettings(
      apps: List.of(_apps),
      locationLocked: _locationLocked,
      internetAlert: _internetLockAlert,
    );
    unawaited(_savePendingSettings(target, settings));
    unawaited(
      sync
          .publishLocks(sync.activeCircleId!, target, settings)
          .then((ok) {
        if (ok) unawaited(_clearPendingSettings(target));
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _customName.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// v0.6.26: on the parent's phone this screen edits a CHILD's
  /// locks — applying them locally would lock the ADMIN's own
  /// apps (reported 27 Nov 2026). Only a non-admin editing their
  /// own locks may apply locally; the parent only publishes to
  /// RTDB and the child's phone enforces them.
  bool get _mayApplyLocally => AppLockService.mayApplyLocally(
        // v0.6.28: nullable on purpose — unknown (no active circle
        // yet) must NOT apply locally; mayApplyLocally fails closed.
        isAdmin: context.read<SyncService>().activeCircle?.isAdmin,
      );

  void _updateApp(LockedApp app, LockedApp updated) {
    setState(() {
      final i = _apps.indexOf(app);
      if (i >= 0) _apps[i] = updated;
    });
    if (_mayApplyLocally) AppLockService.applyLocks(_apps);
    _publishLocks();
  }

  void _withPin(VoidCallback action) =>
      askParentPin(context, onUnlocked: action);

  /// Plain-words status line under the number field (v0.6.14):
  /// what is saved now, or why the call card cannot appear yet.
  String _targetPhoneStatus(List<Member> targets, {required bool isUrdu}) {
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(isUrdu, key, args);
    String t(String key) => tr(isUrdu, key);
    final target = _targetMemberId == null
        ? null
        : targets.where((m) => m.id == _targetMemberId).firstOrNull;
    if (target == null) return '';
    if (memberPhoneCanMatchCalls(target.phone)) {
      return tf('scr_lockPhoneSaved', {'phone': target.phone});
    }
    return t('scr_lockNoNumber');
  }

  /// Save the target member's mobile number (v0.6.14 — the
  /// change-later option for members who joined before numbers were
  /// asked at join time, e.g. mehvish). Validated BEFORE the PIN
  /// prompt — a bad number needs no code. The save itself is
  /// PIN-gated (parent only, via [_withPin]) and the service
  /// refuses it for a child or for the parent's own number.
  Future<void> _saveTargetPhone() async {
    final target = _targetMemberId;
    if (target == null) return;
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final validated =
        validateMemberPhone(_phoneController.text, isUrdu: isUrdu);
    if (validated.number == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(validated.error ?? t('scr_lockInvalidNumber'))),
      );
      return;
    }
    _withPin(() {
      unawaited(_doSaveTargetPhone(target));
    });
  }

  Future<void> _doSaveTargetPhone(String target) async {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final family = context.read<FamilyService>();
    final (ok, error) = await family.setMemberPhone(
      target,
      _phoneController.text,
      isUrdu: isUrdu,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? t('scr_lockNumberSaved')
              : (error ?? t('scr_lockSaveFailed')),
        ),
      ),
    );
    if (ok) setState(() {});
  }

  void _addCustomApp() {
    final isUrdu = context.read<LanguageService>().isUrdu;
    String t(String key) => tr(isUrdu, key);
    final name = _customName.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('scr_lockTypeAppName'))),
      );
      return;
    }
    if (_apps.any((a) => a.name.toLowerCase() == name.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('scr_lockAppExists'))),
      );
      return;
    }
    _withPin(() {
      setState(() {
        _apps.add(AppLockService.customApp(name));
        _customName.clear();
      });
      // v0.6.26: same guard as _updateApp — never apply a child's
      // list on the parent's own phone.
      if (_mayApplyLocally) AppLockService.applyLocks(_apps);
      _publishLocks();
    });
  }

  Future<void> _pickTime(LockedApp app, bool isStart) async {
    final window = app.window ?? TimeWindow.workday8to2;
    final current = TimeOfDay(
      hour: (isStart ? window.startMinutes : window.endMinutes) ~/ 60,
      minute: (isStart ? window.startMinutes : window.endMinutes) % 60,
    );
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    _withPin(() {
      _updateApp(
        app,
        app.copyWith(
          window: TimeWindow(
            startMinutes: isStart ? minutes : window.startMinutes,
            endMinutes: isStart ? window.endMinutes : minutes,
            days: window.days,
          ),
        ),
      );
    });
  }

  void _toggleDay(LockedApp app, int weekday) {
    final window = app.window ?? TimeWindow.workday8to2;
    final days = Set<int>.of(window.days);
    if (days.contains(weekday)) {
      if (days.length == 1) {
        final isUrdu = context.read<LanguageService>().isUrdu;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr(isUrdu, 'scr_lockOneDay')),
          ),
        );
        return;
      }
      days.remove(weekday);
    } else {
      days.add(weekday);
    }
    _withPin(() {
      _updateApp(
        app,
        app.copyWith(
          window: TimeWindow(
            startMinutes: window.startMinutes,
            endMinutes: window.endMinutes,
            days: days,
          ),
        ),
      );
    });
  }

  Widget _timeLockEditor(LockedApp app) {
    final lang = context.watch<LanguageService>();
    final isUrdu = lang.isUrdu;
    String t(String key) => tr(isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(isUrdu, key, args);
    final window = app.window ?? TimeWindow.workday8to2;
    final now = DateTime.now();
    final active = app.isLockedAt(now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => _pickTime(app, true),
              child: Text(tf('scr_lockStart', {
                'time': TimeWindow.formatMinutes(window.startMinutes),
              })),
            ),
            const Text('–'),
            TextButton(
              onPressed: () => _pickTime(app, false),
              child: Text(tf('scr_lockEnd', {
                'time': TimeWindow.formatMinutes(window.endMinutes),
              })),
            ),
            const SizedBox(width: 8),
            Text(
              active ? t('lockedNow') : t('openNow'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: active ? Colors.red : Colors.green,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 4,
          children: [
            for (var d = 1; d <= 7; d++)
              ChoiceChip(
                label: Text([
                  t('scr_lockDayMon'),
                  t('scr_lockDayTue'),
                  t('scr_lockDayWed'),
                  t('scr_lockDayThu'),
                  t('scr_lockDayFri'),
                  t('scr_lockDaySat'),
                  t('scr_lockDaySun'),
                ][d - 1]),
                selected: window.days.contains(d),
                onSelected: (_) => _toggleDay(app, d),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '🔁 ${window.summary(isUrdu: isUrdu)}',
          style: const TextStyle(fontSize: 12),
        ),
        Text(
          window.nextStartAfter(now) == null
              ? ''
              : tf('scr_lockNextLock', {
                  'time': window.nextStartAfter(now).toString(),
                }),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  /// v0.6.3 — App Lock service status on THIS phone. Locks only
  /// work while the service is ON; before this card existed, a
  /// parent could set locks that silently did nothing on the
  /// child's phone. The button opens Settings → Accessibility —
  /// only the user's own tap there can turn the service on.
  Widget _serviceStatusCard() {
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    final on = _serviceOn;
    final isOn = on == true;
    return Card(
      color: on == null
          ? null
          : isOn
              ? Colors.green.shade50
              : Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  on == null
                      ? Icons.help_outline
                      : isOn
                          ? Icons.check_circle
                          : Icons.warning_amber,
                  color: on == null
                      ? Colors.grey
                      : isOn
                          ? Colors.green
                          : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    on == null
                        ? t('scr_lockChecking')
                        : isOn
                            ? t('scr_lockOn')
                            : t('scr_lockOff'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: t('scr_lockCheckAgain'),
                  onPressed: _checkService,
                ),
              ],
            ),
            Text(
              on == null
                  ? ''
                  : isOn
                      ? t('scr_lockBlockedNote')
                      : t('scr_lockNotBlockedNote'),
            ),
            if (on == false) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  await AppLockService.openAccessibilitySettings();
                },
                child: Text(t('scr_lockEnable')),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              t('scr_lockEveryChild'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    String tf(String key, [Map<String, Object> args = const {}]) =>
        trf(lang.isUrdu, key, args);
    final family = context.watch<FamilyService>();
    final sync = context.watch<SyncService>();
    final amAdmin = sync.activeCircle?.isAdmin ?? false;
    final targets = family.members
        .where((m) => !m.isParent && m.id != sync.uid)
        .toList();
    // Members may arrive after the first frame (RTDB) — pick the
    // default target once they are here.
    if (sync.isAvailable &&
        amAdmin &&
        targets.isNotEmpty &&
        _targetMemberId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _targetMemberId == null) {
          _loadTargetLocks(targets.first.id);
        }
      });
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _serviceStatusCard(),
        const SizedBox(height: 8),
        if (sync.isAvailable && amAdmin && targets.isNotEmpty) ...[
          Text(
            t('scr_lockLocksFor'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          DropdownButton<String>(
            value: _targetMemberId,
            isExpanded: true,
            items: [
              for (final m in targets)
                DropdownMenuItem(value: m.id, child: Text(m.name)),
            ],
            onChanged: (v) {
              if (v != null) _loadTargetLocks(v);
            },
          ),
          Text(
            t('scr_lockChangesLive'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Divider(),
          if (_targetMemberId != null) ...[
            Text(
              t('scr_lockCallDistance'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              _targetPhoneStatus(targets, isUrdu: lang.isUrdu),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: t('scr_lockMobileNumber'),
                      hintText: 'e.g. 03001234567',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saveTargetPhone,
                  child: Text(t('scr_lockSave')),
                ),
              ],
            ),
            Text(
              t('scr_lockPinNote'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const Divider(),
          ],
        ],
        SwitchListTile(
          title: Text(t('scr_lockLocationLock')),
          subtitle: Text(t('scr_lockLocationHint')),
          value: _locationLocked,
          // v0.6.9: the switch is saved + published now — before,
          // it only did a local setState and never stuck.
          onChanged: (v) => _withPin(() {
            setState(() => _locationLocked = v);
            _publishLocks();
          }),
        ),
        SwitchListTile(
          title: Text(t('scr_lockInternetAlert')),
          subtitle: Text(t('scr_lockInternetHint')),
          value: _internetLockAlert,
          // v0.6.9: same — saved + published, not just local.
          onChanged: (v) => _withPin(() {
            setState(() => _internetLockAlert = v);
            _publishLocks();
          }),
        ),
        const Divider(),
        Text(
          t('scr_lockAppLockTitle'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(
          t('scr_lockModesHint'),
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customName,
                decoration: InputDecoration(
                  labelText: t('addApp'),
                  hintText: t('scr_lockAddHint'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                onPressed: _addCustomApp, child: Text(t('addAndLock'))),
          ],
        ),
        const SizedBox(height: 12),
        for (final app in _apps)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(app.name),
                    subtitle: Text(
                      app.isCustom
                          ? tf('scr_lockAddedByParent', {
                              'summary': app.scheduleSummary(
                                isUrdu: lang.isUrdu,
                              ),
                            })
                          : app.scheduleSummary(isUrdu: lang.isUrdu),
                    ),
                    value: app.locked,
                    onChanged: (v) => _withPin(
                      () => _updateApp(app, app.copyWith(locked: v)),
                    ),
                  ),
                  SegmentedButton<LockMode>(
                    segments: [
                      ButtonSegment(
                        value: LockMode.always,
                        label: Text(t('alwaysLock')),
                      ),
                      ButtonSegment(
                        value: LockMode.time,
                        label: Text(t('timeLock')),
                      ),
                    ],
                    selected: {app.mode},
                    onSelectionChanged: (modes) => _withPin(
                      () => _updateApp(
                        app,
                        app.copyWith(
                          mode: modes.first,
                          window: modes.first == LockMode.time
                              ? (app.window ?? TimeWindow.workday8to2)
                              : app.window,
                          clearWindow: modes.first == LockMode.always,
                        ),
                      ),
                    ),
                  ),
                  if (app.mode == LockMode.time && app.locked)
                    _timeLockEditor(app),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
