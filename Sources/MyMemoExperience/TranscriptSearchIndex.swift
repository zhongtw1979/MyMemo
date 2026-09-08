import Foundation
import SQLite3
import MyMemoCore

/// Local, disposable full-text cache. Never changes recordings or transcript files.
public actor TranscriptSearchIndex {
    private let db: OpaquePointer
    private var usesFTS = false
    public private(set) var textReadCount = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw MemoError("无法打开本机文字搜索索引。文件名搜索仍可使用。")
        }
        db = handle
        sqlite3_busy_timeout(handle, 1500)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS documents (
          id TEXT PRIMARY KEY, path TEXT NOT NULL, bytes INTEGER NOT NULL,
          modified REAL NOT NULL, metadata TEXT NOT NULL, body TEXT NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw MemoError("文字索引无法初始化，录音和文字稿不受影响。")
        }
        // FTS accelerates longer keywords; short Chinese words use exact substring matching.
        let fts = """
        CREATE VIRTUAL TABLE IF NOT EXISTS document_search USING fts5(body, content='documents', content_rowid='rowid', tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
          INSERT INTO document_search(rowid,body) VALUES(new.rowid,new.body); END;
        CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
          INSERT INTO document_search(document_search,rowid,body) VALUES('delete',old.rowid,old.body); END;
        CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
          INSERT INTO document_search(document_search,rowid,body) VALUES('delete',old.rowid,old.body);
          INSERT INTO document_search(rowid,body) VALUES(new.rowid,new.body); END;
        """
        usesFTS = sqlite3_exec(handle, fts, nil, nil, nil) == SQLITE_OK
    }
    deinit { sqlite3_close(db) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MemoError("本机文字索引暂时不可用，文件名搜索仍可使用。")
        }
        return statement
    }
    private func bind(_ text: String, to statement: OpaquePointer, at position: Int32) {
        sqlite3_bind_text(statement, position, text, -1, Self.transient)
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: bytes)
    }
    private func remove(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM documents WHERE id=?")
        defer { sqlite3_finalize(statement) }; bind(id.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MemoError("无法更新文字索引。") }
    }
    public func prune(keeping ids: Set<UUID>) throws {
        let statement = try prepare("SELECT id FROM documents")
        var obsolete: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: string(statement, 0)), !ids.contains(id) { obsolete.append(id) }
        }
        sqlite3_finalize(statement)
        for id in obsolete { try remove(id) }
    }
    @discardableResult public func update(_ job: RecordingJob, force: Bool = false) async throws -> Bool {
        guard let path = job.transcriptPath else { try remove(job.id); return false }
        let file: TranscriptFile
        do { file = try await Task.detached(priority: .utility) { try TranscriptFile.resolve(path) }.value }
        catch { try remove(job.id); throw error }
        try Task.checkCancellation()
        let metadata = job.originalName + "\n" + job.deviceName
        if !force {
            let statement = try prepare("SELECT path,bytes,modified,metadata FROM documents WHERE id=?")
            bind(job.id.uuidString, to: statement, at: 1)
            let same = sqlite3_step(statement) == SQLITE_ROW && string(statement, 0) == file.path && sqlite3_column_int64(statement, 1) == file.size && sqlite3_column_double(statement, 2) == file.modified && string(statement, 3) == metadata
            sqlite3_finalize(statement)
            if same { return false }
        }
        let document: TranscriptDocument
        do { document = try await Task.detached(priority: .utility) { try file.read(limit: 32 * 1024 * 1024, requireComplete: true) }.value }
        catch { try remove(job.id); throw error }
        try Task.checkCancellation(); textReadCount += 1
        let body = RecordingQuery.normalize(metadata + "\n" + document.text)
        let statement = try prepare("INSERT INTO documents(id,path,bytes,modified,metadata,body) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,bytes=excluded.bytes,modified=excluded.modified,metadata=excluded.metadata,body=excluded.body")
        defer { sqlite3_finalize(statement) }
        bind(job.id.uuidString, to: statement, at: 1); bind(file.path, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, file.size); sqlite3_bind_double(statement, 4, file.modified)
        bind(metadata, to: statement, at: 5); bind(body, to: statement, at: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MemoError("无法保存文字搜索索引。") }
        return true
    }
    public func search(_ query: String) throws -> Set<UUID> {
        let words = RecordingQuery.terms(query)
        guard !words.isEmpty else { return [] }
        let long = usesFTS ? words.filter { $0.count >= 3 } : []
        let short = usesFTS ? words.filter { $0.count < 3 } : words
        var conditions: [String] = [], parameters: [String] = []
        if !long.isEmpty {
            conditions.append("rowid IN (SELECT rowid FROM document_search WHERE document_search MATCH ?)")
            parameters.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        for word in short { conditions.append("instr(body, ?) > 0"); parameters.append(word) }
        let statement = try prepare("SELECT id FROM documents WHERE " + conditions.joined(separator: " AND "))
        defer { sqlite3_finalize(statement) }
        for (i, value) in parameters.enumerated() { bind(value, to: statement, at: Int32(i + 1)) }
        var result: Set<UUID> = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            if let id = UUID(uuidString: string(statement, 0)) { result.insert(id) }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw MemoError("正文搜索暂时失败，请缩短关键词后重试。") }
        return result
    }
}
