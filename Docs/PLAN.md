# FamilyRules macOS Native Client Implementation Plan

## Implementation Steps

1. **Bootstrap signed app + helper skeleton**
   - Create the Xcode project with two targets: `FamilyRulesAgent` and `FamilyRulesHelper`.
   - Set up code signing, entitlements, app groups if needed, and the minimal `SMAppService`/`SMJobBless` path.
   - Implement a working menu bar app with a simple status menu and a basic XPC ping to the helper.
   - End state: a launchable signed app that lives in the menu bar, can talk to the helper, and shows basic diagnostics.
   - Testable by: launch app, verify menu bar presence, verify helper registration, run XPC ping from UI.

2. **Initial setup + secure persistence**
   - Build the Initial Setup flow: server URL, parent username/password, instance name.
   - Wire `POST /api/v2/register-instance`.
   - Store token in Keychain and basic settings in SQLite.
   - Add startup logic: show setup when unregistered, normal mode when registered.
   - End state: a working app that can register with the server and remember its identity across restarts.
   - Testable by: complete setup, restart app, verify it skips setup and loads stored registration.

3. **Core sync loop: `client-info` + basic reporting**
   - Implement periodic `client-info` and `report` scheduling.
   - Start with screen-on tracking and foreground app tracking only.
   - Add basic local logging and sync status in the menu UI.
   - End state: a working monitoring app that registers, syncs with the server, and reports usable data every cycle.
   - Testable by: inspect server requests, verify startup sync, 10-minute `client-info`, 30-second reports while active.

4. **Visible-app collector + reconciliation loop**
   - Add event-driven tracking plus the 1-second reconciliation loop.
   - Collect visible-app usage internally while keeping upload payload foreground-only.
   - Handle sleep/wake and lock/unlock transitions correctly.
   - End state: a working app with the full intended usage model, even though only foreground totals are uploaded.
   - Testable by: open multiple apps/windows, verify local visible-app totals and correct screen-time accounting.

5. **Dashboard UI**
   - Add a parent-facing dashboard window accessible from the menu bar.
   - Present the live usage data already collected locally: screen time, foreground totals, visible-app totals, and current activity state.
   - Surface registration and sync health in a more product-facing layout than diagnostics.
   - Keep the first dashboard iteration read-only and based on current in-memory data; historical trends and server-backed views stay for later phases.
   - End state: a usable dashboard window that gives a clear overview of the device without relying on diagnostics.
   - Testable by: open the dashboard, verify live values update while switching apps, and confirm it stays consistent with diagnostics.

6. **Helper-backed lifecycle hardening**
   - Add agent relaunch/watchdog behavior.
   - Add start-at-login and recovery after agent kill.
   - Implement `ADMIN_DISABLED` handling at the lifecycle level, including helper-side reactivation polling.
   - End state: a working app that survives casual termination and can enter/exit admin-disabled mode safely.
   - Testable by: kill agent, verify relaunch; force `ADMIN_DISABLED`, verify enforcement pauses and helper can reactivate.

7. **State engine + lock/logout flows**
   - Implement unified state handling for `ACTIVE`, `LOCK_SCREEN`, `LOCK_SCREEN_WITH_TIMEOUT`, `LOGOUT`, `LOGOUT_WITH_TIMEOUT`, and legacy mappings.
   - Add countdown UI and helper-executed lock/logout actions.
   - Keep blocked-app mode out of this step.
   - End state: a working app that fully reacts to non-app-blocking server states.
   - Testable by: simulate each state locally or from server, verify countdowns, lock, logout, and recovery.

8. **Restricted app blocking**
   - Implement blocked-app fetch/cache and state arming.
   - Add overlay windows, Android-derived branding, and the `Minimize all windows` action.
   - Apply the persistence rule: overlay stays while blocked app is still running with visible windows.
   - Add helper kill fallback.
   - End state: a working parental-control app with actual restricted-app enforcement.
   - Testable by: mark an app blocked, launch/focus it, verify overlay behavior, minimize flow, and fallback termination.

9. **Commands + diagnostics**
   - Implement command persistence, ack/result flow, and `SEND_LOGS`.
   - Add local log viewer and packaging of logs for upload.
   - End state: a working app that matches Android's server command behavior.
   - Testable by: inject a `SEND_LOGS` command, verify ack, result upload, and retry behavior after restart.

10. **All My Devices + install/uninstall polish**
    - Build the `All My Devices` UI from `groups-usage-report`.
    - Finalize installer behavior, explicit uninstall path, `unregister-instance`, and Keychain cleanup.
    - Do final packaging/notarization work and multi-user smoke tests.
    - End state: a full working product matching the spec closely enough for end-to-end validation.
    - Testable by: install from package, complete setup, use app normally, uninstall cleanly, verify server deregistration.

## Recommended Cut Points

- First useful demo: Step 3
- First resilient background app: Step 6
- First real parental-control milestone: Step 8
- First release candidate: Step 10

## Why This Split Works

- The app is usable after every step.
- The risky platform pieces land early: signing, helper, persistence, lifecycle.
- Enforcement features come after the sync/state backbone is stable.
- Each step has a clear manual test surface.
