import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Share → משרות" from WhatsApp (or any app): adds a candidate to the Notion candidates table,
/// under a chosen client and job, with where the candidate came from.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let root = ShareView(model: model).environment(\.layoutDirection, .rightToLeft)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.start() }
    }
}

enum CandidateSource: String, CaseIterable, Identifiable {
    case colleague = "קולגה"
    case referral = "הפניה ממועמד"
    case direct = "מועמד פנה ישירות"
    case linkedin = "לינקדאין"
    case other = "אחר"
    var id: String { rawValue }
}

struct Client: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class ShareModel {
    let context: NSExtensionContext?

    // What was shared
    var sharedText = ""
    var fileName = ""

    // Form
    var name = ""
    var linkedIn = ""
    var clients: [Client] = []
    var jobs: [Job] = []
    var clientID: String = "" { didSet { if !jobsForClient.contains(where: { $0.id == jobID }) { jobID = jobsForClient.first?.id ?? "" } } }
    var jobID = ""
    var source: CandidateSource = .colleague
    var sourceDetail = ""
    var note = ""

    // State
    var token = AppConfig.token
    var loading = false
    var saving = false
    var error: String?

    private let memory = UserDefaults.standard

    init(context: NSExtensionContext?) { self.context = context }

    var hasToken: Bool { !AppConfig.token.isEmpty }
    var jobsForClient: [Job] {
        let open = jobs.filter { $0.status != .closed }
        return clientID.isEmpty ? open : open.filter { $0.clientID?.replacingOccurrences(of: "-", with: "") == clientID.replacingOccurrences(of: "-", with: "") }
    }
    var canSave: Bool { !jobID.isEmpty && !(name.trimmingCharacters(in: .whitespaces).isEmpty && linkedIn.isEmpty) && !saving }

    func start() async {
        source = CandidateSource(rawValue: memory.string(forKey: "share.source") ?? "") ?? .colleague
        await readShared()
        if hasToken { await loadLists() }
    }

    func saveToken() async {
        AppConfig.token = token
        await loadLists()
    }

    // MARK: Input

    private func readShared() async {
        var texts: [String] = []
        for item in context?.inputItems as? [NSExtensionItem] ?? [] {
            if let t = item.attributedContentText?.string, !t.isEmpty { texts.append(t) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL { fileName = url.lastPathComponent } else { texts.append(url.absoluteString) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let t = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(t)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    fileName = provider.suggestedName ?? "קובץ מצורף"
                }
            }
        }
        sharedText = Array(NSOrderedSet(array: texts)).compactMap { $0 as? String }.joined(separator: "\n")
        linkedIn = Self.findLinkedIn(in: sharedText) ?? ""
        name = Self.guessName(text: sharedText, linkedIn: linkedIn, fileName: fileName)
    }

