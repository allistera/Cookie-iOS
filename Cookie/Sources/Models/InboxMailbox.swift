import Foundation
import Observation

@MainActor @Observable
final class InboxMailbox {
    var emails: [DummyEmail] = []
    private(set) var unreadCount = 0
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingInitialPage = true
    var errorMessage: String?
    /// Set once a load has settled (success or a real failure), so returning
    /// to the inbox doesn't reset it to page one and the top of the list.
    private(set) var hasLoaded = false
    private var generation = 0

    /// The first-appearance load. Later appearances (popping back from a
    /// message) keep the current list; pull-to-refresh reloads explicitly.
    func loadIfNeeded(fetch: @MainActor (String?) async throws -> EmailListResponse) async {
        guard !hasLoaded else { return }
        await load(refresh: true, fetch: fetch)
    }

    /// Refresh supersedes any old page; only one pagination request runs at a
    /// time. Failed requests keep their cursor and can be retried.
    func load(
        refresh: Bool,
        fetch: @MainActor (String?) async throws -> EmailListResponse
    ) async {
        if !refresh && (isLoading || nextCursor == nil) { return }
        generation += 1
        let requestGeneration = generation
        let cursor = refresh ? nil : nextCursor
        isLoading = true
        defer {
            if generation == requestGeneration {
                isLoading = false
                isLoadingInitialPage = false
            }
        }
        do {
            let page = try await fetch(cursor)
            guard generation == requestGeneration else { return }
            let rows = page.emails.compactMap(DummyEmail.init(message:))
            var seen = Set(refresh ? [] : emails.map(\.id))
            let unique = rows.filter { seen.insert($0.id).inserted }
            emails = refresh ? unique : emails + unique
            nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
            unreadCount = page.unreadCount ?? unreadCount
            errorMessage = nil
            hasLoaded = true
        } catch {
            guard generation == requestGeneration else { return }
            // A cancelled load (the view disappeared mid-request) is not a
            // failure; leave the state as it was so the next appearance retries.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = "Couldn't load your inbox. Try again."
            hasLoaded = true
        }
    }
}
