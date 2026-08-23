import Foundation

enum CalendarEventsAPIError: Error {
    case unauthorized
    /// The per-user AI quota (10 requests/minute) was exhausted — surfaced
    /// separately so the UI can show the same wait-a-moment message the web
    /// app does for 429s.
    case rateLimited
    case server(status: Int)
    case invalidResponse
}

/// Talks to Cookie-Web's `POST /api/calendar-events` on the Vercel deployment
/// — the same endpoint the web app's CalendarView uses to create events from
/// natural language: one `action: "interpret"` call turns the text into a
/// draft, and a second plain POST saves that draft as an event.
struct CalendarEventsAPI {
    static let baseURL = SendAPI.baseURL

    /// A calendar row from `GET /api/calendar-events?resource=calendars`.
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
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/calendar-events"),
                resolvingAgainstBaseURL: false
            )
        else { throw CalendarEventsAPIError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "resource", value: "calendars")]
        guard let url = components.url else { throw CalendarEventsAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
        return try JSONDecoder().decode(CalendarsResponse.self, from: data).calendars
    }

    /// Asks the backend's model to turn free text ("Dinner with Sam tomorrow
    /// at 7pm") into an event draft. `timeZone` is the IANA identifier the
    /// server resolves relative dates in.
    static func interpretEvent(text: String, timeZone: String, accessToken: String) async throws -> EventDraft {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/calendar-events"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(InterpretBody(text: text, timeZone: timeZone))

        let data = try await send(request)
        return try JSONDecoder().decode(InterpretResponse.self, from: data).draft
    }

    /// Saves an interpreted draft as a real event. `tone: "accepted"` matches
    /// what the web client sends so AI-created events render like confirmed
    /// ones rather than suggestions.
    static func createEvent(_ draft: EventDraft, calendar: String, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/calendar-events"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateEventBody(draft: draft, calendar: calendar, tone: "accepted")
        )

        _ = try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CalendarEventsAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw CalendarEventsAPIError.unauthorized }
            if http.statusCode == 429 { throw CalendarEventsAPIError.rateLimited }
            throw CalendarEventsAPIError.server(status: http.statusCode)
        }
        return data
    }
}
