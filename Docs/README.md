# FamilyRules macOS Client

Native macOS menu-bar agent for FamilyRules. See `000-SPEC.md` for the full product spec.

Current implementation includes:

- `FamilyRulesAgent`: menu bar app with setup, dashboard, diagnostics, device-state enforcement, and server sync
- `FamilyRulesHelper`: XPC helper for privileged actions (lock screen, switch user, logout, terminate app, media playback probe)
- registration, `client-info`, and `/report` sync
- foreground/visible-app and screen/session activity tracking
- server command pipeline: `SEND_LOGS`, `DISABLE`, `UNINSTALL`
- restricted-app blocking with overlay UX
- media playback reporting and blocking
- server-backed "All My Devices" view
- explicit local unregister flow

## Project Layout

- `FamilyRulesClient.xcodeproj`: Xcode project
- `FamilyRulesAgent/`: menu bar app code
- `FamilyRulesHelper/`: XPC helper code
- `Shared/`: shared XPC protocol code
- `Config/`: `Info.plist` and entitlements
- `Docs/`: product spec (`000-SPEC.md`) and this guide

## Helper Role

`FamilyRulesHelper` is an XPC service invoked by the agent for privileged operations:

- screen lock and switch-user (via `login.framework`)
- logout (via AppleScript)
- force-terminate a blocked app
- media playback snapshot (via MediaRemote private framework)

The helper does **not** poll the server or relaunch the agent. Autostart is managed by `SMAppService` login-item registration in the agent.

## Requirements

You need:

- macOS
- Xcode installed
- an Apple signing identity configured in Xcode
- a reachable FamilyRules server
- a valid parent username and password on that server

## Open The Project In Xcode

1. Start Xcode.
2. Choose `Open a project or file`.
3. Open `FamilyRulesClient.xcodeproj`.

## Configure Signing In Xcode

1. In Xcode, select the project navigator on the left.
2. Click the top-level project `FamilyRulesClient`.
3. Select the `FamilyRulesAgent` target.
4. Open the `Signing & Capabilities` tab.
5. Check `Automatically manage signing`.
6. Choose your Apple team in the `Team` dropdown.
7. Repeat the same steps for the `FamilyRulesHelper` target.

If Xcode says the bundle identifiers already exist on your team, change them to something unique, for example:

- `com.yourname.familyrules.agent`
- `com.yourname.familyrules.agent.helper`

If you change the helper bundle identifier, also update `Shared/FamilyRulesHelperXPCProtocol.swift` so `HelperXPC.serviceName` matches the helper bundle identifier exactly.

## Build And Run The App

1. In Xcode, select the `FamilyRulesAgent` scheme.
2. Choose `My Mac` as the run destination.
3. Press `Cmd+R`.
4. Look for the shield icon in the menu bar near the clock.

On first run, the setup window should open automatically.

## Initial Setup Flow

The setup window asks for:

- server URL
- parent username
- parent password
- instance name

### Fill In The Form

1. Enter the server URL, for example `https://your-server.example.com`.
2. Enter the parent username.
3. Enter the parent password.
4. Enter the instance name for this Mac.
5. Click `Register`.

### Expected Result

If registration succeeds:

- the setup window closes
- the diagnostics window opens
- diagnostics show `Registration: Registered`
- the instance ID is shown in diagnostics
- restarting the app should skip setup and keep the registration

If registration fails:

- the setup window stays open
- an error message is shown inline

## What Gets Stored Where

Step 2 intentionally splits persistence:

- SQLite stores:
  - server URL
  - username
  - instance ID
  - instance name
- Keychain stores:
  - instance token

### SQLite Location

The SQLite database is stored at:

`~/Library/Application Support/FamilyRulesAgent/FamilyRules.sqlite3`

### Keychain Entry

The token is stored in Keychain under:

- service: `com.familyrules.agent.registration`
- account: `instanceToken`

## Dashboard Window

Open it from the menu bar with `Open Dashboard` (left-click on the tray icon also opens the dashboard).

It shows:

- live screen time for the current day
- current foreground app
- foreground and visible-app usage breakdowns
- registration and sync status

The dashboard overflow menu (⋯) includes admin actions such as **Refresh Device State** and **Unregister This Mac**.

### Refresh Device State

Use **Refresh Device State** in the dashboard overflow menu to force an immediate `/report` sync and display the current server device state and any pending commands. This is useful when verifying that a state change from the server GUI has reached the Mac.

## All My Devices Window

Open it from the menu bar with `Open All My Devices`.

It shows server-backed usage groups from `POST /api/v2/groups-usage-report`:

- group name
- total time per group
- member apps across devices
- per-app device name
- per-app usage duration

Use `Refresh` to reload the latest group usage snapshot from the server.

## Diagnostics Window

Open it from the menu bar with `Open Diagnostics`.

It shows:

- registration status
- saved server URL, username, instance name, and instance ID
- screen awake and session active state
- foreground app
- sync status and last `client-info` / `/report` activity
- last server device state and command activity
- recent sync log lines
- **log file location** (`~/Library/Application Support/FamilyRulesAgent/Diagnostics.log`) with an option to open it in Finder
- helper reachability and last helper reply
- login-item / service-management status

