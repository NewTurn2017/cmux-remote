# Per-workspace notification badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a per-workspace unread-notification badge in the workspace list, clear it when the user opens that workspace, and confirm tapping a notification navigates to that workspace's tab.

**Architecture:** A pure `WorkspaceNotificationTally` (SharedKit) computes per-workspace unread counts from `[NotificationRecord]` + a `readIds` set. `NotificationStore` keeps `readIds` + an observed `unreadByWorkspace` recomputed via the tally. `WorkspaceCard` renders the badge; `ContentView` marks a workspace seen on open. Navigation (tap → surface) already exists and is only verified.

**Tech Stack:** Swift 5.10, SwiftUI, `@Observable`, SwiftPM (SharedKit via `swift test`), xcodegen + xcodebuild for the iOS app target.

**Spec:** `docs/superpowers/specs/2026-05-22-notification-workspace-badges-design.md`

**Depends on:** the reconnect plan (`2026-05-22-relay-cmux-reconnect.md`) — event delivery must work first. Execute this plan **on the same branch** (`fix/relay-cmux-reconnect`) **after** the reconnect plan is complete.

---

## File Structure

- **Create** `Sources/SharedKit/WorkspaceNotificationTally.swift` — pure per-workspace unread tally.
- **Create** `Tests/SharedKitTests/WorkspaceNotificationTallyTests.swift`
- **Modify** `ios/CmuxRemote/Stores/NotificationStore.swift` — add `readIds`, `unreadByWorkspace`, `markWorkspaceSeen(_:)`, recompute on append.
- **Modify** `ios/CmuxRemote/Workspace/WorkspaceListView.swift` — `notifStore` param + per-row badge.
- **Modify** `ios/CmuxRemote/ContentView.swift` — pass `notifStore`; mark seen on open.
- **Verify (no expected change)** `ios/CmuxRemote/Workspace/WorkspaceView.swift`.

**iOS build command (used in Tasks 2–4, 5):**
```bash
cd /Users/genie/dev/side/cmux-iphone/ios
xcodebuild build -project CmuxRemote.xcodeproj -scheme CmuxRemote \
  -destination "${CMUX_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" -quiet
```
(SharedKit is consumed by the app as a local SPM package; modifying existing iOS files needs no `xcodegen generate`.)

---

## Task 1: WorkspaceNotificationTally (pure)

**Files:**
- Create: `Sources/SharedKit/WorkspaceNotificationTally.swift`
- Test: `Tests/SharedKitTests/WorkspaceNotificationTallyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SharedKitTests/WorkspaceNotificationTallyTests.swift`:
```swift
import XCTest
@testable import SharedKit

final class WorkspaceNotificationTallyTests: XCTestCase {
    private func rec(_ id: String, _ ws: String) -> NotificationRecord {
        NotificationRecord(id: id, workspaceId: ws, surfaceId: nil, title: "t",
                           subtitle: nil, body: "b", ts: 0, threadId: "th")
    }

    func testGroupsUnreadByWorkspace() {
        let records = [rec("1", "A"), rec("2", "A"), rec("3", "B")]
        let counts = WorkspaceNotificationTally.unreadCounts(records: records, readIds: [])
        XCTAssertEqual(counts, ["A": 2, "B": 1])
    }

    func testExcludesReadIds() {
        let records = [rec("1", "A"), rec("2", "A"), rec("3", "B")]
        let counts = WorkspaceNotificationTally.unreadCounts(records: records, readIds: ["1"])
        XCTAssertEqual(counts, ["A": 1, "B": 1])
    }

    func testFullyReadWorkspaceHasNoEntry() {
        let records = [rec("1", "A"), rec("2", "A")]
        let counts = WorkspaceNotificationTally.unreadCounts(records: records, readIds: ["1", "2"])
        XCTAssertNil(counts["A"])
    }

    func testIdsForWorkspace() {
        let records = [rec("1", "A"), rec("2", "A"), rec("3", "B")]
        XCTAssertEqual(WorkspaceNotificationTally.ids(in: records, forWorkspace: "A"), ["1", "2"])
        XCTAssertEqual(WorkspaceNotificationTally.ids(in: records, forWorkspace: "B"), ["3"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter WorkspaceNotificationTallyTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'WorkspaceNotificationTally' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SharedKit/WorkspaceNotificationTally.swift`:
