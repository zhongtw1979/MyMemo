import Foundation
import AVFoundation

public enum MediaKind: String, Sendable {
    case audio, video, noAudio, unreadable
    public var reason: String {
        switch self {
        case .audio: "纯音频"
        case .video: "含视频轨道，已跳过"
        case .noAudio: "没有音轨，已跳过"
        case .unreadable: "文件不存在或无法确认是纯音频，已跳过"
        }
    }
}

public enum MediaInspector {
    /// Inspect container tracks before any copy. Extensions only limit discovery.
    public static func inspect(_ file: URL, useFFprobe: Bool = true) async -> MediaKind {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else { return .unreadable }
        let asset = AVURLAsset(url: file)
        var native: MediaKind = .unreadable
        do {
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            if !video.isEmpty { native = .video }
            else if !audio.isEmpty { native = .audio }
            else { native = .noAudio }
        } catch { }
        // FFprobe handles additional audio codecs and distinguishes embedded album
        // artwork from moving video. Without it, ambiguous media is not imported.
        // AVFoundation can choose an audio-only reader for a mislabeled .wav.
        // Never accept an ISO media container through that extension-based path.
        if let handle = try? FileHandle(forReadingFrom: file) {
            let header = try? handle.read(upToCount: 16)
            try? handle.close()
            if let header, header.count >= 8, String(data: header[4..<8], encoding: .ascii) == "ftyp",
               !["mp4", "m4a", "m4b", "mov"].contains(file.pathExtension.lowercased()) { native = .unreadable }
        }
        guard useFFprobe, let executable = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return native }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MyMemo-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            try await ChildProcess.run(executable: executable,
                arguments: ["-v", "error", "-show_entries", "stream=codec_type:stream_disposition=attached_pic", "-of", "json", file.path],
                timeout: 15, failureMessage: "无法读取媒体轨道。", outputURL: output)
            let probe = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: output))
            guard let streams = probe.streams else { return native }
            if streams.contains(where: { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }) { return .video }
            return streams.contains(where: { $0.codec_type == "audio" }) ? .audio : .noAudio
        } catch { return .unreadable }
    }

    private struct Probe: Decodable {
        var streams: [Stream]?
        struct Stream: Decodable {
            var codec_type: String?
            var disposition: Disposition?
            struct Disposition: Decodable { var attached_pic: Int? }
        }
    }
}
