/// Builds the row the detail screen needs from a message id, using the body
/// endpoint's subject and metadata from its thread or the mailbox endpoints.
enum EmailReference {
    enum Resolution: Equatable {
        case found(email: EmailSummary, body: MessageBody, isInboxMessage: Bool?)
        case metadataUnavailable(body: MessageBody)
    }

    static func summary(for messageID: String, unread: Bool, from body: MessageBody) -> EmailSummary? {
        guard let row = body.thread.first(where: { $0.id == messageID }) else { return nil }
        return EmailSummary(
            id: messageID, fromName: row.fromName, fromAddress: row.fromAddress, subject: body.subject,
            snippet: row.snippet, sentAt: row.sentAt, isUnread: unread, priority: nil, labels: [], category: nil)
    }

    /// Resolves mailbox metadata without fetching the message body a second time.
    /// The body endpoint is authoritative for the content, while `/emails` is the
    /// authoritative source for sender and date metadata when the body has no thread row.
    @MainActor
    static func resolve(
        for messageID: String, unread: Bool, from body: MessageBody, mailbox: Mailbox, client: APIClient
    ) async throws -> Resolution {
        if let row = mailbox.emails.first(where: { $0.id == messageID }) {
            return .found(
                email: summary(for: messageID, unread: unread, body: body, row: row),
                body: body,
                isInboxMessage: mailbox.folder == .inbox)
        }

        if let email = summary(for: messageID, unread: unread, from: body) {
            // AI Today only cites inbox triage. A thread row has no folder
            // metadata, so treat it as inbox mail unless an `/emails` row above
            // established a different folder explicitly.
            return .found(email: email, body: body, isInboxMessage: true)
        }

        for folder in searchableFolders {
            if folder == mailbox.folder, mailbox.phase == .loaded, mailbox.nextCursor == nil {
                continue
            }
            var cursor = initialCursor(for: folder, mailbox: mailbox)
            var seenCursors = Set<String>()

            for _ in 0..<maxPagesPerFolder {
                try Task.checkCancellation()
                if let cursor, !seenCursors.insert(cursor).inserted { break }
                let page: InboxPage = try await client.get(CookieAPIEndpoints.mailbox(folder: folder, before: cursor))
                try Task.checkCancellation()
                if let row = page.emails.first(where: { $0.id == messageID }) {
                    return .found(
                        email: summary(for: messageID, unread: unread, body: body, row: row),
                        body: body,
                        isInboxMessage: folder == .inbox)
                }
                guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else { break }
                cursor = nextCursor
            }
        }

        // The body was fetched successfully, so this is different from a missing
        // message. Keep the distinction so the reader can offer an honest recovery state.
        return .metadataUnavailable(body: body)
    }

    /// AI Today cites recent inbox triage, so older mail and other folders are not walked.
    private static let searchableFolders: [MailboxFolder] = [.inbox, .screening]
    /// Bounds the fallback to a few requests per folder before the reader opens.
    private static let maxPagesPerFolder = 3

    @MainActor
    private static func initialCursor(for folder: MailboxFolder, mailbox: Mailbox) -> String? {
        guard mailbox.folder == folder, mailbox.phase == .loaded else { return nil }
        return mailbox.nextCursor
    }

    private static func summary(
        for messageID: String, unread: Bool, body: MessageBody, row: EmailSummary
    ) -> EmailSummary {
        EmailSummary(
            id: messageID,
            fromName: row.fromName,
            fromAddress: row.fromAddress,
            subject: body.subject ?? row.subject,
            snippet: row.snippet,
            sentAt: row.sentAt,
            isUnread: unread,
            priority: row.priority,
            labels: row.labels,
            category: row.category,
            isSent: row.isSent,
            recipients: row.recipients)
    }
}
