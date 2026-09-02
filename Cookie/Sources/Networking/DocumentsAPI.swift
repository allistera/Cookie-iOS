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

enum DocumentsAPIError: Error {
    case unauthorized
    /// The document changed elsewhere since it was loaded; the save was
    /// rejected rather than clobbering the newer copy.
    case conflict
    case server(status: Int)
    case invalidResponse
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
        var request = URLRequest(url: CookieAPIEndpoints.documents)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DocumentsAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw DocumentsAPIError.unauthorized }
            throw DocumentsAPIError.server(status: http.statusCode)
        }

        return try JSONDecoder().decode(DocumentWorkspace.self, from: data)
    }

    /// Fetches one document including its blocks — `GET /documents?id=…`.
    static func fetchDocument(id: String, accessToken: String) async throws -> DocumentDetail {
        guard
            var components = URLComponents(
                url: CookieAPIEndpoints.documents,
                resolvingAgainstBaseURL: false
            )
        else {
            throw DocumentsAPIError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { throw DocumentsAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
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
        var request = URLRequest(url: CookieAPIEndpoints.documents)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await send(request)
        return try JSONDecoder().decode(DocumentSummaryResponse.self, from: data).document
    }

    private struct DocumentResponse: Decodable {
        let document: DocumentDetail
    }

    private struct DocumentSummaryResponse: Decodable {
        let document: DocumentSummary
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DocumentsAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw DocumentsAPIError.unauthorized
            case 409: throw DocumentsAPIError.conflict
            default: throw DocumentsAPIError.server(status: http.statusCode)
            }
        }
        return data
    }
}
