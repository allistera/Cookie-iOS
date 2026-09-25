import SwiftUI

/// The composer's draft. `body` is attributed so the WYSIWYG editor can hold
/// bold/italic/underline/bullet formatting; it's exported to HTML on send.
struct ComposeDraft {
    var recipient = ""
    var subject = ""
    var body = NSAttributedString()

    /// Mirrors Cookie-Web's `recipientsValid`: at least one comma-separated
    /// recipient, every one containing an `@`.
    var canSend: Bool {
        ContactSuggest.recipientsValid(recipient)
    }

    /// Whether the body carries any actual content.
    var hasBody: Bool {
        !body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the Send button and `send()` both require, so the button is
    /// never enabled for a draft that `send()` would silently ignore.
    var isReadyToSend: Bool {
        canSend && hasBody
    }
}

extension ComposeDraft: Equatable {
    static func == (lhs: ComposeDraft, rhs: ComposeDraft) -> Bool {
        lhs.recipient == rhs.recipient
            && lhs.subject == rhs.subject
            && lhs.body == rhs.body
    }
}

struct ComposeView: View {
    private enum Field: Hashable {
        case recipient
        case subject
        case body
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationManager.self) private var auth

    /// The message id being replied to, threading the sent copy with the
    /// original on the server (`storeSentMessage`'s `replyToMessageId`).
    /// `nil` for a fresh, non-reply message.
    private let replyToMessageId: String?

    @State private var sendRequestId = UUID().uuidString
    @State private var draft: ComposeDraft
    @State private var isSending = false
    @State private var sendErrorMessage: String?
    @State private var contacts: [Contact] = []
    @State private var contactsLoaded = false
    @State private var richText = RichTextController()
    @FocusState private var focusedField: Field?

    /// Fires after a message is sent successfully, just before the composer
    /// dismisses — lets the presenting view show a confirmation, mirroring
    /// Cookie-Web's `notify('Email sent.')` in `commitPendingSend`.
    private var onSent: (() -> Void)?

    /// A blank composer for a new message.
    init() {
        replyToMessageId = nil
        _draft = State(initialValue: ComposeDraft())
    }

