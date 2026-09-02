import Foundation

/// Canonical production endpoints for the Cookie API Workers.
///
/// Keep complete route URLs here so a backend route migration cannot leave
/// one client using an old origin or path shape.
enum CookieAPIEndpoints {
    static let emails = URL(string: "https://emails-api.infinitywave.online/emails")!
    static let messages = URL(string: "https://messages-api.infinitywave.online/messages")!
    static let contacts = URL(string: "https://messages-api.infinitywave.online/messages/contacts")!
    static let search = URL(string: "https://search-api.infinitywave.online/search")!
    static let send = URL(string: "https://send-api.infinitywave.online/send")!
    static let calendarEvents = URL(string: "https://calendar-api.infinitywave.online/calendar-events")!
    static let calendars = URL(string: "https://calendar-api.infinitywave.online/calendars")!
    static let documents = URL(string: "https://tasks-api.infinitywave.online/documents")!
}
