# FamilyRules macOS Client

This repository currently contains step 1 from the implementation plan: a native macOS project skeleton with:

- `FamilyRulesAgent`: a menu bar app
- `FamilyRulesHelper`: an embedded XPC helper skeleton
- a basic helper ping flow shown in a diagnostics window
- placeholder signing configuration for Xcode

## Tooling Status On This Machine

I verified the currently installed Apple tooling before implementation:

- `swift --version`: installed
- `xcode-select -p`: points to Command Line Tools only
- `xcodebuild -version`: failed because full Xcode is not installed or not selected
- `xcodegen`: not installed

Current result: you can edit the project files now, but you cannot build the macOS app until full Xcode is installed and selected.

## What You Need To Install

1. Install Xcode from the Mac App Store.
2. Open Xcode once and accept the license if prompted.
3. Switch the active developer directory to Xcode.

Run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

4. Verify the switch worked.

Run:

```bash
xcodebuild -version
swift --version
```

Expected result: `xcodebuild` should print an Xcode version instead of the Command Line Tools error.

## Project Layout

- `FamilyRulesClient.xcodeproj`: Xcode project
- `FamilyRulesAgent/`: menu bar app code
- `FamilyRulesHelper/`: XPC helper code
- `Shared/`: code shared between agent and helper
- `Config/`: `Info.plist` and entitlements

## Open The Project In Xcode

1. Start Xcode.
2. Choose `Open a project or file`.
3. Open `FamilyRulesClient.xcodeproj`.

## Configure Signing In Xcode

You need to do this once before the app can run on your Mac.

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

1. In Xcode, select the `FamilyRulesAgent` scheme near the top toolbar.
2. Choose `My Mac` as the run destination.
3. Press the Run button or use `Cmd+R`.
4. Look for a shield icon in the macOS menu bar near the clock.
5. Click the menu bar icon.
6. Choose `Open Diagnostics`.
7. In the diagnostics window, click `Ping Helper`.

Expected result:

- the app runs as a menu bar app
- it does not appear as a normal Dock app
- the diagnostics window opens
- `Helper Reachability` changes to `Reachable`
- `Last Helper Reply` shows a `pong from helper ...` message

## What Step 1 Includes

- Menu bar app skeleton
- Debug-only quit item
- Diagnostics window
- Basic helper communication over XPC
- Xcode target structure for app and helper
- Placeholder signing and entitlements setup

## What Step 1 Does Not Include Yet

- initial setup flow
- server registration
- persistence
- reporting
- app usage collection
- start-at-login
- helper blessing / privileged daemon install
- watchdog / relaunch behavior

Those are planned for later steps in `PLAN.md`.

## Command-Line Build After Xcode Is Installed

After Xcode is installed and signing is configured in Xcode, you can try:

```bash
xcodebuild -project FamilyRulesClient.xcodeproj -scheme FamilyRulesAgent -configuration Debug build
```

If signing is not configured yet, Xcode will usually show a signing error. Fix signing in the GUI first, then retry.

## Troubleshooting

If `xcodebuild -version` still fails:

1. Check whether `/Applications/Xcode.app` exists.
2. Re-run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

3. Open Xcode manually once.
4. Retry `xcodebuild -version`.

If the helper ping fails:

1. Confirm the app target embeds `FamilyRulesHelper.xpc`.
2. Confirm the helper bundle identifier matches `HelperXPC.serviceName`.
3. Clean the build folder in Xcode: `Product` -> `Clean Build Folder`.
4. Run again.
