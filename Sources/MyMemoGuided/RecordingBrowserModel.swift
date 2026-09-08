import Foundation
import Combine
import MyMemoCore
import MyMemoExperience

@MainActor
final class RecordingBrowserModel: ObservableObject {
    @Published var query = "" { didSet { if RecordingQuery.terms(query).isEmpty { indexTask?.cancel() }; scheduleSearch() } }
    @Published var filter = "all" { didSet { scheduleSearch(debounce: false) } }
    @Published var includeBody = true { didSet { if !includeBody { indexTask?.cancel() }; scheduleSearch(debounce: false) } }
    @Published private(set) var sort: RecordingSort = .importedAt
    @Published private(set) var ascending = false
    @Published private(set) var visible: [RecordingJob] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isIndexing = false
    @Published private(set) var indexed = 0
    @Published private(set) var indexTotal = 0
    @Published private(set) var unavailable = 0
    @Published private(set) var indexError: String?
    private var jobs: [RecordingJob] = []
    private let indexURL: URL
    private let preferencesURL: URL
    private struct Preferences: Codable { var sort: String; var ascending: Bool }
    private var index: TranscriptSearchIndex?
    private var openTask: Task<TranscriptSearchIndex, Error>?
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var searchToken = UUID()
    private var revision = 0
    private var needsIndex = true
    private var forceRequested = false
    private var active = true
    private var lastValidation = Date.distantPast

    init(indexURL: URL) {
        self.indexURL = indexURL
        preferencesURL = indexURL.deletingLastPathComponent().appendingPathComponent("browser.json")
        if let data = try? Data(contentsOf: preferencesURL), let stored = try? JSONDecoder().decode(Preferences.self, from: data) {
            sort = RecordingSort(rawValue: stored.sort) ?? .importedAt; ascending = stored.ascending
        } else { ascending = sort.defaultAscending }
    }
    func setJobs(_ values: [RecordingJob]) {
        active = true
        if jobs != values { jobs = values; revision += 1; needsIndex = true }
        scheduleSearch(debounce: false)
    }
    func setSort(_ value: RecordingSort, ascending: Bool) {
        sort = value; self.ascending = ascending
        if let data = try? JSONEncoder().encode(Preferences(sort: value.rawValue, ascending: ascending)) {
            try? data.write(to: preferencesURL, options: .atomic)
        }
        scheduleSearch(debounce: false)
    }
    func rebuildIndex() {
        needsIndex = true; forceRequested = true
        requestIndex(force: true)
    }
    func stop() {
        active = false; isSearching = false
        searchTask?.cancel(); indexTask?.cancel(); searchToken = UUID()
    }
    private func getIndex() async throws -> TranscriptSearchIndex {
        if let index { return index }
        if let openTask { return try await openTask.value }
        let url = indexURL
        let task = Task.detached(priority: .utility) { try TranscriptSearchIndex(url: url) }
        openTask = task
        do { let loaded = try await task.value; index = loaded; openTask = nil; return loaded }
        catch { openTask = nil; throw error }
    }
    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel(); searchToken = UUID()
        let token = searchToken, text = query, source = jobs, status = filter, ordering = sort, forward = ascending, body = includeBody
        isSearching = true
        searchTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let self else { return }
            if Date().timeIntervalSince(self.lastValidation) > 30 { self.needsIndex = true }
            var matches: Set<UUID> = []
            if body && !RecordingQuery.terms(text).isEmpty {
                do { matches = try await self.getIndex().search(text); self.indexError = nil }
                catch { self.indexError = error.localizedDescription }
            }
            let ids = matches
            let results = await Task.detached(priority: .userInitiated) {
                RecordingQuery.apply(source, query: text, contentMatches: ids, status: status, sort: ordering, ascending: forward)
            }.value
            guard !Task.isCancelled, self.searchToken == token else { return }
            self.visible = results; self.isSearching = false
            if body && !RecordingQuery.terms(text).isEmpty { self.requestIndex() }
        }
    }
    private func requestIndex(force: Bool = false) {
        guard indexTask == nil, needsIndex, includeBody, force || !RecordingQuery.terms(query).isEmpty else { return }
        let currentRevision = revision
        let candidates = jobs.filter { $0.transcriptPath != nil && $0.status != .excluded }
        let shouldForce = forceRequested; forceRequested = false
        isIndexing = true; indexed = 0; indexTotal = candidates.count; unavailable = 0
        indexTask = Task { [weak self] in
            guard let self else { return }
            do {
                let index = try await self.getIndex()
                try await index.prune(keeping: Set(candidates.map(\.id)))
                for (position, job) in candidates.enumerated() {
                    try Task.checkCancellation()
                    do { try await index.update(job, force: shouldForce) }
                    catch is CancellationError { throw CancellationError() }
                    catch { self.unavailable += 1 }
                    self.indexed = position + 1
                    if position % 12 == 11 { self.scheduleSearch(debounce: false) }
                }
                if self.revision == currentRevision && !self.forceRequested { self.needsIndex = false; self.lastValidation = Date() }
                self.indexError = nil
            } catch is CancellationError { }
            catch { self.indexError = error.localizedDescription; self.needsIndex = false; self.lastValidation = Date() }
            self.isIndexing = false; self.indexTask = nil
            if self.active {
                self.scheduleSearch(debounce: false)
                if self.forceRequested { self.requestIndex(force: true) }
            }
        }
    }
}
