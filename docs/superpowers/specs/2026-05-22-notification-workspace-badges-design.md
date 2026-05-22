# Per-workspace notification badges + tap navigation — design

- **Date:** 2026-05-22
- **Status:** Approved (pre-implementation)
- **Area:** `Sources/SharedKit`, `ios/CmuxRemote/Stores/NotificationStore.swift`, `ios/CmuxRemote/Workspace/WorkspaceListView.swift`, `ios/CmuxRemote/ContentView.swift`
- **Depends on:** `2026-05-22-relay-cmux-reconnect-design.md` (event delivery must work first)

## Problem

The user has never seen notifications work. They want, with no real-time/APNs requirement:
- cmux notification state surfaced **as per-workspace badges** in the workspace list.
- Tapping a notification (inbox) navigates to that workspace's tab (surface).
- In-app only — **no lock-screen / APNs push.**

## Why notifications have never appeared (root cause)

The in-app pipeline already exists and is wired end-to-end **for foreground events**:

- The relay subscribes to `EventCategory.allCases` (incl. `.notification`) and
  broadcasts `.event` frames to every session (`CmuxRelay.swift`,
  `SessionManager.broadcastToAll`).
- iOS `RPCClient.onPush` → `NotificationStore.ingest(_:)` filters notification
  events into `NotificationRecord`s (`NotificationStore.swift`). The decoder is
  very forgiving (snake/camel + fallbacks), so a wire-format mismatch is unlikely.
- The inbox tab (`NotificationCenterView`) renders them; tapping calls
  `ContentView.open(notification:)`, which sets `workspaceStore.selectedId` +
  `requestedSurfaceId` and switches to the `.active` tab. `WorkspaceView` already
  reacts to `preferredSurfaceId` (`.onChange` + `subscribeFirstSurfaceIfNeeded`)
  and subscribes to that surface — so **tap → navigate already works.**

The missing piece is upstream: the relay's `events.stream` subscription is set up
once and never re-attaches after a drop (the reconnect bug). With the stream dead,
**no notification events ever reach the app**, so the inbox stayed empty and the
user never saw anything to tap. APNs (lock-screen) is also entirely unimplemented,
but that is out of scope here.

## Goals

- Per-workspace unread notification **badge** in the workspace list, derived from
  received notification events grouped by `workspaceId`.
- A badge clears when the user opens that workspace.
- Tap-to-navigate verified working end-to-end (likely no code change).
- Unread-derivation logic is deterministically unit-testable via `swift test`.

## Non-goals (explicit)

- APNs / lock-screen / background push.
- Backfilling notifications that occurred while disconnected — cmux exposes only
  `notification.create` and event streaming (no list/history RPC in
  `CMUXMethods.swift`), so there is nothing to query for past state.
- Persisting notifications or read-state across app launches (in-memory is fine
  for v1; `NotificationStore` already keeps the last 200 in memory).

## Design

### 1. `WorkspaceNotificationTally` (new, SharedKit) — pure, testable

`NotificationRecord` is already in `SharedKit/Models.swift` (public), so the tally
lives in SharedKit and is unit-tested via `swift test`.

```swift
public enum WorkspaceNotificationTally {
    /// Unread = records whose id is not in `readIds`, grouped by workspaceId.
    public static func unreadCounts(records: [NotificationRecord],
                                    readIds: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records where !readIds.contains(r.id) {
            counts[r.workspaceId, default: 0] += 1
        }
        return counts
    }

    /// Notification ids belonging to a workspace (to mark them read).
    public static func ids(in records: [NotificationRecord],
                           forWorkspace workspaceId: String) -> Set<String> {
        Set(records.lazy.filter { $0.workspaceId == workspaceId }.map(\.id))
    }
}
```

Id-set based (not timestamp based) to avoid `ts`-granularity edge cases.

### 2. `NotificationStore` (modify) — read tracking + per-workspace unread

- Add `private(set) var readIds: Set<String> = []`.
- Add `private(set) var unreadByWorkspace: [String: Int] = [:]` (observed by SwiftUI).
- Recompute `unreadByWorkspace` via `WorkspaceNotificationTally.unreadCounts` at the
  end of `append(_:)` and `markWorkspaceSeen(_:)`.
- Add `func markWorkspaceSeen(_ workspaceId: String)`:
  `readIds.formUnion(WorkspaceNotificationTally.ids(in: items, forWorkspace: workspaceId))`
  then recompute.
- Prune `readIds` when items are evicted past 200 (mirror the existing `seenIds`
  pruning in `append`).

The store is thin glue around the pure tally; its correctness rests on
`WorkspaceNotificationTallyTests`.

### 3. `WorkspaceCard` / `WorkspaceListView` (modify) — badge UI

- `WorkspaceListView` gains a `notifStore: NotificationStore` parameter.
- Each `WorkspaceCard` gets an `unreadCount: Int`; when `> 0` it renders a small red
  badge reusing the inbox badge style (`CmuxTheme.accentRed`, `99+` cap).
- `ContentView` passes `notifStore` and reads
  `notifStore.unreadByWorkspace[workspace.id] ?? 0` per row.

### 4. `ContentView` (modify) — mark seen on open

- In the workspace card `onSelect` closure and in `open(notification:)`, call
  `notifStore.markWorkspaceSeen(workspaceId)` so opening a workspace clears its badge.

### 5. Navigation — verify (no expected code change)

`WorkspaceView` already consumes `preferredSurfaceId` (`.onChange` at line 107,
`subscribeFirstSurfaceIfNeeded` at line 98, the preferred-surface subscribe at
~line 564). The plan verifies tap → subscribe end-to-end and only wires a fix if
the manual test reveals a gap (e.g., nil `surfaceId` should fall back to the first
surface — which `subscribeFirstSurfaceIfNeeded` already does).

### 6. Integration verification

After the reconnect fix is live, use the existing Settings "test notification"
(`onTriggerTestNotification` → `notification.create`): cmux emits
`notification.created` → it flows back over the event stream → appears in the inbox,
increments the originating workspace's badge; tapping it navigates to that
workspace's surface; opening the workspace clears the badge.

## Read / clear semantics

A workspace's badge clears when the user **opens that workspace** (card tap or
notification tap). Implemented by adding that workspace's current notification ids
to `readIds`.

## Testing

- `WorkspaceNotificationTallyTests` (SharedKitTests, `swift test`):
  - groups unread counts by `workspaceId`;
  - excludes ids present in `readIds`;
  - `ids(in:forWorkspace:)` returns exactly that workspace's ids.
- `NotificationStore` + UI changes are thin glue verified by build + the manual
  integration check (§6).

## Risks / edge cases

- **Reconnect dependency:** without the reconnect fix, no events arrive and this
  feature shows nothing. Must land first.
- **Unknown workspace id:** the decoder falls back to `"unknown"` for missing
  `workspace_id`; such notifications badge a non-existent workspace. Acceptable —
  they still appear in the inbox; they just won't match a visible row.
- **readIds growth:** bounded by the 200-item cap via the same prune path as
  `seenIds`.
- **@Observable updates:** badges update because `unreadByWorkspace` is a stored,
  observed property recomputed on `append`/`markWorkspaceSeen`.
