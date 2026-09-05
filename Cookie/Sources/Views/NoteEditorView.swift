import SwiftUI

/// A note opened for editing: its title plus one editable line per text
/// block. Edits autosave on a debounce, the same cadence as Cookie-Web's
/// document editor.
struct NoteEditorView: View {
    @Environment(AuthenticationManager.self) private var auth

    let document: DocumentSummary
    /// Hands the saved row back so the tree behind this screen shows the new
    /// title without a round trip.
    var onSaved: (DocumentSummary) -> Void = { _ in }

    /// How long edits sit before a PATCH goes out, matching Cookie-Web's
    /// `SAVE_DEBOUNCE_MS`.
    private static let saveDebounce = Duration.milliseconds(800)

    @State private var title = ""
    @State private var blocks: [DocumentBlock] = []
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var isSavingCopy = false
    @State private var saves = NoteSaveCoordinator()
    @Environment(\.dismiss) private var dismiss

    @State private var debounceTask: Task<Void, Never>?

    @FocusState private var focusedField: BlockFieldPath?

    private var rows: [DocumentBodyRow] { DocumentBody.rows(in: blocks) }

    // MARK: - Loading

    private func load() async {
        do {
            let accessToken = try await auth.validAccessToken()
            let detail = try await DocumentsAPI.fetchDocument(
                id: document.id,
                accessToken: accessToken
            )
            title = detail.title ?? ""
            blocks = detail.blocks
            saves.configure(updatedAt: detail.updatedAt ?? document.updatedAt)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "Couldn't open this note. Go back and try again."
        }
        isLoading = false
    }

    // MARK: - Saving

    private func edited() {
        guard !isLoading else { return }
        saves.edited(id: document.id, title: title, blocks: blocks)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    @discardableResult
    private func save() async -> Bool {
        let auth = auth
        let onSaved = onSaved
        return await saves.flush { body in
            let accessToken = try await auth.validAccessToken()
            let saved = try await DocumentsAPI.saveDocument(body, accessToken: accessToken)
            onSaved(saved)
            return saved
        }
    }

    private func leave() {
        guard !isSavingCopy else { return }
        debounceTask?.cancel()
        Task { if await save() { dismiss() } }
    }

    private func saveCopy() {
        guard !isSavingCopy else { return }
        isSavingCopy = true
        debounceTask?.cancel()
        Task {
            defer { isSavingCopy = false }
            do {
                await saves.waitUntilIdle()
                let token = try await auth.validAccessToken()
                let copy = try await DocumentsAPI.createCopy(title: title, blocks: blocks, accessToken: token)
                onSaved(copy)
                saves.savedAsCopy()
                dismiss()
            } catch {
                loadErrorMessage = "Couldn't save the copy. Your edits are still open."
            }
        }
    }

    private func flushOnExit() {
        debounceTask?.cancel()
        Task { await save() }
    }

    // MARK: - Editing

    private func binding(for field: EditableBlockField) -> Binding<String> {
        Binding(
            get: { field.text },
            set: { newValue in
                let updated = DocumentBody.setting(newValue, at: field.path, in: blocks)
                guard updated != blocks else { return }
                blocks = updated
                edited()
            }
        )
    }

    private func addParagraph() {
        blocks = DocumentBody.appendingParagraph(to: blocks)
        edited()
        if case .editable(let field) = rows.last {
            focusedField = field.path
        }
    }

    private func deleteBlock(at index: Int) {
        blocks = DocumentBody.removingBlock(at: index, from: blocks)
        edited()
    }

    // MARK: - View

    var body: some View {
        List {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title2.bold())
                    .disabled(isLoading || loadErrorMessage != nil)
                    .onChange(of: title) { _, _ in edited() }
                    .listRowSeparator(.hidden)
            }

            if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            ForEach(rows) { row in
                switch row {
                case .editable(let field):
                    editableRow(field)
                case .unsupported(_, let type):
                    unsupportedRow(type: type)
                }
            }
            .onDelete(perform: deleteRows)

            if !isLoading, loadErrorMessage == nil {
                Button {
                    addParagraph()
                } label: {
                    Label("Add paragraph", systemImage: "plus")
                        .font(.subheadline)
                }
                .listRowSeparator(.hidden)
            }
        }
        .disabled(isSavingCopy)
        .listStyle(.plain)
        .overlay {
            if isLoading {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(title.isEmpty ? "Untitled" : title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Notes", systemImage: "chevron.left", action: leave)
            }
            ToolbarItem(placement: .topBarTrailing) {
                saveStatus
            }
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .task { await load() }
        .onDisappear { flushOnExit() }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch saves.state {
        case .idle:
            EmptyView()
        case .saving:
            Text("Saving…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Menu {
                Button("Retry") { Task { await save() } }
                    .disabled(isSavingCopy)
                Button("Save a copy", action: saveCopy)
                    .disabled(isSavingCopy)
            } label: {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func editableRow(_ field: EditableBlockField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if case .listItem(_, let marker) = field.style {
                Text(marker)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
            } else if case .quote = field.style {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 3)
            }

            TextField(placeholder(for: field.style), text: binding(for: field), axis: .vertical)
                .font(font(for: field.style))
                .focused($focusedField, equals: field.path)
        }
        .padding(.leading, indent(for: field.style))
        .listRowSeparator(.hidden)
    }

    private func unsupportedRow(type: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(forBlockType: type))
                .foregroundStyle(.secondary)
            Text(DocumentBody.displayName(forBlockType: type))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Web only")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityHint("This block can only be edited on the web")
    }

    /// Only whole blocks can be removed — a swipe on a list item would
    /// otherwise silently delete the entire list around it.
    private func deleteRows(_ offsets: IndexSet) {
        let deletable = offsets.compactMap { offset -> Int? in
            guard rows.indices.contains(offset) else { return nil }
            if case .editable(let field) = rows[offset], !field.ownsWholeBlock { return nil }
            return rows[offset].blockIndex
        }
        for index in deletable.sorted(by: >) {
            deleteBlock(at: index)
        }
    }

    private func placeholder(for style: EditableBlockField.Style) -> String {
        switch style {
        case .header: "Heading"
        case .code: "Code"
        case .quote: "Quote"
        case .listItem: "List item"
        case .paragraph: "Write something…"
        }
    }

    private func font(for style: EditableBlockField.Style) -> Font {
        switch style {
        case .header(let level):
            switch level {
            case 1: .title.bold()
            case 2: .title2.bold()
            case 3: .title3.bold()
            default: .headline
            }
        case .code: .system(.subheadline, design: .monospaced)
        case .quote: .body.italic()
        case .paragraph, .listItem: .body
        }
    }

    private func indent(for style: EditableBlockField.Style) -> CGFloat {
        guard case .listItem(let depth, _) = style else { return 0 }
        return CGFloat(depth) * 18
    }

    private func icon(forBlockType type: String) -> String {
        switch type {
        case "table": "tablecells"
        case "image": "photo"
        case "kanban": "rectangle.split.3x1"
        case "excalidraw": "scribble"
        case "delimiter": "minus"
        default: "square.dashed"
        }
    }
}
