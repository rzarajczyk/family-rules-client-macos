import Foundation

enum LocalAccountIdentity {
    static func currentUserScopedInstanceName(
        hostName: String = Host.current().localizedName ?? "My Mac",
        userName: String = NSUserName()
    ) -> String {
        let normalizedHostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserName = userName.trimmingCharacters(in: .whitespacesAndNewlines)

        let fallbackHostName = normalizedHostName.isEmpty ? "My Mac" : normalizedHostName
        guard !normalizedUserName.isEmpty else {
            return fallbackHostName
        }

        if fallbackHostName.localizedCaseInsensitiveContains(normalizedUserName) {
            return fallbackHostName
        }

        return "\(fallbackHostName) (\(normalizedUserName))"
    }
}
