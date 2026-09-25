import Foundation

/// Talks to the `cookie-web-calendar` Cloudflare Worker — the same endpoints
/// the web app's CalendarView uses to create events from
/// natural language: one `action: "interpret"` call turns the text into a
/// draft, and a second plain POST saves that draft as an event.
struct CalendarEventsAPI {
    /// A calendar row from `GET /calendars`.
    /// A non-nil `subscriptionUrl` marks a subscribed (read-only) calendar,
    /// which the backend refuses to create events in.
    struct CalendarSummary: Decodable {
        let id: String
        let name: String
        let subscriptionUrl: String?
    }

    /// The AI-interpreted event returned by `action: "interpret"`. The web
    /// client spreads this object straight into the create body, so the
    /// fields double as `Encodable` create fields; the backend derives
    /// `recurrenceRule` from the repeat trio itself.
    struct EventDraft: Codable {
        let title: String
        let description: String?
        let location: String?
        /// `YYYY-MM-DD` in the user's time zone.
        let date: String
        /// `HH:MM`, 24-hour local time.
        let start: String
        /// Minutes.
        let duration: Int
        /// `none`, `daily`, `weekly`, `monthly` or `yearly`.
        let `repeat`: String
        let repeatUntil: String?
        /// Two-letter weekday codes (`MO`…`SU`); only set for weekly repeats.
        let repeatDays: [String]?
    }

    private struct CalendarsResponse: Decodable {
        let calendars: [CalendarSummary]
    }

    private struct InterpretBody: Encodable {
        let action = "interpret"
        let text: String
        let timeZone: String
    }

    private struct InterpretResponse: Decodable {
        let draft: EventDraft
    }

    /// Mirrors the web client's `{ ...draft, calendar, tone: 'accepted' }`
    /// spread: the draft's own fields and the two extras end up as one flat
    /// JSON object.
    struct CreateEventBody: Encodable {
        let draft: EventDraft
        let calendar: String
        let tone: String

        private enum CodingKeys: String, CodingKey {
            case calendar
            case tone
        }

        func encode(to encoder: Encoder) throws {
            try draft.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(calendar, forKey: .calendar)
            try container.encode(tone, forKey: .tone)
        }
    }

    /// The user's calendars, needed to pick the default one an AI-created
    /// event files under (the create endpoint requires an owned calendar id).
    static func fetchCalendars(accessToken: String) async throws -> [CalendarSummary] {
        let request = APIClient.request(CookieAPIEndpoints.calendars, accessToken: accessToken)
        return try await APIClient.send(request, decoding: CalendarsResponse.self).calendars
    }

    /// Asks the backend's model to turn free text ("Dinner with Sam tomorrow
    /// at 7pm") into an event draft. `timeZone` is the IANA identifier the
    /// server resolves relative dates in.
    static func interpretEvent(text: String, timeZone: String, accessToken: String) async throws -> EventDraft {
        let request = APIClient.request(
            CookieAPIEndpoints.calendarEvents,
            method: "POST",
            accessToken: accessToken,
            jsonBody: try JSONEncoder().encode(InterpretBody(text: text, timeZone: timeZone))
        )
        return try await APIClient.send(request, decoding: InterpretResponse.self).draft
    }

    /// Saves an interpreted draft as a real event. `tone: "accepted"` matches
    /// what the web client sends so AI-created events render like confirmed
    /// ones rather than suggestions.
    static func createEvent(_ draft: EventDraft, calendar: String, accessToken: String) async throws {
        let request = APIClient.request(
            CookieAPIEndpoints.calendarEvents,
            method: "POST",
            accessToken: accessToken,
            jsonBody: try JSONEncoder().encode(CreateEventBody(draft: draft, calendar: calendar, tone: "accepted"))
        )
        try await APIClient.send(request)
    }
}
