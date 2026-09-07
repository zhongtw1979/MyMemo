import SwiftUI
import AppKit
import ServiceManagement
import Speech
import MyMemoCore
import MyMemoExperience

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = AppConfiguration()
    @Published var preferences = GuidedPreferences()
    @Published var snapshot = LibrarySnapshot()
    @Published var volumes: [MountedVolume] = []
    @Published var activity = "连接设备后，录音会自动整理到这里"
    @Published var busy = false
    @Published var paused = false
    @Published var errorMessage: String?
    @Published var startupError: String?
    @Published var speechStatus = "正在检查中文识别是否就绪"
    @Published var speechReady = false
    @Published var checkingSpeech = false
    @Published var installingModel = false
    @Published var finishingSetup = false
    @Published var showSetup = true
    @Published var draft = SetupDraft()
    @Published var step: SetupStep = .source
    @Published var section = "home"
    @Published var selectedID: UUID?
    @Published var loginEnabled = false
    @Published var lastImport: ImportResult?

    let dataDirectory: URL
    let configURL: URL
    private let preferencesURL: URL
    private var library: RecordingLibrary?
    private let monitor = VolumeMonitor()
    private var started = false
    private var pendingImports: [MountedVolume] = []
    private var worker: Task<Void, Never>?
    private var observed: Set<String> = []
    private var forceTranscription = false
    private var validatingMedia = true

    var recordings: [RecordingJob] { snapshot.jobs.filter { $0.status != .excluded } }
    var completed: [RecordingJob] { recordings.filter { $0.status == .done } }
    var failed: [RecordingJob] { recordings.filter { $0.status == .failed } }
    var matchingVolumes: [MountedVolume] { volumes.filter { configuration.matches(name: $0.name, uuid: $0.uuid) } }
    var selectedDeviceConnected: Bool { volumes.contains { $0.name == draft.deviceName && $0.url.path == draft.devicePath } }

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), args.count > i + 1 {
            dataDirectory = URL(fileURLWithPath: args[i + 1])
        } else { dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MyMemoGuided") }
        configURL = dataDirectory.appendingPathComponent("config.json")
        preferencesURL = dataDirectory.appendingPathComponent("experience.json")
        do {
            configuration = try AppConfiguration.load(from: configURL)
            preferences = try GuidedPreferences.load(from: preferencesURL)
            library = try RecordingLibrary(stateURL: dataDirectory.appendingPathComponent("library.json"))
            paused = preferences.paused || args.contains("--paused")
            showSetup = !preferences.completed
            seedDraft()
        } catch { startupError = error.localizedDescription }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func start() {
        guard !started else { return }; started = true
        monitor.onChange = { [weak self] in self?.refreshVolumes() }
        monitor.start(); refreshVolumes()
        Task {
            if preferences.completed {
                do { try await library?.auditMedia() } catch { startupError = error.localizedDescription }
            }
            await refresh(); await checkSpeech()
            validatingMedia = false; kickWorker()
        }
    }
    func refresh() async { if let library { snapshot = await library.snapshot() } }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
    private func updateActivity(_ text: String) { activity = text }
    private func canContinue() -> Bool { !paused && !showSetup }

    func checkSpeech() async {
        checkingSpeech = true
        let localeID = showSetup ? "zh-CN" : configuration.localeIdentifier
        speechStatus = await SpeechService.status(localeID: localeID)
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) {
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            speechReady = await AssetInventory.status(forModules: [module]) == .installed
        } else { speechReady = false }
        checkingSpeech = false
    }
    func installModel() {
        guard !installingModel else { return }; installingModel = true
        speechStatus = "正在准备中文识别，请保持联网"
        Task {
            defer { installingModel = false }
            do { try await SpeechService.installModel(localeID: showSetup ? "zh-CN" : configuration.localeIdentifier) }
            catch { report(error) }
            await checkSpeech()
        }
    }

    func refreshVolumes() {
        volumes = monitor.mounted()
        let now = Set(volumes.map { "\($0.url.path)|\($0.name)|\($0.uuid ?? "")" })
        if preferences.completed && !showSetup && configuration.automaticImport {
            for volume in matchingVolumes {
                let key = "\(volume.url.path)|\(volume.name)|\(volume.uuid ?? "")"
                if !observed.contains(key) { enqueue(volume) }
            }
        }
        observed = now
    }

    func selectDevice(_ device: MountedVolume) {
        draft.source = .device; draft.deviceName = device.name; draft.devicePath = device.url.path
    }
    func chooseSourceFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "选择这个文件夹"; panel.message = "选择已有录音所在的文件夹。MyMemo 会筛选其中的纯音频。"
        if panel.runModal() == .OK, let url = panel.url { draft.source = .folder; draft.sourceFolder = url.path }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "保存到这里"; panel.message = "选择电脑上的文件夹，用来保存录音和文字稿。"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { draft.destination = url.path }
    }
    func nextStep() {
        guard draft.canAdvance(from: step) else { return }
        if step == .source { step = .destination }
        else if step == .destination { step = .ready; Task { await checkSpeech() } }
    }
    func previousStep() {
        if step == .ready { step = .destination } else if step == .destination { step = .source }
    }
    private func seedDraft() {
        var value = SetupDraft()
        if preferences.completed {
            value.source = preferences.source
            value.sourceFolder = preferences.sourceFolder ?? ""
            value.destination = configuration.destinationPath
            value.transcribe = configuration.automaticTranscription
            if let device = configuration.devices.first { value.deviceName = device.name }
            value.devicePath = volumes.first { $0.name == value.deviceName }?.url.path ?? ""
        }
        draft = value
    }
    func beginSetup() {
        guard !busy else { return }
        paused = true; preferences.paused = true
        do { try preferences.save(to: preferencesURL) } catch { report(error); return }
        seedDraft(); step = .source; showSetup = true
    }
    func cancelSetup() { guard preferences.completed else { return }; showSetup = false; section = "home" }

    func finishSetup() {
        guard !finishingSetup, startupError == nil else { return }; finishingSetup = true
        Task {
            defer { finishingSetup = false }
            do {
                if draft.transcribe { await checkSpeech() }
                let config = try draft.configuration(modelReady: speechReady)
                if draft.source == .folder && !FileManager.default.isReadableFile(atPath: draft.sourceFolder) {
                    throw MemoError("找不到选择的录音文件夹，请返回第一步重新选择。")
                }
                let destination = URL(fileURLWithPath: config.destinationPath)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let check = destination.appendingPathComponent(".mymemo-write-check-\(UUID().uuidString)")
                try Data().write(to: check, options: .withoutOverwriting)
                try FileManager.default.removeItem(at: check)
                // A restart between the two files returns to setup, never starts
                // processing with a partly committed onboarding choice.
                var next = preferences; next.completed = false; next.paused = true
                try next.save(to: preferencesURL); preferences = next
                try config.save(to: configURL)
                next.completed = true; next.paused = false; next.source = draft.source
                next.sourceFolder = draft.source == .folder ? draft.sourceFolder : nil
                try next.save(to: preferencesURL)
                configuration = config; preferences = next; paused = false
                showSetup = false; section = "home"; activity = "设置完成，已经准备好了"
                pendingImports.removeAll(); observed.removeAll(); refreshVolumes()
                if draft.source == .folder { importFolder(URL(fileURLWithPath: draft.sourceFolder)) }
                kickWorker()
            } catch { report(error) }
        }
    }

    func scanMountedVolumes(fullVerification: Bool = false) {
        if preferences.source == .folder, let folder = preferences.sourceFolder {
            enqueue(MountedVolume(name: URL(fileURLWithPath: folder).lastPathComponent, uuid: nil,
                url: URL(fileURLWithPath: folder), isManual: true, fullVerification: fullVerification))
            return
        }
        refreshVolumes()
        if configuration.devices.isEmpty { beginSetup(); return }
        if matchingVolumes.isEmpty { activity = "还没找到你的录音设备，接好后会自动识别" }
        for var volume in matchingVolumes { volume.fullVerification = fullVerification; enqueue(volume) }
    }
    private func enqueue(_ volume: MountedVolume) {
        guard preferences.completed, !showSetup, startupError == nil, !configuration.destinationPath.isEmpty else { return }
        if let i = pendingImports.firstIndex(where: { $0.url == volume.url }) {
            pendingImports[i].fullVerification = pendingImports[i].fullVerification || volume.fullVerification
        } else { pendingImports.append(volume) }
        kickWorker()
    }
    private func importFolder(_ url: URL) { enqueue(MountedVolume(name: url.lastPathComponent, uuid: nil, url: url, isManual: true)) }
    func chooseImportFolder() {
        guard preferences.completed else { showSetup = true; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "整理这些录音"; panel.message = "原文件会保留，只复制纯音频。"
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }
    func togglePause() {
        paused.toggle(); preferences.paused = paused
        do { try preferences.save(to: preferencesURL) } catch { paused = true; report(error); return }
        if paused { activity = busy ? "当前录音处理完就暂停" : "自动整理已暂停" }
        else { observed.removeAll(); refreshVolumes(); kickWorker() }
    }
    func startTranscription() {
        if configuration.provider == .apple && !speechReady {
            section = "settings"
            errorMessage = "中文识别还没准备好。点击“准备中文识别”后，就可以为已保存的录音生成文字。"
            return
        }
        paused = false; preferences.paused = false; forceTranscription = true
        do { try preferences.save(to: preferencesURL); kickWorker() } catch { report(error) }
    }
    func retry(id: UUID? = nil) {
        Task {
            guard let library else { return }
            do { try await library.retryFailed(id: id); await refresh(); startTranscription() } catch { report(error) }
        }
    }
    private func kickWorker() {
        guard worker == nil, !validatingMedia, preferences.completed, !showSetup, !paused, startupError == nil, library != nil else { return }
        worker = Task { await runWorker() }
    }
    private func runWorker() async {
        guard let library else { worker = nil; return }
        defer { worker = nil; busy = false; forceTranscription = false }
        let power = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "整理录音")
        defer { ProcessInfo.processInfo.endActivity(power) }
        while !paused && !showSetup && !Task.isCancelled {
            if !pendingImports.isEmpty {
                let volume = pendingImports.removeFirst(); busy = true
                do {
                    if !volume.isManual {
                        guard monitor.mounted().contains(where: { $0.url == volume.url && $0.name == volume.name && $0.uuid == volume.uuid }),
                              configuration.matches(name: volume.name, uuid: volume.uuid) else { throw MemoError("设备已断开或名称发生变化，请重新连接后再试。") }
                    }
                    let result = try await library.importDirectory(volume.url, deviceName: volume.name,
                        destination: URL(fileURLWithPath: configuration.destinationPath),
                        progress: { [weak self] in await self?.updateActivity($0) },
                        shouldContinue: { [weak self] in await self?.canContinue() ?? false },
                        deviceID: volume.isManual ? nil : volume.uuid, fullVerification: volume.fullVerification)
                    lastImport = result
                    if result.interrupted { pendingImports.insert(volume, at: 0) }
                    activity = result.summary
                } catch let error as PersistenceFailure { startupError = error.localizedDescription; break }
                catch { report(error); activity = "有录音未能保存，请查看提示" }
                await refresh(); continue
            }
            guard configuration.automaticTranscription || forceTranscription else { break }
            do {
                guard let job = try await library.claimNext(provider: configuration.provider) else { break }
                busy = true; activity = "正在生成文字：\(job.originalName)"; await refresh()
                let config = configuration
                do {
                    try await library.verifyRecording(job)
                    let text = try await SpeechService.transcribe(file: URL(fileURLWithPath: job.localPath), configuration: config)
                    try await library.complete(id: job.id, text: text, provider: config.provider.title)
                    activity = "文字稿已生成：\(job.originalName)"
                } catch let error as PersistenceFailure { throw error }
                catch { try await library.fail(id: job.id, message: error.localizedDescription); activity = "有录音未能生成文字，可以重试" }
                await refresh()
            } catch { startupError = error.localizedDescription; break }
        }
        if paused { activity = "自动整理已暂停" }
    }

    // Advanced settings reuse the working editor, away from first-time setup.
    func saveConfiguration(_ value: AppConfiguration) {
        do { try value.save(to: configURL); configuration = value; activity = "设置已保存"; observed.removeAll(); refreshVolumes(); Task { await checkSpeech(); kickWorker() } }
        catch { report(error) }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.prompt = "载入配置"
        if panel.runModal() == .OK, let url = panel.url {
            do { var config = try AppConfiguration.load(from: url); config.cloudConsent = false; saveConfiguration(config) } catch { report(error) }
        }
    }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MyMemo-Guided-config.json"
        if panel.runModal() == .OK, let url = panel.url { do { try configuration.save(to: url) } catch { report(error) } }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { errorMessage = "请在系统设置 → 通用 → 登录项与扩展中允许 MyMemo 引导版。" }
        } catch { report(error) }
    }
}
