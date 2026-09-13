import SwiftUI

struct EmailFilter: RawRepresentable, Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    static let newsletters = Self(rawValue: "Newsletters")
    static let personal = Self(rawValue: "Personal")
    static let recruitment = Self(rawValue: "Recruitment")
    static let shopping = Self(rawValue: "Shopping")
    static let work = Self(rawValue: "Work")
    static let uncategorised = Self(rawValue: "Uncategorised")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(category: EmailCategory?) {
        let name = category?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self = name.isEmpty ? .uncategorised : Self(rawValue: name)
    }
}

struct DummyEmail: Identifiable, Hashable {
    let id: UUID
    let sender: String
    /// The sender's actual email address. Empty for the static preview
    /// data below (no real mailbox to reply to); populated from
    /// `EmailMessage.fromAddress` for live rows, so replies address the
    /// right person even when `sender` is just a display name.
    let address: String
    let initial: String
    let color: Color
    let time: String
    let subject: String
    let preview: String
    let isUnread: Bool
    let filter: EmailFilter

    init(
        id: UUID = UUID(),
        sender: String,
        address: String = "",
        initial: String,
        color: Color,
        time: String,
        subject: String,
        preview: String,
        isUnread: Bool,
        filter: EmailFilter
    ) {
        self.id = id
        self.sender = sender
        self.address = address
        self.initial = initial
        self.color = color
        self.time = time
        self.subject = subject
        self.preview = preview
        self.isUnread = isUnread
        self.filter = filter
    }

    static let sample: [DummyEmail] = [
        DummyEmail(sender: "GitHub", initial: "G", color: .black, time: "3:03 pm",
                   subject: "[Cookie] New pull request opened",
                   preview: "allistera opened a pull request in cookie/cookie-ios: Add inbox screen…",
                   isUnread: true,
                   filter: .work),
        DummyEmail(sender: "Stripe", initial: "S", color: Color(red: 0.39, green: 0.29, blue: 0.94), time: "2:57 pm",
                   subject: "Your weekly payout has been sent",
                   preview: "A payout of $482.10 was sent to your bank account ending in 4821…",
                   isUnread: true,
                   filter: .shopping),
        DummyEmail(sender: "Linear", initial: "L", color: .black, time: "2:57 pm",
                   subject: "New login to Linear",
                   preview: "Login detected with Safari on iOS from Edinburgh, SCT, GB",
                   isUnread: true,
                   filter: .work),
        DummyEmail(sender: "Figma", initial: "F", color: Color(red: 0.94, green: 0.29, blue: 0.42), time: "2:39 pm",
                   subject: "Comment on \"Cookie – Inbox v2\"",
                   preview: "Ada left a comment: \"love the new list spacing, can we ship this?\"",
                   isUnread: true,
                   filter: .work),
        DummyEmail(sender: "Slack", initial: "S", color: Color(red: 0.90, green: 0.11, blue: 0.39), time: "2:22 pm",
                   subject: "You have 3 unread messages in #cookie-ios",
                   preview: "sam: anyone free to review the auth PR before standup?",
                   isUnread: true,
                   filter: .personal),
        DummyEmail(sender: "Vercel", initial: "V", color: .black, time: "2:00 pm",
                   subject: "Deployment succeeded for cookie-web",
                   preview: "Your production deployment is now live at cookie.app…",
                   isUnread: true,
                   filter: .work),
        DummyEmail(sender: "Supabase", initial: "S", color: Color(red: 0.19, green: 0.71, blue: 0.51), time: "1:54 pm",
                   subject: "Weekly database usage report",
                   preview: "Your project used 1.2 GB of storage and 340k row reads this week…",
                   isUnread: false,
                   filter: .newsletters),
        DummyEmail(sender: "Notion", initial: "N", color: .black, time: "1:49 pm",
                   subject: "Your shared doc was updated",
                   preview: "Ada made changes to \"Q3 Roadmap\" — 4 new comments to review…",
                   isUnread: false,
                   filter: .recruitment)
    ]
}

extension DummyEmail {
    /// Builds the inbox row model from a live `GET /emails` row. Returns
    /// `nil` only if the backend ever sends a malformed id, which shouldn't
    /// happen since `messages.id` is a Postgres UUID column.
    init?(message: EmailMessage) {
        guard let uuid = UUID(uuidString: message.id) else { return nil }

        let name = message.fromName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displaySender = name.isEmpty ? message.fromAddress : name
        let subjectText = message.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        self.init(
            id: uuid,
            sender: displaySender,
            address: message.fromAddress,
            initial: String(displaySender.first ?? "?").uppercased(),
            color: DummyEmail.avatarColor(for: displaySender),
            time: DummyEmail.formattedTime(from: message.sentAt),
            subject: subjectText.isEmpty ? "(no subject)" : subjectText,
            preview: message.snippet ?? "",
            isUnread: message.isUnread,
            filter: EmailFilter(category: message.category)
        )
    }

    /// `"Re: <subject>"`, without doubling up if the subject already has
    /// one — mirrors Cookie-Web's `followUpSubject` in `stores/inbox.js`.
    static func replySubject(for subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let alreadyReply = trimmed.range(
            of: "^re:",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        return alreadyReply ? trimmed : "Re: \(trimmed)"
    }

    /// A quoted-reply starter body. Quotes the list snippet rather than the
    /// complete original text — the composer is built from the row model,
    /// before the detail screen's full-body fetch has necessarily run.
    static func quotedReplyBody(for email: DummyEmail) -> String {
        "\n\nOn \(email.time), \(email.sender) wrote:\n> \(email.preview)"
    }

    private static let avatarPalette: [Color] = [
        .black,
        Color(red: 0.39, green: 0.29, blue: 0.94),
        Color(red: 0.94, green: 0.29, blue: 0.42),
        Color(red: 0.90, green: 0.11, blue: 0.39),
        Color(red: 0.19, green: 0.71, blue: 0.51),
    ]

    private static func avatarColor(for sender: String) -> Color {
        guard !sender.isEmpty else { return .black }
        let index = abs(sender.hashValue) % avatarPalette.count
        return avatarPalette[index]
    }

    // Format styles are immutable, Sendable values. Foundation caches their
    // formatting machinery, avoiding mutable global formatters under Swift 6.
    private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func formattedTime(from iso8601: String) -> String {
        guard let date = (try? fractionalTimestamp.parse(iso8601))
            ?? (try? wholeTimestamp.parse(iso8601)) else { return "" }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }
}
