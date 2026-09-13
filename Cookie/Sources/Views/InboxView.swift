import SwiftUI

enum InboxEmailActions {
    static func markingDone(emailID: UUID, in emails: [DummyEmail]) -> [DummyEmail] {
        emails.filter { $0.id != emailID }
    }
}

/// The top-level sections reachable from the title dropdown. Only `email` is
/// built out for now; the others render a placeholder.
enum AppSection: String, CaseIterable, Identifiable {
    case email = "Email"
    case calendar = "Calendar"
    case notes = "Notes"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .email: "tray.fill"
        case .calendar: "calendar"
        case .notes: "note.text"
        }
    }
}

struct InboxView: View {
    @Environment(AuthenticationManager.self) private var auth
    let profile: AuthenticationManager.Profile

    @State private var showSignOutConfirmation = false
    @State private var mailbox = InboxMailbox()
    @State private var showComposer = false
    @State private var selectedSection: AppSection = .email
    @State private var selectedFilter: EmailFilter?
    @State private var toastMessage: String?
    @State private var searchText = ""
    /// Non-empty while search results replace the inbox list — the same
    /// signal the web store's `activeSearchQuery` carries. Set only after a
    /// search succeeds, so the type-ahead dedupe compares against the last
    /// query whose results are actually on screen.
    @State private var activeSearchQuery = ""
    @State private var searchResults: [DummyEmail] = []
    @State private var isSearching = false
    /// The web store's `listSeq` guard: whichever search started last wins,
    /// regardless of response order.
    @State private var searchSeq = 0
    @State private var searchTask: Task<Void, Never>?

    private var displayedEmails: [DummyEmail] {
        // Search results are relevance-ranked server-side and bypass the
        // category filter, matching the web's flat "Results" group.
        if !activeSearchQuery.isEmpty { return searchResults }
        guard let selectedFilter else { return mailbox.emails }
        return mailbox.emails.filter { $0.filter == selectedFilter }
    }

    private func loadEmails(refresh: Bool = true) async {
        await mailbox.load(refresh: refresh) { before in
            let token = try await auth.validAccessToken()
            return try await EmailsAPI.fetchEmails(before: before, accessToken: token)
        }
    }

    private func refreshEmails() async {
        if activeSearchQuery.isEmpty {
            await loadEmails()
        } else {
            // Pull-to-refresh re-runs the active search at full (semantic)
            // strength rather than clobbering the results with the inbox.
            await runSearch(activeSearchQuery, semantic: true)
        }
    }

    // MARK: Search

    /// Mirrors the web header's input watcher: cancel any pending request,
    /// ignore sub-2-character queries (restoring the inbox if results were
    /// showing), and otherwise run the cheap keyword-only search after the
    /// same 400 ms pause. Semantic search is reserved for an explicit submit.
    private func searchTextChanged() {
        // The server rejects queries over 500 chars.
        searchText = String(searchText.prefix(500))
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count < 2 {
            if !activeSearchQuery.isEmpty { exitSearchMode() }
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await runSearch(query, semantic: false)
        }
    }

