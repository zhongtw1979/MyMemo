import XCTest
@testable import MyMemoCore

final class MediaFilteringTests: XCTestCase {
    func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)") }

    func testNativeFallbackRejectsMislabeledMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disguised = directory.appendingPathComponent("recording.wav")
        try FileManager.default.copyItem(at: fixture("video-with-audio.mp4"), to: disguised)
        let result = await MediaInspector.inspect(disguised, useFFprobe: false)
        XCTAssertNotEqual(result, .audio)
        let audio = await MediaInspector.inspect(fixture("audio-only.mp4"), useFFprobe: false)
        XCTAssertEqual(audio, .audio)
        let video = await MediaInspector.inspect(fixture("video-with-audio.mp4"), useFFprobe: false)
        XCTAssertEqual(video, .video)
        let m4a = directory.appendingPathComponent("recording.m4a")
        try FileManager.default.copyItem(at: fixture("video-with-audio.mp4"), to: m4a)
        let mislabeledM4A = await MediaInspector.inspect(m4a, useFFprobe: false)
        XCTAssertNotEqual(mislabeledM4A, .audio)
    }

    func testFiltersVideoBeforeCopyAndDoesNotTrustFilename() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("input")
        let output = base.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["audio-only.mp4", "video-with-audio.mp4", "video-silent.mp4"] {
            try FileManager.default.copyItem(at: fixture(name), to: source.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: fixture("video-with-audio.mp4"), to: source.appendingPathComponent("disguised.wav"))
        try Data("not an audio file".utf8).write(to: source.appendingPathComponent("invalid.mp3"))
        let library = try RecordingLibrary(stateURL: base.appendingPathComponent("state.json"))
        let result = try await library.importDirectory(source, deviceName: "REC", destination: output)
        XCTAssertEqual(result.imported, 1)
        let jobs = await library.snapshot().jobs
        XCTAssertEqual(jobs.map(\.originalName), ["audio-only.mp4"])
        let copied = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { ["mp4","mp3","wav"].contains($0.pathExtension) }
        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path).count, 5)
    }

    func testOldVideoQueueCannotBeClaimedForTranscription() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let video = fixture("video-with-audio.mp4")
        var snapshot = LibrarySnapshot()
        snapshot.jobs.append(RecordingJob(contentHash: try FileSafety.hash(video), originalName: video.lastPathComponent,
            deviceName: "REC", sourcePath: video.path, localPath: video.path, byteCount: 100))
        let state = base.appendingPathComponent("state.json")
        try Persistence.write(snapshot, to: state)
        let library = try RecordingLibrary(stateURL: state)
        let claimed = try await library.claimNext()
        XCTAssertNil(claimed)
        let count = await library.snapshot().jobs[0].attempts
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testAuditBacksUpAndPreservesFilesWithoutRetryingExcludedVideo() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let video = fixture("video-with-audio.mp4")
        var snapshot = LibrarySnapshot()
        snapshot.jobs.append(RecordingJob(contentHash: try FileSafety.hash(video), originalName: video.lastPathComponent,
            deviceName: "REC", sourcePath: video.path, localPath: video.path, byteCount: 100))
        let state = base.appendingPathComponent("state.json")
        try Persistence.write(snapshot, to: state)
        let library = try RecordingLibrary(stateURL: state)
        let count = try await library.auditMedia()
        XCTAssertEqual(count, 1)
        try await library.retryFailed()
        let audited = await library.snapshot()
        XCTAssertEqual(audited.jobs[0].status, .excluded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("library-before-audio-filter-") })
        let previous = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: backup))
        XCTAssertEqual(previous.jobs[0].status, .queued)
    }
}
