import Foundation

/// Manages the `nowplaying-cli` external tool.
///
/// nowplaying-cli (https://github.com/kirtan-shah/nowplaying-cli) is a small
/// Apple-signed binary that queries MediaRemote and works on plain macOS
/// installations without Xcode. It can be installed via Homebrew.
///
/// The app functions without it — media-playing detection is simply skipped.
enum NowPlayingCliTool {

    // MARK: - Known candidate paths

    private static let candidatePaths: [String] = [
        "/opt/homebrew/bin/nowplaying-cli",   // Apple Silicon Homebrew
        "/usr/local/bin/nowplaying-cli",       // Intel Homebrew
        "/opt/local/bin/nowplaying-cli",       // MacPorts
    ]

    // MARK: - Status

    enum Status: Equatable {
        /// Binary found and executable at `path`.
        case installed(path: String)
        /// Binary not found; Homebrew is available for auto-install.
        case notInstalledBrewAvailable
        /// Binary not found; Homebrew not available either.
        case notInstalledNoBrewAvailable
        /// Auto-install via Homebrew is currently in progress.
        case installing
    }

    /// Current status — computed fresh each call (fast path check only).
    static var status: Status {
        if let path = installedPath {
            return .installed(path: path)
        }
        return brewPath != nil ? .notInstalledBrewAvailable : .notInstalledNoBrewAvailable
    }

    /// URL to the binary when installed, `nil` otherwise.
    static var binaryURL: URL? {
        guard let path = installedPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `true` when the binary is present and executable.
    static var isInstalled: Bool {
        installedPath != nil
    }

    // MARK: - Auto-install via Homebrew

    /// Attempts to install `nowplaying-cli` via `brew install`.
    /// Calls `completion` on the main thread with `true` on success.
    static func installViaBrew(completion: @escaping @MainActor (Bool) -> Void) {
        guard let brew = brewPath else {
            Task { @MainActor in completion(false) }
            return
        }

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "nowplaying-cli"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DiagnosticsLogger.record(error: error, context: "NowPlayingCliTool: brew install failed")
                await MainActor.run { completion(false) }
                return
            }
            let success = installedPath != nil
            DiagnosticsLogger.record("NowPlayingCliTool: brew install finished, installed=\(success)")
            await MainActor.run { completion(success) }
        }
    }

    // MARK: - Private helpers

    private static var installedPath: String? {
        candidatePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static var brewPath: String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
