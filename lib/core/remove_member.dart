/// Parent-only guard for removing a member (v0.6.16, 25 Nov 2026).
///
/// The user asked: "Agr kisi child ko remove krna ho tu wo option
/// be hona chaye" — if a child must be removed, there should be an
/// option for it. The service plumbing already existed
/// (`FamilyService.removeMember` + `SyncService.removeMemberNode`)
/// but NO UI anywhere called it — that was the whole gap.
///
/// RULES (same shape as `canSetMemberPhone` in member_phone.dart):
/// only the circle admin may remove one, and never themselves.
/// Pure — the service and the UI use it, and it is unit-tested.
/// The "already gone" check lives in the service (it owns the
/// member list), and the parent PIN prompt lives in the UI.
bool canRemoveMember({
  required bool isAdmin,
  required String? myUid,
  required String targetMemberId,
}) =>
    isAdmin && myUid != null && myUid != targetMemberId;
