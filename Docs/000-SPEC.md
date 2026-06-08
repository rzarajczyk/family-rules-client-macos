# SPEC: FamilyRules macOS Native Client

## Goal

Build a native macOS client for FamilyRules that reaches feature parity with the Android client, while preserving the desktop-specific parental-control requirements already present in the Python desktop client.

Target capabilities:
- Runs in the macOS menu bar next to the clock
- Has no normal quit path for the child user
- Is non-uninstallable by a typical child-level user
- Starts automatically at login
- Runs initial setup immediately after install
- Collects screen-on time and app usage
- Sends periodic reports to the server
- Sends periodic client-info to the server
- Reacts to server commands like the Android client
- Shows "All my devices" like the Android app
- Supports lock screen and logout, with or without timeout
- Supports blocking specific apps only
- When a blocked app is opened, shows a lockscreen with a "Minimize all windows" action
- Reuses Android icons and branding assets
- Stores local data in a way that a typical user cannot easily modify or reset

## Source Context

This spec is based on analysis of:
- `~/Developer/family-rules-android`
- `~/Developer/family-rules-client`
- `~/Developer/family-rules-server`

Observed server/API endpoints:
- `POST /api/v2/register-instance`
- `POST /api/v2/client-info`
- `POST /api/v2/report`
- `POST /api/v2/get-blocked-apps`
- `POST /api/v2/groups-usage-report`
- `POST /api/v2/command-acks`
- `POST /api/v2/command-results`

Observed Android behavior:
- Initial setup and registration flow
- Periodic report every 30 seconds
- Periodic client-info every 10 minutes
- Server command ack/result protocol
- App-blocking using overlay UX
- "All devices" view from groups usage report
- Device states:
  - `ACTIVE`
  - `BLOCK_RESTRICTED_APPS`
  - `BLOCK_RESTRICTED_APPS_WITH_TIMEOUT`

Observed legacy desktop behavior:
- Tray/menu bar presence
- Autostart with relaunch
- Lock/logout states
- Remote disable/uninstall via `DISABLE` / `UNINSTALL` server commands
- Multi-monitor blocking overlays
- Initial setup flow
- Periodic reporting
- Legacy desktop states:
  - `ACTIVE`
  - `LOCKED`
  - `LOCKED_WITH_COUNTDOWN`
  - `LOGGED_OUT`
  - `LOGGED_OUT_WITH_COUNTDOWN`

## Product Direction

The macOS client should be a native macOS implementation, not a Python/Qt port.

Recommended stack:
- Swift
- SwiftUI for standard windows
- AppKit for menu bar integration and overlay windows
- SQLite for persistence
- Keychain for secrets
- XPC between agent and helper
- Signed and notarized `.pkg` installer

## High-Level Architecture

Use a two-process architecture.

### 1. FamilyRulesAgent

Runs in the user session.

Responsibilities:
- Menu bar app (`NSStatusItem`)
- Initial setup UI
- Dashboard UI
- "All My Devices" UI
- App usage collection
- Screen-on/session tracking
- Server sync
- Local SQLite database
- Overlay windows for app blocking and countdowns
- Parent-facing diagnostics and logs

### 2. FamilyRulesHelper

Runs as a privileged helper / daemon.

Responsibilities:
- Relaunch the agent if it is killed
- Execute privileged operations
- Lock screen
- Logout
- Force-terminate blocked apps as fallback
- Health/watchdog functionality

### Why two processes

This is required for the requested product behavior:
- "Unclosable" is not credible with a single user-space process
- "Non-uninstallable by the typical user" is not credible with a single user-space process
- Autostart and auto-recovery are more reliable
- Lock/logout are cleaner through a helper
- Tamper resistance is meaningfully better than the current Python bundle

## Installation and Lifecycle

### Packaging

Ship as a signed and notarized `.pkg`.

Installer responsibilities:
- Install the app bundle
- Install/register the privileged helper
- Register per-user login/start behavior
- Set up the files, permissions, and helper-owned directories needed for tamper-resistant local storage
- Trigger initial launch or instruct the user to complete it immediately

### Uninstall path

Uninstall must be an explicit admin action, not a child-visible workflow.

Uninstall responsibilities:
1. Call `POST /api/v2/unregister-instance` to deregister the instance on the server
2. Delete the instance token and all secrets from Keychain
3. Remove the privileged helper and its launchd registration
4. Remove agent login item / launch agent registration
5. Remove the app bundle and helper-managed data directories

