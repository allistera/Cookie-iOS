import Foundation

/// Which Notes folders are open, remembered on the device so the tree comes
/// back the way it was left — the counterpart of Cookie-Web's
/// documentsSidebarFolders. Nothing stored means every folder starts closed.
enum ExpandedFolderStore {
    static let key = "notes.expandedFolderIDs"
    static let maxStoredIDs = 500

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(sanitize(defaults.stringArray(forKey: key) ?? []))
    }

    static func save(_ ids: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(sanitize(ids.sorted()), forKey: key)
    }

    /// Trims, drops blanks and duplicates, and caps the list so a stray
    /// value can neither crash the tree nor grow without bound.
    private static func sanitize(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var cleaned: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            cleaned.append(id)
            if cleaned.count == maxStoredIDs { break }
        }
        return cleaned
    }
}
