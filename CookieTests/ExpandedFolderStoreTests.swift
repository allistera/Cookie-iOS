import XCTest
@testable import Cookie

final class ExpandedFolderStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ExpandedFolderStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testEveryFolderStartsCollapsedWhenNothingIsStored() {
        XCTAssertEqual(ExpandedFolderStore.load(from: defaults), [])
    }

    func testRoundTripsTheSavedFolderIDs() {
        ExpandedFolderStore.save(["f-projects", "f-kitchen"], to: defaults)

        XCTAssertEqual(ExpandedFolderStore.load(from: defaults), ["f-projects", "f-kitchen"])
        XCTAssertEqual(defaults.stringArray(forKey: ExpandedFolderStore.key)?.sorted(), ["f-kitchen", "f-projects"])
    }

    func testSavingAnEmptySetCollapsesEverythingAgain() {
        ExpandedFolderStore.save(["f-projects"], to: defaults)
        ExpandedFolderStore.save([], to: defaults)

        XCTAssertEqual(ExpandedFolderStore.load(from: defaults), [])
    }

    func testTreatsAValueOfTheWrongShapeAsNothingStored() {
        defaults.set("not an array", forKey: ExpandedFolderStore.key)
        XCTAssertEqual(ExpandedFolderStore.load(from: defaults), [])

        defaults.set([1, 2], forKey: ExpandedFolderStore.key)
        XCTAssertEqual(ExpandedFolderStore.load(from: defaults), [])
    }

    func testDropsBlankIDsAndTrimsWhitespace() {
        defaults.set(["f-projects", "", "   ", " f-kitchen "], forKey: ExpandedFolderStore.key)

        XCTAssertEqual(ExpandedFolderStore.load(from: defaults), ["f-projects", "f-kitchen"])
    }

    func testCapsTheNumberOfStoredIDs() {
        let many = Set((0..<600).map { "f-\($0)" })
        ExpandedFolderStore.save(many, to: defaults)

        XCTAssertEqual(defaults.stringArray(forKey: ExpandedFolderStore.key)?.count, ExpandedFolderStore.maxStoredIDs)
        XCTAssertEqual(ExpandedFolderStore.load(from: defaults).count, ExpandedFolderStore.maxStoredIDs)
    }
}
