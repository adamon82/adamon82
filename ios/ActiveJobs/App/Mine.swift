import SwiftUI

// MARK: - Model

enum Decision: String, CaseIterable, Identifiable {
    case fit = "מתאים", maybe = "אולי", no = "לא", connect = "חיבור"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .fit: "✓"; case .maybe: "?"; case .no: "✗"; case .connect: "🤝" }
    }
    var color: Color {
        switch self {
        case .fit: Color(red: 0.24, green: 0.66, blue: 0.47)
        case .maybe: Color(red: 0.62, green: 0.52, blue: 0.85)
        case .no: Color(red: 0.85, green: 0.42, blue: 0.37)
        case .connect: Theme.tint
        }
    }
}

struct Candidate: Identifiable, Hashable {
    var id: String
    var name: String
    var grade: String
    var decision: Decision?
    var contacted: Bool
    var title: String
    var company: String
    var years: Double?
    var why: String
    var career: [String]
    var linkedIn: String
}

enum AppIDs {
    static let candidatesDataSource = "0adba494-d721-44c2-8fb8-9df400a6c1da"
}

extension NotionClient {
    func fetchCandidates(jobID: String) async throws -> [Candidate] {
        var out: [Candidate] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "page_size": 100,
                "filter": ["property": "Job", "relation": ["contains": jobID]],
            ]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await request("data_sources/\(AppIDs.candidatesDataSource)/query", method: "POST", body: body)
            guard let results = json["results"] as? [[String: Any]] else { throw NotionError.badResponse }
            out += results.compactMap(Self.parseCandidate)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return out
    }

    func setDecision(_ candidateID: String, _ d: Decision?) async throws {
        let select: Any = d.map { ["name": $0.rawValue] as Any } ?? NSNull()
        let date: Any = d == nil ? NSNull() : ["start": ISO8601DateFormatter().string(from: Date())] as Any
        let props: [String: Any] = [
            "Decision": ["select": select],
            "Decided": ["date": date],
            "Decided by": ["rich_text": [["text": ["content": "אדם (אייפון)"]]]],
        ]
        _ = try await request("pages/\(candidateID)", method: "PATCH", body: ["properties": props])
    }

    static func parseCandidate(_ page: [String: Any]) -> Candidate? {
        guard let id = page["id"] as? String, let props = page["properties"] as? [String: Any] else { return nil }
        func p(_ k: String) -> [String: Any] { props[k] as? [String: Any] ?? [:] }
        func text(_ k: String) -> String {
            let arr = (p(k)["title"] ?? p(k)["rich_text"]) as? [[String: Any]] ?? []
            return arr.compactMap { $0["plain_text"] as? String }.joined()
        }
        let sel: (String) -> String? = { k in (p(k)["select"] as? [String: Any])?["name"] as? String }
        return Candidate(
            id: id,
            name: text("Name"),
            grade: sel("Grade") ?? "B",
            decision: sel("Decision").flatMap(Decision.init(rawValue:)),
            contacted: p("Contacted")["checkbox"] as? Bool ?? false,
            title: text("Title"),
            company: text("Company"),
            years: (p("Years")["number"] as? NSNumber)?.doubleValue,
            why: text("Why"),
            career: text("Career").split(separator: "\n").map(String.init),
            linkedIn: p("LinkedIn")["url"] as? String ?? ""
        )
    }
}

// MARK: - Store

@MainActor
@Observable
final class MineStore {
    let jobID: String
    var candidates: [Candidate] = []
    var loading = false
    var error: String?
    private var history: [(id: String, previous: Decision?)] = []

    init(jobID: String) { self.jobID = jobID }

    /// Grades shown in the swipe queue; empty = all.
    var grades: Set<String> = []
    var availableGrades: [String] { Array(Set(candidates.map(\.grade))).sorted() }
    func remaining(_ g: String) -> Int { candidates.filter { $0.grade == g && $0.decision == nil && !$0.contacted }.count }