If `POST /api/v2/unregister-instance` fails (e.g. no network), log the failure but proceed with local cleanup regardless. Do not silently skip the call.

**Note:** Without explicit Keychain cleanup, the instance token persists after app bundle deletion, creating an orphaned registration on the server.

### First-run behavior

After installation, the app must enter Initial Setup automatically.

Flow:
1. Open Initial Setup window
2. Ask for:
   - server URL
   - parent username
   - parent password
   - instance name
3. Call `POST /api/v2/register-instance`
4. Save:
   - server URL
   - username
   - instance ID
   - instance token
   - instance name
5. Run protection setup
6. Transition into normal background mode

### Protection setup

The setup flow must verify and guide the user through required permissions.

Required:
- Accessibility permission
- Login/start-at-login registration
- Helper installation/approval

Optional:
- User notifications for status/countdowns

Note on Screen Recording:
- Using `CGWindowListCopyWindowInfo` to map PIDs requires Screen Recording permission on macOS 10.15+ if we want window titles or full visual bounds. However, if we only extract `kCGWindowOwnerPID` and filter to `kCGWindowLayerNormalWindow`, we may be able to operate without the explicit user prompt, or at minimum, we must handle the permission prompt gracefully during the setup flow if it triggers. Assume it might be required for v1 depending on API enforcement.

Not required for v1:
- Full Disk Access

## Menu Bar App Behavior

### Normal mode

- The app lives in the menu bar, next to the clock
- It should not appear in the Dock during normal operation
- Closing windows must never exit the app
- There must be no standard "Quit" action in production

### Menu contents

Recommended menu items:
- Open Dashboard
- All My Devices
- Status / Last Sync
- Open Permissions
- Open Logs
- Parent Settings

Developer-only builds may expose:
- Quit

### Meaning of "unclosable"

For this product, "unclosable" means:
- user cannot exit through the UI
- closing windows does not stop monitoring
- if the agent is killed, the helper/watchdog relaunches it

It does not mean a determined administrator can never remove it. The practical requirement is that a child-level user should not be able to stop it easily.

### Meaning of "non-uninstallable by the typical user"

For this product, this means:
- no self-service uninstall UI available to the child user
- app bundle removal alone should not be enough to fully disable the product
- helper/watchdog and launch registration should restore the agent when possible
- configuration, tokens, and durable state should not live in easily editable plain files in user-writable locations

It does not mean a real administrator with full machine control can never remove the software. The product goal is resistance against the normal child-level user, not against the device owner.

## Branding and Icons

Use Android app assets as the visual source of truth.

Use Android icons for:
- app branding
- setup screens
- state icons sent in `client-info`
- restricted-app overlay
- countdown overlay

For the menu bar icon:
- derive a proper monochrome template image from the Android icon
- keep colored Android artwork for windows and overlays

## Data Model and Persistence

Use SQLite.

Recommended tables:
- `settings`
- `known_apps`
- `usage_daily_foreground`
- `usage_daily_visible`
- `screen_time_daily`
- `blocked_apps_cache`
- `server_commands`
- `command_acks`
- `command_results`
- `health_events`
- `logs_index`

The app should keep both raw event data and rolled-up daily totals only as needed. Prefer the smallest schema that supports reliable restart recovery and pending command retries.

### Local data protection

Local data must be stored in a way that a typical user cannot easily inspect, edit, or reset it.

Recommended split:
- Keychain:
  - instance token
  - any long-lived secrets
- SQLite database:
  - usage data
  - command queue state
  - cached blocked app list
  - app inventory
- helper-protected location and permissions where feasible:
  - durable state that should survive simple app-bundle deletion

Requirements:
- do not store secrets in plain JSON or plist files in a user-writable app support directory
- sign/validate internal state where useful so naive edits are detectable
- assume a typical user can inspect `~/Library` and drag app bundles to Trash
- optimize for tamper resistance, not for secrecy against a machine administrator

Recommended implementation details:
- store secrets in Keychain under a stable service name
- store the main SQLite database under a helper-managed or permission-hardened location when feasible
- if some data must remain user-session writable, design it so deleting or editing it does not silently disable monitoring
- detect missing/corrupt local state and repair from helper/server where possible

## App Identity on macOS

Recommended canonical app identifier:
- `bundleId` as primary
- canonical `.app` bundle path as fallback when no bundle ID exists

