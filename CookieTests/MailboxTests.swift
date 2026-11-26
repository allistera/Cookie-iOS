import Foundation
import Testing

@testable import Cookie

/// Lets a test hold one response until it says so.
private actor Gate {
    private var isOpen = false
    private(set) var isWaiting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        isWaiting = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}

private actor Counter {
    private var value = 0

    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

private func row(_ id: String, unread: Bool = false) -> String {
    #"{"id":"\#(id)","from_address":"\#(id)@example.com","sent_at":"2026-10-05T09:48:12Z","#
        + #""is_unread":\#(unread),"labels":[]}"#
}

private func page(_ ids: [String], next: String?) -> String {
    let cursor = next.map { #""\#($0)""# } ?? "null"
    let rows = ids.map { row($0) }.joined(separator: ",")
    return #"{"emails":[\#(rows)],"nextCursor":\#(cursor),"unreadCount":1}"#
}

private let categoriesJSON = #"{"categories":[{"id":"c1","name":"Finance","color":null}]}"#

/// Records the URLs the mailbox requested.
private actor URLLog {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

/// Routes by path: `/categories` always succeeds; `/emails` answers from a
/// queue of (status, body), repeating the last entry. `gate` holds the
/// `/emails` request numbered `gatedRequest`, counting from zero.
@MainActor
private func makeMailbox(
    emailResponses: [(Int, String)], gateFirstEmails gate: Gate? = nil, gatedRequest: Int = 0, log: URLLog? = nil
) -> Mailbox {
    let tokens = TokenProvider(current: { "t" }, renewed: { "t" }, invalidate: {})
    let counter = Counter()
    let client = APIClient(tokens: tokens) { request in
        guard let url = request.url else { throw URLError(.badURL) }
        await log?.record(url)
        let (status, body): (Int, String)
        if url.path == "/categories" {
            (status, body) = (200, categoriesJSON)
        } else {
            let index = await counter.next()
            if index == gatedRequest, let gate { await gate.wait() }
            (status, body) = emailResponses[min(index, emailResponses.count - 1)]
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return (Data(body.utf8), response)
    }
    return Mailbox(client: client)
}

@MainActor
struct MailboxTests {
    @Test func refreshLoadsRowsCategoriesAndCursor() async {
        let mailbox = makeMailbox(emailResponses: [(200, page(["a", "b"], next: "cur"))])
        #expect(mailbox.phase == .loading)

        await mailbox.refresh()

        #expect(mailbox.phase == .loaded)
        #expect(mailbox.emails.map(\.id) == ["a", "b"])
        #expect(mailbox.categories.map(\.id) == ["c1"])
        #expect(mailbox.nextCursor == "cur")
        #expect(mailbox.tabs.map(\.id) == ["important", "category:c1", "other"])
    }

    @Test func loadMoreAppendsAndSkipsDuplicates() async {
        let mailbox = makeMailbox(
            emailResponses: [(200, page(["a", "b"], next: "cur")), (200, page(["b", "c"], next: nil))])
        await mailbox.refresh()

        await mailbox.loadMore()

        #expect(mailbox.emails.map(\.id) == ["a", "b", "c"])
        #expect(mailbox.nextCursor == nil)
        #expect(!mailbox.loadMoreFailed)
    }

    @Test func loadMoreWithoutCursorDoesNothing() async {
        let mailbox = makeMailbox(emailResponses: [(200, page(["a"], next: nil))])
        await mailbox.refresh()

        await mailbox.loadMore()

        #expect(mailbox.emails.map(\.id) == ["a"])
    }

    @Test func loadMoreFailureIsReportedAndRetryable() async {
        let mailbox = makeMailbox(
            emailResponses: [(200, page(["a"], next: "cur")), (500, "{}"), (200, page(["b"], next: nil))])
        await mailbox.refresh()

        await mailbox.loadMore()
        #expect(mailbox.loadMoreFailed)
        #expect(mailbox.emails.map(\.id) == ["a"])

        await mailbox.loadMore()
        #expect(!mailbox.loadMoreFailed)
        #expect(mailbox.emails.map(\.id) == ["a", "b"])
    }

    @Test func firstLoadFailureSetsFailed() async {
        let mailbox = makeMailbox(emailResponses: [(503, "{}")])
        await mailbox.refresh()
        #expect(mailbox.phase == .failed)
        #expect(mailbox.emails.isEmpty)
    }

    @Test func refreshFailureWithRowsKeepsThem() async {
        let mailbox = makeMailbox(emailResponses: [(200, page(["a"], next: nil)), (500, "{}")])
        await mailbox.refresh()

        await mailbox.refresh()

        #expect(mailbox.phase == .loaded)
        #expect(mailbox.refreshFailed)
        #expect(mailbox.emails.map(\.id) == ["a"])
    }

    @Test func supersededRefreshIsDiscarded() async {
        let gate = Gate()
        let mailbox = makeMailbox(
            emailResponses: [(200, page(["old"], next: nil)), (200, page(["new"], next: nil))],
            gateFirstEmails: gate)

        let first = Task { await mailbox.refresh() }
        while await !gate.isWaiting {
            await Task.yield()
        }
        await mailbox.refresh()
        await gate.open()
        await first.value

        #expect(mailbox.emails.map(\.id) == ["new"])
    }

    @Test func markReadAndUnreadUpdateTheRow() async {
        let mailbox = makeMailbox(emailResponses: [(200, #"{"emails":[\#(row("a", unread: true))],"nextCursor":null}"#)]
        )
        await mailbox.refresh()

        mailbox.markRead("a")
        #expect(mailbox.emails.first?.isUnread == false)
        #expect(mailbox.tabs.last?.unreadCount == 0)

        mailbox.markUnread("a")
        #expect(mailbox.emails.first?.isUnread == true)
    }

    @Test func selectingAFolderDropsRowsRequestsItAndShowsOneTab() async {
        let log = URLLog()
        let mailbox = makeMailbox(
            emailResponses: [(200, page(["a"], next: "cur")), (200, page(["s1", "s2"], next: nil))], log: log)
        await mailbox.refresh()
        #expect(mailbox.unreadCount == 1)

        await mailbox.select(.sent)

        #expect(mailbox.folder == .sent)
        #expect(mailbox.emails.map(\.id) == ["s1", "s2"])
        #expect(mailbox.nextCursor == nil)
        #expect(mailbox.tabs.map(\.id) == ["folder"])
        #expect(mailbox.tabs.first?.name == "Sent")
        let urls = await log.urls
        #expect(urls.filter { $0.path == "/categories" }.count == 1)
        #expect(urls.last?.query?.contains("folder=sent") == true)
    }

    @Test func selectingTheCurrentFolderDoesNothing() async {
        let log = URLLog()
        let mailbox = makeMailbox(emailResponses: [(200, page(["a"], next: nil))], log: log)
        await mailbox.refresh()
        let count = await log.urls.count

        await mailbox.select(.inbox)

        #expect(await log.urls.count == count)
    }

    @Test func confirmedReadUpdatesTheInboxBadgeExactlyOnce() async {
        let body = #"{"emails":[\#(row("a", unread: true))],"nextCursor":null,"unreadCount":3}"#
        let mailbox = makeMailbox(emailResponses: [(200, body)])
        await mailbox.refresh()

        mailbox.markRead("a")
        mailbox.markRead("a")
        #expect(mailbox.unreadCount == 2)
        #expect(mailbox.emails.first?.isUnread == false)
        #expect(mailbox.tabs.last?.unreadCount == 0)

        mailbox.markUnread("a")
        mailbox.markUnread("a")
        #expect(mailbox.unreadCount == 3)
    }

    @Test func citedUnreadOutsideTheLoadedPageUpdatesBadgeExactlyOnce() async {
        let mailbox = makeMailbox(emailResponses: [(200, page(["a"], next: "more"))])
        await mailbox.refresh()

        mailbox.markRead("cited", wasUnread: true, isInboxMessage: true)
        mailbox.markRead("cited", wasUnread: true, isInboxMessage: true)

        #expect(mailbox.unreadCount == 0)
        #expect(mailbox.emails.map(\.id) == ["a"])
    }

    @Test func readingSpamDoesNotChangeTheInboxBadge() async {
        let body = #"{"emails":[\#(row("spam", unread: true))],"nextCursor":null,"unreadCount":4}"#
        let mailbox = makeMailbox(emailResponses: [(200, body)])
        await mailbox.select(.spam)

        mailbox.markRead("spam")

        #expect(mailbox.unreadCount == 4)
        #expect(mailbox.emails.first?.isUnread == false)
    }

    @Test func confirmedReadCannotBeUndoneByAnOlderRefresh() async {
        let gate = Gate()
        let body = #"{"emails":[\#(row("a", unread: true))],"nextCursor":null,"unreadCount":1}"#
        let mailbox = makeMailbox(emailResponses: [(200, body)], gateFirstEmails: gate)
        let refresh = Task { await mailbox.refresh() }
        while await !gate.isWaiting { await Task.yield() }

        mailbox.markRead("a", wasUnread: true, isInboxMessage: true)
        await gate.open()
        await refresh.value

        // The refresh still lands; only the stale flag and count are not applied.
        #expect(mailbox.unreadCount == 0)
        #expect(mailbox.phase == .loaded)
        #expect(mailbox.emails.map(\.id) == ["a"])
        #expect(mailbox.emails.first?.isUnread == false)
    }

    @Test func confirmedReadDoesNotDiscardAnInFlightLoadMore() async {
        let gate = Gate()
        let first = #"{"emails":[\#(row("a"))],"nextCursor":"cur","unreadCount":2}"#
        let second = #"{"emails":[\#(row("b", unread: true))],"nextCursor":null}"#
        let mailbox = makeMailbox(
            emailResponses: [(200, first), (200, second)], gateFirstEmails: gate, gatedRequest: 1)
        await mailbox.refresh()
        let loadMore = Task { await mailbox.loadMore() }
        while await !gate.isWaiting { await Task.yield() }

        mailbox.markRead("b", wasUnread: true, isInboxMessage: true)
        await gate.open()
        await loadMore.value

        #expect(mailbox.emails.map(\.id) == ["a", "b"])
        #expect(mailbox.emails.last?.isUnread == false)
        #expect(mailbox.unreadCount == 1)
        #expect(mailbox.nextCursor == nil)
        #expect(!mailbox.loadMoreFailed)
    }

    @Test func pagingDoesNotCreateDuplicateRowsWithinOneResponse() async {
        let mailbox = makeMailbox(
            emailResponses: [(200, page(["a"], next: "cur")), (200, page(["b", "b"], next: nil))])
        await mailbox.refresh()
        await mailbox.loadMore()

        #expect(mailbox.emails.map(\.id) == ["a", "b"])
        #expect(mailbox.tabIDs == mailbox.tabs.map(\.id))
    }
}
