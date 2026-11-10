import SwiftUI

/// Every change saves itself to Notion (debounced), like the iOS Settings app.
struct JobDetailView: View {
    @Environment(JobStore.self) private var store
    @Environment(\.openURL) private var openURL
    let jobID: String
    @State private var tab: Tab = .details

    enum Tab: String, CaseIterable, Identifiable {
        case details = "📋 משרה", company = "🏢 חברה", mine = "🔥 מכרה"
        var id: String { rawValue }
    }

    private var job: Job? { store.jobs.first { $0.id == jobID } }

    private func binding<T>(_ kp: WritableKeyPath<Job, T>) -> Binding<T> {
        Binding(
            get: { job?[keyPath: kp] ?? Job.blank()[keyPath: kp] },
            set: { v in store.change(jobID) { $0[keyPath: kp] = v } }
        )
    }

    var body: some View {
        if let job {
            VStack(spacing: 0) {
                Picker("תצוגה", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                switch tab {
                case .details: detailsForm(job)
                case .company: CompanyView(job: job)
                case .mine: MineView(jobID: job.id).frame(maxHeight: .infinity, alignment: .top).padding(.top, 6)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(job.role)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("המשרה לא נמצאה", systemImage: "questionmark.folder")
        }
    }

    @ViewBuilder
    private func detailsForm(_ job: Job) -> some View {
        Form {
            Section {
                Picker("סטטוס", selection: binding(\.status)) {
                    ForEach(JobStatus.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section("מועמדים בתהליך") {
                ForEach(Stage.allCases) { s in
                    Stepper(value: Binding(
                        get: { job.count(s) },
                        set: { v in store.change(jobID) { $0.setCount(s, v) } }
                    ), in: 0...99) {
                        HStack {
                            Text(s.rawValue)
                            Spacer()
                            Text("\(job.count(s))").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .sensoryFeedback(.increase, trigger: job.count(s))
                }
            }

            Section {
                Toggle("עדיפות גבוהה", isOn: binding(\.hot)).tint(Theme.hot)
                LabeledContent("חברה") { TextField("חברה", text: binding(\.company)).multilineTextAlignment(.trailing) }
                LabeledContent("מיקום") { TextField("מיקום", text: binding(\.location)).multilineTextAlignment(.trailing) }
            }

            Section("הערות") {
                TextField("מי בתהליך, מה חסר, הצעד הבא", text: binding(\.notes), axis: .vertical)
                    .lineLimit(3...10)
            }

            Section {
                if let url = URL(string: job.link), !job.link.isEmpty {
                    Button { openURL(url) } label: { Label("פתיחת הקישור", systemImage: "arrow.up.forward.square") }
                }
                if let url = URL(string: "https://www.notion.so/\(job.id.replacingOccurrences(of: "-", with: ""))") {
                    Button { openURL(url) } label: { Label("פתיחה ב-Notion", systemImage: "doc.text") }
                }
            } footer: {
                if !job.updatedBy.isEmpty || job.updated != nil {
                    Text("עודכן \(job.updatedText)\(job.updatedBy.isEmpty ? "" : " · \(job.updatedBy)")")
                }
            }
        }
    }
}
