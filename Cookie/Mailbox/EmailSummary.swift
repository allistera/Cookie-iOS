import Foundation

struct EmailLabel: Decodable, Hashable, Sendable {
    let name: String
    let color: String?
}

struct EmailCategory: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let color: String?

    /// A category named "Important" shares the fixed Important tab, as in the web app.
    var isImportant: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "important"
    }
}

struct Recipient: Decodable, Hashable, Sendable {
    let name: String?
    let address: String?

    var displayName: String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedAddress.isEmpty ? nil : trimmedAddress
    }
}

extension Recipient {
    private enum CodingKeys: String, CodingKey {
        case name, address
    }

    /// Accepts `{name, address}` or a bare address string, which some stored rows hold.
    init(from decoder: any Decoder) throws {
        if let address = try? decoder.singleValueContainer().decode(String.self) {
            self.init(name: nil, address: address)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            address: try container.decodeIfPresent(String.self, forKey: .address)
        )
    }
}

/// The `recipients` column: `{to, cc, bcc}` lists. Only `to` is read.
struct Recipients: Decodable, Hashable, Sendable {
    let primary: [Recipient]?

    private enum CodingKeys: String, CodingKey {
        case primary = "to"
    }
}

/// One mailbox row from `GET /emails`. Bodies are fetched separately when read.
struct EmailSummary: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let fromName: String?
    let fromAddress: String
    let subject: String?
    let snippet: String?
    let sentAt: Date
    var isUnread: Bool
    let priority: String?
    let labels: [EmailLabel]
    let category: EmailCategory?
    var isSent = false
    var recipients: Recipients?

    private enum CodingKeys: String, CodingKey {
        case id, fromName, fromAddress, subject, snippet, sentAt, isUnread, priority, labels, category, isSent
        case recipients
    }

    init(
        id: String, fromName: String?, fromAddress: String, subject: String?, snippet: String?, sentAt: Date,
        isUnread: Bool, priority: String?, labels: [EmailLabel], category: EmailCategory?, isSent: Bool = false,
        recipients: Recipients? = nil
    ) {
        self.id = id
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.subject = subject
        self.snippet = snippet
        self.sentAt = sentAt
        self.isUnread = isUnread
        self.priority = priority
        self.labels = labels
        self.category = category
        self.isSent = isSent
        self.recipients = recipients
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fromName = try container.decodeIfPresent(String.self, forKey: .fromName)
        fromAddress = try container.decode(String.self, forKey: .fromAddress)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        isUnread = try container.decode(Bool.self, forKey: .isUnread)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        labels = try container.decode([EmailLabel].self, forKey: .labels)
        category = try container.decodeIfPresent(EmailCategory.self, forKey: .category)
        isSent = try container.decodeIfPresent(Bool.self, forKey: .isSent) ?? false
        // Recipients only label sent rows; a malformed value must not fail the whole page.
        recipients = try? container.decodeIfPresent(Recipients.self, forKey: .recipients)
    }

    var senderName: String {
        let name = fromName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fromAddress : name
    }

    /// The row's first line: the sender, or "To: <recipient>" for sent mail.
    var displayName: String {
        guard isSent, let recipient = recipients?.primary?.first?.displayName else { return senderName }
        return String(localized: "To: \(recipient)")
    }

    /// High-rated mail, or mail in a category named Important.
    var isImportant: Bool {
        priority == "high" || category?.isImportant == true
    }
}

struct InboxPage: Decodable, Equatable, Sendable {
    let emails: [EmailSummary]
    let nextCursor: String?
    /// Present on the first page only.
    let unreadCount: Int?
}

struct CategoryList: Decodable, Equatable, Sendable {
    let categories: [EmailCategory]
}