    static func findLinkedIn(in text: String) -> String? {
        guard let r = text.range(of: #"(https?://)?([a-z]{2,3}\.)?linkedin\.com/in/[^\s/?#]+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var s = String(text[r])
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return s + "/"
    }

    static func slug(_ url: String) -> String? {
        guard let r = url.range(of: #"/in/([^/?#]+)"#, options: .regularExpression) else { return nil }
        return String(url[r]).replacingOccurrences(of: "/in/", with: "").removingPercentEncoding
    }

    static func guessName(text: String, linkedIn: String, fileName: String) -> String {
        if let s = slug(linkedIn) {
            let parts = s.split(separator: "-").filter { !$0.contains(where: \.isNumber) }
            if !parts.isEmpty { return parts.prefix(3).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        }
        if !fileName.isEmpty {
            let base = (fileName as NSString).deletingPathExtension
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "CV", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "קורות חיים", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { return base }
        }
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.count <= 40 && !first.contains("http") ? first : ""
    }

    // MARK: Notion

    func loadLists() async {
        loading = true
        defer { loading = false }
        do {
            async let j = NotionClient().fetchJobs()
            async let c = Self.fetchClients()
            jobs = try await j
            let used = Set(jobs.compactMap { $0.clientID?.replacingOccurrences(of: "-", with: "") })
            // Clients that have at least one job first, then the rest.
            clients = (try await c).sorted { (used.contains($0.id) ? 0 : 1, $0.name.lowercased()) < (used.contains($1.id) ? 0 : 1, $1.name.lowercased()) }
            let last = memory.string(forKey: "share.client") ?? ""
            clientID = clients.contains(where: { $0.id == last }) ? last : ""
            if jobID.isEmpty { jobID = jobsForClient.first?.id ?? "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func fetchClients() async throws -> [Client] {
        var out: [Client] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await NotionClient().request("data_sources/24b78c96-d34b-80e1-a289-000b4dc2d455/query", method: "POST", body: body)
            for page in json["results"] as? [[String: Any]] ?? [] {
                guard let id = page["id"] as? String,
                      let props = page["properties"] as? [String: Any],
                      let title = (props["Customer"] as? [String: Any])?["title"] as? [[String: Any]] else { continue }
                let name = title.compactMap { $0["plain_text"] as? String }.joined().trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { out.append(Client(id: id.replacingOccurrences(of: "-", with: ""), name: name)) }
            }
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return out
    }

    func save() async {
        saving = true
        defer { saving = false }
        func rich(_ s: String) -> [String: Any] { ["rich_text": s.isEmpty ? [] : [["text": ["content": String(s.prefix(1900))]]]] }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        var noteText = note
        if !fileName.isEmpty { noteText += (noteText.isEmpty ? "" : "\n") + "קובץ: \(fileName)" }
        let leftover = sharedText.replacingOccurrences(of: linkedIn.trimmingCharacters(in: CharacterSet(charactersIn: "/")), with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty { noteText += (noteText.isEmpty ? "" : "\n") + "מההודעה: \(leftover)" }

        var props: [String: Any] = [
            "Name": ["title": [["text": ["content": cleanName.isEmpty ? (Self.slug(linkedIn) ?? "מועמד") : cleanName]]]],
            "Job": ["relation": [["id": jobID]]],
            "Key": rich(Self.slug(linkedIn) ?? "wa-\(Int(Date().timeIntervalSince1970))"),
            "Mine": rich("whatsapp"),
            "Source": ["select": ["name": source.rawValue]],
            "Source detail": rich(sourceDetail),
            "Note": rich(noteText),
            "Why": rich(note),
        ]
        if !linkedIn.isEmpty { props["LinkedIn"] = ["url": linkedIn] }
        do {
            _ = try await NotionClient().request("pages", method: "POST", body: [
                "parent": ["type": "data_source_id", "data_source_id": AppIDsShare.candidates],
                "properties": props,
            ])
            memory.set(clientID, forKey: "share.client")
            memory.set(source.rawValue, forKey: "share.source")
            context?.completeRequest(returningItems: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(domain: "ShareToJobs", code: 0))
    }
}

enum AppIDsShare {
    static let candidates = "0adba494-d721-44c2-8fb8-9df400a6c1da"
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if !model.hasToken {
                    Section {
                        SecureField("ntn_…", text: $model.token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("שמירה") { Task { await model.saveToken() } }.disabled(model.token.isEmpty)
                    } header: { Text("מפתח Notion (פעם אחת)") }
                      footer: { Text("אותו מפתח שהדבקת באפליקציה משרות › הגדרות.") }
                }

                if let e = model.error {
                    Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }

                Section("מועמד") {
                    TextField("שם", text: $model.name)
                    TextField("קישור לינקדאין", text: $model.linkedIn)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !model.fileName.isEmpty {
                        Label(model.fileName, systemImage: "doc").foregroundStyle(.secondary)
                    }
                }

                Section("לאן") {
                    Picker("לקוח", selection: $model.clientID) {
                        Text("כל הלקוחות").tag("")
                        ForEach(model.clients) { Text($0.name).tag($0.id) }
                    }
                    Picker("משרה", selection: $model.jobID) {
                        if model.jobsForClient.isEmpty { Text("אין משרות פתוחות").tag("") }
                        ForEach(model.jobsForClient) { j in
                            Text(model.clientID.isEmpty ? "\(j.company) · \(j.role)" : j.role).tag(j.id)
                        }
                    }
                    if model.loading { ProgressView() }
                }

                Section("מקור") {
                    Picker("מאיפה הגיע", selection: $model.source) {
                        ForEach(CandidateSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField(model.source == .colleague ? "איזה קולגה?" : "פרטים (לא חובה)", text: $model.sourceDetail)
                }

                Section("הערה") {
                    TextField("למשל: חזקה ב-PMM, מחפשת משרת הקמה", text: $model.note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if !model.sharedText.isEmpty {
                    Section("מה ששותף") {
                        Text(model.sharedText).font(.footnote).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
            }
            .navigationTitle("הוספת מועמד")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("ביטול") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.saving ? "שומר…" : "הוספה") { Task { await model.save() } }
                        .disabled(!model.canSave)
                }
            }
        }
        .tint(Color(red: 0.42, green: 0.48, blue: 0.91))
    }
}