    /// A composer pre-filled to reply to `email`: addressed back to its
    /// sender, subject prefixed with "Re:", and a quoted starter body —
    /// mirroring Cookie-Web's reply behavior in `stores/inbox.js`.
    init(replyingTo email: DummyEmail) {
        replyToMessageId = email.id.uuidString.lowercased()
        _draft = State(
            initialValue: ComposeDraft(
                recipient: email.address,
                subject: DummyEmail.replySubject(for: email.subject),
                body: NSAttributedString(string: DummyEmail.quotedReplyBody(for: email))
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let sendErrorMessage {
                Text(sendErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            addressFields
            Divider()
            messageEditor
        }
        .background(Color(.systemBackground))
        .onAppear {
            focusedField = .recipient
        }
        .task {
            await loadContacts()
        }
    }

    /// Loads the user's contacts once for auto-suggest, mirroring Cookie-Web's
    /// `loadContacts` (`GET /messages/contacts`, fetched a single time per
    /// composer session). Best-effort: on failure the To field still works,
    /// just without suggestions.
    private func loadContacts() async {
        guard !contactsLoaded else { return }
        do {
            let accessToken = try await auth.validAccessToken()
            contacts = try await ContactsAPI.fetchContacts(accessToken: accessToken)
            contactsLoaded = true
        } catch {
            // Suggestions are optional; typing an address still works.
        }
    }

    /// The suggestions shown under the To field while it has focus — the
    /// current token matched against contacts the user hasn't already
    /// committed before the last comma.
    private var contactSuggestions: [Contact] {
        guard focusedField == .recipient else { return [] }
        let completed = Set(
            ContactSuggest.completedRecipients(draft.recipient).map { $0.lowercased() }
        )
        let pool = contacts.filter { !completed.contains($0.address.lowercased()) }
        return ContactSuggest.filterContacts(
            pool,
            query: ContactSuggest.currentRecipientToken(draft.recipient)
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            circularButton(systemName: "xmark", accessibilityLabel: "Close") {
                dismiss()
            }

            Spacer()

            circularButton(systemName: "paperclip", accessibilityLabel: "Add attachment") {}
            circularButton(systemName: "calendar", accessibilityLabel: "Schedule send") {}

            Button {
                Task { await send() }
            } label: {
                if isSending {
                    ProgressView()
                        .tint(.white)
                        .frame(minWidth: 40)
                } else {
                    Text("Send")
                }
            }
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.primary)
            .disabled(!draft.isReadyToSend || isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func send() async {
        guard draft.isReadyToSend, !isSending else { return }
        isSending = true
        sendErrorMessage = nil

        do {
            let accessToken = try await auth.validAccessToken()
            // HTML export goes through WebKit internally — main actor only.
            let bodyHtml = try RichText.html(from: draft.body)
            try await SendAPI.sendMail(
                SendAPI.SendMailBody(
                    to: draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                    subject: draft.subject,
                    text: draft.body.string,
                    html: bodyHtml,
                    replyToMessageId: replyToMessageId,
                    requestId: sendRequestId
                ),
                accessToken: accessToken
            )
            onSent?()
            dismiss()
        } catch {
            sendErrorMessage = "Couldn't send that email. Try again."
        }

        isSending = false
    }

    /// Registers a callback for a successful send, without adding it to
    /// either initializer's parameter list.
    func onSendSuccess(_ action: @escaping () -> Void) -> ComposeView {
        var copy = self
        copy.onSent = action
        return copy
    }

    private var addressFields: some View {
        VStack(spacing: 0) {
            recipientField

            if !contactSuggestions.isEmpty {
                contactSuggestionList
            }

            TextField("Subject", text: $draft.subject)
                .font(.headline)
                .focused($focusedField, equals: .subject)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = .body
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
        }
    }

    private var recipientField: some View {
        HStack(spacing: 12) {
            Text("To")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            TextField("Add an email", text: $draft.recipient)
                .font(.headline)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .focused($focusedField, equals: .recipient)
                .submitLabel(.next)
                .onSubmit {
                    focusedField = .subject
                }

            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("More recipient options")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The auto-suggest dropdown, mirroring Cookie-Web's
    /// `composer-suggestions` rows: person icon, display name, address.
    private var contactSuggestionList: some View {
        VStack(spacing: 0) {
            ForEach(contactSuggestions) { contact in
                Button {
                    draft.recipient = ContactSuggest.appendRecipient(draft.recipient, contact.address)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .font(.subheadline)
                            .foregroundStyle(.purple)

                        VStack(alignment: .leading, spacing: 1) {
                            if let name = contact.name, !name.isEmpty {
                                Text(name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            Text(contact.address)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(contact.name ?? contact.address), \(contact.address)")

                Divider()
                    .padding(.leading, 40)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4))
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private var messageEditor: some View {
        RichTextEditor(text: $draft.body, controller: richText)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField == .body {
                        formatButton("bold", systemImage: "bold", style: .bold)
                        formatButton("italic", systemImage: "italic", style: .italic)
                        formatButton("underline", systemImage: "underline", style: .underline)
                        formatButton("bullets", systemImage: "list.bullet", style: .bulletList)
                    }
                    Spacer()
                }
            }
    }

    /// One WYSIWYG toggle in the keyboard's format bar, highlighted while the
    /// style is active at the selection.
    private func formatButton(
        _ label: String,
        systemImage: String,
        style: RichTextStyle
    ) -> some View {
        let isActive = richText.activeStyles.contains(style)
        return Button {
            richText.toggle(style)
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(isActive ? .bold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .frame(width: 36, height: 32)
                .background(
                    isActive ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func circularButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
                }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    ComposeView()
        .environment(AuthenticationManager())
}
