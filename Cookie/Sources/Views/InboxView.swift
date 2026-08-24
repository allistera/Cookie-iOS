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
    @State private var showComposer = false
    @State private var selectedSection: AppSection = .email
    @State private var selectedFilter: EmailFilter?
    @State private var emails: [DummyEmail] = []
    @State private var unreadCount = 0
    @State private var isLoadingInitialPage = true
    @State private var loadErrorMessage: String?
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
        guard let selectedFilter else { return emails }
        return emails.filter { $0.filter == selectedFilter }
    }

    private func loadEmails() async {
        do {
            let accessToken = try await auth.validAccessToken()
            let page = try await EmailsAPI.fetchEmails(accessToken: accessToken)
            emails = page.emails.compactMap(DummyEmail.init(message:))
            unreadCount = page.unreadCount ?? 0
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "Couldn't load your inbox. Pull to refresh to try again."
        }
        isLoadingInitialPage = false
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
        let originalIndex = emails.firstIndex(where: { $0.id == email.id })
        let originalSearchIndex = searchResults.firstIndex(where: { $0.id == email.id })
        withAnimation {
            emails = InboxEmailActions.markingDone(emailID: email.id, in: emails)
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
                    if let originalIndex, !emails.contains(where: { $0.id == email.id }) {
                        emails.insert(email, at: min(originalIndex, emails.count))
                    }
                    if let originalSearchIndex,
                       !searchResults.contains(where: { $0.id == email.id }) {
                        searchResults.insert(email, at: min(originalSearchIndex, searchResults.count))
                    }
                }
                loadErrorMessage = "Couldn't mark that email as done. Try again."
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

                        if let loadErrorMessage, emails.isEmpty {
                            Text(loadErrorMessage)
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

                if selectedSection == .email, isLoadingInitialPage, emails.isEmpty {
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
        HStack(alignment: .center) {
            Menu {
                Picker("Section", selection: $selectedSection) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedSection.icon)
                        .font(.title2)
                        .foregroundStyle(.red)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(selectedSection.rawValue)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.primary)
                        if selectedSection == .email, unreadCount > 0 {
                            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityLabel("Switch section, currently \(selectedSection.rawValue)")

            Spacer()

            Button {
                showSignOutConfirmation = true
            } label: {
                Circle()
                    .fill(Color(red: 0.72, green: 0.29, blue: 0.15))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(avatarInitial)
                            .font(.headline)
                            .foregroundStyle(.white)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
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
        HStack(spacing: 12) {
            Menu {
                Picker("Filter", selection: $selectedFilter) {
                    Text("All emails")
                        .tag(EmailFilter?.none)

                    ForEach(EmailFilter.allCases) { filter in
                        Text(filter.rawValue)
                            .tag(Optional(filter))
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Filter emails")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search emails...", text: $searchText)
                    .foregroundStyle(.primary)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        submitSearch()
                    }
                    .onChange(of: searchText) {
                        searchTextChanged()
                    }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                // Independent of the spinner so a slow search can still be
                // abandoned, like the web bar's always-present close icon.
                if !searchText.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.ultraThinMaterial, in: Capsule())

            Button {
                showComposer = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Compose email")
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct EmailRow: View {
    let email: DummyEmail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(email.color)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(email.initial)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 6) {
                        Text(email.sender)
                            .font(.subheadline.bold())
                        if email.isUnread {
                            Circle()
                                .fill(.blue)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Spacer()
                    Text(email.time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(email.subject)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Text(email.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview {
    InboxView(profile: .init(name: "Ada", email: "ada@example.com", picture: nil))
        .environment(AuthenticationManager())
}
