import Foundation

extension String {
    static func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
