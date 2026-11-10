import WidgetKit
import SwiftUI

struct JobsEntry: TimelineEntry {
    let date: Date
    let jobs: [Job]
    var open: [Job] { jobs.filter { $0.status != .closed } }
    var active: Int { jobs.filter { $0.status == .active }.count }
    var attention: [Job] { jobs.filter(\.needsAttention).sortedForBoard() }
    var people: Int { open.reduce(0) { $0 + $1.total } }
}

struct JobsProvider: TimelineProvider {
    func placeholder(in context: Context) -> JobsEntry { JobsEntry(date: .now, jobs: []) }

    func getSnapshot(in context: Context, completion: @escaping (JobsEntry) -> Void) {
        completion(JobsEntry(date: .now, jobs: AppConfig.cachedJobs))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JobsEntry>) -> Void) {
        Task {
            var jobs = AppConfig.cachedJobs
            if let fresh = try? await NotionClient().fetchJobs() {
                jobs = fresh
                AppConfig.cachedJobs = fresh
            }
            let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
            completion(Timeline(entries: [JobsEntry(date: .now, jobs: jobs)], policy: .after(next)))
        }
    }
}

struct JobsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JobsEntry
    private let tint = Color(red: 0.42, green: 0.48, blue: 0.91)

    var body: some View {
        switch family {
        case .systemSmall: small
        default: medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("משרות", systemImage: "briefcase.fill").font(.caption.weight(.semibold)).foregroundStyle(tint)
            Spacer(minLength: 0)
            Text("\(entry.active)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            Text("פעילות").font(.subheadline).foregroundStyle(.secondary)
            if !entry.attention.isEmpty {
                Text("\(entry.attention.count) דורשות טיפול")
                    .font(.caption.weight(.semibold)).foregroundStyle(JobStatus.verify.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.active)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text("פעילות").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(entry.people) מועמדים").font(.caption.weight(.medium)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.attention.isEmpty ? "הכי עדכניות" : "דורש טיפול")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach((entry.attention.isEmpty ? entry.open.sortedForBoard() : entry.attention).prefix(3)) { j in
                    HStack(spacing: 7) {
                        Capsule().fill(j.status.color).frame(width: 3, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(j.role).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(j.company).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct JobsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JobsWidget", provider: JobsProvider()) { entry in
            JobsWidgetView(entry: entry)
                .environment(\.layoutDirection, .rightToLeft)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("משרות פעילות")
        .description("כמה משרות פעילות ומה דורש טיפול.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
