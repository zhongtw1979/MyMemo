import Foundation
import MyMemoCore

public enum SetupStep: Int, CaseIterable, Sendable {
    case source, destination, ready
    public var title: String {
        switch self { case .source: "连接设备"; case .destination: "保存位置"; case .ready: "确认并开始" }
    }
}
public enum RecordingSource: String, Codable, Sendable { case device, folder, later }

public struct SetupDraft: Sendable {
    public var source: RecordingSource = .device
    public var deviceName = ""
    public var devicePath = ""
    public var sourceFolder = ""
    public var destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MyMemo 录音").path
    public var transcribe = true
    public init() {}

    public func canAdvance(from step: SetupStep) -> Bool {
        switch step {
        case .source:
            switch source {
            case .device: return !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .folder: return sourceFolder.hasPrefix("/") && sourceFolder != "/"
            case .later: return true
            }
        case .destination:
            guard destination.hasPrefix("/"), destination != "/" else { return false }
            let origin = source == .device ? devicePath : (source == .folder ? sourceFolder : "")
            guard !origin.isEmpty else { return true }
            let root = URL(fileURLWithPath: origin).resolvingSymlinksInPath().standardizedFileURL.path
            let target = URL(fileURLWithPath: destination).resolvingSymlinksInPath().standardizedFileURL.path
            return target != root && !target.hasPrefix(root + "/")
        case .ready: return canAdvance(from: .source) && canAdvance(from: .destination)
        }
    }

    public func configuration(modelReady: Bool) throws -> AppConfiguration {
        guard canAdvance(from: .source) else { throw MemoError("请选择录音设备、录音文件夹，或选择稍后连接。") }
        guard canAdvance(from: .destination) else { throw MemoError("请选择电脑上的保存文件夹，不能保存在录音设备或源文件夹内部。") }
        guard !transcribe || modelReady else { throw MemoError("请先准备中文识别，或选择仅保存录音。") }
        var config = AppConfiguration()
        config.destinationPath = destination
        config.devices = source == .device ? [DeviceRule(name: deviceName)] : []
        config.automaticImport = source != .folder
        config.automaticTranscription = transcribe
        return config
    }
}
