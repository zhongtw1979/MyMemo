import Foundation

public actor RecordingLibrary {
    private let stateURL: URL
    private let fileLock: StateLock?
    private var state: LibrarySnapshot

    public init(stateURL: URL, exclusiveAccess: Bool = true) throws {
        self.stateURL = stateURL
        self.fileLock = try exclusiveAccess ? StateLock(url: stateURL.appendingPathExtension("lock")) : nil
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                var loaded = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: stateURL))
                guard loaded.version == 1, Set(loaded.jobs.map(\.id)).count == loaded.jobs.count else {
                    throw MemoError("记录版本或任务编号有误。")
                }
                var recovered = false
                for i in loaded.jobs.indices where loaded.jobs[i].status == .transcribing {
                    recovered = true
                    if loaded.jobs[i].requestProvider == .volcengine {
                        loaded.jobs[i].status = .failed
                        loaded.jobs[i].lastError = "上次云端转写中断，服务端可能已经计费。请确认后手动重试。"
                    } else {
                        loaded.jobs[i].status = .queued
                        loaded.jobs[i].lastError = "上次转写中断，已恢复到等待队列。"
                    }
                }
                self.state = loaded
                if recovered { try Persistence.write(loaded, to: stateURL) }
            } catch { throw MemoError("无法读取录音记录，已保留原文件：\(stateURL.path)\n\(error.localizedDescription)") }
        } else { state = LibrarySnapshot() }
    }

    public func snapshot() -> LibrarySnapshot { state }

    private func commit(_ next: LibrarySnapshot) throws {
        do { try Persistence.write(next, to: stateURL); state = next }
        catch { throw PersistenceFailure(message: "无法保存处理记录，当前任务已停止：\(error.localizedDescription)") }
    }

    public func log(_ message: String, isError: Bool = false) throws {
        var next = state
        next.events.append(LibraryEvent(message, isError: isError))
        next.events = Array(next.events.suffix(200))
        try commit(next)
    }

    public func importDirectory(_ source: URL, deviceName: String, destination: URL,
                                progress: (@Sendable (String) async -> Void)? = nil,
                                shouldContinue: (@Sendable () async -> Bool)? = nil,
                                deviceID: String? = nil, fullVerification: Bool = false) async throws -> ImportResult {
        let startedAt = Date()
        guard !FileSafety.contains(destination, in: source) else {
            throw MemoError("保存目录不能位于录音设备或导入目录内部。")
        }
        guard !FileSafety.contains(stateURL, in: source) else {
            throw MemoError("导入目录包含 MyMemo 的运行数据，请选择实际录音目录。")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MemoError("录音目录无法读取，设备可能已拔出。")
        }
        let root = source.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var enumerationErrors: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants], errorHandler: { url, error in
                enumerationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true
            }) else { throw MemoError("无法扫描录音目录，请检查读取权限。") }
        var files: [URL] = []
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: Set(keys))
            if file.lastPathComponent.hasPrefix(".") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true, file.path != root.path,
               FileSafety.contains(destination, in: file) { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true && FileSafety.extensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        var result = ImportResult()
        var cacheChanges: [String: ScanCacheEntry] = [:]
        var indexByID: [UUID: Int] = [:]
        var indexByHash: [String: Int] = [:]
        for (i, job) in state.jobs.enumerated() {
            indexByID[job.id] = i
            if indexByHash[job.contentHash] == nil { indexByHash[job.contentHash] = i }
        }
        for message in enumerationErrors { try log(message, isError: true); result.failed += 1 }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: Date())
        for (index, file) in files.sorted(by: { $0.path < $1.path }).enumerated() {
            try Task.checkCancellation()
            if let shouldContinue, !(await shouldContinue()) { result.interrupted = true; break }
            await progress?("正在检查新增录音 \(index + 1)/\(files.count)：\(file.lastPathComponent)")
            var staged: URL?
            var importedJob: RecordingJob?
            var existingIndex: Int?
            var cacheKey: String?
            var sourceStamp: FileStamp?
            var sourceFingerprint: String?
            do {
                guard FileSafety.contains(file, in: root) else { throw MemoError("文件路径超出设备目录。") }
                let stamp = try IncrementalFiles.stamp(file)
                let sample = try IncrementalFiles.fingerprint(file, size: stamp.size)
                result.fingerprintBytesRead += sample.bytes
                let key = IncrementalFiles.key(deviceID: deviceID, root: root, file: file)
                cacheKey = key; sourceStamp = stamp; sourceFingerprint = sample.digest
                if !fullVerification, let cached = cacheChanges[key] ?? state.scanCache?[key],
                   cached.policy == 1, cached.sourceStamp == stamp, cached.sourceFingerprint == sample.digest,
                   try IncrementalFiles.stamp(file) == stamp {
                    if cached.kind == MediaKind.video.rawValue {
                        result.filtered += 1; result.fastSkipped += 1; continue
                    }
                    if cached.kind == MediaKind.audio.rawValue, let id = cached.recordingID,
                       let i = indexByID[id], state.jobs[i].id == id, state.jobs[i].status != .excluded,
                       state.jobs[i].contentHash == cached.contentHash,
                       cachedLocalIsUnchanged(cached, job: state.jobs[i], bytesRead: &result.fingerprintBytesRead),
                       try IncrementalFiles.stamp(file) == stamp {
                        result.skipped += 1; result.fastSkipped += 1; continue
                    }
                }
                result.mediaInspections += 1
                let media = await MediaInspector.inspect(file)
                guard media == .audio else {
                    result.filtered += 1
                    if media == .video, try IncrementalFiles.stamp(file) == stamp {
                        cacheChanges[key] = ScanCacheEntry(sourceStamp: stamp, sourceFingerprint: sample.digest, kind: media.rawValue)
                    }
                    if media == .unreadable { try log("\(file.lastPathComponent)：\(media.reason)", isError: true) }
                    continue
                }
                await progress?("正在导入录音：\(file.lastPathComponent)")
                // Hash before copying to avoid writing known duplicates to the destination again.
                result.fullHashReads += 1
                let fingerprint = try FileSafety.hash(file)
                existingIndex = indexByHash[fingerprint] ?? state.jobs.firstIndex { $0.contentHash == fingerprint }
                if let i = existingIndex,
                   FileManager.default.fileExists(atPath: state.jobs[i].localPath),
                   try countedHash(URL(fileURLWithPath: state.jobs[i].localPath), result: &result) == fingerprint {
                    if state.jobs[i].status == .excluded {
                        var next = state; next.jobs[i].status = .queued; next.jobs[i].lastError = nil
                        try commit(next)
                    }
                    if let entry = makeCacheEntry(file: file, stamp: stamp, fingerprint: sample.digest, job: state.jobs[i], result: &result) {
                        cacheChanges[key] = entry
                    }
                    result.skipped += 1; continue
                }
                let folder = destination.appendingPathComponent(FileSafety.safeName(deviceName)).appendingPathComponent(day)
                guard FileSafety.contains(folder, in: destination), !FileSafety.contains(folder, in: root) else {
                    throw MemoError("保存目录中的链接指向了其他位置，请选择普通文件夹。")
                }
                let copy = try FileSafety.stage(file, in: folder); staged = copy.url
                result.fullHashReads += 2
                guard copy.hash == fingerprint else { throw MemoError("复制前后录音内容发生变化，请重新扫描。") }
                let stem = FileSafety.safeName(file.deletingPathExtension().lastPathComponent)
                var target = folder.appendingPathComponent("\(stem)-\(fingerprint.prefix(16)).\(file.pathExtension.lowercased())")
                if let i = existingIndex, !FileManager.default.fileExists(atPath: state.jobs[i].localPath) {
                    target = URL(fileURLWithPath: state.jobs[i].localPath)
                    guard !FileSafety.contains(target, in: root) else { throw MemoError("历史保存路径指向了源设备。") }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    if try countedHash(target, result: &result) != fingerprint {
                        target = folder.appendingPathComponent("\(stem)-\(UUID().uuidString).\(file.pathExtension.lowercased())")
                    }
                }
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.moveItem(at: copy.url, to: target)
                } else { try FileManager.default.removeItem(at: copy.url) }
                staged = nil
                if let i = existingIndex {
                    var job = state.jobs[i]; job.localPath = target.path
                    if job.status == .failed || job.status == .excluded { job.status = .queued; job.lastError = nil }
                    importedJob = job
                } else {
                    importedJob = RecordingJob(contentHash: fingerprint, originalName: file.lastPathComponent,
                        deviceName: deviceName, sourcePath: file.path, localPath: target.path, byteCount: copy.size)
                }
            } catch {
                if let staged { try? FileManager.default.removeItem(at: staged) }
                if error is PersistenceFailure { throw error }
                if error is CancellationError { throw error }
                try log("导入失败 · \(file.lastPathComponent)：\(error.localizedDescription)", isError: true)
                result.failed += 1
            }
            // Persistence errors escape the per-file handler and stop the run.
            if let job = importedJob {
                var next = state
                if let i = existingIndex { next.jobs[i] = job; indexByID[job.id] = i; indexByHash[job.contentHash] = i }
                else { indexByID[job.id] = next.jobs.count; indexByHash[job.contentHash] = next.jobs.count; next.jobs.append(job) }
                if let cacheKey, let sourceStamp, let sourceFingerprint,
                   let entry = makeCacheEntry(file: file, stamp: sourceStamp, fingerprint: sourceFingerprint, job: job, result: &result) {
                    cacheChanges[cacheKey] = entry
                }
                mergeCache(cacheChanges, into: &next)
                try commit(next); cacheChanges.removeAll()
                result.imported += 1
            }
        }
        if !cacheChanges.isEmpty { var next = state; mergeCache(cacheChanges, into: &next); try commit(next) }
        try log("\(deviceName)：\(result.summary)", isError: result.failed > 0)
        result.elapsedSeconds = Date().timeIntervalSince(startedAt)
        return result
    }

    private func countedHash(_ url: URL, result: inout ImportResult) throws -> String {
        result.fullHashReads += 1
        return try FileSafety.hash(url)
    }
    private func mergeCache(_ updates: [String: ScanCacheEntry], into next: inout LibrarySnapshot) {
        var cache = next.scanCache ?? [:]
        cache.merge(updates) { _, new in new }; next.scanCache = cache
    }
    private func cachedLocalIsUnchanged(_ cached: ScanCacheEntry, job: RecordingJob, bytesRead: inout Int64) -> Bool {
        let local = URL(fileURLWithPath: job.localPath)
        do {
            let stamp = try IncrementalFiles.stamp(local)
            guard stamp == cached.localStamp else { return false }
            let sample = try IncrementalFiles.fingerprint(local, size: stamp.size); bytesRead += sample.bytes
            let finalStamp = try IncrementalFiles.stamp(local)
            return sample.digest == cached.localFingerprint && finalStamp == stamp
        } catch { return false }
    }
    private func makeCacheEntry(file: URL, stamp: FileStamp, fingerprint: String, job: RecordingJob,
                                result: inout ImportResult) -> ScanCacheEntry? {
        do {
            guard try IncrementalFiles.stamp(file) == stamp else { return nil }
            let local = URL(fileURLWithPath: job.localPath)
            let localStamp = try IncrementalFiles.stamp(local)
            let localSample = try IncrementalFiles.fingerprint(local, size: localStamp.size)
            result.fingerprintBytesRead += localSample.bytes
            guard localSample.digest == fingerprint, try IncrementalFiles.stamp(local) == localStamp else { return nil }
            return ScanCacheEntry(sourceStamp: stamp, sourceFingerprint: fingerprint, kind: MediaKind.audio.rawValue,
                recordingID: job.id, contentHash: job.contentHash, localStamp: localStamp, localFingerprint: localSample.digest)
        } catch { return nil }
    }

    public func claimNext(provider: TranscriptionProvider = .apple) async throws -> RecordingJob? {
        while let job = state.jobs.first(where: { $0.status == .queued }) {
            let media = await MediaInspector.inspect(URL(fileURLWithPath: job.localPath))
            guard let i = state.jobs.firstIndex(where: { $0.id == job.id }), state.jobs[i].status == .queued else { continue }
            var next = state
            if media != .audio {
                next.jobs[i].status = .excluded; next.jobs[i].lastError = media.reason
                try commit(next); continue
            }
            next.jobs[i].status = .transcribing; next.jobs[i].attempts += 1; next.jobs[i].lastError = nil
            next.jobs[i].requestProvider = provider
            try commit(next)
            return state.jobs[i]
        }
        return nil
    }

    /// Keep history and existing files; exclude ineligible old entries from work.
    @discardableResult public func auditMedia() async throws -> Int {
        let candidates = state.jobs.filter { $0.status != .excluded && $0.status != .transcribing }
        var changed = 0
        var backedUp = false
        var cachedByID: [UUID: ScanCacheEntry] = [:]
        for entry in state.scanCache?.values ?? [:].values {
            if let id = entry.recordingID, entry.policy == 1, entry.kind == MediaKind.audio.rawValue { cachedByID[id] = entry }
        }
        for job in candidates {
            var sampleBytes: Int64 = 0
            if let cached = cachedByID[job.id], cached.contentHash == job.contentHash,
               cachedLocalIsUnchanged(cached, job: job, bytesRead: &sampleBytes) { continue }
            let media = await MediaInspector.inspect(URL(fileURLWithPath: job.localPath))
            guard media != .audio,
                  let i = state.jobs.firstIndex(where: { $0.id == job.id }), state.jobs[i].status != .transcribing else { continue }
            if !backedUp && FileManager.default.fileExists(atPath: stateURL.path) {
                try FileManager.default.copyItem(at: stateURL, to: stateURL.deletingLastPathComponent()
                    .appendingPathComponent("library-before-audio-filter-\(UUID().uuidString).json"))
                backedUp = true
            }
            var next = state; next.jobs[i].status = .excluded; next.jobs[i].lastError = media.reason
            try commit(next); changed += 1
        }
        if changed > 0 { try log("音频筛选：已将 \(changed) 条视频、非音频或文件缺失的旧记录标为已跳过，现有文件保留。") }
        return changed
    }

    public func fail(id: UUID, message: String) throws {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }) else { throw MemoError("找不到录音记录。") }
        var next = state; next.jobs[i].status = .failed; next.jobs[i].lastError = message
        try commit(next)
    }

    public func retryFailed(id: UUID? = nil) throws {
        var next = state
        for i in next.jobs.indices where next.jobs[i].status == .failed && (id == nil || next.jobs[i].id == id) {
            next.jobs[i].status = .queued; next.jobs[i].lastError = nil
        }
        try commit(next)
    }

    public func verifyRecording(_ job: RecordingJob) throws {
        guard try FileSafety.hash(URL(fileURLWithPath: job.localPath)) == job.contentHash else {
            throw MemoError("本机录音副本发生变化，请重新接入设备并扫描。")
        }
    }

    public func complete(id: UUID, text: String, provider: String) throws {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[i].status == .transcribing else {
            throw MemoError("录音当前未处于转写状态。")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MemoError("未识别出有效文字；录音已保留，可检查内容后重试。") }
        let job = state.jobs[i]
        // Each attempt writes unique output files; never replace a user's existing transcript.
        let base = URL(fileURLWithPath: job.localPath).deletingPathExtension()
        let prefix = base.path + "-转写-\(job.id.uuidString.prefix(8))-\(job.attempts)"
        var markdown = URL(fileURLWithPath: prefix + ".md")
        var plain = URL(fileURLWithPath: prefix + ".txt")
        if FileManager.default.fileExists(atPath: markdown.path) || FileManager.default.fileExists(atPath: plain.path) {
            let suffix = UUID().uuidString
            markdown = URL(fileURLWithPath: prefix + "-\(suffix).md")
            plain = URL(fileURLWithPath: prefix + "-\(suffix).txt")
        }
        let contents = "# \(job.originalName)\n\n录音设备：\(job.deviceName)  \n转写方式：\(provider)  \n处理时间：\(ISO8601DateFormatter().string(from: Date()))\n\n> 语音识别原文，未经过人工校订。\n\n\(body)\n"
        try Data(body.utf8).write(to: plain, options: .atomic)
        try Data(contents.utf8).write(to: markdown, options: .atomic)
        var next = state
        next.jobs[i].status = .done; next.jobs[i].transcriptPath = markdown.path
        next.jobs[i].provider = provider; next.jobs[i].lastError = nil
        try commit(next)
    }
}
