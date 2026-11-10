import SwiftUI

struct CompanyBlock: Identifiable {
    enum Kind { case h1, h2, h3, text, bullet, quote }
    let id = UUID()
    let kind: Kind
    let text: String
    var internalOnly = false
}

extension NotionClient {
    func fetchPitch(pageID: String) async throws -> (name: String, pitch: String) {
        let json = try await request("pages/\(pageID)", method: "GET", body: nil)
        let props = json["properties"] as? [String: Any] ?? [:]
        func text(_ k: String) -> String {
            let p = props[k] as? [String: Any] ?? [:]
            let arr = (p["title"] ?? p["rich_text"]) as? [[String: Any]] ?? []
            return arr.compactMap { $0["plain_text"] as? String }.joined()
        }
        return (text("Customer"), text("Pitch"))
    }

    func fetchBlocks(pageID: String) async throws -> [CompanyBlock] {
        var out: [CompanyBlock] = []
        var cursor: String?
        repeat {
            let path = "blocks/\(pageID)/children?page_size=100" + (cursor.map { "&start_cursor=\($0)" } ?? "")
            let json = try await request(path, method: "GET", body: nil)
            for b in json["results"] as? [[String: Any]] ?? [] {
                guard let type = b["type"] as? String, let body = b[type] as? [String: Any] else { continue }
                let rich = body["rich_text"] as? [[String: Any]] ?? []
                let t = rich.compactMap { $0["plain_text"] as? String }.joined()
                let kind: CompanyBlock.Kind?
                switch type {
                case "heading_1": kind = .h1
                case "heading_2": kind = .h2
                case "heading_3": kind = .h3
                case "paragraph": kind = t.isEmpty ? nil : .text
                case "bulleted_list_item", "numbered_list_item", "to_do": kind = .bullet
                case "quote", "callout": kind = .quote
                default: kind = nil
                }
                if let kind { out.append(CompanyBlock(kind: kind, text: t)) }
            }
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return Self.markInternal(out)
    }

    /// Everything under a heading that says "לא לומר" (until the next heading of the same or higher level) is internal.
    static func markInternal(_ blocks: [CompanyBlock]) -> [CompanyBlock] {
        func level(_ k: CompanyBlock.Kind) -> Int? { switch k { case .h1: 1; case .h2: 2; case .h3: 3; default: nil } }
        var result = blocks
        var internalLevel: Int?
        for i in result.indices {
            if let l = level(result[i].kind) {
                if let il = internalLevel, l <= il { internalLevel = nil }
                if result[i].text.contains("לא לומר") || result[i].text.contains("פנימי") { internalLevel = l }
            }
            result[i].internalOnly = internalLevel != nil
        }
        return result
    }
}

struct CompanyView: View {
    let job: Job
    @State private var pitch = ""
    @State private var blocks: [CompanyBlock] = []
    @State private var loading = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Group {
            if job.clientID == nil {
                ContentUnavailableView("אין דף לקוח מקושר", systemImage: "building.2",
                                       description: Text("ב-Notion, בטבלת המשרות, מקשרים את המשרה לדף הלקוח בעמודה Client."))
            } else {
                List {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(JobStatus.verify.color)
                    }
                    if !pitch.isEmpty {
                        Section {
                            Text(pitch).font(.subheadline).textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = pitch
                                copied.toggle()
                            } label: { Label("העתקת הפיץ' למועמד", systemImage: "doc.on.doc") }
                            .sensoryFeedback(.success, trigger: copied)
                        } header: { Text("פיץ' למועמדים") }
                    }
                    let shared = blocks.filter { !$0.internalOnly }
                    let internalBlocks = blocks.filter(\.internalOnly)
                    if !shared.isEmpty {
                        Section("הפיץ' המלא") { ForEach(shared) { BlockRow(block: $0) } }
                    }
                    if !internalBlocks.isEmpty {
                        Section {
                            ForEach(internalBlocks) { BlockRow(block: $0) }
                        } header: {
                            Label("פנימי, לא לשתף עם מועמדים", systemImage: "lock.fill").foregroundStyle(Decision.no.color)
                        }
                        .listRowBackground(Decision.no.color.opacity(0.08))
                    }
                }
                .overlay { if loading && blocks.isEmpty && pitch.isEmpty { ProgressView() } }
                .refreshable { await load() }
                .task { await load() }
            }
        }
    }

    private func load() async {
        guard let id = job.clientID else { return }
        loading = true
        defer { loading = false }
        do {
            async let p = NotionClient().fetchPitch(pageID: id)
            async let b = NotionClient().fetchBlocks(pageID: id)
            pitch = try await p.pitch
            blocks = try await b
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BlockRow: View {
    let block: CompanyBlock
    var body: some View {
        switch block.kind {
        case .h1, .h2: Text(block.text).font(.headline)
        case .h3: Text(block.text).font(.subheadline.weight(.semibold))
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(block.text) }.font(.subheadline)
        case .quote: Text(block.text).font(.subheadline).italic().foregroundStyle(.secondary)
        case .text: Text(block.text).font(.subheadline)
        }
    }
}
