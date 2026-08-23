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

    private var filteredEmails: [DummyEmail] {
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
        await loadEmails()
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
        let originalIndex = emails.firstIndex(where: { $0.id == email.id })
        withAnimation {
            emails = InboxEmailActions.markingDone(emailID: email.id, in: emails)
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
                    if !emails.contains(where: { $0.id == email.id }) {
                        let insertIndex = min(originalIndex ?? emails.count, emails.count)
                        emails.insert(email, at: insertIndex)
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
        ForEach(filteredEmails) { email in
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
                Text("Search emails...")
                    .foregroundStyle(.secondary)
                Spacer()
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
