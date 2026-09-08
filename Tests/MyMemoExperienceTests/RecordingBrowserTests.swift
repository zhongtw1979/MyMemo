import XCTest
import MyMemoCore
@testable import MyMemoExperience

final class RecordingBrowserTests: XCTestCase {
    func job(_ name: String, device: String = "录音笔", date: Double = 0, bytes: Int64 = 100) throws -> RecordingJob {
        let values: [String: Any] = ["id": UUID().uuidString, "contentHash": "hash", "originalName": name,
            "deviceName": device, "sourcePath": "/tmp/source", "localPath": "/tmp/local", "byteCount": bytes,
            "importedAt": date, "status": "done", "attempts": 1]
        return try JSONDecoder().decode(RecordingJob.self, from: JSONSerialization.data(withJSONObject: values))
    }
    func testNaturalNameOrderAndDescendingDates() throws {
        let a = try job("录音10.wav", date: 10)
        let b = try job("录音2.wav", date: 20)
        XCTAssertEqual(RecordingQuery.apply([a,b], sort: .name, ascending: true).map(\.originalName), [b.originalName,a.originalName])
        XCTAssertEqual(RecordingQuery.apply([a,b], sort: .importedAt, ascending: false).map(\.id), [b.id,a.id])
        XCTAssertEqual(RecordingQuery.apply([a,b], sort: .importedAt, ascending: true).map(\.id), [a.id,b.id])
    }
    func testSearchMetadataAndBodyMatchesRespectStatus() throws {
        let a = try job("访谈.wav", device: "会议录音笔")
        var b = try job("其他.wav"); b.status = .excluded
        XCTAssertEqual(RecordingQuery.apply([a,b], query: "会议", sort: .name).map(\.id), [a.id])
        XCTAssertEqual(RecordingQuery.apply([a,b], query: "预算", contentMatches: [a.id,b.id], sort: .name).map(\.id), [a.id])
        XCTAssertEqual(RecordingQuery.apply([a,b], status: "excluded").map(\.id), [b.id])
    }
    func testSizeAndDeviceSort() throws {
        let a = try job("A.wav", device: "B", bytes: 1000), b = try job("B.wav", device: "A", bytes: 1)
        XCTAssertEqual(RecordingQuery.apply([a,b], sort: .size, ascending: true).map(\.id), [b.id,a.id])
        XCTAssertEqual(RecordingQuery.apply([a,b], sort: .device, ascending: true).map(\.id), [b.id,a.id])
    }
    func testPreviewCacheRefreshAndMarkdownFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let markdown = folder.appendingPathComponent("one.md"), plain = folder.appendingPathComponent("one.txt")
        try "Markdown 原稿".write(to: markdown, atomically: true, encoding: .utf8)
        let reader = TranscriptReader()
        let fallback = try await reader.load(transcriptPath: markdown.path)
        XCTAssertEqual(fallback.text, "Markdown 原稿")
        try "新的纯文本".write(to: plain, atomically: true, encoding: .utf8)
        let cached = try await reader.load(transcriptPath: markdown.path)
        XCTAssertEqual(cached.text, fallback.text)
        let refreshed = try await reader.load(transcriptPath: markdown.path, force: true)
        XCTAssertEqual(refreshed.text, "新的纯文本")
        let reads = await reader.diskReadCount
        XCTAssertEqual(reads, 2)
    }
    func testLargePreviewIsBoundedAndValidChinese() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try String(repeating: "中文会议记录。", count: 10000).write(to: file, atomically: true, encoding: .utf8)
        let reader = TranscriptReader(previewLimit: 1001)
        let doc = try await reader.load(transcriptPath: file.path)
        XCTAssertTrue(doc.truncated); XCTAssertFalse(doc.text.contains("�"))
        XCTAssertLessThanOrEqual(doc.text.utf8.count, 1001)
    }
    func testPersistentChineseSearchAndUpdatedContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("one.txt")
        try "客户讨论预算，Q3 Budget 已确认。".write(to: file, atomically: true, encoding: .utf8)
        var record = try job("项目甲.wav"); record.transcriptPath = file.path
        let index = try TranscriptSearchIndex(url: folder.appendingPathComponent("search.sqlite3"))
        try await index.update(record)
        let found = try await index.search("预算")
        XCTAssertEqual(found, [record.id])
        let combined = try await index.search("项目甲 budget")
        XCTAssertEqual(combined, [record.id])
        let reopened = try TranscriptSearchIndex(url: folder.appendingPathComponent("search.sqlite3"))
        let restored = try await reopened.search("预算")
        XCTAssertEqual(restored, [record.id])
        try "改为讨论交付。".write(to: file, atomically: true, encoding: .utf8)
        try await reopened.update(record)
        let old = try await reopened.search("预算"), new = try await reopened.search("交付")
        XCTAssertTrue(old.isEmpty); XCTAssertEqual(new, [record.id])
        let readsBefore = await reopened.textReadCount
        try await reopened.update(record)
        let readsAfter = await reopened.textReadCount
        XCTAssertEqual(readsBefore, readsAfter)
        let injected = try await reopened.search("\" OR 1=1 --")
        XCTAssertTrue(injected.isEmpty)
    }

    @MainActor func testLateDocumentDoesNotReplaceNewSelection() async throws {
        let selection = TranscriptSelection(loader: { path, _ in
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(path == "slow" ? 150 : 5))
                return TranscriptDocument(text: path, path: path, truncated: false, characterCount: path.count)
            }.value
        })
        selection.select(path: "slow")
        try await Task.sleep(for: .milliseconds(20))
        selection.select(path: "new")
        try await Task.sleep(for: .milliseconds(220))
        guard case .loaded(let doc) = selection.state else { return XCTFail("latest document not loaded") }
        XCTAssertEqual(doc.text, "new")
    }

    func testConcurrentPreviewRequestsReuseTheRead() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try String(repeating: "并发读取测试。", count: 10000).write(to: file, atomically: true, encoding: .utf8)
        let reader = TranscriptReader()
        async let first = reader.load(transcriptPath: file.path)
        async let second = reader.load(transcriptPath: file.path)
        let docs = try await (first, second)
        XCTAssertEqual(docs.0.id, docs.1.id)
        let reads = await reader.diskReadCount
        XCTAssertEqual(reads, 1)
    }

    func testLargeListAndCachedTranscriptPerformance() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = String(repeating: "这是用于测试的会议文字，讨论预算与交付安排。", count: 10000)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let reader = TranscriptReader()
        var start = Date()
        _ = try await reader.load(transcriptPath: file.path)
        let cold = Date().timeIntervalSince(start)
        start = Date()
        _ = try await reader.load(transcriptPath: file.path)
        let warm = Date().timeIntervalSince(start)
        var records: [RecordingJob] = []
        for i in 0..<5000 { records.append(try job("录音\(i).wav", device: i % 2 == 0 ? "项目录音笔" : "访谈设备", date: Double(i))) }
        start = Date()
        let found = RecordingQuery.apply(records, query: "项目", sort: .importedAt, ascending: false)
        let queryTime = Date().timeIntervalSince(start)
        XCTAssertEqual(found.count, 2500)
        let reads = await reader.diskReadCount
        XCTAssertEqual(reads, 1)
        print("BROWSER_BENCHMARK=" + String(data: try JSONSerialization.data(withJSONObject: ["records": 5000, "characters": text.count, "coldReadSeconds": cold, "cachedReadSeconds": warm, "metadataSearchSortSeconds": queryTime], options: .sortedKeys), encoding: .utf8)!)
    }
}
