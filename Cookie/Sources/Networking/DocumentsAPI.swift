import Foundation

/// A folder row from the documents workspace endpoint. `parentID` is `nil`
/// for a root-level folder.
struct DocumentFolder: Decodable, Identifiable, Hashable {
    let id: String
    let parentID: String?
    let title: String
    let emoji: String?

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case title
        case emoji
    }
}

/// A document row from the workspace endpoint. Blocks are never included in
/// a list response — the web app fetches them separately when a document is
/// opened, the same rule email bodies follow. `folderID` is `nil` for a
/// document sitting at the root of the workspace.
struct DocumentSummary: Decodable, Identifiable, Hashable {
    let id: String
    let folderID: String?
    let title: String?
    let emoji: String?
    let starred: Bool
    let tags: [String]
    /// Opaque ISO timestamp echoed back on save so the server can reject a
    /// write over a copy that changed elsewhere.
    let updatedAt: String?

    /// Documents can be created with an empty title (`createDocument` defaults
    /// to `''`), which Cookie-Web renders as "Untitled".
    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case folderID = "folder_id"
        case title
        case emoji
        case starred
        case tags
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

/// The response body of `GET /documents`.
struct DocumentWorkspace: Decodable {
    let folders: [DocumentFolder]
    let documents: [DocumentSummary]
    var nextCursor: String?
    var version: String?
}

/// A document with its blocks — only ever fetched one at a time, the way
/// email bodies are. List responses never carry blocks.
struct DocumentDetail: Decodable, Sendable {
    let id: String
    let title: String?
    let blocks: [DocumentBlock]
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case blocks
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        blocks = try container.decodeIfPresent([DocumentBlock].self, forKey: .blocks) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// Talks to Cookie-Web's `cookie-web-tasks` Cloudflare Worker
/// `GET /documents` — the same workspace endpoint the web app's Pinia
/// `documents` store calls in `loadWorkspace`, which backs the Documents
/// sidebar tree. Folders come back ordered by title, documents by most
/// recently updated; both arrive flat and are nested client-side.
struct DocumentsAPI {
    /// - Parameter accessToken: A valid Auth0 access token for the
    ///   `cookie-web` API audience.
    static func fetchWorkspace(accessToken: String) async throws -> DocumentWorkspace {
        let data = try await getDocuments(query: [URLQueryItem(name: "view", value: "meta")], accessToken: accessToken)
        struct Metadata: Decodable {
            let folders: [DocumentFolder]
            let documents: [DocumentSummary]?
            let version: String?
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        if let documents = metadata.documents {
            return DocumentWorkspace(folders: metadata.folders, documents: documents)
        }
        let page = try await fetchDocumentPage(folderID: nil, accessToken: accessToken)
        return DocumentWorkspace(folders: metadata.folders, documents: page.documents,
                                 nextCursor: page.nextCursor, version: metadata.version)
    }

    struct DocumentPage: Decodable {
        let documents: [DocumentSummary]
        let nextCursor: String?
    }

    static func fetchDocumentPage(folderID: String?, before: String? = nil, accessToken: String) async throws -> DocumentPage {
        var query = [URLQueryItem(name: "view", value: "page"), URLQueryItem(name: "folder", value: folderID ?? "root")]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let data = try await getDocuments(query: query, accessToken: accessToken)
        return try JSONDecoder().decode(DocumentPage.self, from: data)
    }

    private static func getDocuments(query: [URLQueryItem], accessToken: String) async throws -> Data {
        let url = try APIClient.url(CookieAPIEndpoints.documents, query: query)
        return try await APIClient.send(APIClient.request(url, accessToken: accessToken))
    }

    /// Fetches one document including its blocks — `GET /documents?id=…`.
    static func fetchDocument(id: String, accessToken: String) async throws -> DocumentDetail {
        let data = try await getDocuments(query: [URLQueryItem(name: "id", value: id)], accessToken: accessToken)
        return try JSONDecoder().decode(DocumentResponse.self, from: data).document
    }

    /// The PATCH body. Absent keys are left alone server-side, so a save that
    /// only changes the title must not carry a `blocks` key at all.
    struct SaveDocumentBody: Encodable, Sendable {
        let id: String
        var title: String?
        var blocks: [DocumentBlock]?
        /// The `updated_at` the edit was based on. The server rejects the
        /// write with 409 if the stored row has moved on since.
        var updatedAt: String?
    }

    /// Saves title and/or blocks — `PATCH /documents`. The response row
    /// carries no blocks, only the new `updated_at` the next save must send.
    static func saveDocument(
        _ body: SaveDocumentBody,
        accessToken: String
    ) async throws -> DocumentSummary {
        let request = APIClient.request(
            CookieAPIEndpoints.documents,
            method: "PATCH",
            accessToken: accessToken,
            jsonBody: try JSONEncoder().encode(body)
        )
        return try await APIClient.send(request, decoding: DocumentSummaryResponse.self).document
    }

    /// A conflict never overwrites the remote document. Save the local draft
    /// as a separate note when the user explicitly chooses that recovery.
    static func createCopy(title: String, blocks: [DocumentBlock], accessToken: String) async throws -> DocumentSummary {
        let request = APIClient.request(
            CookieAPIEndpoints.documents,
            method: "POST",
            accessToken: accessToken,
            jsonBody: try JSONSerialization.data(withJSONObject: ["kind": "document", "title": title + " (copy)"])
        )
        let created = try await APIClient.send(request, decoding: DocumentSummaryResponse.self).document
        return try await saveDocument(.init(id: created.id, blocks: blocks, updatedAt: created.updatedAt), accessToken: accessToken)
    }

    private struct DocumentResponse: Decodable {
        let document: DocumentDetail
    }

    private struct DocumentSummaryResponse: Decodable {
        let document: DocumentSummary
    }
}
