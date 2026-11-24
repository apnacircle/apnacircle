import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_lock_service.dart';
import '../core/time_lock.dart';
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
  bool _locationLocked = true;
  bool _internetLockAlert = true;

  /// App Lock service on THIS phone (v0.6.3): null = still checking.
  /// The service must be ON here or locked apps are never blocked —
  /// before v0.6.3 nothing showed this, so a parent could set locks
  /// that silently did nothing.
  bool? _serviceOn;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

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
    final sync = context.read<SyncService>();
    final family = context.read<FamilyService>();
    if (!sync.isAvailable || sync.activeCircleId == null) return;
    final circleId = sync.activeCircleId!;
    final amAdmin = sync.activeCircle?.isAdmin ?? false;
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
    super.dispose();
  }

  void _updateApp(LockedApp app, LockedApp updated) {
    setState(() {
      final i = _apps.indexOf(app);
      if (i >= 0) _apps[i] = updated;
    });
    AppLockService.applyLocks(_apps);
    _publishLocks();
  }

  void _withPin(VoidCallback action) =>
      askParentPin(context, onUnlocked: action);

  void _addCustomApp() {
    final name = _customName.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please type an app name first.')),
      );
      return;
    }
    if (_apps.any((a) => a.name.toLowerCase() == name.toLowerCase())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That app is already in the list.')),
      );
      return;
    }
    _withPin(() {
      setState(() {
        _apps.add(AppLockService.customApp(name));
        _customName.clear();
      });
      AppLockService.applyLocks(_apps);
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('At least one day must stay selected.'),
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
              child: Text('Start ${TimeWindow.formatMinutes(window.startMinutes)}'),
            ),
            const Text('–'),
            TextButton(
              onPressed: () => _pickTime(app, false),
              child: Text('End ${TimeWindow.formatMinutes(window.endMinutes)}'),
            ),
            const SizedBox(width: 8),
            Text(
              active ? 'Locked now' : 'Open now',
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
                label: Text(_dayLabels[d - 1]),
                selected: window.days.contains(d),
                onSelected: (_) => _toggleDay(app, d),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '🔁 ${window.summary()}',
          style: const TextStyle(fontSize: 12),
        ),
        Text(
          window.nextStartAfter(now) == null
              ? ''
              : 'Next lock: ${window.nextStartAfter(now)}',
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
                        ? 'Checking App Lock service…'
                        : isOn
                            ? 'App Lock is ON on this phone'
                            : 'App Lock is OFF on this phone',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Check again',
                  onPressed: _checkService,
                ),
              ],
            ),
            Text(
              on == null
                  ? ''
                  : isOn
                      ? 'Locked apps will be blocked on this phone.'
                      : 'Locked apps will NOT be blocked until this is '
                          'turned on. Tap Enable, then in Settings → '
                          'Accessibility turn ON "ApnaCircle App Lock".',
            ),
            if (on == false) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  await AppLockService.openAccessibilitySettings();
                },
                child: const Text('Enable App Lock'),
              ),
            ],
            const SizedBox(height: 4),
            const Text(
              'Every child\'s phone needs this ON — it can only be '
              'turned on from that phone itself, never from the '
              'parent phone.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          const Text(
            'Locks for',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
          const Text(
            'Changes here are sent to that member\'s phone live.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Divider(),
        ],
        SwitchListTile(
          title: const Text('Location Lock'),
          subtitle: const Text(
            'Member cannot turn location off. Only the parent PIN can change this.',
          ),
          value: _locationLocked,
          // v0.6.9: the switch is saved + published now — before,
          // it only did a local setState and never stuck.
          onChanged: (v) => _withPin(() {
            setState(() => _locationLocked = v);
            _publishLocks();
          }),
        ),
        SwitchListTile(
          title: const Text('Internet-off alert'),
          subtitle: const Text(
            'Alert the parent when internet is turned off. '
            'Android does not allow a full lock on the data toggle.',
          ),
          value: _internetLockAlert,
          // v0.6.9: same — saved + published, not just local.
          onChanged: (v) => _withPin(() {
            setState(() => _internetLockAlert = v);
            _publishLocks();
          }),
        ),
        const Divider(),
        const Text(
          'App Lock — parent locks any app',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const Text(
          'Two modes per app: Always lock, or Time lock — set the time '
          'once and it auto-locks / auto-unlocks every scheduled day.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _customName,
                decoration: const InputDecoration(
                  labelText: 'Add any other app yourself',
                  hintText: 'e.g. Snapchat or a game',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _addCustomApp, child: const Text('Add & Lock')),
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
                          ? 'Added by parent · ${app.scheduleSummary()}'
                          : app.scheduleSummary(),
                    ),
                    value: app.locked,
                    onChanged: (v) => _withPin(
                      () => _updateApp(app, app.copyWith(locked: v)),
                    ),
                  ),
                  SegmentedButton<LockMode>(
                    segments: const [
                      ButtonSegment(
                        value: LockMode.always,
                        label: Text('Always lock'),
                      ),
                      ButtonSegment(
                        value: LockMode.time,
                        label: Text('Time lock'),
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
