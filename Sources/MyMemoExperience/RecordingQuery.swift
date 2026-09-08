import Foundation
import MyMemoCore

public enum RecordingSort: String, CaseIterable, Sendable {
    case importedAt, name, size, device, status
    public var title: String {
        switch self { case .importedAt: "导入时间"; case .name: "文件名称"; case .size: "文件大小"; case .device: "录音设备"; case .status: "处理状态" }
    }
    public var defaultAscending: Bool { self == .name || self == .device || self == .status }
    public func directionTitle(ascending: Bool) -> String {
        switch self {
        case .importedAt: ascending ? "由旧到新" : "由新到旧"
        case .size: ascending ? "由小到大" : "由大到小"
        default: ascending ? "升序" : "降序"
        }
    }
}

public enum RecordingQuery {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans_CN")).lowercased()
    }
    public static func terms(_ query: String) -> [String] { normalize(query).split(whereSeparator: \.isWhitespace).map(String.init) }
    public static func apply(_ jobs: [RecordingJob], query: String = "", contentMatches: Set<UUID> = [],
                             status: String = "all", sort: RecordingSort = .importedAt, ascending: Bool = false) -> [RecordingJob] {
        let words = terms(query)
        let filtered = jobs.filter { job in
            guard (status == "all" && job.status != .excluded) || job.status.rawValue == status else { return false }
            if words.isEmpty || contentMatches.contains(job.id) { return true }
            let metadata = normalize(job.originalName + " " + job.deviceName)
            return words.allSatisfy { metadata.contains($0) }
        }
        let ranks: [JobStatus: Int] = [.queued: 0, .transcribing: 1, .failed: 2, .done: 3, .excluded: 4]
        return filtered.sorted { a, b in
            let result: ComparisonResult
            switch sort {
            case .name: result = a.originalName.localizedStandardCompare(b.originalName)
            case .device: result = a.deviceName.localizedStandardCompare(b.deviceName)
            case .importedAt: result = a.importedAt.compare(b.importedAt)
            case .size: result = a.byteCount == b.byteCount ? .orderedSame : a.byteCount < b.byteCount ? .orderedAscending : .orderedDescending
            case .status:
                let first = ranks[a.status] ?? 0, second = ranks[b.status] ?? 0
                result = first == second ? .orderedSame : first < second ? .orderedAscending : .orderedDescending
            }
            if result == .orderedSame { return a.id.uuidString < b.id.uuidString }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
