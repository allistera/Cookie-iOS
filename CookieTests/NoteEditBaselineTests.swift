import XCTest
@testable import Cookie

final class NoteEditBaselineTests: XCTestCase {
    private func blocks(_ json: String) throws -> [DocumentBlock] {
        try JSONDecoder().decode([DocumentBlock].self, from: XCTUnwrap(json.data(using: .utf8)))
    }

    func testOpeningANoteIsNotAnEdit() throws {
        let loaded = try blocks(#"[{"type": "paragraph", "data": {"text": "Hello"}}]"#)
        var baseline = NoteEditBaseline()
        baseline.loaded(title: "Plans", blocks: loaded)

        // SwiftUI's `onChange(of: title)` echoes the loaded title back.
        XCTAssertFalse(baseline.isEdit(title: "Plans", blocks: loaded))
        XCTAssertFalse(baseline.isEdit(title: "Plans", blocks: loaded))
    }

    func testChangedTitleOrBlocksAreEdits() throws {
        let loaded = try blocks(#"[{"type": "paragraph", "data": {"text": "Hello"}}]"#)
        let changed = try blocks(#"[{"type": "paragraph", "data": {"text": "Hello there"}}]"#)

        var titleBaseline = NoteEditBaseline()
        titleBaseline.loaded(title: "Plans", blocks: loaded)
        XCTAssertTrue(titleBaseline.isEdit(title: "Plans!", blocks: loaded))

        var blocksBaseline = NoteEditBaseline()
        blocksBaseline.loaded(title: "Plans", blocks: loaded)
        XCTAssertTrue(blocksBaseline.isEdit(title: "Plans", blocks: changed))
    }

    func testUndoingBackToTheLoadedContentStillSaves() throws {
        let loaded = try blocks(#"[{"type": "paragraph", "data": {"text": "Hello"}}]"#)
        var baseline = NoteEditBaseline()
        baseline.loaded(title: "Plans", blocks: loaded)

        XCTAssertTrue(baseline.isEdit(title: "Plans!", blocks: loaded))
        // The edited draft may already be queued or saved, so the revert has
        // to go out too rather than be dropped as "unchanged".
        XCTAssertTrue(baseline.isEdit(title: "Plans", blocks: loaded))
    }

    func testReloadingResetsTheBaseline() throws {
        var baseline = NoteEditBaseline()
        baseline.loaded(title: "Plans", blocks: [])
        XCTAssertTrue(baseline.isEdit(title: "Other", blocks: []))

        baseline.loaded(title: "Other", blocks: [])
        XCTAssertFalse(baseline.isEdit(title: "Other", blocks: []))
    }
}
