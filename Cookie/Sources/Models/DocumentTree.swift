import Foundation

/// One rendered line of the Notes tree: a folder or a document, plus how deep
/// it sits so the list can indent it.
struct DocumentTreeRow: Identifiable, Hashable {
    enum Item: Hashable {
        case folder(DocumentFolder)
        case document(DocumentSummary)
    }

    let item: Item
    let depth: Int
    /// Only meaningful for folders; documents are always leaves.
    let isExpanded: Bool

    var id: String {
        switch item {
        case .folder(let folder): "folder-\(folder.id)"
        case .document(let document): "document-\(document.id)"
        }
    }
}

/// Flattens the folder/document forest the workspace endpoint returns into
/// ordered, depth-annotated rows — the same shape (and the same rules) as
/// Cookie-Web's `flattenDocumentsTree`, so the two apps agree on what the
/// tree looks like. Rows inside a collapsed folder are omitted. A folder
/// whose `parentID` no longer resolves, or which sits in a parent cycle, is
/// treated as a root so its subtree never silently vanishes.
enum DocumentTree {
    static func flatten(
        folders: [DocumentFolder],
        documents: [DocumentSummary],
        expandedFolderIDs: Set<String>
    ) -> [DocumentTreeRow] {
        let folderIDs = Set(folders.map(\.id))

        var childFolders: [String?: [DocumentFolder]] = [nil: []]
        for folder in folders {
            let parent = folder.parentID.flatMap { folderIDs.contains($0) ? $0 : nil }
            childFolders[parent, default: []].append(folder)
        }

        var documentsByFolder: [String?: [DocumentSummary]] = [:]
        for document in documents {
            let folder = document.folderID.flatMap { folderIDs.contains($0) ? $0 : nil }
            documentsByFolder[folder, default: []].append(document)
        }

        // Reachability ignores expansion: a folder inside a collapsed parent
        // is hidden, not orphaned. Only members of a cycle — reachable from
        // no root at all — get pulled up to the top level below.
        var reachable: Set<String> = []
        func mark(_ parentID: String?) {
            for child in childFolders[parentID] ?? [] where !reachable.contains(child.id) {
                reachable.insert(child.id)
                mark(child.id)
            }
        }
        mark(nil)

        for orphan in folders where !reachable.contains(orphan.id) {
            reachable.insert(orphan.id)
            childFolders[nil, default: []].append(orphan)
            // Break the cycle so the walk below terminates at this new root.
            if let index = childFolders[orphan.parentID]?.firstIndex(of: orphan) {
                childFolders[orphan.parentID]?.remove(at: index)
            }
            mark(orphan.id)
        }

        var rows: [DocumentTreeRow] = []
        func walk(_ parentID: String?, depth: Int) {
            for folder in childFolders[parentID] ?? [] {
                let expanded = expandedFolderIDs.contains(folder.id)
                rows.append(.init(item: .folder(folder), depth: depth, isExpanded: expanded))
                guard expanded else { continue }
                walk(folder.id, depth: depth + 1)
                for document in documentsByFolder[folder.id] ?? [] {
                    rows.append(.init(item: .document(document), depth: depth + 1, isExpanded: false))
                }
            }
        }
        walk(nil, depth: 0)

        for document in documentsByFolder[nil] ?? [] {
            rows.append(.init(item: .document(document), depth: 0, isExpanded: false))
        }

        return rows
    }
}