You can also use `Open Setup` from the menu if you want to bring the setup window back manually.

## Remote Admin Commands

The macOS client advertises these capabilities in `/api/v2/client-info`:

- `LOGS_COMMAND` — gates `SEND_LOGS`
- `DISABLE_COMMAND` — gates `DISABLE`
- `UNINSTALL_COMMAND` — gates `UNINSTALL`

Parents can trigger `DISABLE` and `UNINSTALL` from the server GUI (Devices page → Device menu) when the device advertises the matching capability.

### `DISABLE`

- confirms the command with the server, then shuts down
- unregisters the login item (stops autostart)
- **preserves** local registration, Keychain token, and SQLite data
- manual relaunch resumes normal operation and re-registers autostart

### `UNINSTALL`

- confirms the command with the server, then shuts down
- unregisters the login item
- **wipes** Keychain token and `~/Library/Application Support/FamilyRulesAgent/`
- manual relaunch opens initial setup again

These replace the legacy `APP_DISABLED` device state, which could not reliably stop the agent because the helper would relaunch it. The helper no longer polls the server or relaunches the agent.

## Unregister This Mac

The menu bar includes an explicit `Unregister This Mac` action for admin cleanup.

It will:

- call `POST /api/v2/unregister-instance`
- remove the saved token from Keychain
- delete the local SQLite settings database
- delete the local command queue database
- delete the local diagnostics log
- unregister the app login item when available

If the server unregister request fails, the app still proceeds with local cleanup and reports that failure in the completion dialog.

## Command-Line Build

You can build from Terminal with:

```bash
xcodebuild -project FamilyRulesClient.xcodeproj -scheme FamilyRulesAgent -configuration Debug build
```

## Command-Line Tests

You can run the unit tests from Terminal with:

```bash
xcodebuild -project FamilyRulesClient.xcodeproj -scheme FamilyRulesAgent -configuration Debug test
```

The current test suite covers:

- `AppModel` registration loading, save, and unregister behavior
- `RegistrationClient` request construction, unregister, and groups-usage-report decoding
- `AllDevicesModel` server-backed group loading and error handling
- `UsageAccumulator` foreground/screen-time accounting
- `ServerSyncClient` `client-info` and `report` request handling
- `SyncController` startup sync, active/inactive report behavior, `SEND_LOGS`, and `DISABLE`/`UNINSTALL` lifecycle commands
- `DiagnosticsLogStore` log rotation and trimming

## Manual Smoke Test

1. Run the app from Xcode.
2. Confirm the setup window appears automatically if the app is not registered yet.
3. Complete registration with real server credentials.
4. Grant Accessibility permission when prompted.
5. Keep the session unlocked with the screen awake for at least 30 seconds.
6. Open the dashboard and confirm screen time and usage sections are populated.
7. Switch between apps and confirm usage values update.
8. Open diagnostics and confirm `Last Client-Info` and `Last Report` update.
9. Use **Refresh Device State** in the dashboard menu and confirm the current server state is shown.
10. Stop the app and run it again — setup should not reappear.
11. Open `All My Devices` and confirm grouped usage cards load from the server.
12. From the server GUI, send **Request logs** and confirm the client uploads logs.
13. Use `Unregister This Mac` and confirm the app returns to setup mode.
14. Verify `~/Library/Application Support/FamilyRulesAgent/` no longer contains local databases/log after unregister.

## Implemented Features

- initial setup UI and registration against `POST /api/v2/register-instance`
- registration persistence in SQLite and Keychain
- startup and 10-minute `client-info` scheduling
- startup and 30-second `/report` scheduling while active
- foreground and visible-app tracking
- parent-facing dashboard with live usage summary
- server-backed `All My Devices` window
- device state enforcement (lock, switch user, restricted apps, media playback block)
- command queue persistence with `SEND_LOGS`, `DISABLE`, and `UNINSTALL`
- explicit unregister flow with server deregistration and local cleanup
- diagnostics log file with rotation

## What Is Still Not Included

- watchdog relaunch after agent kill (helper no longer auto-relaunches)
- signed `.pkg` build/notarization artifacts checked into this repo
- dashboard UX refinements tracked in `001.md` (tabs, scrolling, menu consolidation)

See `000-SPEC.md` for the full delivery plan and acceptance criteria.

## Troubleshooting

If setup succeeds but is forgotten after restart:

1. Check whether `~/Library/Application Support/FamilyRulesAgent/FamilyRules.sqlite3` exists.
2. Open diagnostics and see whether a startup error is shown.
3. Check whether the Keychain entry exists for service `com.familyrules.agent.registration`.

If registration fails with `INVALID_PASSWORD`:

1. Re-check the parent username.
2. Re-check the parent password.
3. Confirm the account exists on the server.

If registration fails with `INSTANCE_ALREADY_EXISTS`:

1. Change the instance name.
2. Register again.

If the helper ping fails:

1. Clean the build folder in Xcode: `Product` -> `Clean Build Folder`.
2. Run the app again.
3. Open diagnostics and retry `Ping Helper`.
