import Foundation

// A real mono PCM WAV fixture. Text seeds deterministic, distinct sample bytes.
func audioData(_ seed: String) -> Data {
    let bytes = Array(seed.utf8.isEmpty ? [UInt8(128)] : Array(seed.utf8))
    var pcm = Data()
    for i in 0..<1600 {
        var sample = Int16((Int(bytes[i % bytes.count]) - 128) * 128).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    var wav = Data("RIFF".utf8)
    func append32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) } }
    func append16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) } }
    append32(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
    append32(16); append16(1); append16(1); append32(16000); append32(32000); append16(2); append16(16)
    wav.append(Data("data".utf8)); append32(UInt32(pcm.count)); wav.append(pcm)
    return wav
}