```swift
/// Pure derivation of per-workspace unread notification counts. Lives in
/// SharedKit so it is unit-testable via `swift test` (no iOS simulator).
public enum WorkspaceNotificationTally {
    /// Unread = records whose id is not in `readIds`, grouped by workspaceId.
    /// Workspaces with zero unread are omitted from the result.
    public static func unreadCounts(records: [NotificationRecord],
                                    readIds: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records where !readIds.contains(r.id) {
            counts[r.workspaceId, default: 0] += 1
        }
        return counts
    }

    /// The notification ids belonging to a workspace (used to mark them read).
    public static func ids(in records: [NotificationRecord],
                           forWorkspace workspaceId: String) -> Set<String> {
        Set(records.lazy.filter { $0.workspaceId == workspaceId }.map(\.id))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/genie/dev/side/cmux-iphone && swift test --filter WorkspaceNotificationTallyTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add Sources/SharedKit/WorkspaceNotificationTally.swift Tests/SharedKitTests/WorkspaceNotificationTallyTests.swift
git commit -m "feat(shared): add WorkspaceNotificationTally for per-workspace unread counts"
```

---

## Task 2: NotificationStore read tracking

**Files:**
- Modify: `ios/CmuxRemote/Stores/NotificationStore.swift`

No unit test (iOS app target; the logic is in the tally tested in Task 1). Verified by build + Task 5 integration.

- [ ] **Step 1: Add read-tracking state**

In `ios/CmuxRemote/Stores/NotificationStore.swift`, inside `public final class NotificationStore`, add two stored properties immediately after `public var onNew: (...)?`:
```swift
    public private(set) var unreadByWorkspace: [String: Int] = [:]
    private var readIds: Set<String> = []
```

- [ ] **Step 2: Recompute unread on append and prune readIds on eviction**

Replace the existing `append(_:)` method:
```swift
    public func append(_ notification: NotificationRecord) {
        let isNew = seenIds.insert(notification.id).inserted
        items.insert(notification, at: 0)
        if items.count > 200 {
            let evicted = items[200...].map(\.id)
            items.removeLast(items.count - 200)
            for id in evicted { seenIds.remove(id) }
        }
        if isNew { onNew?(notification) }
    }
```
with:
```swift
    public func append(_ notification: NotificationRecord) {
        let isNew = seenIds.insert(notification.id).inserted
        items.insert(notification, at: 0)
        if items.count > 200 {
            let evicted = items[200...].map(\.id)
            items.removeLast(items.count - 200)
            for id in evicted {
                seenIds.remove(id)
                readIds.remove(id)
            }
        }
        recomputeUnread()
        if isNew { onNew?(notification) }
    }

    /// Mark every currently-known notification for a workspace as read, so the
    /// workspace's badge clears. Called when the user opens that workspace.
    public func markWorkspaceSeen(_ workspaceId: String) {
        readIds.formUnion(WorkspaceNotificationTally.ids(in: items, forWorkspace: workspaceId))
        recomputeUnread()
    }

    private func recomputeUnread() {
        unreadByWorkspace = WorkspaceNotificationTally.unreadCounts(records: items, readIds: readIds)
    }
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
cd /Users/genie/dev/side/cmux-iphone/ios && xcodebuild build -project CmuxRemote.xcodeproj -scheme CmuxRemote -destination "${CMUX_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" -quiet 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add ios/CmuxRemote/Stores/NotificationStore.swift
git commit -m "feat(ios): track per-workspace unread notifications in NotificationStore"
```

