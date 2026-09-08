import XCTest
@testable import MyMemoCore

final class LibraryTests: XCTestCase {
    var base: URL!
    var source: URL { base.appendingPathComponent("Recorder") }
    var destination: URL { base.appendingPathComponent("Library") }
    var state: URL { base.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audioData(text).write(to: url)
        return url
    }
    func library() throws -> RecordingLibrary { try RecordingLibrary(stateURL: state, exclusiveAccess: false) }

    func testMatchesOnlyConfiguredNameAndOptionalUUID() {
        var config = AppConfiguration()
        config.devices = [DeviceRule(name: "RECORDER", volumeUUID: "abc")]
        XCTAssertTrue(config.matches(name: "RECORDER", uuid: "abc"))
        XCTAssertFalse(config.matches(name: "RECORDER", uuid: "other"))
        XCTAssertFalse(config.matches(name: "RECORDER 1", uuid: "abc"))
        XCTAssertFalse(config.matches(name: "OTHER", uuid: nil))
    }

    func testExplicitSourceUnderHiddenParentStillImportsVisibleChildren() async throws {
        let hiddenSource = base.appendingPathComponent(".private/recordings")
        try FileManager.default.createDirectory(at: hiddenSource, withIntermediateDirectories: true)
        try audioData("recording").write(to: hiddenSource.appendingPathComponent("one.wav"))
        let store = try library()
        let result = try await store.importDirectory(hiddenSource, deviceName: "REC", destination: destination)
        XCTAssertEqual(result.imported, 1)
    }

    func testRecursiveImportSkipsHiddenNonAudioAndSymlinks() async throws {
        let original = try file("VOICE/中文录音.WAV", "recording")
        _ = try file("notes.txt", "not audio")
        _ = try file(".hidden.mp3", "hidden")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.mp3"), withDestinationURL: original)
        let store = try library()
        let result = try await store.importDirectory(source, deviceName: "RECORDER", destination: destination)
        XCTAssertEqual(result.imported, 1)
        let jobs = await store.snapshot().jobs
        XCTAssertEqual(jobs.count, 1)
        let saved = try XCTUnwrap(jobs.first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: saved.localPath)), audioData("recording"))
        XCTAssertEqual(try Data(contentsOf: original), audioData("recording"))
    }

    func testContentDedupSurvivesRestartAndDifferentNames() async throws {
        _ = try file("one.wav", "same recording")
        _ = try file("two.mp3", "same recording")
        let store = try library()
        let first = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(first.skipped, 1)
        let reloaded = try library()
        let again = try await reloaded.importDirectory(source, deviceName: "REC", destination: destination)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skipped, 2)
    }

    func testSameFilenameDifferentContentDoesNotOverwrite() async throws {
        let input = try file("one.wav", "version one")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        try audioData("version two").write(to: input)
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        let jobs = await store.snapshot().jobs
        XCTAssertEqual(jobs.count, 2)
        XCTAssertNotEqual(jobs[0].localPath, jobs[1].localPath)
        let contents = try Set(jobs.map { try Data(contentsOf: URL(fileURLWithPath: $0.localPath)) })
        XCTAssertEqual(contents, [audioData("version one"), audioData("version two")])
    }

    func testMissingLocalCopyIsReimported() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        let job = await store.snapshot().jobs[0]
        try FileManager.default.removeItem(atPath: job.localPath)
        let result = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        XCTAssertEqual(result.imported, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.localPath))
        let count = await store.snapshot().jobs.count
        XCTAssertEqual(count, 1)
    }

    func testRejectsDestinationInsideSource() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        do {
            _ = try await store.importDirectory(source, deviceName: "REC", destination: source.appendingPathComponent("output"))
            XCTFail("must reject recursion")
        } catch { XCTAssertTrue(error.localizedDescription.contains("保存目录")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("output").path))
    }

    func testCorruptStateIsNotSilentlyReset() throws {
        let corrupt = Data("broken state".utf8)
        try corrupt.write(to: state)
        XCTAssertThrowsError(try library())
        XCTAssertEqual(try Data(contentsOf: state), corrupt)
    }

    func testOpeningCompletedLibraryDoesNotRewriteState() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: state.path)
        _ = try library()
        let after = try FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate] as? Date
        XCTAssertEqual(after, stamp)
    }

    func testExclusiveStoreRejectsSecondWriter() throws {
        let first = try RecordingLibrary(stateURL: state, exclusiveAccess: true)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try RecordingLibrary(stateURL: state, exclusiveAccess: true))
        }
    }

    func testCloudJobInterruptedAtRestartRequiresExplicitRetry() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        _ = try await store.claimNext(provider: .volcengine)
        let reloaded = try library()
        let recovered = await reloaded.snapshot().jobs[0]
        XCTAssertEqual(recovered.status, .failed)
    }

    func testStateWriteFailureStopsWithoutClaimingImportSuccess() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        do {
            _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
            XCTFail("State write must fail")
        } catch { XCTAssertTrue(error is PersistenceFailure) }
        let count = await store.snapshot().jobs.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("one.wav").path))
    }

    func testCloudConsentIsCheckedBeforeStartingAnyProcess() async throws {
        var config = AppConfiguration(); config.provider = .volcengine; config.cloudConsent = false
        do {
            _ = try await SpeechService.transcribe(file: source.appendingPathComponent("absent.wav"), configuration: config)
            XCTFail("Cloud access must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("尚未启用云端")) }
    }

    func testPauseStopsBetweenFilesAndNextScanResumes() async throws {
        _ = try file("one.wav", "one"); _ = try file("two.wav", "two")
        let store = try library()
        let gate = ImportGate()
        let first = try await store.importDirectory(source, deviceName: "REC", destination: destination,
            shouldContinue: { await gate.take() })
        XCTAssertTrue(first.interrupted)
        XCTAssertEqual(first.imported, 1)
        let second = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        XCTAssertEqual(second.imported, 1); XCTAssertEqual(second.skipped, 1)
    }

    func testInterruptedTranscriptionReturnsToQueue() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        let job = try await store.claimNext()!
        XCTAssertEqual(job.status, .transcribing)
        let reloaded = try library()
        let recovered = await reloaded.snapshot().jobs[0]
        XCTAssertEqual(recovered.status, .queued)
    }

    func testEmptyTranscriptCannotCompleteAndRetryIsExplicit() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        let job = try await store.claimNext()!
        do {
            try await store.complete(id: job.id, text: " \n ", provider: "test")
            XCTFail("empty result cannot succeed")
        } catch { }
        try await store.fail(id: job.id, message: "无法识别")
        let next = try await store.claimNext()
        XCTAssertNil(next)
        try await store.retryFailed()
        let retried = try await store.claimNext()
        XCTAssertEqual(retried?.id, job.id)
    }

    func testTranscriptPublicationAndCompletedJobNotRetried() async throws {
        _ = try file("one.wav", "recording")
        let store = try library()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: destination)
        let job = try await store.claimNext()!
        try await store.complete(id: job.id, text: "今天讨论自动导入录音。", provider: "测试")
        try await store.retryFailed()
        let completed = await store.snapshot().jobs[0]
        XCTAssertEqual(completed.status, .done)
        XCTAssertTrue(try String(contentsOfFile: completed.transcriptPath!, encoding: .utf8).contains("今天讨论自动导入录音。"))
        let next = try await store.claimNext()
        XCTAssertNil(next)
    }
}

private actor ImportGate {
    var count = 0
    func take() -> Bool { count += 1; return count == 1 }
}