    /// Return on the web runs the full hybrid search immediately, even for
    /// text the type-ahead already searched in keyword mode.
    private func submitSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask = Task { await runSearch(query, semantic: true) }
    }

    private func runSearch(_ query: String, semantic: Bool) async {
        // The debounced path skips a query whose results are already showing;
        // a submit re-runs it semantically (the web's `force` flag).
        if !semantic, query == activeSearchQuery { return }
        searchSeq += 1
        let seq = searchSeq
        isSearching = true
        do {
            let accessToken = try await auth.validAccessToken()
            let rows = try await SearchAPI.searchEmails(
                query: query,
                semantic: semantic,
                accessToken: accessToken
            )
            guard seq == searchSeq else { return }
            activeSearchQuery = query
            searchResults = rows.compactMap(DummyEmail.init(message:))
        } catch {
            guard seq == searchSeq else { return }
            // A superseded request's cancellation is not a failure.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                showToast("Search failed. Please try again.")
            }
        }
        if seq == searchSeq { isSearching = false }
    }

    /// The store-level clear (web `clearSearch()`): drop the results and any
    /// in-flight request but keep whatever is typed.
    private func exitSearchMode() {
        searchTask?.cancel()
        searchTask = nil
        searchSeq += 1
        activeSearchQuery = ""
        searchResults = []
        isSearching = false
    }

    /// The clear (×) button (web `leaveSearchResults()`): also empties the field.
    private func clearSearch() {
        searchText = ""
        exitSearchMode()
    }

    /// Shows a transient confirmation, mirroring Cookie-Web's toast
    /// notifications (`notify('Email sent.')`), and clears it after a beat.
    private func showToast(_ message: String) {
        Task {
            withAnimation { toastMessage = message }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toastMessage = nil }
        }
    }

    private func markDone(_ email: DummyEmail) {
        // A row can be in the inbox page, the search results, or both — a
        // search can surface mail beyond the loaded inbox page.
        let originalIndex = mailbox.emails.firstIndex(where: { $0.id == email.id })
        let originalSearchIndex = searchResults.firstIndex(where: { $0.id == email.id })
        withAnimation {
            mailbox.emails = InboxEmailActions.markingDone(emailID: email.id, in: mailbox.emails)
            searchResults = InboxEmailActions.markingDone(emailID: email.id, in: searchResults)
        }

        Task {
            do {
                let accessToken = try await auth.validAccessToken()
                try await MessagesAPI.markDone(
                    id: email.id.uuidString.lowercased(),
                    accessToken: accessToken
                )
            } catch {
                // The server didn't persist it — put the row back where it
                // was, mirroring Cookie-Web's `archiveEmail` undo-on-failure
                // behavior, rather than clobbering the whole list.
                withAnimation {
                    if let originalIndex, !mailbox.emails.contains(where: { $0.id == email.id }) {
                        mailbox.emails.insert(email, at: min(originalIndex, mailbox.emails.count))
                    }
                    if let originalSearchIndex,
                       !searchResults.contains(where: { $0.id == email.id }) {
                        searchResults.insert(email, at: min(originalSearchIndex, searchResults.count))
                    }
                }
                mailbox.errorMessage = "Couldn't mark that email as done. Try again."
            }
        }
    }

    private var avatarInitial: String {
        String(profile.name.trimmingCharacters(in: .whitespaces).first ?? "A").uppercased()
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(.systemBackground).ignoresSafeArea()

                if selectedSection != .email {
                    VStack(spacing: 0) {
                        header

                        switch selectedSection {
                        case .notes: NotesView()
                        case .calendar: CalendarView()
                        case .email: Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    List {
                        header
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)

                        if let message = mailbox.errorMessage, mailbox.emails.isEmpty {
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 24)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }

                        if !activeSearchQuery.isEmpty, searchResults.isEmpty, !isSearching {
                            Text("No emails matched your search.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 24)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                        }

                        emailList

                        if activeSearchQuery.isEmpty, mailbox.nextCursor != nil {
                            Button(mailbox.isLoading ? "Loading…" : "Load more emails") {
                                Task { await loadEmails(refresh: false) }
                            }
                            .disabled(mailbox.isLoading)
                        }

                        Color.clear
                            .frame(height: 90)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await refreshEmails()
                    }
                }

                if selectedSection == .email, mailbox.isLoadingInitialPage, mailbox.emails.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                if let toastMessage {
                    Text(toastMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black, in: Capsule())
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if selectedSection == .email {
                    floatingToolbar
                }
            }
            .task {
                await loadEmails()
            }
            // Leaving the email section or picking a category filter leaves
            // search mode too — on the web both are route changes, and every
            // route change funnels through `leaveSearchResults()`.
            .onChange(of: selectedSection) {
                if selectedSection != .email { clearSearch() }
            }
            .onChange(of: selectedFilter) {
                if !activeSearchQuery.isEmpty { clearSearch() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DummyEmail.self) { email in
                EmailDetailView(email: email) {
                    markDone(email)
                }
            }
            .confirmationDialog("Account", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task { await auth.logout() }
                }
            }
            .fullScreenCover(isPresented: $showComposer) {
                ComposeView()
                    .onSendSuccess {
                        showToast("Email sent.")
                    }
            }
        }
    }

    private var header: some View {
        InboxHeader(selectedSection: $selectedSection, unreadCount: mailbox.unreadCount, avatarInitial: avatarInitial) {
            showSignOutConfirmation = true
        }
    }

    private var emailList: some View {
        ForEach(displayedEmails) { email in
            NavigationLink(value: email) {
                EmailRow(email: email)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .alignmentGuide(.listRowSeparatorLeading) { _ in
                16
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    markDone(email)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
    }

    private var floatingToolbar: some View {
        InboxToolbar(selectedFilter: $selectedFilter, searchText: $searchText, isSearching: isSearching,
                     filters: Array(Set(mailbox.emails.map(\.filter)).union(selectedFilter.map { [$0] } ?? []))
                         .sorted { $0.rawValue.localizedCaseInsensitiveCompare($1.rawValue) == .orderedAscending },
                     onSubmit: submitSearch, onSearchChange: searchTextChanged, onClear: clearSearch) {
            showComposer = true
        }
    }

}

#Preview {
    InboxView(profile: .init(name: "Ada", email: "ada@example.com", picture: nil))
        .environment(AuthenticationManager())
}
