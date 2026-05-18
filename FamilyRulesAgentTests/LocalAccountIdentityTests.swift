import XCTest
@testable import FamilyRules

final class LocalAccountIdentityTests: XCTestCase {
    func testCurrentUserScopedInstanceNameAppendsUserName() {
        let result = LocalAccountIdentity.currentUserScopedInstanceName(
            hostName: "School Mac",
            userName: "alice"
        )

        XCTAssertEqual(result, "School Mac (alice)")
    }

    func testCurrentUserScopedInstanceNameAvoidsDuplicateUserName() {
        let result = LocalAccountIdentity.currentUserScopedInstanceName(
            hostName: "School Mac (alice)",
            userName: "alice"
        )

        XCTAssertEqual(result, "School Mac (alice)")
    }

    func testCurrentUserScopedInstanceNameFallsBackWhenUserNameMissing() {
        let result = LocalAccountIdentity.currentUserScopedInstanceName(
            hostName: "School Mac",
            userName: "   "
        )

        XCTAssertEqual(result, "School Mac")
    }

    func testCurrentUserScopedInstanceNameFallsBackWhenHostNameMissing() {
        let result = LocalAccountIdentity.currentUserScopedInstanceName(
            hostName: "   ",
            userName: "alice"
        )

        XCTAssertEqual(result, "My Mac (alice)")
    }
}
