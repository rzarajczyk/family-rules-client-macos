import Darwin
import XCTest
@testable import FamilyRules

final class DiagnosticsLogStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testAppendUsesDatedTimestampFormat() throws {
        let logURL = tempDirectory.appendingPathComponent("Diagnostics.log")
        let store = DiagnosticsLogStore(fileURL: logURL)

        try store.append(line: "[2026-06-08 10:15:30] test message")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(text, "[2026-06-08 10:15:30] test message\n")
    }

    func testAppendTrimsFileToConfiguredMaxSize() throws {
        let logURL = tempDirectory.appendingPathComponent("Diagnostics.log")
        let maxBytes: UInt64 = 128
        let filler = String(repeating: "x", count: 80)

        for index in 0..<6 {
            try DiagnosticsLogFileIO.append(
                line: "[2026-06-08 10:15:\(index)] \(filler)",
                to: logURL,
                maxFileSizeBytes: maxBytes,
                trimInterval: 0
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? UInt64)
        XCTAssertLessThanOrEqual(fileSize, maxBytes)

        let text = try String(contentsOf: logURL, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(text.contains("[2026-06-08 10:15:0]"))
        XCTAssertTrue(text.contains("[2026-06-08 10:15:5]"))
    }

    func testTrimPreservesFileInode() throws {
        let logURL = tempDirectory.appendingPathComponent("Diagnostics.log")
        let maxBytes: UInt64 = 128
        let filler = String(repeating: "x", count: 80)

        try DiagnosticsLogFileIO.append(
            line: "[seed] \(filler)",
            to: logURL,
            maxFileSizeBytes: maxBytes,
            trimInterval: 0
        )
        let inodeBefore = try fileInode(at: logURL)

        for index in 1..<6 {
            try DiagnosticsLogFileIO.append(
                line: "[2026-06-08 10:15:\(index)] \(filler)",
                to: logURL,
                maxFileSizeBytes: maxBytes,
                trimInterval: 0
            )
        }

        let inodeAfter = try fileInode(at: logURL)
        XCTAssertEqual(inodeBefore, inodeAfter)
    }

    func testTrimIsThrottledUntilIntervalElapses() throws {
        let logURL = tempDirectory.appendingPathComponent("Diagnostics.log")
        let maxBytes: UInt64 = 128
        let trimInterval: TimeInterval = 3_600
        let filler = String(repeating: "x", count: 80)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<6 {
            try DiagnosticsLogFileIO.append(
                line: "[2026-06-08 10:15:\(index)] \(filler)",
                to: logURL,
                maxFileSizeBytes: maxBytes,
                trimInterval: trimInterval,
                now: start
            )
        }

        let oversizedAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let oversizedSize = try XCTUnwrap(oversizedAttributes[.size] as? UInt64)
        XCTAssertGreaterThan(oversizedSize, maxBytes)

        try DiagnosticsLogFileIO.append(
            line: "[2026-06-08 12:15:00] \(filler)",
            to: logURL,
            maxFileSizeBytes: maxBytes,
            trimInterval: trimInterval,
            now: start.addingTimeInterval(trimInterval)
        )

        let trimmedAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let trimmedSize = try XCTUnwrap(trimmedAttributes[.size] as? UInt64)
        XCTAssertLessThanOrEqual(trimmedSize, maxBytes)
    }

    private func fileInode(at url: URL) throws -> UInt64 {
        var status = stat()
        let path = url.path(percentEncoded: false)
        guard lstat(path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        return UInt64(status.st_ino)
    }
}
