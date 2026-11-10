import SwiftUI

struct JobEditorView: View {
    @Environment(JobStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var job = Job.blank()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("חברה", text: $job.company)
                    TextField("תפקיד", text: $job.role)
                    TextField("מיקום", text: $job.location)
                }
                Section {
                    Picker("סטטוס", selection: $job.status) {
                        ForEach(JobStatus.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section("מועמדים בתהליך") {
                    ForEach(Stage.allCases) { s in
                        Stepper("\(s.rawValue): \(job.count(s))",
                                value: Binding(get: { job.count(s) }, set: { job.setCount(s, $0) }), in: 0...99)
                    }
                }
                Section {
                    Toggle("עדיפות גבוהה", isOn: $job.hot).tint(Theme.hot)
                    TextField("קישור", text: $job.link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("הערות") {
                    TextField("מי בתהליך, מה חסר, הצעד הבא", text: $job.notes, axis: .vertical).lineLimit(3...10)
                }
            }
            .navigationTitle("משרה חדשה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("ביטול") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמירה") {
                        saving = true
                        Task {
                            if await store.create(job) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || job.company.trimmingCharacters(in: .whitespaces).isEmpty || job.role.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
