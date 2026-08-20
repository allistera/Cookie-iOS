import SwiftUI

struct ComposeDraft: Equatable {
    var recipient = ""
    var subject = ""
    var body = ""

    var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    @State private var draft: ComposeDraft
    @State private var isSending = false
    @State private var sendErrorMessage: String?
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
                body: DummyEmail.quotedReplyBody(for: email)
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
            .disabled(!draft.canSend || isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func send() async {
        guard draft.canSend, !isSending else { return }
        isSending = true
        sendErrorMessage = nil

        do {
            let accessToken = try await auth.validAccessToken()
            try await SendAPI.sendMail(
                SendAPI.SendMailBody(
                    to: draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                    subject: draft.subject,
                    text: draft.body,
                    replyToMessageId: replyToMessageId
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

    private var messageEditor: some View {
        TextEditor(text: $draft.body)
            .font(.body)
            .focused($focusedField, equals: .body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 16)
            .padding(.top, 12)
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
