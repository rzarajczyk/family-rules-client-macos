#!/usr/bin/env swift

import AppKit
import Dispatch
import Foundation
import Darwin

private let mediaRemoteFrameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
private let mediaPlayPauseKeyCode = 16

typealias MRGetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

struct PlaybackSnapshot {
    let pid: pid_t?
    let isPlaying: Bool?

    var runningApplication: NSRunningApplication? {
        guard let pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    var description: String {
        guard let runningApplication else {
            if isPlaying == true {
                return "playing app: <unknown pid>, isPlaying=true"
            }

            return "playing app: none"
        }

        let name = runningApplication.localizedName ?? "Unknown"
        let bundleIdentifier = runningApplication.bundleIdentifier ?? "<no bundle id>"
        return "playing app: \(name) [\(bundleIdentifier)] pid=\(runningApplication.processIdentifier) isPlaying=\(isPlaying.map(String.init) ?? "unknown")"
    }
}

final class MediaRemoteProbe {
    private let handle: UnsafeMutableRawPointer
    private let getNowPlayingApplicationPID: MRGetNowPlayingApplicationPID
    private let getNowPlayingApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying?
    private let callbackQueue = DispatchQueue(label: "media-playback-spike.mediaremote")

    init() throws {
        guard let handle = dlopen(mediaRemoteFrameworkPath, RTLD_NOW) else {
            let message = dlerror().map { String(cString: $0) } ?? "Unknown dlopen error"
            throw ProbeError("Failed to open MediaRemote: \(message)")
        }

        self.handle = handle

        guard let pidSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") else {
            let message = dlerror().map { String(cString: $0) } ?? "Unknown dlsym error"
            dlclose(handle)
            throw ProbeError("Missing MRMediaRemoteGetNowPlayingApplicationPID: \(message)")
        }

        getNowPlayingApplicationPID = unsafeBitCast(pidSymbol, to: MRGetNowPlayingApplicationPID.self)

        if let playingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getNowPlayingApplicationIsPlaying = unsafeBitCast(playingSymbol, to: MRGetNowPlayingApplicationIsPlaying.self)
        } else {
            getNowPlayingApplicationIsPlaying = nil
        }
    }

    deinit {
        dlclose(handle)
    }

    func snapshot(timeout: TimeInterval = 2) -> PlaybackSnapshot {
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

        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            return PlaybackSnapshot(pid: nil, isPlaying: nil)
        }

        if isPlaying == false {
            return PlaybackSnapshot(pid: nil, isPlaying: false)
        }

        return PlaybackSnapshot(pid: pid, isPlaying: isPlaying)
    }
}

struct ProbeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@discardableResult
private func simulatePlayPauseMediaKey() -> Bool {
    func post(keyDown: Bool) -> Bool {
        let keyState = keyDown ? 0xA : 0xB
        let data1 = Int((mediaPlayPauseKeyCode << 16) | (keyState << 8))
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

do {
    let probe = try MediaRemoteProbe()
    print("media_playback_spike started at \(Date())")

    var tick = 0
    while true {
        tick += 1
        let snapshot = probe.snapshot()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] \(snapshot.description)")
        fflush(stdout)

        if tick % 4 == 0 {
            if snapshot.isPlaying == true, snapshot.pid != nil {
                let success = simulatePlayPauseMediaKey()
                let target = snapshot.runningApplication?.bundleIdentifier ?? "<unknown>"
                print("[\(timestamp)] stop attempt for \(target): \(success ? "sent media key" : "failed to send media key")")
            } else {
                print("[\(timestamp)] stop attempt skipped: no playing app detected")
            }
            fflush(stdout)
        }

        Thread.sleep(forTimeInterval: 5)
    }
} catch {
    fputs("media_playback_spike failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
