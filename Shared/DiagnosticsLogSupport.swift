import Foundation

enum DiagnosticsLogFormatting {
    static func timestamp(for date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

enum DiagnosticsLogLimits {
    static let maxFileSizeBytes: UInt64 = 2 * 1024 * 1024
    static let trimInterval: TimeInterval = 2 * 60 * 60
}

enum DiagnosticsLogFileIO {
    static func append(
        line: String,
        to fileURL: URL,
        maxFileSizeBytes: UInt64 = DiagnosticsLogLimits.maxFileSizeBytes,
        trimInterval: TimeInterval = DiagnosticsLogLimits.trimInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = Data((line + "\n").utf8)
        let path = fileURL.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }

        try trimToMaxSizeIfNeeded(
            at: fileURL,
            maxBytes: maxFileSizeBytes,
            trimInterval: trimInterval,
            now: now,
            fileManager: fileManager
        )
    }

    static func trimToMaxSizeIfNeeded(
        at fileURL: URL,
        maxBytes: UInt64 = DiagnosticsLogLimits.maxFileSizeBytes,
        trimInterval: TimeInterval = DiagnosticsLogLimits.trimInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        let path = fileURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard let fileSize = attributes[.size] as? UInt64, fileSize > maxBytes else { return }

        if trimInterval > 0 {
            if let lastTrim = try readLastTrimDate(for: fileURL, fileManager: fileManager) {
                if now.timeIntervalSince(lastTrim) < trimInterval {
                    return
                }
            } else {
                // First time over the limit: record now and trim on a later append.
                try writeLastTrimDate(now, for: fileURL, fileManager: fileManager)
                return
            }
        }

        // Rewrite in place so the file inode stays stable and `tail -f` keeps following.
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }

        let offset = fileSize - maxBytes
        try handle.seek(toOffset: offset)
        var trimmed = try handle.readToEnd() ?? Data()

        if let newlineIndex = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            trimmed = Data(trimmed[(newlineIndex + 1)...])
        }

        try handle.seek(toOffset: 0)
        if trimmed.isEmpty {
            try handle.truncate(atOffset: 0)
        } else {
            try handle.write(contentsOf: trimmed)
            try handle.truncate(atOffset: UInt64(trimmed.count))
        }

        try writeLastTrimDate(now, for: fileURL, fileManager: fileManager)
    }

    private static func trimStateURL(for logURL: URL) -> URL {
        logURL.appendingPathExtension("trim")
    }

    private static func readLastTrimDate(for logURL: URL, fileManager: FileManager) throws -> Date? {
        let stateURL = trimStateURL(for: logURL)
        let path = stateURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return nil }

        let text = try String(contentsOf: stateURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func writeLastTrimDate(_ date: Date, for logURL: URL, fileManager: FileManager) throws {
        let stateURL = trimStateURL(for: logURL)
        try ISO8601DateFormatter().string(from: date).write(to: stateURL, atomically: true, encoding: .utf8)
    }
}
