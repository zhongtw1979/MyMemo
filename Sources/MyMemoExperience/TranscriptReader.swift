import Foundation
import MyMemoCore

public struct TranscriptDocument: Sendable {
    public let id = UUID()
    public let text: String
    public let path: String
    public let truncated: Bool
    public let characterCount: Int
}

struct TranscriptFile: Sendable {
    var path: String
    var size: Int64
    var modified: Double

    static func resolve(_ path: String) throws -> TranscriptFile {
        let original = URL(fileURLWithPath: path)
        let plain = original.deletingPathExtension().appendingPathExtension("txt")
        for url in [plain, original] {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let size = (values[.size] as? NSNumber)?.int64Value,
                  let date = values[.modificationDate] as? Date else { continue }
            return TranscriptFile(path: url.path, size: size, modified: date.timeIntervalSinceReferenceDate)
        }
        throw MemoError("文字稿文件无法读取。请检查文件是否被移动，或打开保存文件夹查找。")
    }
    func read(limit: Int, requireComplete: Bool = false) throws -> TranscriptDocument {
        if requireComplete && size > limit { throw MemoError("文字稿过大，暂未建立正文搜索索引。") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var bytes = Data()
        while bytes.count < limit {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1024, limit - bytes.count)) ?? Data()
            if chunk.isEmpty { break }; bytes.append(chunk)
        }
        let truncated = size > Int64(bytes.count)
        var text = String(data: bytes, encoding: .utf8)
        if text == nil && truncated {
            for _ in 0..<3 where !bytes.isEmpty {
                bytes.removeLast(); text = String(data: bytes, encoding: .utf8)
                if text != nil { break }
            }
        }
        guard let text else { throw MemoError("文字稿不是可读取的 UTF-8 文本。请打开原文件检查格式。") }
        return TranscriptDocument(text: text, path: path, truncated: truncated, characterCount: text.count)
    }
}

public actor TranscriptReader {
    private struct Flight { var token: UUID; var task: Task<TranscriptDocument, Error> }
    private var cache: [String: TranscriptDocument] = [:]
    private var order: [String] = []
    private var flights: [String: Flight] = [:]
    private let previewLimit: Int
    private let cacheLimit: Int
    public private(set) var diskReadCount = 0

    public init(previewLimit: Int = 2 * 1024 * 1024, cacheLimit: Int = 16 * 1024 * 1024) {
        self.previewLimit = previewLimit; self.cacheLimit = cacheLimit
    }
    public func load(transcriptPath: String, force: Bool = false) async throws -> TranscriptDocument {
        if !force, let doc = cache[transcriptPath] {
            order.removeAll { $0 == transcriptPath }; order.append(transcriptPath)
            return doc
        }
        if !force, let flight = flights[transcriptPath] { return try await flight.task.value }
        let token = UUID(), limit = previewLimit
        let task = Task.detached(priority: .userInitiated) {
            try TranscriptFile.resolve(transcriptPath).read(limit: limit)
        }
        diskReadCount += 1
        flights[transcriptPath] = Flight(token: token, task: task)
        do {
            let document = try await task.value
            if flights[transcriptPath]?.token == token {
                flights.removeValue(forKey: transcriptPath)
                cache[transcriptPath] = document
                order.removeAll { $0 == transcriptPath }; order.append(transcriptPath)
                while order.count > 12 || cache.values.reduce(0, { $0 + $1.text.utf8.count }) > cacheLimit {
                    guard let oldest = order.first else { break }
                    order.removeFirst(); cache.removeValue(forKey: oldest)
                }
            }
            return document
        } catch {
            if flights[transcriptPath]?.token == token { flights.removeValue(forKey: transcriptPath) }
            throw error
        }
    }
}
