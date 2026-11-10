import SwiftUI

@main
struct ActiveJobsApp: App {
    @State private var store = JobStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
                .tint(Theme.tint)
                .task { await store.load() }
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await store.load() } }
                }
        }
    }
}

enum Theme {
    static let tint = Color(red: 0.42, green: 0.48, blue: 0.91)
    static let hot = Color(red: 0.87, green: 0.42, blue: 0.37)
}
