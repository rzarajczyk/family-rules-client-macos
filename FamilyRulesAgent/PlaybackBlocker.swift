import AppKit
import Dispatch
import Foundation
import Darwin

protocol PlaybackBlockingProtocol: Actor {
    func updateConfiguration(enabled: Bool, blockedApplications: [BlockedAppPayload]) async
    func setEnabled(_ enabled: Bool) async
    func clear() async
    func enforceIfNeeded() async
}

actor PlaybackBlocker: PlaybackBlockingProtocol {
    private let probe: any MediaRemotePlaybackProbeProtocol
    private let sleep: @Sendable (Int) async throws -> Void
    private let enforcementIntervalSeconds: Int

    private var blockedApplicationIdentifiers: Set<String> = []
    private var blockedApplicationNames: [String: String] = [:]
    private var isEnabled = false
    private var enforcementTask: Task<Void, Never>?

    init(
        probe: any MediaRemotePlaybackProbeProtocol = MediaRemotePlaybackProbe(),
        enforcementIntervalSeconds: Int = 5,
        sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.probe = probe
        self.enforcementIntervalSeconds = enforcementIntervalSeconds
        self.sleep = sleep
    }

    func updateConfiguration(enabled: Bool, blockedApplications: [BlockedAppPayload]) async {
        blockedApplicationIdentifiers = Set(blockedApplications.map(\.appPath))
        blockedApplicationNames = blockedApplications.reduce(into: [:]) { partialResult, app in
            if let name = app.appName, !name.isEmpty {
                partialResult[app.appPath] = name
            }
        }

        DiagnosticsLogger.record(
            "Playback blocking configuration updated: enabled=\(enabled), blockedApps=\(blockedApplicationIdentifiers.count)"
        )

        applyEnabledState(enabled)
    }

    func setEnabled(_ enabled: Bool) async {
        applyEnabledState(enabled)
    }

    func clear() async {
        blockedApplicationIdentifiers = []
        blockedApplicationNames = [:]
        applyEnabledState(false)
    }

    func enforceIfNeeded() async {
        guard isEnabled, !blockedApplicationIdentifiers.isEmpty else { return }
        guard let snapshot = probe.snapshot(), snapshot.isPlaying else { return }
        guard blockedApplicationIdentifiers.contains(snapshot.identifier) else { return }

        let appName = blockedApplicationNames[snapshot.identifier] ?? snapshot.name ?? snapshot.identifier
        let didSendPause = await MainActor.run { Self.simulatePlayPauseMediaKey() }

        if didSendPause {
            DiagnosticsLogger.record("Playback blocking pause requested for \(appName) [\(snapshot.identifier)]")
        } else {
            DiagnosticsLogger.record("Playback blocking failed to send media key for \(appName) [\(snapshot.identifier)]")
        }
    }

    private func applyEnabledState(_ enabled: Bool) {
        guard isEnabled != enabled else {
            if enabled {
                startEnforcementLoopIfNeeded()
            } else {
                stopEnforcementLoop()
            }
            return
        }

        isEnabled = enabled
        DiagnosticsLogger.record("Playback blocking \(enabled ? "enabled" : "disabled")")

        if enabled {
            startEnforcementLoopIfNeeded()
        } else {
            stopEnforcementLoop()
        }
    }

    private func startEnforcementLoopIfNeeded() {
        guard enforcementTask == nil else { return }

        enforcementTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.enforceIfNeeded()

                do {
                    try await self.sleep(self.enforcementIntervalSeconds)
                } catch {
                    return
                }

                let shouldContinue = await self.shouldContinueEnforcementLoop()
                if !shouldContinue {
                    return
                }
            }
        }
    }

    private func shouldContinueEnforcementLoop() -> Bool {
        isEnabled && !blockedApplicationIdentifiers.isEmpty
    }

    private func stopEnforcementLoop() {
        enforcementTask?.cancel()
        enforcementTask = nil
    }

    @MainActor
    private static func simulatePlayPauseMediaKey() -> Bool {
        func post(keyDown: Bool) -> Bool {
            let keyCode = 16
            let keyState = keyDown ? 0xA : 0xB
            let data1 = Int((keyCode << 16) | (keyState << 8))

            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else {
                return false
            }

            event.cgEvent?.post(tap: .cghidEventTap)
            return true
        }

        return post(keyDown: true) && post(keyDown: false)
    }
}

protocol MediaRemotePlaybackProbeProtocol: Sendable {
    func snapshot(timeout: TimeInterval) -> PlaybackAppSnapshot?
}

extension MediaRemotePlaybackProbeProtocol {
    func snapshot() -> PlaybackAppSnapshot? {
        snapshot(timeout: 2)
    }
}

struct PlaybackAppSnapshot: Equatable, Sendable {
    let identifier: String
    let name: String?
    let pid: pid_t?
    let isPlaying: Bool
}

final class MediaRemotePlaybackProbe: MediaRemotePlaybackProbeProtocol, @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer?
    private let callbackQueue = DispatchQueue(label: "com.familyrules.playback-blocker.mediaremote")
    private let getNowPlayingApplicationPID: MRGetNowPlayingApplicationPID?
    private let getNowPlayingApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying?

    init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let message = dlerror().map { String(cString: $0) } ?? "Unknown dlopen error"
            DiagnosticsLogger.record("Playback blocking failed to open MediaRemote: \(message)")
            self.handle = nil
            self.getNowPlayingApplicationPID = nil
            self.getNowPlayingApplicationIsPlaying = nil
            return
        }

        self.handle = handle

        if let pidSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
            getNowPlayingApplicationPID = unsafeBitCast(pidSymbol, to: MRGetNowPlayingApplicationPID.self)
        } else {
            getNowPlayingApplicationPID = nil
            let message = dlerror().map { String(cString: $0) } ?? "Unknown dlsym error"
            DiagnosticsLogger.record("Playback blocking missing MRMediaRemoteGetNowPlayingApplicationPID: \(message)")
        }

        if let playingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getNowPlayingApplicationIsPlaying = unsafeBitCast(playingSymbol, to: MRGetNowPlayingApplicationIsPlaying.self)
        } else {
            getNowPlayingApplicationIsPlaying = nil
            DiagnosticsLogger.record("Playback blocking missing MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func snapshot(timeout: TimeInterval = 2) -> PlaybackAppSnapshot? {
        guard let getNowPlayingApplicationPID else { return nil }

        let group = DispatchGroup()
        var pid: pid_t?
        var isPlaying: Bool?

        group.enter()
        getNowPlayingApplicationPID(callbackQueue) { value in
            pid = value > 0 ? value : nil
            group.leave()
        }

        if let getNowPlayingApplicationIsPlaying {
            group.enter()
            getNowPlayingApplicationIsPlaying(callbackQueue) { value in
                isPlaying = value
                group.leave()
            }
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            DiagnosticsLogger.record("Playback blocking timed out waiting for MediaRemote state")
            return nil
        }

        guard isPlaying != false else { return nil }
        guard let pid else { return nil }
        guard let application = NSRunningApplication(processIdentifier: pid) else { return nil }

        let identifier = application.bundleIdentifier
            ?? application.bundleURL?.path(percentEncoded: false)
            ?? application.executableURL?.path(percentEncoded: false)
            ?? String(pid)

        return PlaybackAppSnapshot(
            identifier: identifier,
            name: application.localizedName,
            pid: pid,
            isPlaying: isPlaying ?? true
        )
    }
}

private typealias MRGetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
private typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
