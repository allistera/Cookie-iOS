import SwiftUI

enum EmailDetailNavigation {
    private static let edgeWidth: CGFloat = 32
    private static let dismissalDistance: CGFloat = 80

    static func shouldDismiss(
        startX: CGFloat,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        let horizontalDistance = max(translation.width, predictedEndTranslation.width)
        let verticalDistance = max(abs(translation.height), abs(predictedEndTranslation.height))

        return startX <= edgeWidth
            && horizontalDistance >= dismissalDistance
            && horizontalDistance > verticalDistance
    }
}

struct EmailDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthenticationManager.self) private var auth
    let email: DummyEmail

    /// The full message body, fetched from `GET /messages?id=` when the
    /// detail screen opens — the inbox list only carries the snippet.
    private enum BodyState {
        case loading
        case loaded(MessageBody)
        case unavailable
    }

    @State private var bodyState: BodyState = .loading
    /// Remote images are blocked by default so tracking pixels don't fire on
    /// open; the "Show images" control opts in per message.
    @State private var showRemoteImages = false
    @State private var renderedBodyHeight: CGFloat = 44
    @State private var showReplyComposer = false

    /// Called when "Done" is tapped, before the screen dismisses. The inbox
    /// owns the optimistic removal and the `PATCH /messages` call (and its
    /// rollback), so tapping Done here behaves exactly like the list's
    /// swipe-to-done action.
    var onDone: () -> Void = {}

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(email.subject)
                            .font(.title3.bold())

                        labelChips
                        senderRow
                        bodyCard
                        Color.clear.frame(height: 70)
                    }
                    .padding(.horizontal, 16)
                }
            }

            bottomToolbar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(backSwipeGesture)
        .task(id: email.id) {
            await loadBody()
        }
        .fullScreenCover(isPresented: $showReplyComposer) {
            ComposeView(replyingTo: email)
        }
    }

    private func loadBody() async {
        guard case .loading = bodyState else { return }
        do {
            let accessToken = try await auth.validAccessToken()
            let body = try await MessagesAPI.fetchMessageBody(
                id: email.id.uuidString.lowercased(),
                accessToken: accessToken
            )
            bodyState = .loaded(body)
        } catch {
            // Fall back to the list snippet rather than an error screen.
            bodyState = .unavailable
        }
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onEnded { value in
                if EmailDetailNavigation.shouldDismiss(
                    startX: value.startLocation.x,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) {
                    dismiss()
                }
            }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.systemGray6), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var labelChips: some View {
        HStack(spacing: 8) {
            chip("Add label")
            chip("Updates")
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray6), in: Capsule())
    }

    private var senderRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(email.color)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(email.initial)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(email.sender)
                    .font(.subheadline.bold())
                HStack(spacing: 4) {
                    Text("To me")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                Text(email.time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Rectangle()
                .fill(email.color)
                .frame(height: 4)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(email.sender)
                        .font(.title3.bold())
                        .foregroundStyle(email.color)
                    Spacer()
                    Text("\(email.sender.lowercased()).com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                messageBody
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray5))
        )
    }

    @ViewBuilder
    private var messageBody: some View {
        switch bodyState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading message…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .unavailable:
            Text(email.preview)
                .font(.subheadline)

        case .loaded(let body):
            if let html = body.renderableHtml {
                htmlBody(html)
            } else if let text = body.renderableText {
                Text(text)
                    .font(.subheadline)
            } else {
                Text(email.preview)
                    .font(.subheadline)
            }
        }
    }

    private func htmlBody(_ html: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !showRemoteImages && EmailBodyWebView.hasBlockedRemoteImages(html) {
                Button {
                    showRemoteImages = true
                } label: {
                    Label("Show images", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6), in: Capsule())
                }
                .accessibilityLabel("Show remote images")
            }

            EmailBodyWebView(
                html: html,
                blocksRemoteImages: !showRemoteImages,
                contentHeight: $renderedBodyHeight
            )
            .frame(height: max(renderedBodyHeight, 44))
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 28) {
            Button {
                showReplyComposer = true
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .accessibilityLabel("Reply")

            Button {} label: {
                Image(systemName: "arrowshape.turn.up.right")
            }
            .accessibilityLabel("Forward")

            Spacer()

            Button {
                onDone()
                dismiss()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
            .accessibilityLabel("Mark as done")
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    NavigationStack {
        EmailDetailView(email: DummyEmail.sample[0])
    }
    .environment(AuthenticationManager())
}