Reason:
- bundle IDs are more stable across updates than executable paths

Compatibility note:
- the current desktop/server ecosystem historically used path-like identifiers
- the macOS native client should treat the server `appPath` field as an opaque per-platform app identifier

Current working assumption for implementation:
- macOS client uses `bundleId` when available
- stores path as metadata/fallback
- **Decision confirmed: bundleId primary, path fallback**

## Usage Collection

The app must collect:
- screen-on time
- screen time of apps (foreground and visible)
- enough live state to react to server restrictions quickly

### Approach: Custom collector, visible-app model

Apple Screen Time was considered and rejected (poor fit for real-time server-driven telemetry, entitlement/distribution risk, no clean public API for 30-second reporting cycles).

A frontmost-only collector was considered and rejected (not Android parity, loses information in split-screen scenarios).

The chosen approach is a custom visible-app collector:

- `screenTime` = time when at least one display is awake and the session is unlocked
- `frontmost app` = current active app receiving focus
- `visible apps` = apps with at least one visible, non-minimized standard window while the screen/session is active

Implication: app totals may exceed `screenTime` if multiple apps are visible at the same time. This is correct for a concurrent-visibility model and differs from legacy foreground-only semantics.

### Chosen reporting strategy

- collect foreground app usage
- collect visible-app usage
- collect screen-on time
- keep `activeApps` as the current frontmost app
- upload only foreground totals in `/api/v2/report` in phase 1
- preserve the richer visible-app collector for future server/API evolution

Why: preserves compatibility with current server behavior and UI assumptions; avoids breaking totals that assume app usage roughly aligns with screen time.

Future extension: server/API may later add a separate field such as `visibleApplications` to expose the richer model where appropriate.

## Collector Design

The collector should be a hybrid of event-driven tracking plus periodic reconciliation.

### Event sources

Use system events where possible:
- `NSWorkspace.didActivateApplicationNotification`
- app launch notifications
- app terminate notifications
- app hide/unhide notifications
- display sleep/wake notifications
- session lock/unlock notifications

### Reconciliation loop

Also run a low-frequency snapshot loop as a safety net.

Cadence:
- every 1 second

The reconciliation loop should:
- enumerate visible windows using `CGWindowListCopyWindowInfo` (note: requires Screen Recording permission on macOS 10.15+; filter to `kCGWindowLayerNormalWindow` and exclude off-screen or minimized entries)
- map windows to owning apps via `kCGWindowOwnerPID`
- determine which apps are currently visible
- attribute elapsed time accordingly
- correct missed transitions when notifications are incomplete

The reconciliation loop must be paused (skipped entirely) when:
- all displays are asleep
- the session is locked

There is no benefit to polling window state when no screen activity can occur, and it wastes CPU.

### Screen-on definition

Count screen-on time only when:
- at least one display is awake
- the user session is unlocked

Do not count screen-on time while:
- system is sleeping
- displays are sleeping
- the session is locked

## Reporting Contract

### Register instance

Endpoint:
- `POST /api/v2/register-instance`

Request:
- `instanceName`
- `clientType`

Recommended `clientType`:
- `MACOS_NATIVE` (**confirmed**)

Note: the server team must add `MACOS_NATIVE` to the supported `clientType` registry before registration will succeed with this value. Coordinate with server team before Phase 1 goes live.

Fallback if the server cannot support it immediately:
- temporary compatibility value aligned with existing desktop naming

### Client info

Endpoint:
- `POST /api/v2/client-info`

Authentication:
- HTTP Basic Auth: `instanceId:instanceToken` (username:password)
- `instanceId` is sent in the Basic Auth header, **not** in the request body

Send on:
- startup
- every 10 minutes
- app inventory changes
- helper/permission repair if desired

Payload should include:
- app version
- known apps map
- available states
- supported server commands
- optionally timezone/platform metadata if the server accepts it

Known app entry should include:
- app identifier
- display name
- icon as base64 PNG when available

### Report

Endpoint:
- `POST /api/v2/report`

Send every 30 seconds while:
- the session is active
- the screen is on

Payload for phase 1:
- `instanceId`
- `screenTime`
- `applications` as foreground-only usage
- `activeApps` containing the frontmost app identifier if any

### Groups usage report

Endpoint:
- `POST /api/v2/groups-usage-report`

Used by:
- "All My Devices" UI

### Blocked apps

Endpoint:
- `POST /api/v2/get-blocked-apps`

