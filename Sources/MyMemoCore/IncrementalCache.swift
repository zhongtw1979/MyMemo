import Foundation
import CryptoKit

public struct FileStamp: Codable, Equatable, Sendable {
    public var size: Int64
    public var modified: Date
}

public struct ScanCacheEntry: Codable, Sendable {
    public var policy = 1
    public var sourceStamp: FileStamp
    public var sourceFingerprint: String
    public var kind: String
    public var recordingID: UUID?
    public var contentHash: String?
    public var localStamp: FileStamp?
    public var localFingerprint: String?
}

enum IncrementalFiles {
    static let blockSize = 64 * 1024
    static func key(deviceID: String?, root: URL, file: URL) -> String {
        // Enumeration can yield /private/var while the selected URL spells /var.
        // Normalize both sides before deriving the device-relative path.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let identity = deviceID.flatMap { $0.isEmpty ? nil : $0 }.map { "volume:\($0)" } ?? "folder:\(rootPath)"
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        let value = "\(identity.utf8.count):\(identity)\(relative)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func stamp(_ url: URL) throws -> FileStamp {
        var fresh = url; fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, let modified = values.contentModificationDate else {
            throw MemoError("文件为空、无法读取或不是普通文件。")
        }
        return FileStamp(size: Int64(size), modified: modified)
    }
    /// Bounded fingerprint, not a full integrity proof. Full verification remains
    /// available for changes that preserve timestamps and unsampled regions.
    static func fingerprint(_ url: URL, size: Int64) throws -> (digest: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        hash.update(data: Data("mymemo-sample-v1:\(size):".utf8))
        let block = Int64(blockSize)
        let offsets: [Int64] = size <= block * 3 ? [0] : [0, size / 2 - block / 2, size - block]
        var read: Int64 = 0
        for offset in offsets {
            try Task.checkCancellation()
            let length = size <= block * 3 ? Int(size) : blockSize
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw MemoError("读取过程中录音文件发生变化，请重新扫描。")
            }
            hash.update(data: Data("\(offset):\(length):".utf8)); hash.update(data: data)
            read += Int64(data.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), read)
    }
}