---

## Task 3: Per-workspace badge in the workspace list

**Files:**
- Modify: `ios/CmuxRemote/Workspace/WorkspaceListView.swift`

- [ ] **Step 1: Accept `notifStore` and pass `unreadCount` into each card**

In `WorkspaceListView`, add the store property after `@Bindable var store: WorkspaceStore`:
```swift
    let notifStore: NotificationStore
```

Replace the `ForEach(filteredWorkspaces)` block:
```swift
                        ForEach(filteredWorkspaces) { workspace in
                            WorkspaceCard(
                                workspace: workspace,
                                surfaceCount: store.surfaceCount(for: workspace.id),
                                isSelected: store.selectedId == workspace.id
                            ) {
                                store.selectedId = workspace.id
                                onSelect(workspace)
                            }
                        }
```
with:
```swift
                        ForEach(filteredWorkspaces) { workspace in
                            WorkspaceCard(
                                workspace: workspace,
                                surfaceCount: store.surfaceCount(for: workspace.id),
                                unreadCount: notifStore.unreadByWorkspace[workspace.id] ?? 0,
                                isSelected: store.selectedId == workspace.id
                            ) {
                                store.selectedId = workspace.id
                                onSelect(workspace)
                            }
                        }
```

- [ ] **Step 2: Add `unreadCount` to `WorkspaceCard` and render the badge**

In the `private struct WorkspaceCard`, add the property after `let surfaceCount: Int`:
```swift
    let unreadCount: Int
```

In `WorkspaceCard.body`, replace the trailing portion of the `HStack`:
```swift
                Spacer()

                if isSelected {
                    Text("→")
                        .cmuxDisplay(16)
                        .foregroundStyle(CmuxTheme.accentGreen)
                }
```
with:
```swift
                Spacer()

                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .cmuxDisplay(9)
                        .foregroundStyle(CmuxTheme.canvas)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(CmuxTheme.accentRed)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .accessibilityLabel("\(unreadCount) unread notifications")
                }

                if isSelected {
                    Text("→")
                        .cmuxDisplay(16)
                        .foregroundStyle(CmuxTheme.accentGreen)
                }
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
cd /Users/genie/dev/side/cmux-iphone/ios && xcodebuild build -project CmuxRemote.xcodeproj -scheme CmuxRemote -destination "${CMUX_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" -quiet 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` (NOTE: this build will surface the missing `notifStore:` argument at the `WorkspaceListView(...)` call site in `ContentView.swift` — that is fixed in Task 4. If building Task 3 alone fails only on that call site, proceed to Task 4 and build there.)

- [ ] **Step 4: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add ios/CmuxRemote/Workspace/WorkspaceListView.swift
git commit -m "feat(ios): render per-workspace unread badge in workspace list"
```

---

## Task 4: Wire notifStore + mark-seen on open

**Files:**
- Modify: `ios/CmuxRemote/ContentView.swift`

- [ ] **Step 1: Pass `notifStore` to `WorkspaceListView` and mark seen on select**

In `ContentView.body`, replace the `.workspaces` case:
```swift
            case .workspaces:
                WorkspaceListView(store: workspaceStore) { _ in selectedTab = .active }
```
with:
```swift
            case .workspaces:
                WorkspaceListView(store: workspaceStore, notifStore: notifStore) { workspace in
                    notifStore.markWorkspaceSeen(workspace.id)
                    selectedTab = .active
                }
```

- [ ] **Step 2: Mark seen when opening from a notification**

Replace `open(notification:)`:
```swift
    private func open(notification: NotificationRecord) {
        if workspaceStore.workspaces.contains(where: { $0.id == notification.workspaceId }) {
            workspaceStore.selectedId = notification.workspaceId
            requestedSurfaceId = notification.surfaceId
        } else {
            requestedSurfaceId = nil
        }
        selectedTab = .active
    }
