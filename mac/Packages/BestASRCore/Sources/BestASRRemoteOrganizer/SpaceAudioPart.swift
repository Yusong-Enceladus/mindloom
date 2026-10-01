import AVFoundation
import Foundation
import MindloomSpaces

/// A meeting part's audio for the members of a space (v8 C1): exactly the
/// part's time range cut out of the recording kept on this Mac, mixed to
/// mono, AAC at 16 kHz. Pauses inside the part are silence, so the sound is
/// as long as the part the signed op declares (members check it before they
/// play: `SpaceAudioCheck`). The whole recording never leaves.
public enum SpaceAudioPart {
  public static let sampleRate = 16_000
  public static let bitRate = 32_000

  public enum PartError: Error, Equatable, Sendable {
    /// No stored audio covers the part.
    case noAudio
    /// The part is the whole recording, empty, or longer than 15 minutes.
    case notAPart
    case encoding
  }

  /// One stored chunk of the recording: where it sits on the monotonic
  /// clock, and its samples mixed to mono at its own rate.
  public struct Chunk: Sendable {
    public let startNS: UInt64
    public let endNS: UInt64
    public let sampleRate: Int
    public let mono: [Float]

    public init(startNS: UInt64, endNS: UInt64, sampleRate: Int, mono: [Float]) {
      self.startNS = startNS
      self.endNS = endNS
      self.sampleRate = sampleRate
      self.mono = mono
    }
  }

  /// `[startNS, endNS)` of the recording at 16 kHz, gaps as silence.
  public static func cut(_ chunks: [Chunk], startNS: UInt64, endNS: UInt64) throws -> [Float] {
    guard endNS > startNS,
      Double(endNS - startNS) / 1_000_000 <= Double(SpaceEngine.maximumSegmentMS)
    else { throw PartError.notAPart }
    let count = Int((Double(endNS - startNS) / 1_000_000_000 * Double(sampleRate)).rounded())
    var out = [Float](repeating: 0, count: count)
    var covered = false
    let rate = Double(sampleRate)
    for chunk in chunks where chunk.endNS > startNS && chunk.startNS < endNS && chunk.sampleRate > 0
    {
      // Only the output samples this chunk covers.
      let from =
        chunk.startNS > startNS
        ? Int((Double(chunk.startNS - startNS) / 1_000_000_000 * rate).rounded(.up)) : 0
      let to = min(
        count, Int((Double(min(chunk.endNS, endNS) - startNS) / 1_000_000_000 * rate).rounded(.up)))
      guard from < to else { continue }
      for index in from..<to {
        let t = startNS + UInt64(Double(index) / rate * 1_000_000_000)
        guard t >= chunk.startNS, t < chunk.endNS else { continue }
        let position = Double(t - chunk.startNS) / 1_000_000_000 * Double(chunk.sampleRate)
        let left = Int(position)
        guard left < chunk.mono.count else { continue }
        let right = min(left + 1, chunk.mono.count - 1)
        let fraction = Float(position - Double(left))
        // Tracks of one recording (the room, the remote side) are mixed.
        out[index] += chunk.mono[left] * (1 - fraction) + chunk.mono[right] * fraction
        covered = true
      }
    }
    guard covered else { throw PartError.noAudio }
    return out
  }

  /// AAC in an M4A container, mono, 16 kHz (through a private temporary file
  /// that is removed before this returns).
  public static func encode(_ samples: [Float], directory: URL) throws -> Data {
    guard !samples.isEmpty,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1,
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else { throw PartError.encoding }
    for (index, value) in samples.enumerated() { channel[0][index] = max(-1, min(1, value)) }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let url = try privateFile(directory, ext: "m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      let file = try AVAudioFile(
        forWriting: url,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
      try file.write(from: buffer)
    } catch { throw PartError.encoding }
    return try Data(contentsOf: url)
  }

  /// The decoded length of an audio file's bytes, in milliseconds.
  public static func durationMS(of data: Data, directory: URL, ext: String = "m4a") throws -> Int {
    let url = try privateFile(directory, ext: ext)
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url, options: [.atomic])
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    guard rate > 0 else { throw PartError.encoding }
    return Int((Double(file.length) / rate * 1000).rounded())
  }

  /// The audio of a part ready to share: cut, encoded, checked against the
  /// part's own length the way members will check it.
  public static func make(
    _ chunks: [Chunk], recordingStartNS: UInt64, segment: SpaceSegmentRef, directory: URL
  ) throws -> Data {
    guard let whole = segment.recordingMS,
      SpaceAudioCheck.isPart(lengthMS: segment.lengthMS, recordingMS: whole),
      segment.lengthMS <= SpaceEngine.maximumSegmentMS
    else { throw PartError.notAPart }
    let start = recordingStartNS + UInt64(segment.startMS) * 1_000_000
    let end = recordingStartNS + UInt64(segment.endMS) * 1_000_000
    let audio = try encode(try cut(chunks, startNS: start, endNS: end), directory: directory)
    let length = try durationMS(of: audio, directory: directory)
    guard SpaceAudioCheck.ok(durationMS: length, segment: segment) else { throw PartError.encoding }
    return audio
  }

  static func privateFile(_ directory: URL, ext: String) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory.appendingPathComponent(".part-\(UUID().uuidString.lowercased()).\(ext)")
  }
}
