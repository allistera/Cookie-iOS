import SwiftUI

/// The Calendar section. Only the new-event field is built so far; the rest
/// of the screen fills in later. Submitting the field runs the same AI flow
/// as the web app's "New event" dialog: interpret the text into a draft,
/// then save the draft into the default calendar.
struct CalendarView: View {
    @Environment(AuthenticationManager.self) private var auth
    @State private var newEventText = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var createdEventTitle: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                TextField("Dinner with Sam tomorrow at 7pm...", text: $newEventText)
                    .font(.subheadline)
                    .focused($isFieldFocused)
                    .submitLabel(.done)
                    .disabled(isCreating)
                    .onSubmit {
                        Task { await createEvent() }
                    }
                    // The web caps its AI input at the server's 1000-char
                    // limit with maxlength; past it, interpret 400s with a
                    // message that never mentions length.
                    .onChange(of: newEventText) {
                        newEventText = String(newEventText.prefix(1000))
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if let errorMessage {
                feedbackText(errorMessage, color: .red)
            } else if let createdEventTitle {
                feedbackText("Added “\(createdEventTitle)” to your calendar.", color: .secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func feedbackText(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }

    /// Mirrors the web CalendarView's `createEventFromText`, including its
    /// error copy: interpret the text, then create the draft in the writable
    /// "Personal" calendar (falling back to the first writable one), the same
    /// default the web form preselects.
    private func createEvent() async {
        let text = newEventText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        createdEventTitle = nil

        do {
            let accessToken = try await auth.validAccessToken()

            let calendars = try await CalendarEventsAPI.fetchCalendars(accessToken: accessToken)
            let writable = calendars.filter { $0.subscriptionUrl == nil }
            guard let calendar = writable.first(where: { $0.name == "Personal" }) ?? writable.first else {
                showError("Create a calendar before adding events.")
                isCreating = false
                return
            }

            let draft = try await CalendarEventsAPI.interpretEvent(
                text: text,
                timeZone: TimeZone.current.identifier,
                accessToken: accessToken
            )
            try await CalendarEventsAPI.createEvent(draft, calendar: calendar.id, accessToken: accessToken)

            newEventText = ""
            // The web app shows the new event on its calendar grid; this
            // screen has no grid yet, so name what was created instead.
            createdEventTitle = draft.title
            AccessibilityNotification.Announcement("Added \(draft.title) to your calendar.").post()
        } catch CalendarEventsAPIError.rateLimited {
            showError("You have made too many AI requests. Please wait a moment and try again.")
        } catch {
            showError("Cookie could not create that event. Try adding a clear date and time.")
        }

        isCreating = false
    }

    /// The web renders this copy with `role="alert"`; an announcement is the
    /// VoiceOver equivalent, since the text below the field appears silently.
    private func showError(_ message: String) {
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview {
    CalendarView()
        .environment(AuthenticationManager())
}
