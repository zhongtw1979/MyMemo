import Foundation

public struct MemoError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PersistenceFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct DeviceRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var volumeUUID: String?
    public var enabled: Bool = true
    public init(name: String, volumeUUID: String? = nil) {
        self.name = name; self.volumeUUID = volumeUUID
    }
}

public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable {
    case apple, volcengine
    public var title: String { self == .apple ? "Apple 本机转写" : "火山引擎 Seed ASR" }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var devices: [DeviceRule] = []
    public var destinationPath: String = ""
    public var automaticImport: Bool = true
    public var automaticTranscription: Bool = true
    public var provider: TranscriptionProvider = .apple
    public var localeIdentifier: String = "zh-CN"
    public var cloudConsent: Bool = false
    public var pythonPath: String = "/opt/homebrew/bin/python3"
    public var volcScriptPath: String = ""
    public init() {}

    public func matches(name: String, uuid: String?) -> Bool {
        devices.contains {
            $0.enabled && $0.name.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping
            && ($0.volumeUUID?.isEmpty != false || $0.volumeUUID == uuid)
        }
    }

    public func validate() throws {
        guard version == 1 else { throw MemoError("配置版本不兼容，请使用新版 MyMemo。") }
        guard destinationPath.isEmpty || destinationPath.hasPrefix("/") else {
            throw MemoError("保存目录必须是完整路径，请使用目录选择按钮。")
        }
        guard devices.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MemoError("设备名称不能为空。")
        }
        guard Set(devices.map(\.id)).count == devices.count else { throw MemoError("配置中存在重复的设备编号。") }
    }

    public static func load(from url: URL) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        do {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try value.validate()
            return value
        } catch { throw MemoError("无法读取配置，已保留原文件：\(url.path)\n\(error.localizedDescription)") }
    }
    public func save(to url: URL) throws { try validate(); try Persistence.write(self, to: url) }
}

enum Persistence {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