```
with:
```swift
    private func open(notification: NotificationRecord) {
        if workspaceStore.workspaces.contains(where: { $0.id == notification.workspaceId }) {
            workspaceStore.selectedId = notification.workspaceId
            requestedSurfaceId = notification.surfaceId
            notifStore.markWorkspaceSeen(notification.workspaceId)
        } else {
            requestedSurfaceId = nil
        }
        selectedTab = .active
    }
```

- [ ] **Step 3: Build the app to verify it compiles**

Run:
```bash
cd /Users/genie/dev/side/cmux-iphone/ios && xcodebuild build -project CmuxRemote.xcodeproj -scheme CmuxRemote -destination "${CMUX_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" -quiet 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/genie/dev/side/cmux-iphone
git add ios/CmuxRemote/ContentView.swift
git commit -m "feat(ios): clear workspace badge on open + wire notifStore into list"
```

---

## Task 5: Verify navigation + full verification

**Files:** none (verification only)

- [ ] **Step 1: Confirm `WorkspaceView` honors `preferredSurfaceId` (read-only check)**

Run: `cd /Users/genie/dev/side/cmux-iphone && grep -nE "preferredSurfaceId|subscribeFirstSurfaceIfNeeded|subscribeAndPinToBottom" ios/CmuxRemote/Workspace/WorkspaceView.swift | head`
Expected: shows `.onChange(of: preferredSurfaceId)`, a preferred-surface subscribe path, and `subscribeFirstSurfaceIfNeeded` (nil fallback). No code change expected. If the preferred surface is NOT subscribed on change, wire a call to `surfaceStore.subscribe(workspaceId:surfaceId:)` in the `.onChange(of: preferredSurfaceId)` handler — otherwise skip.

- [ ] **Step 2: Run the pure tally tests + build the app**

Run:
```bash
cd /Users/genie/dev/side/cmux-iphone && swift test --filter WorkspaceNotificationTallyTests 2>&1 | tail -10
cd ios && xcodebuild build -project CmuxRemote.xcodeproj -scheme CmuxRemote -destination "${CMUX_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" -quiet 2>&1 | tail -20
```
Expected: tally tests PASS; `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual integration check (requires the reconnect fix live + a running cmux)**

1. Launch the app on a device/simulator connected to the relay, with at least one workspace.
2. In Settings, tap the test-notification action (`onTriggerTestNotification`).

Expected:
- The notification appears in the Inbox tab.
- The originating workspace shows a red unread badge in the Workspaces list.
- Tapping the notification (Inbox) switches to the terminal and subscribes to that workspace's surface (its tab).
- Returning to Workspaces and opening that workspace clears its badge.

- [ ] **Step 4: Final state**

Run: `cd /Users/genie/dev/side/cmux-iphone && git status -sb && git log --oneline -6`
Expected: clean tree on `fix/relay-cmux-reconnect`; commits for the tally, NotificationStore, WorkspaceListView, ContentView.

---

## Self-Review notes

- **Spec coverage:** §Design.1 → Task 1; §Design.2 → Task 2; §Design.3 → Task 3; §Design.4 → Task 4; §Design.5 (navigation verify) → Task 5 Step 1; §Design.6 (integration) → Task 5 Step 3; read/clear semantics → Tasks 2+4; testing → Task 1 + Task 5.
- **Type consistency:** `WorkspaceNotificationTally.unreadCounts(records:readIds:)` / `ids(in:forWorkspace:)`, `NotificationStore.unreadByWorkspace` / `markWorkspaceSeen(_:)`, `WorkspaceCard(... unreadCount:)`, `WorkspaceListView(store:notifStore:)` are used identically across tasks.
- **No placeholders:** every code step has complete code; every command has expected output. Task 3 Step 3 explicitly notes the expected cross-file build dependency resolved in Task 4.
