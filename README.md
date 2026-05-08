# FamilyRules macOS Client

This repository currently contains steps 1 and 2 from the implementation plan:

- `FamilyRulesAgent`: a native macOS menu bar app
- `FamilyRulesHelper`: an embedded XPC helper skeleton
- helper ping diagnostics
- initial setup window
- `POST /api/v2/register-instance` integration
- secure persistence split across SQLite and Keychain

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

## Diagnostics Window

Open it from the menu bar with `Open Diagnostics`.

It shows:

- registration status
- saved server URL
- saved username
- saved instance name
- saved instance ID
- helper reachability
- last helper reply
- service-management status

You can also use `Open Setup` from the menu if you want to bring the setup window back manually.

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
- `RegistrationClient` request construction and server status mapping

## Manual Test For Step 2

1. Run the app from Xcode.
2. Confirm the setup window appears automatically if the app is not registered yet.
3. Complete registration with real server credentials.
4. Confirm diagnostics shows `Registered` and the returned instance ID.
5. Stop the app.
6. Run it again.
7. Confirm setup does not appear again.
8. Open diagnostics and confirm the saved registration is still loaded.

## What Step 2 Includes

- initial setup UI
- registration against `POST /api/v2/register-instance`
- registration persistence in SQLite and Keychain
- startup logic for registered vs unregistered state
- diagnostics updated to show registration state

## What Step 2 Does Not Include Yet

- periodic `client-info`
- periodic `/report`
- app usage collection
- start-at-login
- watchdog relaunch
- permissions flow
- blocked app handling
- lock/logout flows

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
