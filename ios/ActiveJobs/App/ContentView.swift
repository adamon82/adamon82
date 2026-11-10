import SwiftUI

enum Grouping: String, CaseIterable, Identifiable {
    case company = "חברה", status = "סטטוס"
    var id: String { rawValue }
}

enum Filter: Hashable {
    case open
    case status(JobStatus)
}

struct ContentView: View {
    @Environment(JobStore.self) private var store
    @AppStorage("grouping") private var groupingRaw = Grouping.company.rawValue
    @State private var filter: Filter = .open
    @State private var search = ""
    @State private var showNew = false
    @State private var showSettings = false

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .company }

    private var visible: [Job] {
        store.jobs.filter { j in
            let passFilter: Bool
            switch filter {
            case .open: passFilter = j.status != .closed
            case .status(let s): passFilter = j.status == s
            }
            guard passFilter else { return false }
            guard !search.isEmpty else { return true }
            return [j.company, j.role, j.notes, j.location].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }.sortedForBoard()
    }

    struct Group: Identifiable { let id: String; let items: [Job] }

    private var groups: [Group] {
        switch grouping {
        case .status:
            return JobStatus.allCases.compactMap { s in
                let items = visible.filter { $0.status == s }
                return items.isEmpty ? nil : Group(id: s.label, items: items)
            }
        case .company:
            var order: [String] = []
            var map: [String: [Job]] = [:]
            for j in visible {
                let k = j.company.isEmpty ? "ללא חברה" : j.company
                if map[k] == nil { order.append(k) }
                map[k, default: []].append(j)
            }
            return order.map { Group(id: $0, items: map[$0] ?? []) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FilterPills(filter: $filter)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if let msg = store.errorMessage {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(JobStatus.verify.color)
                        if !store.hasToken {
                            Button("פתיחת ההגדרות") { showSettings = true }
                        }
                    }
                }

                if filter == .open, search.isEmpty, !store.attention.isEmpty {
                    Section("דורש טיפול") {
                        ForEach(store.attention.prefix(4)) { job in
                            NavigationLink(value: job.id) { JobRow(job: job, showCompany: true) }
                        }
                    }
                }

                ForEach(groups) { group in
                    let name = group.id
                    let items = group.items
                    Section {
                        ForEach(items) { job in
                            NavigationLink(value: job.id) { JobRow(job: job, showCompany: grouping == .status) }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if job.status != .active {
                                        Button { setStatus(job, .active) } label: { Label("פעילה", systemImage: JobStatus.active.symbol) }
                                            .tint(JobStatus.active.color)
                                    }
                                    Button { bump(job) } label: { Label("+ פנייה", systemImage: "person.badge.plus") }
                                        .tint(Theme.tint)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button { setStatus(job, .closed) } label: { Label("נסגרה", systemImage: JobStatus.closed.symbol) }
                                        .tint(JobStatus.closed.color)
                                    Button { setStatus(job, .hold) } label: { Label("בהמתנה", systemImage: JobStatus.hold.symbol) }
                                        .tint(JobStatus.hold.color)
                                }
                        }
                    } header: {
                        HStack {
                            Text(name)
                            Spacer()
                            let total = items.reduce(0) { $0 + $1.total }
                            Text("\(items.count) \(items.count == 1 ? "משרה" : "משרות")\(total > 0 ? " · \(total) מועמדים" : "")")
                                .monospacedDigit()
                        }
                    }
                }

                if visible.isEmpty && !store.isLoading {
                    ContentUnavailableView(store.jobs.isEmpty ? "הלוח ריק" : "אין כאן משרות",
                                           systemImage: "briefcase",
                                           description: Text(store.jobs.isEmpty ? "הכפתור + מוסיף משרה." : "נסה סינון אחר."))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("משרות פעילות")
            .navigationDestination(for: String.self) { id in JobDetailView(jobID: id) }
            .searchable(text: $search, prompt: "חיפוש")
            .refreshable { await store.load() }
            .safeAreaInset(edge: .top) {
                Text("\(store.openJobs.count) פתוחות · \(store.peopleInProcess) מועמדים בתהליך")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 2)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("הגדרות")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("תצוגה", selection: $groupingRaw) {
                        ForEach(Grouping.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Button { showNew = true } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Theme.tint, in: Circle())
                        .shadow(color: Theme.tint.opacity(0.35), radius: 12, y: 6)
                }
                .padding(22)
                .accessibilityLabel("משרה חדשה")
                .sensoryFeedback(.impact(weight: .light), trigger: showNew)
            }
            .sheet(isPresented: $showNew) { JobEditorView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { if !store.hasToken { showSettings = true } }
        }
    }

    private func setStatus(_ job: Job, _ s: JobStatus) { store.change(job.id) { $0.status = s } }
    private func bump(_ job: Job) { store.change(job.id) { $0.setCount(.outreach, $0.outreach + 1) } }
}

struct FilterPills: View {
    @Environment(JobStore.self) private var store
    @Binding var filter: Filter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("הפתוחות", count: store.openJobs.count, color: nil, value: .open)
                ForEach(JobStatus.allCases) { s in
                    pill(s.label, count: store.count(s), color: s.color, value: .status(s))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private func pill(_ title: String, count: Int, color: Color?, value: Filter) -> some View {
        let on = filter == value
        return Button {
            withAnimation(.snappy) { filter = value }
        } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(on ? .white : color).frame(width: 7, height: 7) }
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.7)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(on ? .white : .primary)
            .background(on ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(.background), in: Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: filter)
    }
}

struct JobRow: View {
    let job: Job
    var showCompany = false

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(job.status.color).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if job.hot { Circle().fill(Theme.hot).frame(width: 8, height: 8) }
                    Text(job.role).font(.body.weight(.semibold)).lineLimit(2)
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(job.isStale ? JobStatus.verify.color : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(job.status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .foregroundStyle(job.status.color)
                    .background(job.status.color.opacity(0.14), in: Capsule())
                PipelineBar(job: job)
            }
        }
        .padding(.vertical, 2)
        .opacity(job.status == .closed ? 0.6 : 1)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showCompany { parts.append(job.company) }
        if !job.location.isEmpty { parts.append(job.location) }
        parts.append(job.isStale ? "לא עודכן \(job.daysSinceUpdate ?? 0) ימים" : job.updatedText)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct PipelineBar: View {
    let job: Job
    var body: some View {
        HStack(spacing: 5) {
            Text(job.total > 0 ? "\(job.total)" : "—").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 2) {
                ForEach(Array(Stage.allCases.enumerated()), id: \.offset) { i, s in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(job.count(s) > 0 ? Theme.tint.opacity([0.45, 0.72, 1][i]) : Color(.systemFill))
                        .frame(width: 14, height: 5)
                }
            }
        }
    }
}
