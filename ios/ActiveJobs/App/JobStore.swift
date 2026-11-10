import SwiftUI
import WidgetKit

@MainActor
@Observable
final class JobStore {
    var jobs: [Job] = AppConfig.cachedJobs
    var isLoading = false
    var errorMessage: String?
    var lastSync: Date?

    private var saveTasks: [String: Task<Void, Never>] = [:]

    var hasToken: Bool { !AppConfig.token.isEmpty }

    func load() async {
        guard hasToken else { errorMessage = NotionError.missingToken.errorDescription; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await NotionClient().fetchJobs()
            // Keep local edits that are still waiting to be saved.
            let pendingIDs = Set(saveTasks.keys)
            jobs = fresh.map { f in pendingIDs.contains(f.id) ? (jobs.first { $0.id == f.id } ?? f) : f }
            errorMessage = nil
            lastSync = Date()
            AppConfig.cachedJobs = jobs
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Optimistic local change, then a debounced save to Notion.
    func change(_ id: String, _ edit: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[i])
        jobs[i].updated = Date()
        jobs[i].updatedBy = "אדם (אייפון)"
        let job = jobs[i]
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do {
                try await NotionClient().update(job)
                AppConfig.cachedJobs = self?.jobs ?? []
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.saveTasks[id] = nil
        }
    }

    func create(_ job: Job) async -> Bool {
        do {
            var j = job
            j.id = try await NotionClient().create(job)
            j.updated = Date()
            jobs.append(j)
            AppConfig.cachedJobs = jobs
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Derived

    var openJobs: [Job] { jobs.filter { $0.status != .closed } }
    var attention: [Job] { jobs.filter(\.needsAttention).sortedForBoard() }
    func count(_ s: JobStatus) -> Int { jobs.filter { $0.status == s }.count }
    var peopleInProcess: Int { openJobs.reduce(0) { $0 + $1.total } }
}