    var queue: [Candidate] {
        candidates.filter { $0.decision == nil && !$0.contacted && (grades.isEmpty || grades.contains($0.grade)) }
            .sorted { ($0.grade, $0.name) < ($1.grade, $1.name) }
    }
    func list(_ d: Decision) -> [Candidate] { candidates.filter { $0.decision == d } }
    var canUndo: Bool { !history.isEmpty }

    func load() async {
        loading = true
        defer { loading = false }
        do { candidates = try await NotionClient().fetchCandidates(jobID: jobID); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func decide(_ c: Candidate, _ d: Decision?) {
        guard let i = candidates.firstIndex(where: { $0.id == c.id }) else { return }
        history.append((c.id, candidates[i].decision))
        candidates[i].decision = d
        save(c.id, d)
    }

    func undo() {
        guard let last = history.popLast(), let i = candidates.firstIndex(where: { $0.id == last.id }) else { return }
        candidates[i].decision = last.previous
        save(last.id, last.previous)
    }

    private func save(_ id: String, _ d: Decision?) {
        Task {
            do { try await NotionClient().setDecision(id, d) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Mine (swipe) view

struct MineView: View {
    @State private var store: MineStore
    @State private var drag: CGSize = .zero
    @State private var showList: Decision?
    @Environment(\.openURL) private var openURL

    init(jobID: String) { _store = State(initialValue: MineStore(jobID: jobID)) }

    var body: some View {
        VStack(spacing: 14) {
            counters
            gradeFilter
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(JobStatus.verify.color)
            }
            ZStack {
                if store.loading && store.candidates.isEmpty {
                    ProgressView()
                } else if store.candidates.isEmpty {
                    ContentUnavailableView("אין עדיין מכרה למשרה הזו", systemImage: "person.3",
                                           description: Text("כשתבקש מ-Claude לבנות מכרה, המועמדים יופיעו כאן."))
                } else if store.queue.isEmpty {
                    ContentUnavailableView("עברת על כולם", systemImage: "checkmark.seal",
                                           description: Text("הרשימות למטה מחכות לך."))
                } else {
                    ForEach(Array(store.queue.prefix(2).enumerated().reversed()), id: \.element.id) { i, c in
                        CandidateCard(c: c)
                            .scaleEffect(i == 0 ? 1 : 0.95)
                            .offset(y: i == 0 ? 0 : 10)
                            .opacity(i == 0 ? 1 : 0.6)
                            .offset(i == 0 ? drag : .zero)
                            .rotationEffect(.degrees(i == 0 ? Double(drag.width / 22) : 0))
                            .overlay(alignment: .top) { if i == 0 { stamp } }
                            .gesture(swipe(c), including: i == 0 ? .all : .none)
                            .allowsHitTesting(i == 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 440)
            // Swipe uses physical directions: finger right = card right = ✓. RTL would mirror the offset.
            .environment(\.layoutDirection, .leftToRight)

            actions
        }
        .padding(.horizontal, 16)
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(item: $showList) { d in DecisionList(store: store, decision: d) }
    }

    private var gradeFilter: some View {
        HStack(spacing: 8) {
            gradeChip("הכל", on: store.grades.isEmpty) { store.grades = [] }
            ForEach(store.availableGrades, id: \.self) { g in
                gradeChip("\(g) · \(store.remaining(g))", on: store.grades.contains(g)) {
                    if store.grades.contains(g) { store.grades.remove(g) } else { store.grades.insert(g) }
                    UserDefaults.standard.set(Array(store.grades), forKey: "mineGrades.\(store.jobID)")
                }
            }
            Spacer()
        }
        .onAppear {
            store.grades = Set(UserDefaults.standard.stringArray(forKey: "mineGrades.\(store.jobID)") ?? [])
        }
    }

    private func gradeChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? .white : .primary)
                .background(on ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }

    private var counters: some View {
        HStack(spacing: 8) {
            Text("נשארו \(store.queue.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
            Spacer()
            ForEach([Decision.fit, .connect, .maybe, .no]) { d in
                Button { showList = d } label: {
                    Text("\(d.symbol) \(store.list(d).count)")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(d.color)
                        .background(d.color.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var stamp: some View {
        let d = decisionFor(drag)
        if let d {
            Text(d.rawValue)
                .font(.title2.weight(.heavy))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(d.color, lineWidth: 3))
                .foregroundStyle(d.color)
                .padding(.top, 22)
                .opacity(min(1, max(abs(drag.width), abs(drag.height)) / 90))
        }
    }

    private func decisionFor(_ t: CGSize) -> Decision? {
        // RTL app, but swipe keeps the familiar physical meaning: right = yes, left = no, up = maybe.
        if t.height < -90 && abs(t.height) > abs(t.width) { return .maybe }
        if t.width > 90 { return .fit }
        if t.width < -90 { return .no }
        return nil
    }

    private func swipe(_ c: Candidate) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { v in
                if let d = decisionFor(v.translation) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        drag = CGSize(width: v.translation.width * 3, height: v.translation.height * 3)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        store.decide(c, d)
                        drag = .zero
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero }
                }
            }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            actionButton(.no)
            actionButton(.maybe)
            actionButton(.fit)
            actionButton(.connect)
            Button { store.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(width: 48, height: 52)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(!store.canUndo)
            .accessibilityLabel("ביטול הסימון האחרון")
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: store.queue.count)
    }

    private func actionButton(_ d: Decision) -> some View {
        Button {
            if let c = store.queue.first { withAnimation(.snappy) { store.decide(c, d) } }
        } label: {
            Text("\(d.symbol) \(d.rawValue)")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(d.color)
                .background(d.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(store.queue.isEmpty)
    }
}

struct CandidateCard: View {
    let c: Candidate
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    Circle().fill(Color(.tertiarySystemFill)).frame(width: 58, height: 58)
                        .overlay(Text(initials).font(.title3.weight(.bold)).foregroundStyle(.secondary))
                    Text(c.grade)
                        .font(.caption.weight(.heavy)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(gradeColor, in: Circle())
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.title3.weight(.bold))
                    Text([c.title, c.company].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if let y = c.years { Text("\(y, specifier: "%.0f") שנות ניסיון").font(.caption).foregroundStyle(.secondary) }
                }
            }

            if !c.why.isEmpty {
                Text(c.why)
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            }

            if !c.career.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(c.career, id: \.self) { line in
                        Text(line).font(.footnote).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
            }

            Spacer(minLength: 0)

            if let url = URL(string: c.linkedIn), !c.linkedIn.isEmpty {
                Button { openURL(url) } label: { Label("פרופיל בלינקדאין", systemImage: "arrow.up.forward.square") }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(18)
        .environment(\.layoutDirection, .rightToLeft)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
    }

    private var initials: String {
        c.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
    private var gradeColor: Color {
        switch c.grade { case "A": Decision.fit.color; case "B": JobStatus.verify.color; default: JobStatus.closed.color }
    }
}

struct DecisionList: View {
    @Bindable var store: MineStore
    let decision: Decision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.list(decision)) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.name).font(.body.weight(.semibold))
                            Spacer()
                            Text(c.grade).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        }
                        Text([c.title, c.company].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if let u = URL(string: c.linkedIn) { openURL(u) } }
                    .swipeActions {
                        Button("החזרה לתור") { store.decide(c, nil) }.tint(.gray)
                    }
                }
            }
            .navigationTitle("\(decision.symbol) \(decision.rawValue) · \(store.list(decision).count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("סיום") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = store.list(decision)
                            .map { "\($0.name) · \($0.linkedIn)" }.joined(separator: "\n")
                    } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("העתקת הרשימה")
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

