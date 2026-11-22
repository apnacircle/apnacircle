import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
class LocksScreen extends StatefulWidget {
  const LocksScreen({super.key});
  @override
  State<LocksScreen> createState() => _LocksScreenState();
}

class _LocksScreenState extends State<LocksScreen> {
  final List<LockedApp> _apps = List.of(AppLockService.presets);
  final _customName = TextEditingController();
  bool _locationLocked = true;
  bool _internetLockAlert = true;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// v0.3 remote locks: in synced mode the parent edits locks for
  /// ONE member (the child) — picked below. The child's phone
  /// subscribes to its own locks node and enforces them live.
  String? _targetMemberId;
  bool _remoteSubscribed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstFrame());
  }

  Future<void> _afterFirstFrame() async {
    if (!mounted) return;
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
            ..addAll(incoming);
        });
        AppLockService.applyLocks(incoming);
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

  Future<void> _loadTargetLocks(String memberId) async {
    final sync = context.read<SyncService>();
    setState(() => _targetMemberId = memberId);
    if (sync.activeCircleId == null) return;
    final remote =
        await sync.getLocksOnce(sync.activeCircleId!, memberId);
    if (!mounted) return;
    if (remote.isNotEmpty) {
      setState(() {
        _apps
          ..clear()
          ..addAll(remote);
      });
    }
  }

  /// Push the current list to the target child's phone (RTDB).
  void _publishLocks() {
    final sync = context.read<SyncService>();
    final target = _targetMemberId;
    if (!sync.isAvailable ||
        sync.activeCircleId == null ||
        target == null) {
      return;
    }
    sync.publishLocks(sync.activeCircleId!, target, List.of(_apps));
  }

  @override
  void dispose() {
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
          onChanged: (v) => _withPin(() => setState(() => _locationLocked = v)),
        ),
        SwitchListTile(
          title: const Text('Internet-off alert'),
          subtitle: const Text(
            'Alert the parent when internet is turned off. '
            'Android does not allow a full lock on the data toggle.',
          ),
          value: _internetLockAlert,
          onChanged: (v) =>
              _withPin(() => setState(() => _internetLockAlert = v)),
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
