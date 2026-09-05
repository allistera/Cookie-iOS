import Foundation
import Observation

/// Owns the latest draft and the single save loop, including a final save
/// while leaving the editor. A failed write retains the draft for Retry.
@MainActor @Observable
final class NoteSaveCoordinator {
    enum State: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var hasConflict = false
    private var updatedAt: String?
    private var pending: DocumentsAPI.SaveDocumentBody?
    private var inFlight: Task<Bool, Never>?

    func configure(updatedAt: String?) {
        self.updatedAt = updatedAt
    }

    func edited(id: String, title: String, blocks: [DocumentBlock]) {
        pending = .init(id: id, title: title, blocks: blocks)
        state = .saving
    }

    func flush(using write: @escaping @MainActor (DocumentsAPI.SaveDocumentBody) async throws -> DocumentSummary) async -> Bool {
        if let inFlight {
            guard await inFlight.value else { return false }
            return pending == nil ? true : await flush(using: write)
        }
        let operation = Task { @MainActor in
            defer { inFlight = nil }
            while var body = pending {
                pending = nil
                body.updatedAt = updatedAt
                do {
                    let saved = try await write(body)
                    updatedAt = saved.updatedAt
                    hasConflict = false
                } catch {
                    // A newer draft supersedes the failed snapshot, retaining
                    // the full title and blocks rather than a partial patch.
                    if pending == nil { pending = body }
                    hasConflict = (error as? DocumentsAPIError) == .conflict
                    state = .failed(hasConflict ? "Changed elsewhere — save a copy" : "Couldn't save — tap Retry")
                    return false
                }
            }
            state = .saved
            return true
        }
        inFlight = operation
        return await operation.value
    }

    func waitUntilIdle() async {
        if let inFlight { _ = await inFlight.value }
    }

    func savedAsCopy() {
        pending = nil
        hasConflict = false
        state = .saved
    }
}
