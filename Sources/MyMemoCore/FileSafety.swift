import Foundation
import CryptoKit

enum FileSafety {
    static let extensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "wma", "amr", "ogg", "opus", "mp4", "dss", "ds2"]

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let a = child.resolvingSymlinksInPath().standardizedFileURL.path
        let b = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return a == b || a.hasPrefix(b == "/" ? "/" : b + "/")
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = ""
        for character in cleaned {
            if (bounded + String(character)).utf8.count > 120 { break }
            bounded.append(character)
        }
        return bounded.isEmpty || bounded == "." || bounded == ".." ? "录音设备" : bounded
    }

    static func hash(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copy into a unique file on the destination filesystem, sync, and verify the bytes.
    static func stage(_ source: URL, in directory: URL) throws -> (url: URL, hash: String, size: Int64) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let before = try source.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, before.isSymbolicLink != true else { throw MemoError("已跳过链接或非常规文件。") }
        guard let size = before.fileSize, size > 0 else { throw MemoError("录音文件为空。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(available) < Int64(size) + 10 * 1024 * 1024 {
            throw MemoError("保存目录所在磁盘空间不足。")
        }
        let temp = directory.appendingPathComponent(".mymemo-\(UUID().uuidString).partial")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: temp) } }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw MemoError("无法创建录音副本。") }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var digest = SHA256()
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            digest.update(data: chunk)
            copied += Int64(chunk.count)
        }
        try output.synchronize()
        var freshSource = source
        freshSource.removeAllCachedResourceValues()
        let after = try freshSource.resourceValues(forKeys: keys)
        guard copied == Int64(size), before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate else {
            throw MemoError("复制期间录音文件发生变化，请停止录音后重新扫描。")
        }
        let sourceHash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard try hash(temp) == sourceHash else { throw MemoError("录音副本校验失败，请重新导入。") }
        succeeded = true
        return (temp, sourceHash, copied)
    }
}
