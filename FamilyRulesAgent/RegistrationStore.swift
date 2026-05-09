import Foundation
import Security
import SQLite3

protocol RegistrationStoreProtocol {
    func loadRegistration() throws -> RegistrationRecord?
    func saveRegistration(_ registration: RegistrationRecord) throws
    func clearRegistration() throws
}

struct RegistrationRecord {
    let serverURL: String
    let username: String
    let instanceId: String
    let instanceToken: String
    let instanceName: String
}

final class RegistrationStore {
    private let database: SettingsDatabase
    private let keychain: TokenKeychainStore
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.database = SettingsDatabase(fileManager: fileManager)
        self.keychain = TokenKeychainStore()
        self.fileManager = fileManager
    }

    func loadRegistration() throws -> RegistrationRecord? {
        let settings = try database.loadAllSettings()

        guard
            let serverURL = settings[.serverURL],
            let username = settings[.username],
            let instanceId = settings[.instanceId],
            let instanceName = settings[.instanceName],
            let instanceToken = try keychain.loadInstanceToken()
        else {
            return nil
        }

        return RegistrationRecord(
            serverURL: serverURL,
            username: username,
            instanceId: instanceId,
            instanceToken: instanceToken,
            instanceName: instanceName
        )
    }

    func saveRegistration(_ registration: RegistrationRecord) throws {
        let previousToken = try keychain.loadInstanceToken()
        try keychain.saveInstanceToken(registration.instanceToken)

        do {
            try database.save(
                settings: [
                    .serverURL: registration.serverURL,
                    .username: registration.username,
                    .instanceId: registration.instanceId,
                    .instanceName: registration.instanceName,
                ]
            )
        } catch {
            if let previousToken {
                try? keychain.saveInstanceToken(previousToken)
            } else {
                try? keychain.deleteInstanceToken()
            }

            throw error
        }
    }

    func clearRegistration() throws {
        var failures: [String] = []

        do {
            try keychain.deleteInstanceToken()
        } catch {
            failures.append(error.localizedDescription)
        }

        // For each SQLite database, also delete the WAL and SHM sidecar files that
        // SQLite creates when using write-ahead logging mode.
        let databaseURLs: [URL] = [
            AgentPersistencePaths.settingsDatabaseURL,
            AgentPersistencePaths.commandQueueDatabaseURL,
        ]
        var filesToDelete: [URL] = [AgentPersistencePaths.diagnosticsLogURL]
        for dbURL in databaseURLs {
            filesToDelete.append(dbURL)
            filesToDelete.append(URL(fileURLWithPath: dbURL.path(percentEncoded: false) + "-wal"))
            filesToDelete.append(URL(fileURLWithPath: dbURL.path(percentEncoded: false) + "-shm"))
        }

        for url in filesToDelete {
            do {
                if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        do {
            let appSupport = AgentPersistencePaths.applicationSupportDirectory
            if fileManager.fileExists(atPath: appSupport.path(percentEncoded: false)) {
                try fileManager.removeItem(at: appSupport)
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        if !failures.isEmpty {
            throw RegistrationStoreError.cleanupFailed(details: failures.joined(separator: "\n"))
        }
    }
}

extension RegistrationStore: RegistrationStoreProtocol {}

private enum StoredSetting: String, CaseIterable {
    case serverURL = "server_url"
    case username = "username"
    case instanceId = "instance_id"
    case instanceName = "instance_name"
}

private final class SettingsDatabase {
    private let databaseURL: URL
    private let fileManager: FileManager

    init(databaseURL: URL = AgentPersistencePaths.settingsDatabaseURL, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    func loadAllSettings() throws -> [StoredSetting: String] {
        try withDatabase { database in
            var statement: OpaquePointer?
            let sql = "SELECT key, value FROM settings"

            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(message: database.errorMessage)
            }

            defer { sqlite3_finalize(statement) }

            var result: [StoredSetting: String] = [:]

            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let keyCString = sqlite3_column_text(statement, 0),
                    let valueCString = sqlite3_column_text(statement, 1),
                    let key = StoredSetting(rawValue: String(cString: keyCString))
                else {
                    continue
                }

                result[key] = String(cString: valueCString)
            }

            return result
        }
    }

    func save(settings: [StoredSetting: String]) throws {
        try withDatabase { database in
            try database.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

            do {
                let sql = "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
                var statement: OpaquePointer?

                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.prepareFailed(message: database.errorMessage)
                }

                defer { sqlite3_finalize(statement) }

                for (key, value) in settings {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)

                    guard sqlite3_bind_text(statement, 1, key.rawValue, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                        throw DatabaseError.bindFailed(message: database.errorMessage)
                    }

                    guard sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                        throw DatabaseError.bindFailed(message: database.errorMessage)
                    }

                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.stepFailed(message: database.errorMessage)
                    }
                }

                try database.execute(sql: "COMMIT TRANSACTION")
            } catch {
                try? database.execute(sql: "ROLLBACK TRANSACTION")
                throw error
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try fileManager.createDirectory(
            at: AgentPersistencePaths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw DatabaseError.openFailed(message: database?.errorMessage ?? "Unknown SQLite open error")
        }

        defer { sqlite3_close(database) }

        try database.execute(sql: "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")

        return try body(database)
    }
}

final class TokenKeychainStore {
    private let service = "com.familyrules.agent.registration"
    private let account = "instanceToken"

    func loadInstanceToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }

            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.operationFailed(status)
        }
    }

    func saveInstanceToken(_ token: String) throws {
        let tokenData = Data(token.utf8)
        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let attributes = [kSecValueData as String: tokenData]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

            guard updateStatus == errSecSuccess else {
                throw KeychainError.operationFailed(updateStatus)
            }
        case errSecItemNotFound:
            var query = baseQuery
            query[kSecValueData as String] = tokenData

            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.operationFailed(addStatus)
            }
        default:
            throw KeychainError.operationFailed(status)
        }
    }

    func deleteInstanceToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private enum RegistrationStoreError: LocalizedError {
    case cleanupFailed(details: String)

    var errorDescription: String? {
        switch self {
        case let .cleanupFailed(details):
            return "Failed to fully clean local registration state:\n\(details)"
        }
    }
}

private enum DatabaseError: LocalizedError {
    case openFailed(message: String)
    case prepareFailed(message: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case executeFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "Failed to open the local database: \(message)"
        case let .prepareFailed(message):
            return "Failed to prepare a database statement: \(message)"
        case let .bindFailed(message):
            return "Failed to bind a database value: \(message)"
        case let .stepFailed(message):
            return "Failed to write the database transaction: \(message)"
        case let .executeFailed(message):
            return "Failed to execute a database statement: \(message)"
        }
    }
}

private enum KeychainError: LocalizedError {
    case invalidData
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The saved token in Keychain is not valid text."
        case let .operationFailed(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

private extension OpaquePointer {
    var errorMessage: String {
        guard let cString = sqlite3_errmsg(self) else {
            return "Unknown SQLite error"
        }

        return String(cString: cString)
    }

    func execute(sql: String) throws {
        guard sqlite3_exec(self, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(message: errorMessage)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
