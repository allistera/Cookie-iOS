import XCTest
@testable import Cookie

final class EmailFilterTests: XCTestCase {
    func testFilterMenuContainsRequestedCategoriesInOrder() {
        XCTAssertEqual(
            EmailFilter.allCases.map(\.rawValue),
            ["Newsletters", "Personal", "Recruitment", "Shopping", "Work"]
        )
    }
}
