import Foundation
import Observation

/// The loaded mailbox: rows, categories and the paging cursor.
@MainActor
@Observable
final class Mailbox {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    private(set) var folder: MailboxFolder = .inbox
    private(set) var phase: Phase = .loading
    /// The inbox's unread count from the first page of any folder.
    private(set) var unreadCount = 0
    private(set) var emails: [EmailSummary] = []
    private(set) var categories: [EmailCategory] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    /// The last load-more failed; the footer offers Retry.
    private(set) var loadMoreFailed = false
    /// A refresh failed while rows were already shown; they are kept.
    private(set) var refreshFailed = false

    private let client: APIClient
    /// Bumped per refresh so a slow response cannot overwrite a newer one.
    @ObservationIgnored private var generation = 0
    /// Counts confirmed read changes; `readChanges` keeps each id's latest number.
    @ObservationIgnored private var readChangeCount = 0
    @ObservationIgnored private var readChanges: [String: Int] = [:]
    /// Confirmed transitions also cover AI Today references outside the loaded page.
    @ObservationIgnored private var knownReadStates: [String: Bool] = [:]

    init(client: APIClient) {
        self.client = client
    }

    /// The inbox is sorted into category tabs; any other folder is one page.
    var tabs: [InboxTab] {
        if folder == .inbox {
            return InboxTab.tabs(for: emails, categories: categories)
        }
        return [InboxTab(id: "folder", name: folder.title, isImportant: false, emails: emails)]
    }

    /// Selection only depends on category identities, not on regrouping every row.
    var tabIDs: [String] {
        guard folder == .inbox else { return ["folder"] }
        return [InboxTab.importantID]
            + categories.filter { !$0.isImportant }.map { "category:\($0.id)" }
            + [InboxTab.otherID]
    }

    /// Switches folder, dropping the previous folder's rows, and loads it.
    func select(_ folder: MailboxFolder) async {
        guard folder != self.folder else { return }
        self.folder = folder
        emails = []
        categories = []
        nextCursor = nil
        loadMoreFailed = false
        refreshFailed = false
        phase = .loading
        await refresh()
    }

    /// Reloads the first page, with the categories for the inbox.
    func refresh() async {
        generation += 1
        let current = generation
        let readsBefore = readChangeCount
        let folder = self.folder
        refreshFailed = false
        if emails.isEmpty { phase = .loading }
        do {
            async let page: InboxPage = client.get(CookieAPIEndpoints.mailbox(folder: folder, before: nil))
            let loadedList: CategoryList? =
                folder == .inbox ? try await client.get(CookieAPIEndpoints.categories) : nil
            let loadedPage = try await page
            guard current == generation, folder == self.folder else { return }
            emails = keepingReadChanges(since: readsBefore, in: loadedPage.emails)
            for email in emails { knownReadStates[email.id] = email.isUnread }
            categories = loadedList?.categories ?? []
            nextCursor = loadedPage.nextCursor
            // A count computed before a confirmed read would undo it; keep the local one.
            if let unread = loadedPage.unreadCount, readChangeCount == readsBefore { unreadCount = unread }
            loadMoreFailed = false
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            if emails.isEmpty {
                phase = .failed
            } else {
                refreshFailed = true
            }
        }
    }

    /// Appends the next page. Requires a user action; never runs twice at once.
    func loadMore() async {
        guard !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let current = generation
        let readsBefore = readChangeCount
        defer { isLoadingMore = false }
        do {
            let page: InboxPage = try await client.get(CookieAPIEndpoints.mailbox(folder: folder, before: cursor))
            guard current == generation else { return }
            let known = Set(emails.map(\.id))
            var newIDs = known
            let fresh = page.emails.filter { newIDs.insert($0.id).inserted }
            let added = keepingReadChanges(since: readsBefore, in: fresh)
            emails += added
            for email in added { knownReadStates[email.id] = email.isUnread }
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            loadMoreFailed = true
        }
    }

    /// Applies a confirmed read, including a cited inbox email outside the loaded page.
    func markRead(_ id: String, wasUnread: Bool? = nil, isInboxMessage: Bool? = nil) {
        setUnread(id, false, wasUnread: wasUnread, isInboxMessage: isInboxMessage)
    }

    private func setUnread(
        _ id: String, _ isUnread: Bool, wasUnread: Bool? = nil, isInboxMessage: Bool? = nil
    ) {
        let index = emails.firstIndex(where: { $0.id == id })
        let previous = knownReadStates[id] ?? index.map { emails[$0].isUnread } ?? wasUnread
        guard let previous, previous != isUnread else { return }
        // A response started before this mutation keeps its rows but not this row's stale flag.
        readChangeCount += 1
        readChanges[id] = readChangeCount
        knownReadStates[id] = isUnread
        if let index { emails[index].isUnread = isUnread }
        if isInboxMessage ?? (folder == .inbox) {
            unreadCount = max(0, unreadCount + (isUnread ? 1 : -1))
        }
    }

    /// Rows from a response that started before a confirmed read keep that read.
    private func keepingReadChanges(since readsBefore: Int, in rows: [EmailSummary]) -> [EmailSummary] {
        guard readChangeCount != readsBefore else { return rows }
        return rows.map { row in
            var updated = row
            if let change = readChanges[row.id], change > readsBefore, let isUnread = knownReadStates[row.id] {
                updated.isUnread = isUnread
            }
            return updated
        }
    }
}