Used when the state is:
- `BLOCK_RESTRICTED_APPS`
- `BLOCK_RESTRICTED_APPS_WITH_TIMEOUT`

### Command ack/result

Endpoints:
- `POST /api/v2/command-acks`
- `POST /api/v2/command-results`

Behavior must mirror Android:
- persist received commands locally
- ack receipt
- execute
- upload results
- retry pending work on startup and after subsequent syncs

## Supported Server Commands

Required for v1:
- `SEND_LOGS`
- `DISABLE`
- `UNINSTALL`

Capabilities advertised in `/api/v2/client-info`:
- `LOGS_COMMAND` — gates `SEND_LOGS`
- `DISABLE_COMMAND` — gates `DISABLE`
- `UNINSTALL_COMMAND` — gates `UNINSTALL`

Implementation behavior (shared pipeline):
- receive command in `/api/v2/report` response or subsequent sync cycle
- persist command locally in SQLite queue
- upload ack through `/api/v2/command-acks`
- execute command locally
- upload result through `/api/v2/command-results`
- mark command complete locally

### `SEND_LOGS`

- collect current diagnostics logs
- package them in the expected result payload
- return `COMPLETED`

### `DISABLE` / `UNINSTALL` (admin maintenance commands)

These replace the legacy server-driven `APP_DISABLED` device state. They are one-shot remote admin actions delivered through the command pipeline, not persistent device states.

Use cases:
- upgrades and repair
- temporary maintenance
- intentional remote shutdown by the parent/admin
- full local wipe before reinstall

#### `DISABLE`

When executed:
- return `COMPLETED` to the server
- after the result upload completes:
  - stop sync/enforcement loops
  - unregister the login item (remove autostart)
  - terminate the agent process
- preserve local registration, Keychain token, SQLite state, and diagnostics

Manual relaunch behavior:
- registration still exists locally
- setup is skipped
- `LifecycleController.start()` re-registers the login item
- agent resumes normal operation

#### `UNINSTALL`

When executed:
- return `COMPLETED` to the server
- after the result upload completes:
  - stop sync/enforcement loops
  - unregister the login item
  - delete Keychain token and `~/Library/Application Support/FamilyRulesAgent/`
  - terminate the agent process

Manual relaunch behavior:
- no local registration remains
- initial setup window opens again

#### Ordering requirement

`DISABLE` and `UNINSTALL` must not terminate or wipe local state before the command result is uploaded. Otherwise the SQLite command queue (and the pending `COMPLETED` result) can be lost.

The agent therefore:
1. executes the command and stores a local `COMPLETED` result
2. uploads the result
3. invokes a lifecycle shutdown callback that performs unregister / wipe / `NSApp.terminate`

#### Resurrection vectors removed

On macOS the only resurrection vectors are:
1. `SMAppService.mainApp` login item
2. helper-driven relaunch

Both commands remove the login item. The helper no longer polls the server or relaunches the agent, so a successful `DISABLE` or `UNINSTALL` leaves no automatic way for the agent to come back until a user manually launches it.

### Why commands instead of `APP_DISABLED`

The legacy `APP_DISABLED` state only soft-disabled the running agent and the helper could still relaunch it, so the app never truly turned off. Explicit `DISABLE` / `UNINSTALL` commands terminate the process and remove autostart, which is the behavior parents expect for maintenance and uninstall.

## Device State Model

There is currently a mismatch between Android and legacy desktop states.

The macOS native client should support a unified state set:
- `ACTIVE`
- `BLOCK_RESTRICTED_APPS`
- `BLOCK_RESTRICTED_APPS_WITH_TIMEOUT`
- `LOCK_SCREEN`
- `LOCK_SCREEN_WITH_TIMEOUT`
- `LOGOUT`
- `LOGOUT_WITH_TIMEOUT`

### Compatibility mapping

Until the server is normalized, the macOS client should accept both old and new names.

Map legacy desktop values as follows:
- `LOCKED` -> `LOCK_SCREEN`
- `LOCKED_WITH_COUNTDOWN` -> `LOCK_SCREEN_WITH_TIMEOUT`
- `LOGGED_OUT` -> `LOGOUT`
- `LOGGED_OUT_WITH_COUNTDOWN` -> `LOGOUT_WITH_TIMEOUT`

### Required server-side changes

