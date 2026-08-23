import XCTest
@testable import Cookie

final class DocumentTreeTests: XCTestCase {
    private func folder(_ id: String, parent: String? = nil, title: String? = nil) throws -> DocumentFolder {
        try decode(
            """
            {"id": "\(id)", "parent_id": \(parent.map { "\"\($0)\"" } ?? "null"),
             "title": "\(title ?? id)", "emoji": null}
            """
        )
    }

    private func document(_ id: String, folder: String? = nil, title: String? = nil) throws -> DocumentSummary {
        try decode(
            """
            {"id": "\(id)", "folder_id": \(folder.map { "\"\($0)\"" } ?? "null"),
             "title": "\(title ?? id)", "emoji": null, "starred": false, "tags": []}
            """
        )
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: XCTUnwrap(json.data(using: .utf8)))
    }

    private func titles(_ rows: [DocumentTreeRow]) -> [String] {
        rows.map { row in
            switch row.item {
            case .folder(let folder): "\(String(repeating: "  ", count: row.depth))📁 \(folder.title)"
            case .document(let document): "\(String(repeating: "  ", count: row.depth))📄 \(document.displayTitle)"
            }
        }
    }

    func testCollapsedFolderHidesItsContents() throws {
        let rows = DocumentTree.flatten(
            folders: [try folder("projects")],
            documents: [try document("plan", folder: "projects")],
            expandedFolderIDs: []
        )

        XCTAssertEqual(titles(rows), ["📁 projects"])
    }

    func testExpandedFolderNestsSubfoldersAboveItsDocuments() throws {
        let rows = DocumentTree.flatten(
            folders: [try folder("projects"), try folder("kitchen", parent: "projects")],
            documents: [
                try document("floor plan", folder: "kitchen"),
                try document("budget", folder: "projects"),
            ],
            expandedFolderIDs: ["projects", "kitchen"]
        )

        XCTAssertEqual(titles(rows), [
            "📁 projects",
            "  📁 kitchen",
            "    📄 floor plan",
            "  📄 budget",
        ])
    }

    func testRootDocumentsSortBelowTheFolderTree() throws {
        let rows = DocumentTree.flatten(
            folders: [try folder("projects")],
            documents: [try document("scratchpad")],
            expandedFolderIDs: []
        )

        XCTAssertEqual(titles(rows), ["📁 projects", "📄 scratchpad"])
    }

    /// A row whose parent isn't in the response would otherwise be dropped
    /// entirely, silently hiding the user's notes.
    func testRowsWithAnUnresolvableParentAreTreatedAsRoots() throws {
        let rows = DocumentTree.flatten(
            folders: [try folder("orphan", parent: "missing")],
            documents: [try document("stray", folder: "gone")],
            expandedFolderIDs: []
        )

        XCTAssertEqual(titles(rows), ["📁 orphan", "📄 stray"])
    }

    /// Two folders parented to each other are reachable from no root; without
    /// the cycle break the walk would never emit them (or would not terminate).
    func testFoldersInAParentCycleAreLiftedToTheTopLevel() throws {
        let rows = DocumentTree.flatten(
            folders: [try folder("a", parent: "b"), try folder("b", parent: "a")],
            documents: [],
            expandedFolderIDs: ["a", "b"]
        )

        XCTAssertEqual(titles(rows), ["📁 a", "  📁 b"])
    }

    /// The workspace endpoint can return a document created with an empty
    /// title; Cookie-Web shows those as "Untitled".
    func testBlankDocumentTitleFallsBackToUntitled() throws {
        let blank: DocumentSummary = try decode(
            #"{"id": "d1", "folder_id": null, "title": "", "emoji": null, "starred": false, "tags": []}"#
        )

        XCTAssertEqual(blank.displayTitle, "Untitled")
    }

    /// `starred` and `tags` are absent from some rows; a strict decode would
    /// fail the whole workspace load over one missing key.
    func testWorkspaceDecodesRowsMissingOptionalFields() throws {
        let workspace: DocumentWorkspace = try decode(
            #"""
            {"folders": [{"id": "f1", "parent_id": null, "title": "Projects", "emoji": "📁"}],
             "documents": [{"id": "d1", "folder_id": "f1", "title": "Notes"}]}
            """#
        )

        XCTAssertEqual(workspace.folders.first?.title, "Projects")
        XCTAssertEqual(workspace.documents.first?.starred, false)
        XCTAssertEqual(workspace.documents.first?.tags, [])
    }
}
