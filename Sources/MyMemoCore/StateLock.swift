import Foundation
import Darwin

final class StateLock: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MemoError("无法打开运行数据锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw MemoError("已有 MyMemo 正在使用这份录音记录，请从菜单栏打开现有应用。")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
