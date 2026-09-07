import XCTest
@testable import MyMemoCore

final class IncrementalBenchmarkTests: XCTestCase {
    func testBoundedReadsOnRepeatedLargeRecordingScan() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("recorder")
        let output = base.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let count = 8, payloadSize = 8 * 1024 * 1024
        for i in 0..<count {
            var data = audioData("sample-\(i)")
            data.append(Data(count: payloadSize + 44 - data.count))
            var riffSize = UInt32(payloadSize + 36).littleEndian
            var pcmSize = UInt32(payloadSize).littleEndian
            withUnsafeBytes(of: &riffSize) { data.replaceSubrange(4..<8, with: $0) }
            withUnsafeBytes(of: &pcmSize) { data.replaceSubrange(40..<44, with: $0) }
            try data.write(to: source.appendingPathComponent("\(i).wav"))
        }
        let store = try RecordingLibrary(stateURL: base.appendingPathComponent("state.json"))
        let first = try await store.importDirectory(source, deviceName: "BENCH", destination: output)
        let fast = try await store.importDirectory(source, deviceName: "BENCH", destination: output)
        let full = try await store.importDirectory(source, deviceName: "BENCH", destination: output, fullVerification: true)
        XCTAssertEqual(first.imported, count)
        XCTAssertEqual(fast.fastSkipped, count); XCTAssertEqual(fast.fullHashReads, 0)
        XCTAssertEqual(fast.mediaInspections, 0)
        XCTAssertLessThanOrEqual(fast.fingerprintBytesRead, Int64(count * 6 * IncrementalFiles.blockSize))
        XCTAssertEqual(full.skipped, count); XCTAssertEqual(full.fastSkipped, 0)
        let report: [String: Any] = ["files": count, "audioBytes": count * (payloadSize + 44),
            "firstSeconds": first.elapsedSeconds, "incrementalSeconds": fast.elapsedSeconds,
            "fullVerificationSeconds": full.elapsedSeconds, "incrementalBytesRead": fast.fingerprintBytesRead,
            "incrementalFullHashes": fast.fullHashReads, "incrementalMediaInspections": fast.mediaInspections]
        print("INCREMENTAL_BENCHMARK=" + String(data: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), encoding: .utf8)!)

        // Demonstrate the documented sampling limit and the full-check recovery.
        let altered = source.appendingPathComponent("0.wav")
        let stamp = try IncrementalFiles.stamp(altered)
        let handle = try FileHandle(forWritingTo: altered)
        try handle.seek(toOffset: 2 * 1024 * 1024)
        try handle.write(contentsOf: Data([27])); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp.modified], ofItemAtPath: altered.path)
        let checked = try await store.importDirectory(source, deviceName: "BENCH", destination: output, fullVerification: true)
        XCTAssertEqual(checked.imported, 1)
        let jobCount = await store.snapshot().jobs.count
        XCTAssertEqual(jobCount, count + 1)
    }
}
