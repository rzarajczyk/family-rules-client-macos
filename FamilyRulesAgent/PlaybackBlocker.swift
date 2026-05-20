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

/// Uses `nowplaying-cli` (https://github.com/kirtan-shah/nowplaying-cli) to detect
/// the currently playing app. The binary must be installed on the system;
/// `NowPlayingCliTool` handles installation / status checking.
///
/// `nowplaying-cli get bundleIdentifier playbackRate` prints two lines:
///   line 1 – bundle ID of the now-playing app, or "null"
///   line 2 – playback rate (1 = playing, 0 = paused / stopped)
final class MediaRemotePlaybackProbe: MediaRemotePlaybackProbeProtocol, @unchecked Sendable {

    init() {}

    func snapshot(timeout: TimeInterval = 5) -> PlaybackAppSnapshot? {
        guard let binaryURL = NowPlayingCliTool.binaryURL else { return nil }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["get", "clientBundleIdentifier", "playbackRate"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            DiagnosticsLogger.record(error: error, context: "MediaRemotePlaybackProbe: failed to launch nowplaying-cli")
            return nil
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                DiagnosticsLogger.record("MediaRemotePlaybackProbe: nowplaying-cli timed out")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard lines.count >= 2 else { return nil }
        let bundleId = lines[0]
        let rate = Double(lines[1]) ?? 0

        guard bundleId != "null", !bundleId.isEmpty, rate > 0 else { return nil }

        let application = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }

        return PlaybackAppSnapshot(
            identifier: bundleId,
            name: application?.localizedName,
            pid: application?.processIdentifier,
            isPlaying: true
        )
    }
}


