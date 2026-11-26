import Foundation
import Observation

/// What the sidebar can show in the main area.
enum SidebarSelection: Hashable {
    case today
    case folder(MailboxFolder)
    case drafts
}

/// The drawer's open state, selection, and the label and draft lists it shows.
@MainActor
@Observable
final class SidebarModel {
    var isOpen = false
    /// The design opens with the extra views expanded.
    var showsMore = true
    private(set) var selection: SidebarSelection = .folder(.inbox)
    private(set) var labels: [MailLabel] = []
    private(set) var labelsFailed = false
    private(set) var drafts: [Draft] = []
    private(set) var draftsFailed = false
    private(set) var isLoadingLists = false

    private let client: APIClient
    /// Owned here so an open-triggered load outlives the view that opened the drawer.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(client: APIClient) {
        self.client = client
    }

    /// Opens the drawer and refreshes its lists.
    func open() {
        isOpen = true
        loadTask?.cancel()
        loadTask = Task { await loadLists() }
    }

    func select(_ selection: SidebarSelection) {
        self.selection = selection
        isOpen = false
    }

    /// Loads labels and drafts together; each failure affects only its section.
    func loadLists() async {
        isLoadingLists = true
        defer { isLoadingLists = false }
        async let labelResult = loadLabels()
        async let draftResult = loadDrafts()
        _ = await (labelResult, draftResult)
    }

    private func loadLabels() async {
        do {
            let list: LabelList = try await client.get(CookieAPIEndpoints.labels)
            labels = list.labels
            labelsFailed = false
        } catch is CancellationError {
            return
        } catch {
            labelsFailed = true
        }
    }

    private func loadDrafts() async {
        do {
            let list: DraftList = try await client.get(CookieAPIEndpoints.drafts)
            drafts = list.drafts
            draftsFailed = false
        } catch is CancellationError {
            return
        } catch {
            draftsFailed = true
        }
    }
}
