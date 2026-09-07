import Foundation
import Speech
import AVFAudio

public enum SpeechService {
    public static func status(localeID: String) async -> String {
        guard SpeechTranscriber.isAvailable else { return "当前设备不支持 Apple 本机转写。" }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            return "当前系统尚不支持所选转写语言。"
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return "本机语言模型已就绪"
        case .downloading: return "语言模型正在下载"
        case .supported: return "需要下载本机语言模型"
        case .unsupported: return "当前设备不支持所选语言模型"
        @unknown default: return "无法确认语言模型状态"
        }
    }

    public static func installModel(localeID: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw MemoError("当前系统尚不支持所选转写语言。")
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    public static func transcribe(file: URL, configuration: AppConfiguration) async throws -> String {
        if configuration.provider == .volcengine && !configuration.cloudConsent {
            throw MemoError("尚未启用云端转写，请在设置中确认。")
        }
        let media = await MediaInspector.inspect(file)
        guard media == .audio else { throw MemoError(media.reason) }
        switch configuration.provider {
        case .apple: return try await apple(file: file, localeID: configuration.localeIdentifier)
        case .volcengine:
            guard configuration.cloudConsent else { throw MemoError("尚未启用云端转写，请在设置中确认。") }
            return try await volcengine(file: file, configuration: configuration)
        }
    }

    private static func apple(file: URL, localeID: String) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw MemoError("此设备或语言暂不支持 Apple 本机转写，请更换转写方式。")
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw MemoError("本机语言模型尚未就绪，请在设置中下载模型，然后重试。")
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("MyMemo-ASR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: file) }
        catch {
            let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let ffmpeg else { throw MemoError("系统无法解码此录音格式。可转换为 WAV/M4A，或安装 FFmpeg 后重试。") }
            let converted = workspace.appendingPathComponent("audio.wav")
            try await ChildProcess.run(executable: ffmpeg,
                arguments: ["-nostdin", "-v", "error", "-i", file.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", converted.path],
                timeout: 3600, failureMessage: "录音格式无法解码，请检查文件是否损坏或为厂商专用格式。")
            audio = try AVAudioFile(forReading: converted)
        }
        guard audio.length > 0 else { throw MemoError("录音不包含可读取的声音数据。") }
        let timeout = max(180, Double(audio.length) / audio.processingFormat.sampleRate * 2 + 120)
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let collector = Task<String, Error> {
                        var parts: [String] = []
                        for try await result in module.results {
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { parts.append(text) }
                        }
                        return parts.joined(separator: "\n\n")
                    }
                    do {
                        _ = try await analyzer.analyzeSequence(from: audio)
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        let text = try await collector.value
                        guard !text.isEmpty else { throw MemoError("未识别出文字，请检查录音中的声音是否清晰。") }
                        return text
                    } catch {
                        collector.cancel()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    await analyzer.cancelAndFinishNow()
                    throw MemoError("本机转写超时，录音已保留，可以重试。")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }, onCancel: { Task { await analyzer.cancelAndFinishNow() } })
    }

    private static func volcengine(file: URL, configuration: AppConfiguration) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonPath),
              FileManager.default.fileExists(atPath: configuration.volcScriptPath) else {
            throw MemoError("找不到 Python 或火山引擎转写脚本，请在设置中检查路径。")
        }
        let credentials = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/volc/agent-plan.env")
        guard FileManager.default.isReadableFile(atPath: credentials.path) else {
            throw MemoError("未找到既有的火山引擎凭据文件 ~/.config/volc/agent-plan.env。请在本机配置服务密钥。")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MyMemo-Cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try await ChildProcess.run(executable: configuration.pythonPath,
            arguments: [configuration.volcScriptPath, "transcribe", file.path, "--work-dir", work.path],
            timeout: 24 * 3600,
            failureMessage: "火山引擎转写失败，请检查网络、服务额度、密钥及 Python websockets / FFmpeg。录音已保留，不会自动重复调用。")
        return try String(contentsOf: work.appendingPathComponent("raw-transcript.txt"), encoding: .utf8)
    }
}

enum ChildProcess {
    static func run(executable: String, arguments: [String], timeout: TimeInterval, failureMessage: String, outputURL: URL? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // Provider output can contain identifiers; no subprocess output is persisted in the app's logs.
        var outputHandle: FileHandle?
        if let outputURL {
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw MemoError("无法创建媒体检测临时文件。") }
            outputHandle = try FileHandle(forWritingTo: outputURL)
        }
        defer { try? outputHandle?.close() }
        process.standardOutput = outputHandle ?? FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let start = Date()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(200))
                if Date().timeIntervalSince(start) > timeout { throw MemoError("处理超时，录音已保留。") }
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw MemoError(failureMessage) }
    }
}
