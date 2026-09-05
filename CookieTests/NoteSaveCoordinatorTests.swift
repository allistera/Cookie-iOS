import XCTest
@testable import Cookie

@MainActor
final class NoteSaveCoordinatorTests: XCTestCase {
    private func summary(_ title: String?, version: String) throws -> DocumentSummary {
        let row: [String: Any] = ["id": "note", "title": title ?? "", "starred": false,
                                  "tags": [String](), "updated_at": version]
        return try JSONDecoder().decode(DocumentSummary.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testFinalFlushWaitsForInflightSaveAndUsesItsVersionForNewerEdits() async {
        let saves = NoteSaveCoordinator()
        saves.configure(updatedAt: "v0")
        saves.edited(id: "note", title: "First", blocks: [])
        var gate: CheckedContinuation<Void, Never>?
        var written: [DocumentsAPI.SaveDocumentBody] = []
        let first = Task {
            await saves.flush { body in
                written.append(body)
                if written.count == 1 { await withCheckedContinuation { gate = $0 } }
                return try self.summary(body.title, version: "v\(written.count)")
            }
        }
        while gate == nil { await Task.yield() }
        saves.edited(id: "note", title: "Latest", blocks: [])
        let final = Task {
            await saves.flush { _ in
                XCTFail("A second flush must join the existing writer")
                return try self.summary(nil, version: "invalid")
            }
        }
        await Task.yield()
        XCTAssertEqual(saves.state, .saving)
        gate?.resume()
        let results = await (first.value, final.value)
        XCTAssertTrue(results.0 && results.1)
        XCTAssertEqual(written.map(\.title), ["First", "Latest"])
        XCTAssertEqual(written.map(\.updatedAt), ["v0", "v1"])
        XCTAssertEqual(saves.state, .saved)
    }

    func testConflictRetainsDraftAndOriginalVersionForRetry() async {
        let saves = NoteSaveCoordinator()
        saves.configure(updatedAt: "v0")
        saves.edited(id: "note", title: "Local draft", blocks: [])
        let failed = await saves.flush { _ in throw DocumentsAPIError.conflict }
        XCTAssertFalse(failed)
        XCTAssertTrue(saves.hasConflict)
        let retried = await saves.flush { body in
            XCTAssertEqual(body.title, "Local draft")
            XCTAssertEqual(body.updatedAt, "v0")
            return try self.summary(body.title, version: "v1")
        }
        XCTAssertTrue(retried)
        XCTAssertFalse(saves.hasConflict)
    }

    func testNewerEditSurvivesAnInflightFailure() async {
        let saves = NoteSaveCoordinator()
        saves.configure(updatedAt: "v0")
        saves.edited(id: "note", title: "First", blocks: [])
        let failed = await saves.flush { _ in
            saves.edited(id: "note", title: "Newer", blocks: [])
            throw URLError(.networkConnectionLost)
        }
        XCTAssertFalse(failed)
        let retried = await saves.flush { body in
            XCTAssertEqual(body.title, "Newer")
            return try self.summary(body.title, version: "v1")
        }
        XCTAssertTrue(retried)
    }
}
