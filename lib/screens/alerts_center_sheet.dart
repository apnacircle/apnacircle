import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/member.dart';
import '../services/alert_history_service.dart';
import '../services/family_service.dart';

/// The alerts centre sheet (v0.6.21) — opened from the bell icon
/// in the AppBar.
///
/// One row per family member, with THEIR alert count in front of
/// their name; tap a row to expand it and see that member's
/// alerts one by one — what kind it was (SOS, phone switched
/// off, internet off, low battery…) and exactly when. The bell
/// badge is the TOTAL unread for the whole family; opening this
/// sheet marks everything read (the badge clears when the sheet
/// closes, the counts stay).
///
/// The sheet shows the latest 200 alerts (the loaded window) —
/// older ones are not kept on the phone.
class AlertsCenterSheet extends StatelessWidget {
  const AlertsCenterSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final history = context.watch<AlertHistoryService>();
    final family = context.watch<FamilyService>();
    final members = family.members;
    final byMember = history.eventsByMember;
    final unreadByMember = history.unreadByMember;
    // Members with the most unread first, then by latest alert.
    final sorted = members.toList()
      ..sort((a, b) {
        final ua = unreadByMember[a.id] ?? 0;
        final ub = unreadByMember[b.id] ?? 0;
        if (ua != ub) return ub.compareTo(ua);
        final la = byMember[a.id]?.firstOrNull?.at;
        final lb = byMember[b.id]?.firstOrNull?.at;
        if (la == null && lb == null) return 0;
        if (la == null) return 1;
        if (lb == null) return -1;
        return lb.compareTo(la);
      });
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Alerts — ${history.events.length} total',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (history.totalUnread > 0)
                  TextButton(
                    onPressed: () => history.markAllRead(),
                    child: const Text('Mark all read'),
                  ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap a member to see their alerts — what it was, and when.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (sorted.isEmpty)
                    const ListTile(
                      title: Text('No family members yet.'),
                    ),
                  for (final m in sorted) _memberRow(context, m, history),
                  if (history.events.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Showing the latest 200 alerts.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _memberRow(
    BuildContext context,
    Member m,
    AlertHistoryService history,
  ) {
    final mine = history.eventsByMember[m.id] ?? const [];
    final count = history.countByMember[m.id] ?? 0;
    final unread = history.unreadByMember[m.id] ?? 0;
    if (mine.isEmpty) {
      return ListTile(
        leading: CircleAvatar(child: Text(m.name[0])),
        title: Text(m.name),
        subtitle: const Text('No alerts yet'),
        trailing: _countBadge(0, unread: 0),
      );
    }
    final latest = mine.first;
    return ExpansionTile(
      leading: CircleAvatar(child: Text(m.name[0])),
      title: Text(m.name),
      subtitle: Text(
        'Latest: ${alertTypeLabel(latest.type)} · '
        '${formatAlertTime(latest.at)}',
      ),
      trailing: _countBadge(count, unread: unread),
      children: [
        for (final e in mine)
          ListTile(
            leading: Icon(_iconFor(e.type), color: _colorFor(e.type)),
            title: Text(alertTypeLabel(e.type)),
            subtitle: Text(formatAlertTime(e.at)),
          ),
      ],
    );
  }

  /// The count badge: the member's total alerts; red when any
  /// are unread (the number shown is the total, the colour is
  /// the unread signal).
  Widget _countBadge(int count, {required int unread}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: unread > 0 ? Colors.red : Colors.grey.shade300,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: unread > 0 ? Colors.white : Colors.black87,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  static IconData _iconFor(String type) => switch (type) {
        'sos' => Icons.emergency,
        'lowBattery' => Icons.battery_alert,
        'phoneOff' => Icons.power_settings_new,
        'internetOff' => Icons.wifi_off,
        'locationOff' => Icons.location_off,
        'simChanged' => Icons.sim_card,
        'adminDisabled' => Icons.shield,
        _ => Icons.notifications,
      };

  static Color _colorFor(String type) => switch (type) {
        'sos' => Colors.red,
        'lowBattery' => Colors.orange,
        'phoneOff' => Colors.red,
        'internetOff' => Colors.orange,
        'locationOff' => Colors.orange,
        'simChanged' => Colors.orange,
        'adminDisabled' => Colors.red,
        _ => Colors.grey,
      };
}
