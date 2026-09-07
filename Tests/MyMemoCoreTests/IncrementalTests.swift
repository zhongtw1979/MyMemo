import XCTest
@testable import MyMemoCore

final class IncrementalTests: XCTestCase {
    var base: URL!
    var source: URL { base.appendingPathComponent("recorder") }
    var output: URL { base.appendingPathComponent("output") }
    var stateURL: URL { base.appendingPathComponent("state.json") }
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    func put(_ name: String, seed: String) throws -> URL {
        let file = source.appendingPathComponent(name); try audioData(seed).write(to: file); return file
    }
    func store() throws -> RecordingLibrary { try RecordingLibrary(stateURL: stateURL, exclusiveAccess: false) }

    func testUnchangedScanSurvivesRestartWithoutFullHashesOrProbes() async throws {
        _ = try put("one.wav", seed: "one")
        let first = try store()
        _ = try await first.importDirectory(source, deviceName: "REC", destination: output, deviceID: "device-A")
        let originalJob = try await first.claimNext()!
        try await first.complete(id: originalJob.id, text: "已完成的测试文字稿", provider: "test")
        let restarted = try store()
        let again = try await restarted.importDirectory(source, deviceName: "REC", destination: output, deviceID: "device-A")
        XCTAssertEqual(again.fastSkipped, 1); XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(again.fullHashReads, 0); XCTAssertEqual(again.mediaInspections, 0)
        let job = await restarted.snapshot().jobs[0]
        XCTAssertEqual(job.attempts, 1); XCTAssertEqual(job.status, .done)
        let next = try await restarted.claimNext()
        XCTAssertNil(next)
    }
    func testNewAndChangedFilesAreProcessedButUnchangedFileIsFast() async throws {
        _ = try put("one.wav", seed: "one"); _ = try put("two.wav", seed: "two")
        let store = try store()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: output)
        _ = try put("two.wav", seed: "changed"); _ = try put("three.wav", seed: "three")
        let next = try await store.importDirectory(source, deviceName: "REC", destination: output)
        XCTAssertEqual(next.fastSkipped, 1); XCTAssertEqual(next.imported, 2)
        XCTAssertEqual(next.mediaInspections, 2)
        let count = await store.snapshot().jobs.count
        XCTAssertEqual(count, 4)
    }
    func testQuickFingerprintDetectsSameSizeAndRestoredModificationDate() async throws {
        let input = try put("one.wav", seed: "one")
        let stamp = try input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let store = try store()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: output)
        try audioData("two").write(to: input)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: input.path)
        let next = try await store.importDirectory(source, deviceName: "REC", destination: output)
        XCTAssertEqual(next.fastSkipped, 0); XCTAssertEqual(next.imported, 1)
    }
    func testMissingOrModifiedLocalCopyCannotTakeFastPath() async throws {
        _ = try put("one.wav", seed: "one")
        let store = try store()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: output)
        let local = URL(fileURLWithPath: await store.snapshot().jobs[0].localPath)
        try audioData("bad").write(to: local)
        let repaired = try await store.importDirectory(source, deviceName: "REC", destination: output)
        XCTAssertEqual(repaired.fastSkipped, 0); XCTAssertEqual(repaired.imported, 1)
        let repairedPath = URL(fileURLWithPath: await store.snapshot().jobs[0].localPath)
        XCTAssertEqual(try Data(contentsOf: repairedPath), audioData("one"))
        try FileManager.default.removeItem(at: repairedPath)
        let restored = try await store.importDirectory(source, deviceName: "REC", destination: output)
        XCTAssertEqual(restored.fastSkipped, 0); XCTAssertEqual(restored.imported, 1)
    }
    func testDeviceIdentitySurvivesChangedMountPathButSeparatesDevices() async throws {
        let input = try put("one.wav", seed: "one")
        let store = try store()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: output, deviceID: "device-A")
        let remount = base.appendingPathComponent("new-mount")
        try FileManager.default.createDirectory(at: remount, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: input, to: remount.appendingPathComponent("one.wav"))
        XCTAssertEqual(try IncrementalFiles.stamp(input), try IncrementalFiles.stamp(remount.appendingPathComponent("one.wav")), "Remount fixture must preserve file metadata")
        let snapshot = await store.snapshot()
        let newFile = remount.appendingPathComponent("one.wav").resolvingSymlinksInPath()
        let key = IncrementalFiles.key(deviceID: "device-A", root: remount.resolvingSymlinksInPath(), file: newFile)
        let cached = try XCTUnwrap(snapshot.scanCache?[key], "Stable device-relative cache key")
        XCTAssertEqual(cached.sourceStamp, try IncrementalFiles.stamp(newFile), "Cached source metadata")
        XCTAssertEqual(cached.sourceFingerprint, try IncrementalFiles.fingerprint(newFile, size: cached.sourceStamp.size).digest)
        let local = URL(fileURLWithPath: snapshot.jobs[0].localPath)
        XCTAssertEqual(cached.localStamp, try IncrementalFiles.stamp(local), "Cached local metadata")
        let fast = try await store.importDirectory(remount, deviceName: "REC", destination: output, deviceID: "device-A")
        XCTAssertEqual(fast.fastSkipped, 1)
        let other = try await store.importDirectory(remount, deviceName: "REC", destination: output, deviceID: "device-B")
        XCTAssertEqual(other.fastSkipped, 0); XCTAssertEqual(other.skipped, 1)
    }
    func testManualFullVerificationBypassesIncrementalCache() async throws {
        _ = try put("one.wav", seed: "one")
        let store = try store()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: output)
        let full = try await store.importDirectory(source, deviceName: "REC", destination: output, fullVerification: true)
        XCTAssertEqual(full.fastSkipped, 0); XCTAssertGreaterThan(full.fullHashReads, 0)
        XCTAssertEqual(full.mediaInspections, 1); XCTAssertEqual(full.skipped, 1)
    }
    func testKnownVideoIsAlsoFastSkippedOnReconnect() async throws {
        let video = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/video-with-audio.mp4")
        try FileManager.default.copyItem(at: video, to: source.appendingPathComponent("video.mp4"))
        let store = try store()
        _ = try await store.importDirectory(source, deviceName: "REC", destination: output)
        let again = try await store.importDirectory(source, deviceName: "REC", destination: output)
        XCTAssertEqual(again.filtered, 1); XCTAssertEqual(again.fastSkipped, 1)
        XCTAssertEqual(again.mediaInspections, 0)
    }
}
