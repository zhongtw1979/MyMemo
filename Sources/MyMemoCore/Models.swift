import Foundation

public enum JobStatus: String, Codable, Sendable {
    case queued, transcribing, done, failed, excluded
    public var title: String {
        switch self {
        case .queued: "等待转写"
        case .transcribing: "正在转写"
        case .done: "已完成"
        case .failed: "需要处理"
        case .excluded: "已跳过"
        }
    }
}

public struct RecordingJob: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var contentHash: String
    public var originalName: String
    public var deviceName: String
    public var sourcePath: String
    public var localPath: String
    public var byteCount: Int64
    public var importedAt: Date = Date()
    public var status: JobStatus = .queued
    public var attempts: Int = 0
    public var lastError: String?
    public var transcriptPath: String?
    public var provider: String?
    public var requestProvider: TranscriptionProvider?
}

public struct LibraryEvent: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var message: String
    public var isError: Bool = false
    public init(_ message: String, isError: Bool = false) { self.message = message; self.isError = isError }
}

public struct LibrarySnapshot: Codable, Sendable {
    public var version: Int = 1
    public var jobs: [RecordingJob] = []
    public var events: [LibraryEvent] = []
    public var scanCache: [String: ScanCacheEntry]?
    public init() {}
}

public struct ImportResult: Sendable {
    public var imported = 0
    public var skipped = 0
    public var failed = 0
    public var filtered = 0
    public var interrupted = false
    public var fastSkipped = 0
    public var mediaInspections = 0
    public var fullHashReads = 0
    public var fingerprintBytesRead: Int64 = 0
    public var elapsedSeconds: Double = 0
    public init() {}
    public var summary: String { "本次保存 \(imported) 个，已有录音 \(skipped) 个，过滤视频/非音频 \(filtered) 个，失败 \(failed) 个" + (fastSkipped > 0 ? "；快速跳过未变化文件 \(fastSkipped) 个" : "") }
}