The following state names are new and do not currently exist in the server's `availableStates` registry:
- `LOCK_SCREEN`
- `LOCK_SCREEN_WITH_TIMEOUT`
- `LOGOUT`
- `LOGOUT_WITH_TIMEOUT`

The server team must add these to the `availableStates` registry before the macOS client can declare them in `client-info`. Until then, the macOS client must either:
- use only the legacy names it knows the server already supports, or
- negotiate carefully with the server team on rollout timing

This is a required coordination item before the Phase 2 server state features go live.

### State semantics

#### `ACTIVE`
- hide all overlays
- stop countdowns
- disable app blocking

#### `BLOCK_RESTRICTED_APPS`
- fetch blocked app list immediately
- cache it locally
- arm app blocker immediately

#### `BLOCK_RESTRICTED_APPS_WITH_TIMEOUT`
- show countdown
- after timeout, arm app blocker
- default timeout is 60 seconds unless later made server-configurable

#### `LOCK_SCREEN`
- invoke real macOS session lock via helper
- if needed, show FamilyRules overlay while the lock is being executed

#### `LOCK_SCREEN_WITH_TIMEOUT`
- show countdown
- then perform `LOCK_SCREEN`

#### `LOGOUT`
- invoke real logout via helper

#### `LOGOUT_WITH_TIMEOUT`
- show countdown
- then perform `LOGOUT`

## Lock Screen and Overlay UX

### General overlay rules

Use one borderless window per monitor.

Overlay requirements:
- highest practical window level, targeting screen-saver level behavior
- visible across Spaces and full-screen apps
- no title bar
- no close controls
- no standard window interactions

Use Android-derived branding:
- app icon
- blocking colors
- typography/theme approximating Android assets where feasible

### Countdown UI

Two acceptable countdown forms:
- compact top overlay for app-block timeout
- full-screen overlay for lock/logout timeout

The visual style should remain consistent with Android branding.

## Restricted App Blocking

This is a core feature.

### Required behavior

When restricted-app mode is enabled and the user opens a blocked app:
- show the FamilyRules lockscreen overlay
- include a visible "Minimize all windows" action

### Detection

Continuously monitor the frontmost app.

If the frontmost app is in the blocked app set:
- present the overlay immediately

### Overlay persistence rule

**Critical:** Do NOT dismiss the overlay simply because the blocked app is no longer frontmost.

The overlay itself claims focus when shown (at `.screenSaver` window level), which means the blocked app immediately loses "frontmost" status. Keying dismissal off "frontmost app" would cause an immediate flicker loop: blocked app gains focus → overlay shown → overlay claims focus → blocked app no longer frontmost → overlay dismissed → blocked app regains focus → repeat.

Correct rule:
- show the overlay when the blocked app becomes frontmost
- keep the overlay visible as long as the blocked app is **running and has at least one visible non-minimized window**
- dismiss the overlay only when the blocked app's windows are all minimized/closed or the app has terminated

### Overlay contents

Required contents:
- FamilyRules icon/branding from Android assets
- clear message that the app is restricted
- "Minimize all windows" button

Optional contents:
- app name
- small explanatory text

### "Minimize all windows" action

When pressed:
- minimize all standard user windows using Accessibility APIs
- activate Finder or another safe target app

### Fallback behavior

If the blocked app remains frontmost or refuses to minimize:
- the helper may terminate the blocked app process as a fallback

### Why overlay-first is preferred

Overlay-first behavior is preferred over kill-only behavior because it:
- matches Android UX more closely
- explains what happened
- gives the child a safe escape path

## Real Lock vs FamilyRules Overlay

The implementation must distinguish clearly between:

### Restricted-app lockscreen

This is a FamilyRules fullscreen overlay that blocks access to a specific app and offers "Minimize all windows".

### `LOCK_SCREEN`

This means a real macOS session lock.

### `LOGOUT`

This means a real macOS logout.

The old Python desktop behavior blurred some of these distinctions. The native macOS client should implement them explicitly and correctly.

## All My Devices

Replicate the Android feature using `POST /api/v2/groups-usage-report`.

### UI behavior

Accessible from the menu bar.

Recommended presentation:
- SwiftUI window
- grouped cards/list view similar in information density to Android

### Data shown

For each group:
- group name
- total time
- member apps

For each app row:
- app icon
- app name
- device name
- usage duration

## Autostart and Recovery

### Autostart requirement

The app must start automatically at login.

### Recovery requirement

If the user kills the agent process:
- it must be relaunched automatically

