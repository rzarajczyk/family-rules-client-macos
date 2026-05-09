import Combine
import Foundation
import ServiceManagement

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published var helperConnectionState = "Idle"
    @Published var helperLastReply = "No ping yet"
    @Published var serviceManagementState = ServiceManagementBridge.registrationDescription()

    func refreshServiceManagementState() {
        serviceManagementState = ServiceManagementBridge.registrationDescription()
    }

    func performPing() {
        helperConnectionState = "Connecting"

        Task {
            do {
                let reply = try await HelperXPCClient().ping()
                helperConnectionState = "Reachable"
                helperLastReply = reply
            } catch {
                helperConnectionState = "Failed"
                helperLastReply = error.localizedDescription
            }
        }
    }
}

protocol DiagnosticsLogStoreProtocol {
    func loadRecentLines(limit: Int) throws -> [String]
    func append(line: String) throws
    func exportArchive() throws -> DiagnosticsLogArchive
}

struct DiagnosticsLogArchive: Equatable {
    let text: String
    let lineCount: Int
}

final class DiagnosticsLogStore: DiagnosticsLogStoreProtocol {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = AgentPersistencePaths.diagnosticsLogURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Returns up to `limit` lines in reverse-chronological order (newest first),
    /// suitable for display in a scrolling UI list.
    func loadRecentLines(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        let lines = try allLines()
        return Array(lines.suffix(limit).reversed())
    }

    func append(line: String) throws {
        try ensureParentDirectory()

        let data = Data((line + "\n").utf8)
        if fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    /// Returns all lines in chronological order (oldest first), suitable for
    /// packaging and uploading. Contrast with `loadRecentLines`, which reverses order.
    func exportArchive() throws -> DiagnosticsLogArchive {
        let lines = try allLines()
        return DiagnosticsLogArchive(text: lines.joined(separator: "\n"), lineCount: lines.count)
    }

    private func allLines() throws -> [String] {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    private func ensureParentDirectory() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

enum AgentPersistencePaths {
    /// The FamilyRulesAgent application support directory.
    /// Computed once at process start and cached as a static constant.
    static let applicationSupportDirectory: URL = {
        let fileManager = FileManager.default
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return root.appendingPathComponent("FamilyRulesAgent", isDirectory: true)
    }()

    static let diagnosticsLogURL: URL =
        applicationSupportDirectory.appendingPathComponent("Diagnostics.log")

    static let settingsDatabaseURL: URL =
        applicationSupportDirectory.appendingPathComponent("FamilyRules.sqlite3")

    static let commandQueueDatabaseURL: URL =
        applicationSupportDirectory.appendingPathComponent("CommandQueue.sqlite3")
}

enum ServiceManagementBridge {
    static func registrationDescription() -> String {
        if #available(macOS 13.0, *) {
            return "mainApp: \(SMAppService.mainApp.status.description)"
        }

        return "SMAppService requires macOS 13+"
    }

    static func registerMainAppIfAvailable() throws {
        guard #available(macOS 13.0, *) else {
            return
        }

        if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        }
    }

    static func unregisterMainAppIfAvailable() throws {
        guard #available(macOS 13.0, *) else {
            return
        }

        if SMAppService.mainApp.status != .notFound {
            try SMAppService.mainApp.unregister()
        }
    }
}

@available(macOS 13.0, *)
private extension SMAppService.Status {
    var description: String {
        switch self {
        case .enabled:
            return "enabled"
        case .notFound:
            return "notFound"
        case .notRegistered:
            return "notRegistered"
        case .requiresApproval:
            return "requiresApproval"
        @unknown default:
            return "unknown"
        }
    }
}
