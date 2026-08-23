import Foundation

/// A contact for compose auto-suggest, as returned by
/// `GET /messages/contacts` (`{ contacts: [{ address, name }] }`). `name`
/// is the display name when known, `nil` otherwise.
struct Contact: Decodable, Hashable, Identifiable {
    let address: String
    let name: String?

    var id: String { address }
}

/// Pure helpers behind the composer "To" auto-suggest, mirroring Cookie-Web's
/// `lib/contactSuggest.js` and `lib/recipients.js`.
///
/// The To field holds a comma-separated list of recipient addresses (send to
/// several people by adding a comma) — same as the web composer.
enum ContactSuggest {
    // MARK: Recipient field parsing

    /// The trimmed, non-empty addresses in the field.
    static func parseRecipients(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when there is at least one recipient and every one looks like an
    /// address.
    static func recipientsValid(_ value: String) -> Bool {
        let list = parseRecipients(value)
        return !list.isEmpty && list.allSatisfy { $0.contains("@") }
    }

    /// The address fragment the user is currently typing (after the last comma).
    static func currentRecipientToken(_ value: String) -> String {
        let text = value
        guard let index = text.lastIndex(of: ",") else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Addresses already committed before the current token.
    static func completedRecipients(_ value: String) -> [String] {
        guard let index = value.lastIndex(of: ",") else { return [] }
        return parseRecipients(String(value[..<index]))
    }

    /// Replaces the current token with a chosen address and readies the next
    /// one, so an auto-suggest pick appends rather than overwriting earlier
    /// recipients.
    static func appendRecipient(_ value: String, _ address: String) -> String {
        guard let index = value.lastIndex(of: ",") else {
            return "\(address), "
        }
        return "\(value[...index]) \(address), "
    }

    // MARK: Suggestion filtering

    /// Filters the contact list for the composer "to" auto-suggest. Matches
    /// the query against BOTH the display name and the address
    /// (case-insensitive), so a user can type a person's name. Prefix matches
    /// rank above substring matches; an address the user has already typed in
    /// full is dropped (nothing left to suggest).
    static func filterContacts(
        _ contacts: [Contact],
        query: String,
        limit: Int = 6
    ) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return [] }

        var scored: [(contact: Contact, rank: Int)] = []
        for contact in contacts {
            let name = (contact.name ?? "").lowercased()
            let address = contact.address.lowercased()
            if address == q { continue } // already fully entered
            guard name.contains(q) || address.contains(q) else { continue }
            let startsWith = name.hasPrefix(q) || address.hasPrefix(q)
            scored.append((contact, startsWith ? 0 : 1))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return (lhs.contact.name ?? lhs.contact.address)
                    .localizedStandardCompare(rhs.contact.name ?? rhs.contact.address) == .orderedAscending
            }
            .prefix(limit)
            .map(\.contact)
    }
}