Recommended implementation:
- start-at-login registration for the agent
- helper watchdog
- launchd keep-alive semantics where applicable

## Multi-User Machines

The helper is a system-wide daemon shared across all user accounts. The agent runs per-user session.

Rules:
- Keychain items (instance token, secrets) are per-user — stored in the login Keychain of the active user, not in the system Keychain
- SQLite databases are per-user — stored in each user's Application Support directory (or a helper-managed per-user subdirectory)
- the helper must distinguish which user session it is currently servicing — it should not apply enforcement for a logged-in admin account that is not a registered child account
- when multiple users are logged in simultaneously (Fast User Switching), each active session has its own agent instance; the helper must correctly route watchdog and lock/logout actions to the correct session
- registration (`register-instance`) is per-user; each user account that should be managed must complete initial setup independently

For v1, single-user machines are the primary target. Multi-user behavior must be architecturally correct from the start but need not be fully tested in the first release.

## Logging and Diagnostics

The app must keep logs suitable for:
- local diagnosis
- upload through `SEND_LOGS`

Recommended log categories:
- startup/install
- permissions
- report sync
- client-info sync
- state changes
- blocked app detection
- overlay lifecycle
- helper communication
- command queue/execution

## Security and Tamper Resistance

The app is a parental-control product, so weak tamper resistance would undermine the product.

Required posture:
- signed app bundle
- notarized installer
- helper separated from agent
- no normal quit path
- auto-relaunch on kill
- no typical-user uninstall path
- secrets stored outside easy-to-edit plain files
- durable state stored with tamper resistance in mind

Non-goals for v1:
- making the app impossible for an administrator to remove
- MDM-level lockdown
- Apple private API dependency unless absolutely necessary

## Performance Requirements

- idle CPU usage should remain very low
- usage collection should be mostly event-driven
- reconciliation polling should stay low-frequency
- no high-frequency busy polling
- overlays should open immediately when needed

## Acceptance Criteria

- installs as signed/notarized macOS package
- first run enters Initial Setup automatically
- lives in the menu bar next to the clock
- does not expose a normal quit path in production
- window close does not terminate monitoring
- starts automatically at login
- relaunches after agent kill
- tracks screen-on time across sleep/wake and lock/unlock correctly
- collects foreground and visible-app usage internally
- uploads foreground-only app usage in `/api/v2/report` phase 1
- sends client-info on startup and every 10 minutes
- acknowledges and completes server commands like Android
- supports `SEND_LOGS`
- shows "All My Devices" from server data
- supports lock screen and logout with and without timeout
- supports blocking specific apps
- when a blocked app is opened, shows overlay with "Minimize all windows"
- uses Android icons/branding throughout the product
- typical child-level user cannot quit or casually uninstall the product
- local secrets are not stored in easy-to-edit plain files
- app supports remote `DISABLE` and `UNINSTALL` server commands for admin maintenance

## Risks

Main risks:
- server/client app identifier normalization between bundle IDs and legacy path-like IDs
- exact implementation details for reliable macOS logout
- Accessibility edge cases for minimizing windows across apps
- visible-app accounting being richer than current server assumptions
- helper installation/signing/notarization complexity

## Recommended Delivery Plan

### Phase 1
- app signing and code identity setup (required from day one: `SMJobBless`/`SMAppService` XPC trust model requires code signing with specific entitlements; cannot prototype unsigned and sign later)
- menu bar app
- initial setup
- SQLite persistence
- foreground and visible-app collector
- screen-on tracking
- `/client-info`
- `/report`
- no blocking yet

### Phase 2
- unified state handling
- lock screen
- logout
- countdown UX

### Phase 3
- blocked-app mode
- overlay with "Minimize all windows"
- process-kill fallback

### Phase 4
- server commands
- `SEND_LOGS`
- retry queues and resilience

### Phase 5
- All My Devices UI
- notarized `.pkg` packaging
- watchdog hardening

## Final Recommendation

Proceed with:
- native two-process macOS architecture
- custom usage collector, not Apple Screen Time
- visible-app model internally
- foreground-only reporting to `/api/v2/report` in phase 1
- compatibility with both Android and legacy desktop server state names
- remote admin maintenance through `DISABLE` / `UNINSTALL` commands instead of a persistent disabled device state
- Android assets as the branding source

This gives the macOS client Android-level product behavior without breaking the current server contract during the first rollout.
