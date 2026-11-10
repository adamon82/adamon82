import SwiftUI

struct SettingsView: View {
    @Environment(JobStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var token = AppConfig.token
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("ntn_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        AppConfig.token = token
                        testing = true
                        Task {
                            await store.load()
                            result = store.errorMessage ?? "מחובר. נטענו \(store.jobs.count) משרות."
                            testing = false
                        }
                    } label: {
                        HStack { Text("שמירה ובדיקה"); if testing { Spacer(); ProgressView() } }
                    }
                    .disabled(token.isEmpty || testing)
                    if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("מפתח Notion")
                } footer: {
                    Text("המפתח נשמר רק באייפון הזה.")
                }

                Section("איך משיגים מפתח (פעם אחת)") {
                    Text("1. פותחים notion.so/profile/integrations ויוצרים Internal integration בשם \"משרות\".")
                    Text("2. מעתיקים את ה-Internal Integration Secret ומדביקים למעלה.")
                    Text("3. ב-Notion, בשלוש הטבלאות \"משרות פעילות\", \"מועמדים\" ו-\"Customers \Text("3. ב-Notion, בטבלת \"משרות פעילות\": ⋯ › Connections › מוסיפים את \"משרות\".") Pitche\": ⋯ › Connections › מוסיפים את \"משרות\".")
                    Button("פתיחת דף ה-integrations") { openURL(URL(string: "https://www.notion.so/profile/integrations")!) }
                    Button("פתיחת טבלת המשרות") { openURL(AppConfig.databaseURL) }
                }
                .font(.subheadline)

                if let last = store.lastSync {
                    Section { LabeledContent("סנכרון אחרון", value: last.formatted(date: .omitted, time: .shortened)) }
                }
            }
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("סיום") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
