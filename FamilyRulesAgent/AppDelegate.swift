import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()
    let diagnosticsStore = DiagnosticsStore()

    private var statusItem: NSStatusItem?
    private var diagnosticsWindowController: NSWindowController?
    private var setupWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()

        if !appModel.isRegistered {
            openSetupWindow()
        }
    }

    @objc
    private func openDiagnosticsWindow() {
        if diagnosticsWindowController == nil {
            let hostingController = NSHostingController(rootView: DiagnosticsView(store: diagnosticsStore, appModel: appModel))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "FamilyRules Diagnostics"
            window.setContentSize(NSSize(width: 620, height: 320))
            window.isReleasedWhenClosed = false
            diagnosticsWindowController = NSWindowController(window: window)
        }

        diagnosticsStore.refreshServiceManagementState()
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

    private func handleRegistrationCompleted() {
        setupWindowController?.close()
        openDiagnosticsWindow()
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
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "FamilyRules")
            button.image?.isTemplate = true
            button.toolTip = "FamilyRules"
        }

        let menu = NSMenu()

        let openDiagnostics = NSMenuItem(title: "Open Diagnostics", action: #selector(openDiagnosticsWindow), keyEquivalent: "")
        openDiagnostics.target = self
        menu.addItem(openDiagnostics)

        let openSetup = NSMenuItem(title: "Open Setup", action: #selector(openSetupWindow), keyEquivalent: "")
        openSetup.target = self
        menu.addItem(openSetup)

        let pingHelper = NSMenuItem(title: "Ping Helper", action: #selector(pingHelper), keyEquivalent: "")
        pingHelper.target = self
        menu.addItem(pingHelper)

#if DEBUG
        menu.addItem(.separator())
        let debugQuit = NSMenuItem(title: "Quit (Debug)", action: #selector(debugQuit), keyEquivalent: "q")
        debugQuit.target = self
        menu.addItem(debugQuit)
#endif

        item.menu = menu
    }
}
