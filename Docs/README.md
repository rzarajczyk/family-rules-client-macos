# FamilyRules macOS Client

This repository currently contains steps 1, 2, and part of step 3 from the implementation plan:

- `FamilyRulesAgent`: a native macOS menu bar app
- `FamilyRulesHelper`: an embedded XPC helper skeleton
- helper ping diagnostics
- initial setup window
- `POST /api/v2/register-instance` integration
- secure persistence split across SQLite and Keychain
- startup and periodic `client-info` sync
- startup and periodic `/report` sync while active
- foreground-app and screen/session activity tracking

## Project Layout

- `FamilyRulesClient.xcodeproj`: Xcode project
- `FamilyRulesAgent/`: menu bar app code
- `FamilyRulesHelper/`: XPC helper code
- `Shared/`: shared XPC protocol code
- `Config/`: `Info.plist` and entitlements

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

Open it from the menu bar with `Open Dashboard`.

It shows:

- live screen time for the current day
- current foreground app
- current visible app count
- foreground usage breakdown by app
- visible-app usage breakdown by app
- registration state
- sync status and last report/client-info activity

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
- saved server URL
- saved username
- saved instance name
- saved instance ID
- screen awake state
- session active state
- foreground app
- sync status
- last `client-info`
- last `/report`
- last server device state
- recent sync log lines
- helper reachability
- last helper reply
- service-management status

You can also use `Open Setup` from the menu if you want to bring the setup window back manually.

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

- `AppModel` registration loading and save behavior
- `RegistrationClient` request construction, unregister, and groups-usage-report decoding
- `AllDevicesModel` server-backed group loading and error handling
- `UsageAccumulator` foreground/screen-time accounting
- `ServerSyncClient` `client-info` and `report` request handling
- `SyncController` startup sync and active/inactive report behavior

## Manual Test For Steps 3-10

1. Run the app from Xcode.
2. Confirm the setup window appears automatically if the app is not registered yet.
3. Complete registration with real server credentials.
4. Confirm the setup advances to the permissions step instead of opening dashboard or diagnostics.
5. Grant Accessibility permission and click `Done`.
6. Confirm the setup window closes and only the dashboard opens.
7. Keep the session unlocked with the screen awake for at least 30 seconds.
8. Open the dashboard and confirm screen time and usage sections are populated.
9. Switch between apps and confirm `Foreground App` and dashboard usage values update.
10. Open diagnostics manually and confirm `Last Client-Info` and `Last Report` update.
11. Confirm `Last Device State` reflects the server response from `/report`.
12. Stop the app.
13. Run it again.
14. Confirm setup does not appear again.
15. Open dashboard and diagnostics and confirm the saved registration is still loaded.
16. Open `All My Devices` and confirm grouped usage cards load from the server.
17. Use `Unregister This Mac` and confirm the app returns to setup mode.
18. Verify `~/Library/Application Support/FamilyRulesAgent/` no longer contains the local databases/log after unregister.

## What Steps 3-10 Include

- initial setup UI
- registration against `POST /api/v2/register-instance`
- registration persistence in SQLite and Keychain
- startup logic for registered vs unregistered state
- diagnostics updated to show registration state
- startup and 10-minute `client-info` scheduling
- startup and 30-second `/report` scheduling while active
- foreground-app tracking for report payloads
- visible-app tracking for local accounting
- basic local sync logging and sync status in diagnostics/menu
- parent-facing dashboard with live usage summary and per-app breakdowns
- server-backed `All My Devices` window
- explicit unregister flow with server deregistration and local cleanup
- command queue persistence and `SEND_LOGS`

## What Is Still Not Included Yet

- watchdog relaunch
- permissions flow
- historical dashboard trends
- signed `.pkg` build/notarization artifacts checked into this repo

Those are planned in later steps in `PLAN.md`.

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
