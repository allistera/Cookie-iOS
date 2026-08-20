import SwiftUI
import XCTest
@testable import Cookie

final class EmailDetailNavigationTests: XCTestCase {
    func testEdgeSwipeDismissesEmailDetail() {
        XCTAssertTrue(
            EmailDetailNavigation.shouldDismiss(
                startX: 10,
                translation: CGSize(width: 100, height: 8),
                predictedEndTranslation: CGSize(width: 140, height: 10)
            )
        )
    }

    func testSwipeMustStartAtLeftEdge() {
        XCTAssertFalse(
            EmailDetailNavigation.shouldDismiss(
                startX: 60,
                translation: CGSize(width: 120, height: 0),
                predictedEndTranslation: CGSize(width: 160, height: 0)
            )
        )
    }

    func testVerticalScrollDoesNotDismissEmailDetail() {
        XCTAssertFalse(
            EmailDetailNavigation.shouldDismiss(
                startX: 10,
                translation: CGSize(width: 90, height: 130),
                predictedEndTranslation: CGSize(width: 110, height: 180)
            )
        )
    }

    func testShortSwipeDoesNotDismissEmailDetail() {
        XCTAssertFalse(
            EmailDetailNavigation.shouldDismiss(
                startX: 10,
                translation: CGSize(width: 35, height: 2),
                predictedEndTranslation: CGSize(width: 60, height: 3)
            )
        )
    }
}
