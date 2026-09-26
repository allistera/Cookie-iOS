import SwiftUI

/// The Notes workspace: the nested folder/document tree from Cookie-Web's
/// documents API, rendered as an indented, expand-collapse list.
struct NotesView: View {
    @Environment(AuthenticationManager.self) private var auth

    @State private var folders: [DocumentFolder] = []
    @State private var documents: [DocumentSummary] = []
    // Restored from the last launch; nothing stored means every folder is
    // closed. Saved again whenever a folder is toggled.
    @State private var expandedFolderIDs = ExpandedFolderStore.load()
    @State private var isLoadingInitialPage = true
    @State private var loadErrorMessage: String?
    @State private var workspacePaged = false
    @State private var loadedFolders: Set<String> = []
    @State private var pageCursors: [String: String] = [:]
    @State private var loadingFolders: Set<String> = []
    @State private var generation = 0

    private var rows: [DocumentTreeRow] {
        DocumentTree.flatten(
            folders: folders,
            documents: documents,
            expandedFolderIDs: expandedFolderIDs,
            moreFolderIDs: workspacePaged ? Set(pageCursors.keys).union(expandedFolderIDs.subtracting(loadedFolders)) : []
        )
    }

    private var isEmpty: Bool {
        folders.isEmpty && documents.isEmpty
    }

    private func loadWorkspace() async {
        generation += 1
        let requestGeneration = generation
        do {
            let accessToken = try await auth.validAccessToken()
            let workspace = try await DocumentsAPI.fetchWorkspace(accessToken: accessToken)
            guard requestGeneration == generation else { return }
            workspacePaged = workspace.version != nil
            loadedFolders = ["root"]
            pageCursors = [:]
            pageCursors["root"] = workspace.nextCursor
            folders = workspace.folders
            documents = workspace.documents
            loadErrorMessage = nil
            await loadFolders(Array(expandedFolderIDs))
        } catch {
            loadErrorMessage = "Couldn't load your notes. Pull to refresh to try again."
        }
        isLoadingInitialPage = false
    }

    private func loadFolder(_ id: String) async {
        await loadFolders([id])
    }

    /// Fetches the next page of each folder concurrently, then merges the
    /// pages in `ids` order, exactly as one-at-a-time loads would. A folder
    /// that fails doesn't stop the others from landing.
    private func loadFolders(_ ids: [String]) async {
        guard workspacePaged else { return }
        let ids = ids.filter { id in
            !loadingFolders.contains(id) && !(loadedFolders.contains(id) && pageCursors[id] == nil)
        }
        guard !ids.isEmpty else { return }
        let requestGeneration = generation
        loadingFolders.formUnion(ids)
        defer { loadingFolders.subtract(ids) }
        let token: String
        do {
            token = try await auth.validAccessToken()
        } catch {
            loadErrorMessage = "Couldn't load more notes. Try again."
            return
        }
        let requests = ids.map { (id: $0, cursor: pageCursors[$0]) }
        let results = await withTaskGroup(of: (Int, Result<DocumentsAPI.DocumentPage, any Error>).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    do {
                        let page = try await DocumentsAPI.fetchDocumentPage(folderID: request.id == "root" ? nil : request.id,
                                                                            before: request.cursor, accessToken: token)
                        return (index, .success(page))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<DocumentsAPI.DocumentPage, any Error>?](repeating: nil, count: requests.count)
            for await (index, result) in group { results[index] = result }
            return results
        }
        guard requestGeneration == generation else { return }
        for (id, result) in zip(ids, results) {
            guard case .success(let page) = result else {
                loadErrorMessage = "Couldn't load more notes. Try again."
                continue
            }
            let incoming = Set(page.documents.map(\.id))
            documents.removeAll { incoming.contains($0.id) }
            documents.append(contentsOf: page.documents)
            pageCursors[id] = page.nextCursor
            loadedFolders.insert(id)
        }
    }

    private func toggle(_ folder: DocumentFolder) {
        withAnimation {
            if expandedFolderIDs.contains(folder.id) {
                expandedFolderIDs.remove(folder.id)
            } else {
                expandedFolderIDs.insert(folder.id)
                if !loadedFolders.contains(folder.id) { Task { await loadFolder(folder.id) } }
            }
        }
    }

    var body: some View {
        ZStack {
            List {
                if let loadErrorMessage, isEmpty {
                    message(loadErrorMessage)
                } else if !isLoadingInitialPage, isEmpty {
                    message("No notes yet.")
                }

                ForEach(rows) { row in
                    switch row.item {
                    case .more(let folderID):
                        Button(loadingFolders.contains(folderID) ? "Loading…" : "More documents") {
                            Task { await loadFolder(folderID) }
                        }
                        .disabled(loadingFolders.contains(folderID))
                        .padding(.leading, CGFloat(row.depth) * 18)
                    case .folder(let folder):
                        Button {
                            toggle(folder)
                        } label: {
                            FolderRow(folder: folder, depth: row.depth, isExpanded: row.isExpanded)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                    case .document(let document):
                        NavigationLink(value: document) {
                            DocumentRow(document: document, depth: row.depth)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 16 }
                    }
                }

                Color.clear
                    .frame(height: 24)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await loadWorkspace()
            }

            if isLoadingInitialPage, isEmpty {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationDestination(for: DocumentSummary.self) { document in
            NoteEditorView(document: document) { saved in
                // Keep the tree's title and updated_at current so reopening
                // the note doesn't save against a stale version.
                if let index = documents.firstIndex(where: { $0.id == saved.id }) {
                    documents[index] = saved
                }
            }
        }
        .task {
            await loadWorkspace()
        }
        .onChange(of: expandedFolderIDs) {
            ExpandedFolderStore.save(expandedFolderIDs)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}

/// Each nesting level shifts a row right by this much, matching the web
/// sidebar's stepped indentation.
private let indentPerDepth: CGFloat = 18

private struct FolderRow: View {
    let folder: DocumentFolder
    let depth: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14)

            if let emoji = folder.emoji, !emoji.isEmpty {
                Text(emoji)
            } else {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(.red)
            }

            Text(folder.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, 16 + CGFloat(depth) * indentPerDepth)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.title) folder")
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }
}

private struct DocumentRow: View {
    let document: DocumentSummary
    let depth: Int

    var body: some View {
        HStack(spacing: 8) {
            // Keeps the icon aligned with a folder's, past its chevron.
            Color.clear.frame(width: 14, height: 1)

            switch DocumentIcon(document.emoji) {
            case .emoji(let emoji):
                Text(emoji)
            case .systemImage(let name):
                Image(systemName: name)
                    .foregroundStyle(.secondary)
            }

            Text(document.displayTitle)
                .font(.subheadline)
                .lineLimit(1)

            if document.starred {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 16 + CGFloat(depth) * indentPerDepth)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
    }
}

#Preview {
    NotesView()
        .environment(AuthenticationManager())
}
