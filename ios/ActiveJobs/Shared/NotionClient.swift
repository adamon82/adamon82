import Foundation

/// Shared settings between the app and the widget (App Group).
enum AppConfig {
    static let appGroup = "group.app.activejobs"
    static let dataSourceID = "4c9b4c8f-c6d5-4655-9411-646a1ae53fd3"
    static let databaseURL = URL(string: "https://www.notion.so/28e862a4647440c6956e9dbd25eb8c21")!

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static var token: String {
        get { defaults.string(forKey: "notionToken") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "notionToken") }
    }

    /// Last successful fetch, so the widget can show something even offline.
    static var cachedJobs: [Job] {
        get {
            guard let data = defaults.data(forKey: "cachedJobs") else { return [] }
            return (try? JSONDecoder().decode([Job].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "cachedJobs") }
    }
}

enum NotionError: LocalizedError {
    case missingToken
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingToken: return "צריך להדביק מפתח Notion בהגדרות."
        case .http(401, _): return "המפתח של Notion לא תקין. בדוק אותו בהגדרות."
        case .http(404, _): return "ל-integration אין גישה לטבלת המשרות. שתף אותה איתו ב-Notion (Connections)."
        case .http(429, _): return "Notion מבקש להאט. נסה שוב בעוד רגע."
        case .http(let code, let msg): return "Notion החזיר שגיאה \(code). \(msg)"
        case .badResponse: return "התשובה מ-Notion לא בפורמט הצפוי."
        }
    }
}

struct NotionClient {
    var token: String = AppConfig.token
    private let base = URL(string: "https://api.notion.com/v1/")!
    private let version = "2025-09-03"

    // MARK: Requests

    private func request(_ path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        guard !token.isEmpty else { throw NotionError.missingToken }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw NotionError.http(code, json["message"] as? String ?? "")
        }
        return json
    }

    func fetchJobs() async throws -> [Job] {
        var jobs: [Job] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await request("data_sources/\(AppConfig.dataSourceID)/query", method: "POST", body: body)
            guard let results = json["results"] as? [[String: Any]] else { throw NotionError.badResponse }
            jobs += results.compactMap(Self.parse)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return jobs
    }

    func update(_ job: Job) async throws {
        _ = try await request("pages/\(job.id)", method: "PATCH", body: ["properties": Self.properties(for: job)])
    }

    func create(_ job: Job) async throws -> String {
        let body: [String: Any] = [
            "parent": ["type": "data_source_id", "data_source_id": AppConfig.dataSourceID],
            "properties": Self.properties(for: job),
        ]
        let json = try await request("pages", method: "POST", body: body)
        guard let id = json["id"] as? String else { throw NotionError.badResponse }
        return id
    }

    // MARK: Mapping

    static func parse(_ page: [String: Any]) -> Job? {
        guard let id = page["id"] as? String, let props = page["properties"] as? [String: Any] else { return nil }
        func p(_ k: String) -> [String: Any] { props[k] as? [String: Any] ?? [:] }
        func text(_ k: String) -> String {
            let arr = (p(k)["title"] ?? p(k)["rich_text"]) as? [[String: Any]] ?? []
            return arr.compactMap { $0["plain_text"] as? String }.joined()
        }
        func number(_ k: String) -> Int { (p(k)["number"] as? NSNumber)?.intValue ?? 0 }
        let statusName = (p("Status")["select"] as? [String: Any])?["name"] as? String ?? ""
        let dateString = (p("Updated")["date"] as? [String: Any])?["start"] as? String
            ?? p("Last edited")["last_edited_time"] as? String
        return Job(
            id: id,
            role: text("Role"),
            company: text("Company"),
            status: JobStatus(rawValue: statusName) ?? .verify,
            outreach: number("Outreach"),
            interview: number("Interview"),
            offer: number("Offer"),
            hot: p("Hot")["checkbox"] as? Bool ?? false,
            location: text("Location"),
            notes: text("Notes"),
            link: p("Link")["url"] as? String ?? "",
            updated: dateString.flatMap(parseDate),
            updatedBy: text("Updated by")
        )
    }

    static func properties(for j: Job) -> [String: Any] {
        func rich(_ s: String) -> [String: Any] { ["rich_text": s.isEmpty ? [] : [["text": ["content": String(s.prefix(2000))]]]] }
        var props: [String: Any] = [
            "Role": ["title": [["text": ["content": j.role]]]],
            "Company": rich(j.company),
            "Status": ["select": ["name": j.status.rawValue]],
            "Outreach": ["number": j.outreach],
            "Interview": ["number": j.interview],
            "Offer": ["number": j.offer],
            "Hot": ["checkbox": j.hot],
            "Location": rich(j.location),
            "Notes": rich(j.notes),
            "Updated": ["date": ["start": ISO8601DateFormatter().string(from: Date())]],
            "Updated by": rich("אדם (אייפון)"),
        ]
        props["Link"] = ["url": j.link.isEmpty ? (NSNull() as Any) : (j.link as Any)]
        return props
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
