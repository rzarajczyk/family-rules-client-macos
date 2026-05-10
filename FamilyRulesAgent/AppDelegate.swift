import AppKit
import ApplicationServices
import Combine
import SwiftUI

struct RestrictedAppEnforcementState {
    private(set) var blockedAppIdentifier: String?

    var isPresentingOverlay: Bool {
        blockedAppIdentifier != nil
    }

    mutating func reconcile(
        restrictedAppBlockingEnabled: Bool,
        frontmostAppIdentifier: String?,
        visibleAppIdentifiers: Set<String>,
        blockedAppIdentifiers: Set<String>
    ) -> String? {
        guard restrictedAppBlockingEnabled else {
            blockedAppIdentifier = nil
            return nil
        }

        if let current = blockedAppIdentifier,
           visibleAppIdentifiers.contains(current),
           blockedAppIdentifiers.contains(current) {
            return current
        }

        if let frontmostAppIdentifier,
           visibleAppIdentifiers.contains(frontmostAppIdentifier),
           blockedAppIdentifiers.contains(frontmostAppIdentifier) {
            blockedAppIdentifier = frontmostAppIdentifier
            return frontmostAppIdentifier
        }

        blockedAppIdentifier = nil
        return nil
    }

    mutating func clear() {
        blockedAppIdentifier = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appModel: AppModel
    let diagnosticsStore: DiagnosticsStore
    let activityMonitor: ActivityMonitor
    let lifecycleController: LifecycleController
    let syncController: SyncController
    let allDevicesModel: AllDevicesModel

    private var statusItem: NSStatusItem?
    private var dashboardWindowController: NSWindowController?
    private var diagnosticsWindowController: NSWindowController?
    private var setupWindowController: NSWindowController?
    private var syncStatusMenuItem: NSMenuItem?
    private var foregroundAppMenuItem: NSMenuItem?
    private var lifecycleStatusMenuItem: NSMenuItem?
    private var moreMenu: NSMenu?
    private var switchUserEnforcementTask: Task<Void, Never>?
    private var stateWindowControllers: [NSWindowController] = []
    private var refreshTask: Task<Void, Never>?
    private var restrictedAppEnforcementState = RestrictedAppEnforcementState()
    /// Tracks when the All My Devices data was last fetched so we avoid firing a
    /// network request every time the menu item is clicked while data is fresh.
    private var allDevicesLastRefreshedAt: Date?
    private let allDevicesStalenessInterval: TimeInterval = 60

    override init() {
        let activityMonitor = ActivityMonitor()
        let lifecycleController = LifecycleController()
        self.appModel = AppModel()
        self.diagnosticsStore = DiagnosticsStore()
        self.activityMonitor = activityMonitor
        self.lifecycleController = lifecycleController
        self.syncController = SyncController(activityMonitor: activityMonitor, lifecycleController: lifecycleController)
        self.allDevicesModel = AllDevicesModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activityMonitor.start()
        configureStatusItem()
        startRefreshLoop()

        if let registration = appModel.registration {
            Task {
                await syncController.start(registration: registration)
            }
        } else {
            openSetupWindow()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStatusItems()
    }

    @objc
    private func openDashboardWindow() {
        if dashboardWindowController == nil {
#if DEBUG
            let debugQuitAction: (() -> Void)? = { [weak self] in self?.debugQuit() }
#else
            let debugQuitAction: (() -> Void)? = nil
#endif

            let hostingController = NSHostingController(rootView: DashboardView(
                appModel: appModel,
                activityMonitor: activityMonitor,
                syncController: syncController,
                lifecycleController: lifecycleController,
                allDevicesModel: allDevicesModel,
                onOpenDiagnostics: { [weak self] in self?.openDiagnosticsWindow() },
                onOpenSetup: { [weak self] in self?.openSetupWindow() },
                onPingHelper: { [weak self] in self?.pingHelper() },
                onUnregister: { [weak self] in self?.unregisterThisMac() },
                onDebugQuit: debugQuitAction
            ))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "FamilyRules Dashboard"
            window.setContentSize(NSSize(width: 820, height: 640))
            window.isReleasedWhenClosed = false
            dashboardWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        dashboardWindowController?.showWindow(nil)
        dashboardWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc
    private func openDiagnosticsWindow() {
        if diagnosticsWindowController == nil {
            let hostingController = NSHostingController(rootView: DiagnosticsView(
                store: diagnosticsStore,
                appModel: appModel,
                activityMonitor: activityMonitor,
                lifecycleController: lifecycleController,
                syncController: syncController
            ))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "FamilyRules Diagnostics"
            window.setContentSize(NSSize(width: 700, height: 520))
            window.isReleasedWhenClosed = false
            diagnosticsWindowController = NSWindowController(window: window)
        }

        diagnosticsStore.refreshServiceManagementState()
        Task {
            await lifecycleController.refreshDiagnostics()
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindowController?.showWindow(nil)
        diagnosticsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc
    private func openSetupWindow() {
        if setupWindowController == nil {
            let hostingController = NSHostingController(rootView: SetupView(appModel: appModel) { [weak self] in
                self?.handleRegistrationCompleted()
            })
            let window = NSWindow(contentViewController: hostingController)
            window.title = "FamilyRules Setup"
            window.setContentSize(NSSize(width: 620, height: 320))
            window.isReleasedWhenClosed = false
            setupWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        setupWindowController?.showWindow(nil)
        setupWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc
    private func pingHelper() {
        openDiagnosticsWindow()
        diagnosticsStore.performPing()
    }

    @objc
    private func unregisterThisMac() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unregister This Mac"
        alert.informativeText = "This removes the saved FamilyRules registration, local logs, and queued commands from this user account."
        alert.addButton(withTitle: "Unregister")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            syncController.stop()
            var loginItemErrorMessage: String?

            do {
                try ServiceManagementBridge.unregisterMainAppIfAvailable()
                syncController.recordUninstallLog("Unregistered FamilyRules login item")
            } catch {
                loginItemErrorMessage = error.localizedDescription
                syncController.recordUninstallLog("Failed to unregister login item: \(error.localizedDescription)")
            }

            let result = await appModel.unregisterAndClearLocalState(log: { [weak self] message in
                self?.syncController.recordUninstallLog(message)
            })

            let completionAlert = NSAlert()
            completionAlert.alertStyle = result.localCleanupErrorMessage == nil ? .informational : .warning
            completionAlert.messageText = "Unregister Complete"
            completionAlert.informativeText = [result.summary, loginItemErrorMessage.map { "Login item cleanup failed: \($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            completionAlert.runModal()

            guard result.localCleanupErrorMessage == nil else {
                if let registration = appModel.registration {
                    await syncController.start(registration: registration)
                }
                return
            }

            allDevicesModel.refresh(registration: nil)
            dashboardWindowController?.close()
            diagnosticsWindowController?.close()
            openSetupWindow()
        }
    }

    private func updateStateWindow() {
        let snapshot = activityMonitor.snapshot()
        let restrictedAppIdentifier = restrictedAppEnforcementState.reconcile(
            restrictedAppBlockingEnabled: lifecycleController.restrictedAppBlockingEnabled,
            frontmostAppIdentifier: snapshot.activeApps.first,
            visibleAppIdentifiers: snapshot.visibleApps,
            blockedAppIdentifiers: syncController.blockedAppIdentifiers
        )

        let restrictedAppPresentation = restrictedAppIdentifier.map {
            RestrictedAppOverlayPresentation(
                appIdentifier: $0,
                appName: syncController.blockedAppNames[$0] ?? snapshot.knownApps[$0]?.name ?? $0
            )
        }

        let shouldShow = lifecycleController.countdownPresentation != nil || restrictedAppPresentation != nil

        if shouldShow {
            let screens = NSScreen.screens
            // Remove controllers whose window no longer matches a live screen.
            var retainedControllers: [NSWindowController] = []
            for wc in stateWindowControllers {
                guard let window = wc.window else { continue }

                let shouldRetain: Bool
                if lifecycleController.shouldPresentCompactCountdown {
                    shouldRetain = compactCountdownScreen(for: window, screens: screens) != nil
                } else {
                    shouldRetain = screens.contains { $0.frame == window.frame }
                }

                if shouldRetain {
                    retainedControllers.append(wc)
                } else {
                    window.close()
                }
            }
            stateWindowControllers = retainedControllers
            // Add a window for any screen that does not yet have one.
            let targetScreens = screens
            for screen in targetScreens {
                let targetFrame = lifecycleController.shouldPresentCompactCountdown ? compactCountdownFrame(for: screen) : screen.frame
                let alreadyCovered = stateWindowControllers.contains { controller in
                    guard let window = controller.window else { return false }
                    if lifecycleController.shouldPresentCompactCountdown {
                        return compactCountdownScreen(for: window, screens: screens) == screen
                    }

                    return window.frame == targetFrame
                }
                if !alreadyCovered {
                    let hostingController = NSHostingController(rootView: StateOverlayView(
                        countdownPresentation: lifecycleController.countdownPresentation,
                        restrictedAppPresentation: restrictedAppPresentation,
                        compactCountdown: lifecycleController.shouldPresentCompactCountdown,
                        onMinimizeAllWindows: { [weak self] in self?.handleMinimizeRestrictedAppWindows() }
                    ))
                    let window = NSPanel(contentViewController: hostingController)
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.styleMask = lifecycleController.shouldPresentCompactCountdown ? [.borderless, .nonactivatingPanel] : [.borderless]
                    window.level = stateWindowLevel(compactCountdown: lifecycleController.shouldPresentCompactCountdown)
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    window.backgroundColor = .clear
                    window.isOpaque = false
                    window.hidesOnDeactivate = false
                    window.ignoresMouseEvents = false
                    window.setFrame(targetFrame, display: true)
                    window.isMovableByWindowBackground = lifecycleController.shouldPresentCompactCountdown
                    window.isReleasedWhenClosed = false
                    let wc = NSWindowController(window: window)
                    stateWindowControllers.append(wc)
                }
            }
            // Update content and show all overlay windows.
            let title = lifecycleController.countdownPresentation?.title ?? restrictedAppPresentation?.appName ?? "FamilyRules"
            for wc in stateWindowControllers {
                if let hc = wc.contentViewController as? NSHostingController<StateOverlayView> {
                    hc.rootView = StateOverlayView(
                        countdownPresentation: lifecycleController.countdownPresentation,
                        restrictedAppPresentation: restrictedAppPresentation,
                        compactCountdown: lifecycleController.shouldPresentCompactCountdown,
                        onMinimizeAllWindows: { [weak self] in self?.handleMinimizeRestrictedAppWindows() }
                    )
                }
                wc.window?.title = title
                wc.window?.level = stateWindowLevel(compactCountdown: lifecycleController.shouldPresentCompactCountdown)
                if !lifecycleController.shouldPresentCompactCountdown,
                   let screen = screenContaining(window: wc.window, screens: screens) {
                    wc.window?.setFrame(screen.frame, display: true)
                }
                wc.window?.orderFrontRegardless()
            }
        } else {
            stateWindowControllers.forEach { $0.window?.close() }
            stateWindowControllers = []
        }

        updateSwitchUserLoop()
    }

    private func handleMinimizeRestrictedAppWindows() {
        guard let targetIdentifier = restrictedAppEnforcementState.blockedAppIdentifier else { return }

        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: targetIdentifier)
        for application in applications {
            let axApp = AXUIElementCreateApplication(application.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for axWindow in windows {
                    AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                }
            }
        }

        // Activate Finder so the desktop is in the foreground after minimizing.
        if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.open(finderURL)
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await MainActor.run {
                self?.attemptRestrictedAppFallbackIfNeeded(targetIdentifier: targetIdentifier)
            }
        }
    }

    private func attemptRestrictedAppFallbackIfNeeded(targetIdentifier: String) {
        let snapshot = activityMonitor.snapshot()
        let shouldTerminate = snapshot.visibleApps.contains(targetIdentifier)
        guard shouldTerminate else {
            restrictedAppEnforcementState.clear()
            updateStateWindow()
            return
        }

        Task {
            _ = await lifecycleController.performRestrictedAppFallbackTermination(targetIdentifier: targetIdentifier)
        }
    }

    private func handleRegistrationCompleted() {
        if let registration = appModel.registration {
            Task {
                await syncController.start(registration: registration)
            }
        }

        setupWindowController?.close()
        allDevicesLastRefreshedAt = Date()
        allDevicesModel.refresh(registration: appModel.registration)
        openDiagnosticsWindow()
        openDashboardWindow()
    }

#if DEBUG
    @objc
    private func debugQuit() {
        NSApp.terminate(nil)
    }
#endif

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            updateStatusItemImage()
            button.toolTip = "FamilyRules"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.delegate = self

        let syncStatusMenuItem = NSMenuItem(title: "Sync: Idle", action: nil, keyEquivalent: "")
        syncStatusMenuItem.isEnabled = false
        menu.addItem(syncStatusMenuItem)
        self.syncStatusMenuItem = syncStatusMenuItem

        let foregroundAppMenuItem = NSMenuItem(title: "Foreground: None", action: nil, keyEquivalent: "")
        foregroundAppMenuItem.isEnabled = false
        menu.addItem(foregroundAppMenuItem)
        self.foregroundAppMenuItem = foregroundAppMenuItem

        menu.addItem(.separator())

        let lifecycleStatusMenuItem = NSMenuItem(title: "Lifecycle: Inactive", action: nil, keyEquivalent: "")
        lifecycleStatusMenuItem.isEnabled = false
        menu.addItem(lifecycleStatusMenuItem)
        self.lifecycleStatusMenuItem = lifecycleStatusMenuItem

        menu.addItem(.separator())

        let openDiagnostics = NSMenuItem(title: "Open Diagnostics", action: #selector(openDiagnosticsWindow), keyEquivalent: "")
        openDiagnostics.target = self
        menu.addItem(openDiagnostics)

        let openSetup = NSMenuItem(title: "Open Setup", action: #selector(openSetupWindow), keyEquivalent: "")
        openSetup.target = self
        menu.addItem(openSetup)

        let pingHelper = NSMenuItem(title: "Ping Helper", action: #selector(pingHelper), keyEquivalent: "")
        pingHelper.target = self
        menu.addItem(pingHelper)

        menu.addItem(.separator())

        let unregister = NSMenuItem(title: "Unregister This Mac", action: #selector(unregisterThisMac), keyEquivalent: "")
        unregister.target = self
        menu.addItem(unregister)

#if DEBUG
        menu.addItem(.separator())
        let debugQuit = NSMenuItem(title: "Quit (Debug)", action: #selector(debugQuit), keyEquivalent: "q")
        debugQuit.target = self
        menu.addItem(debugQuit)
#endif

        moreMenu = menu
        refreshMenuStatusItems()
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openDashboardWindow()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            openDashboardMenu(of: sender)
            return
        }

        openDashboardWindow()
    }

    private func openDashboardMenu(of view: NSView? = nil) {
        guard let menu = moreMenu else { return }
        refreshMenuStatusItems()

        let statusButton = statusItem?.button
        let anchorView = view ?? statusButton
        guard let anchorView else { return }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height + 4), in: anchorView)
    }

    private func refreshAllDevicesIfNeeded(force: Bool = false) {
        let isStale = allDevicesLastRefreshedAt.map { Date().timeIntervalSince($0) > allDevicesStalenessInterval } ?? true
        guard force || isStale || allDevicesModel.groups.isEmpty else { return }
        allDevicesLastRefreshedAt = Date()
        allDevicesModel.refresh(registration: appModel.registration)
    }

    private func compactCountdownFrame(for screen: NSScreen?) -> NSRect {
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 280, height: 170)
        }

        return NSRect(
            x: visibleFrame.maxX - 304,
            y: visibleFrame.maxY - 194,
            width: 280,
            height: 170
        )
    }

    private func stateWindowLevel(compactCountdown: Bool) -> NSWindow.Level {
        compactCountdown ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) : .screenSaver
    }

    private func screenContaining(window: NSWindow?, screens: [NSScreen]) -> NSScreen? {
        guard let frame = window?.frame else { return nil }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return screens.first { $0.frame.contains(center) }
    }

    private func compactCountdownScreen(for window: NSWindow, screens: [NSScreen]) -> NSScreen? {
        if let screen = window.screen, screens.contains(screen) {
            return screen
        }

        return screenContaining(window: window, screens: screens)
    }

    private func updateSwitchUserLoop() {
        if lifecycleController.shouldEnforceSwitchUserLoop {
            guard switchUserEnforcementTask == nil else { return }

            switchUserEnforcementTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.lifecycleController.shouldEnforceSwitchUserLoop {
                    do {
                        _ = try await HelperXPCClient().executeDeviceAction(HelperDeviceActionRequest(action: .switchUser, requestedAt: Date()))
                    } catch {
                        DiagnosticsLogger.record(error: error, context: "Failed to enforce switch-user loop")
                    }

                    do {
                        try await Task.sleep(for: .seconds(3))
                    } catch {
                        return
                    }
                }
            }
        } else {
            switchUserEnforcementTask?.cancel()
            switchUserEnforcementTask = nil
        }
    }

    private func refreshMenuStatusItems() {
        syncStatusMenuItem?.title = "Sync: \(syncController.syncStatus)"
        foregroundAppMenuItem?.title = "Foreground: \(activityMonitor.frontmostApplicationName)"
        lifecycleStatusMenuItem?.title = "Lifecycle: \(lifecycleController.statusDescription)"
        updateStatusItemImage()
        updateStateWindow()
    }

    private func updateStatusItemImage() {
        statusItem?.button?.image = AppIconImage.loadStatusBarImage(
            blockingEnabled: appModel.isRegistered && lifecycleController.lastObservedDeviceState != "ACTIVE",
            size: NSSize(width: 18, height: 18)
        )
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshMenuStatusItems()

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }
}
