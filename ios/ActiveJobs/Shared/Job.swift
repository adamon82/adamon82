import SwiftUI

enum JobStatus: String, CaseIterable, Identifiable, Codable {
    case active = "פעילה"
    case verify = "לאימות"
    case hold = "בהמתנה"
    case closed = "נסגרה"

    var id: String { rawValue }
    var label: String { rawValue }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var color: Color {
        switch self {
        case .active: return Color(red: 0.24, green: 0.66, blue: 0.47)
        case .verify: return Color(red: 0.86, green: 0.58, blue: 0.22)
        case .hold:   return Color(red: 0.52, green: 0.54, blue: 0.75)
        case .closed: return Color(red: 0.62, green: 0.62, blue: 0.66)
        }
    }
    var symbol: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .verify: return "questionmark.circle.fill"
        case .hold:   return "pause.circle.fill"
        case .closed: return "xmark.circle.fill"
        }
    }
}

enum Stage: String, CaseIterable, Identifiable {
    case outreach = "פנייה"
    case interview = "ראיון"
    case offer = "הצעה"
    var id: String { rawValue }
}

struct Job: Identifiable, Hashable, Codable {
    var id: String
    var role: String
    var company: String
    var status: JobStatus
    var outreach: Int
    var interview: Int
    var offer: Int
    var hot: Bool
    var location: String
    var notes: String
    var link: String
    var updated: Date?
    var updatedBy: String
    var clientID: String? = nil

    static func blank() -> Job {
        Job(id: "", role: "", company: "", status: .active, outreach: 0, interview: 0, offer: 0,
            hot: false, location: "", notes: "", link: "", updated: Date(), updatedBy: "")
    }

    var total: Int { outreach + interview + offer }

    func count(_ s: Stage) -> Int {
        switch s { case .outreach: return outreach; case .interview: return interview; case .offer: return offer }
    }
    mutating func setCount(_ s: Stage, _ v: Int) {
        let v = max(0, min(99, v))
        switch s { case .outreach: outreach = v; case .interview: interview = v; case .offer: offer = v }
    }

    var daysSinceUpdate: Int? {
        guard let updated else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: updated, to: Date()).day ?? 0)
    }
    var isStale: Bool { status == .active && (daysSinceUpdate ?? 0) >= 14 }
    var needsAttention: Bool { status == .verify || isStale }

    var updatedText: String {
        guard let d = daysSinceUpdate else { return "" }
        switch d {
        case 0: return "היום"
        case 1: return "אתמול"
        default: return "לפני \(d) ימים"
        }
    }
}

extension Array where Element == Job {
    func sortedForBoard() -> [Job] {
        sorted {
            if $0.status.order != $1.status.order { return $0.status.order < $1.status.order }
            if $0.hot != $1.hot { return $0.hot }
            return ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
        }
    }
}
