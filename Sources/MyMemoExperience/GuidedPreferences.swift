import Foundation
import MyMemoCore

public struct GuidedPreferences: Codable, Sendable {
    public var completed = false
    public var paused = false
    public var source: RecordingSource = .device
    public var sourceFolder: String?
    public init() {}
    public static func load(from file: URL) throws -> GuidedPreferences {
        guard FileManager.default.fileExists(atPath: file.path) else { return GuidedPreferences() }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) }
        catch { throw MemoError("无法读取引导版设置。原文件已保留，请检查 \(file.path)。") }
    }
    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
