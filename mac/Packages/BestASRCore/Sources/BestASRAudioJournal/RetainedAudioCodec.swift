import AVFoundation
import BestASRDictation
import BestASRDomain
import BestASRInference
import CryptoKit
import Foundation

/// How a retained recording's file holds its samples, read from its name.
///
/// A recording is journaled as raw PCM (`.pcm`, in the track's own format).
/// After 30 days its 16-bit master is kept in a Core Audio Format file: Apple
/// Lossless (`.lossless.caf`, decodes to exactly the same samples) or, once
/// the user has agreed to it, Opus 24 kbps (`.caf`). A file brought in from
/// elsewhere (Typeless's `.ogg`, an imported `.m4a`) is kept exactly as it
/// came. Everything that reads a recording — playback, re-recognition, the
/// speaker model, export — asks this one type for the samples, so a
/// compressed file is decoded on demand in one place.
public enum RetainedAudioContainer: String, Equatable, Sendable {
  case pcm
  case losslessCAF
  case opusCAF
  case compressedOriginal

  public init(reference: String) {
    let lowered = reference.lowercased()
    if lowered.hasSuffix(".pcm") {
      self = .pcm
    } else if lowered.hasSuffix(RetainedAudioArchiveFormat.lossless.fileSuffix) {
      self = .losslessCAF
    } else if lowered.hasSuffix(RetainedAudioArchiveFormat.opus.fileSuffix) {
      self = .opusCAF
    } else {
      self = .compressedOriginal
    }
  }

  public var isCompressed: Bool { self != .pcm }
}

/// The form a recording older than 30 days is kept in (PRD STORE-001).
public enum RetainedAudioArchiveFormat: String, CaseIterable, Equatable, Sendable {
  /// Apple Lossless in CAF: the 16-bit master, bit for bit, in less space.
  case lossless
  /// Opus 24 kbps in CAF: about a twelfth of the 16-bit master. Not exact;
  /// measured against recognition and the speaker model before use
  /// (TECHNICAL_DESIGN.md「录音压缩的测量」).
  case opus

  /// What a chunk's file name ends with.
  public var fileSuffix: String {
    switch self {
    case .lossless: ".lossless.caf"
    case .opus: ".caf"
    }
  }

  public var container: RetainedAudioContainer {
    switch self {
    case .lossless: .losslessCAF
    case .opus: .opusCAF
    }
  }
}

public enum RetainedAudioCodecError: Error, Equatable, Sendable {
  case digestMismatch
  case decodeFailed
  case encodeFailed
  case encoderUnavailable
  case emptyAudio
  case lengthMismatch(expected: UInt64, actual: UInt64)
  case verificationFailed(String)
}

/// Opus encoding and on-demand decoding of retained recordings, through the
/// system's own codec (AudioToolbox has encoded and decoded Opus in CAF since
/// macOS 10.13; Ogg Opus decodes on the macOS versions this App supports
/// through `AVAudioFile`). No third-party library is involved.
///
/// Two archive formats, both 16 kHz mono in CAF: Apple Lossless (exact) and
/// Opus 24 kbps. Which one the App uses, and the measurement behind that, is
/// in TECHNICAL_DESIGN.md「录音压缩的测量」.
public enum RetainedAudioCodec {
  public static let sampleRateHertz: UInt32 = 16_000
  public static let archiveBitRate = 24_000
  /// Opus codes 20 ms frames (320 samples at 16 kHz). A decoded file whose
  /// length is further than one frame from what was encoded is refused.
  public static let lengthToleranceFrames: UInt64 = 320
  /// Lowest correlation, over 20 ms loudness frames, between the 16-bit
  /// master and its decoded Opus copy for the copy to replace the master
  /// (two seconds or longer).
  /// Opus does not keep the waveform, so this compares loudness over time:
  /// a copy that dropped, shifted or garbled the speech fails it.
  public static let minimumEnvelopeCorrelation = 0.9

  // MARK: - Encoding

  /// Writes 16 kHz mono samples as Opus in a CAF file. The file is written
  /// next to `destination` and renamed into place, so `destination` is either
  /// absent or complete.
  public static func encodeOpus(
    samples: [Float],
    to destination: URL,
    bitRate: Int = archiveBitRate
  ) throws {
    try encode(samples: samples, to: destination, format: .opus, bitRate: bitRate)
  }

  /// Writes 16 kHz mono samples in `format` in a CAF file, atomically.
  /// For `.lossless` the samples must be 16-bit values (`samples(int16LittleEndian:)`),
  /// which then decode back exactly.
  public static func encode(
    samples: [Float],
    to destination: URL,
    format: RetainedAudioArchiveFormat,
    bitRate: Int = archiveBitRate
  ) throws {
    guard !samples.isEmpty else { throw RetainedAudioCodecError.emptyAudio }
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp.caf")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      try write(samples: samples, to: temporary, settings: settings(format, bitRate: bitRate))
    } catch let error as RetainedAudioCodecError {
      throw error
    } catch {
      throw RetainedAudioCodecError.encodeFailed
    }
    // The system writer reserves a 'free' chunk of about 240 KB for metadata
    // it might add later (measured 2026-10-06: 241,294 bytes in front of
    // 11 KB of audio for a 3.8 s take). Nothing is added later, so it goes.
    guard let written = try? Data(contentsOf: temporary),
      let compact = withoutFreeChunks(written)
    else { throw RetainedAudioCodecError.encodeFailed }
    try compact.write(to: temporary)
    let handle = try FileHandle(forUpdating: temporary)
    try handle.synchronize()
    try handle.close()
    let result = temporary.path.withCString { source in
      destination.path.withCString { target in Darwin.rename(source, target) }
    }
    guard result == 0 else { throw RetainedAudioCodecError.encodeFailed }
  }

  static func settings(_ format: RetainedAudioArchiveFormat, bitRate: Int) -> [String: Any] {
    switch format {
    case .opus:
      [
        AVFormatIDKey: kAudioFormatOpus,
        AVSampleRateKey: Double(sampleRateHertz),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: bitRate,
      ]
    case .lossless:
      [
        AVFormatIDKey: kAudioFormatAppleLossless,
        AVSampleRateKey: Double(sampleRateHertz),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitDepthHintKey: 16,
      ]
    }
  }

  private static func write(samples: [Float], to url: URL, settings: [String: Any]) throws {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRateHertz),
        channels: 1, interleaved: false)
    else { throw RetainedAudioCodecError.encoderUnavailable }
    // The file is closed when it goes out of scope; the scope ends before the
    // caller renames it.
    let file: AVAudioFile
    do {
      file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
        interleaved: false)
    } catch {
      throw RetainedAudioCodecError.encoderUnavailable
    }
    let block = 16_000
    var offset = 0
    while offset < samples.count {
      let count = min(block, samples.count - offset)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
        let channel = buffer.floatChannelData?[0]
      else { throw RetainedAudioCodecError.encodeFailed }
      samples.withUnsafeBufferPointer { source in
        channel.update(from: source.baseAddress!.advanced(by: offset), count: count)
      }
      buffer.frameLength = AVAudioFrameCount(count)
      try file.write(from: buffer)
      offset += count
    }
    if #available(macOS 15.0, *) { file.close() }
  }

  /// A CAF file with its 'free' chunks (reserved padding, no content)
  /// removed; nil when it is not a well-formed CAF file.
  static func withoutFreeChunks(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= 8, Array(bytes[0..<4]) == Array("caff".utf8) else { return nil }
    var output = Data(bytes[0..<8])
    var offset = 8
    while offset < bytes.count {
      guard offset + 12 <= bytes.count else { return nil }
      var size: Int64 = 0
      for byte in bytes[(offset + 4)..<(offset + 12)] { size = size << 8 | Int64(byte) }
      let end: Int
      if size < 0 {
        // A data chunk of unknown length runs to the end of the file.
        end = bytes.count
      } else {
        guard size <= Int64(bytes.count - offset - 12) else { return nil }
        end = offset + 12 + Int(size)
      }
      if Array(bytes[offset..<(offset + 4)]) != Array("free".utf8) {
        output.append(contentsOf: bytes[offset..<end])
      }
      offset = end
    }
    return output
  }

  // MARK: - Decoding

  /// Every sample of a file `AVAudioFile` can read, as 16 kHz mono float.
  /// Several channels are averaged; another rate is converted.
  public static func decodeMono16k(_ url: URL) throws -> [Float] {
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      throw RetainedAudioCodecError.decodeFailed
    }
    let format = file.processingFormat
    guard file.length > 0, format.sampleRate > 0, format.channelCount > 0 else {
      throw RetainedAudioCodecError.emptyAudio
    }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
    else { throw RetainedAudioCodecError.decodeFailed }
    do {
      try file.read(into: buffer)
    } catch {
      throw RetainedAudioCodecError.decodeFailed
    }
    guard let channels = buffer.floatChannelData else {
      throw RetainedAudioCodecError.decodeFailed
    }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: frames)
    for channel in 0..<channelCount {
      let source = channels[channel]
      for index in 0..<frames { mono[index] += source[index] }
    }
    if channelCount > 1 {
      let scale = 1 / Float(channelCount)
      for index in 0..<frames { mono[index] *= scale }
    }
    guard abs(format.sampleRate - Double(sampleRateHertz)) > 0.5 else { return mono }
    return resample(mono, from: format.sampleRate, to: Double(sampleRateHertz))
  }

  /// Linear-phase resampling through `AVAudioConverter`, for the rare
  /// compressed original that is not stored at 16 kHz.
  static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
    guard
      let input = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
      let output = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: input, to: output),
      let inBuffer = AVAudioPCMBuffer(
        pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))
    else { return samples }
    samples.withUnsafeBufferPointer { pointer in
      inBuffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
    }
    inBuffer.frameLength = AVAudioFrameCount(samples.count)
    let capacity = AVAudioFrameCount(Double(samples.count) * target / source + 1_024)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
    else { return samples }
    var supplied = false
    var conversionError: NSError?
    _ = converter.convert(to: outBuffer, error: &conversionError) { _, status in
      if supplied {
        status.pointee = .endOfStream
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return inBuffer
    }
    guard conversionError == nil, let channel = outBuffer.floatChannelData?[0] else {
      return samples
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
  }

  // MARK: - One read path for every reader

  /// The bytes a retained chunk stands for, in its track's PCM format.
  ///
  /// A `.pcm` file is returned as stored once its digest matches. A
  /// compressed file is checked against its digest, decoded to 16 kHz mono,
  /// and fitted to `frameCount` (Opus works in 20 ms frames, so a decoder may
  /// hand back a few samples more or less than were encoded; more than one
  /// frame off is an error). It is then written in `encoding`, which for a
  /// compressed chunk is the 16-bit format its track records.
  public static func pcmBytes(
    at url: URL,
    expectedDigest: String,
    frameCount: UInt64?,
    encoding: PCMEncoding
  ) throws -> Data {
    let stored = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard digest(stored) == expectedDigest.lowercased() else {
      throw RetainedAudioCodecError.digestMismatch
    }
    guard RetainedAudioContainer(reference: url.lastPathComponent).isCompressed else {
      return stored
    }
    var samples = try decodeMono16k(url)
    if let frameCount {
      let actual = UInt64(samples.count)
      let difference = actual > frameCount ? actual - frameCount : frameCount - actual
      guard difference <= lengthToleranceFrames else {
        throw RetainedAudioCodecError.lengthMismatch(expected: frameCount, actual: actual)
      }
      if actual > frameCount {
        samples.removeLast(Int(actual - frameCount))
      } else if actual < frameCount {
        samples.append(contentsOf: repeatElement(0, count: Int(frameCount - actual)))
      }
    }
    switch encoding {
    case .int16LittleEndian: return int16LittleEndian(samples)
    case .float32LittleEndian: return float32LittleEndian(samples)
    }
  }

  // MARK: - Verification

  /// Checks that `encoded` decodes to the same recording as `master`. For
  /// `.lossless`: exactly the same 16-bit samples (returns 1). For `.opus`:
  /// the same length within one Opus frame and the same loudness over time
  /// (returns the envelope correlation it measured).
  @discardableResult
  public static func verify(
    encoded: URL, master: [Float], format: RetainedAudioArchiveFormat = .opus
  ) throws -> Double {
    let decoded = try decodeMono16k(encoded)
    if format == .lossless {
      guard decoded.count == master.count,
        int16LittleEndian(decoded) == int16LittleEndian(master)
      else {
        throw RetainedAudioCodecError.verificationFailed("lossless-samples-differ")
      }
      return 1
    }
    let expected = UInt64(master.count)
    let actual = UInt64(decoded.count)
    let difference = actual > expected ? actual - expected : expected - actual
    guard difference <= lengthToleranceFrames else {
      throw RetainedAudioCodecError.lengthMismatch(expected: expected, actual: actual)
    }
    // Under two seconds has too few 20 ms frames for the correlation to be
    // stable (a 1.6 s take of the user's measured 0.889 against a median of
    // 0.996), and near-silence has no envelope to compare: for those the
    // length check is the check.
    guard master.count >= Int(sampleRateHertz) * 2 else { return .nan }
    let correlation = envelopeCorrelation(master, decoded)
    guard correlation.isNaN || correlation >= minimumEnvelopeCorrelation else {
      throw RetainedAudioCodecError.verificationFailed(
        "envelope-correlation-\(String(format: "%.3f", correlation))")
    }
    return correlation
  }

  /// Pearson correlation of 20 ms RMS loudness (in dB) of two signals over
  /// their common length. NaN when either is silent throughout.
  public static func envelopeCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Double {
    let frame = 320
    let count = min(lhs.count, rhs.count) / frame
    guard count >= 2 else { return .nan }
    func envelope(_ signal: [Float]) -> [Double] {
      (0..<count).map { index in
        var sum = 0.0
        for sample in signal[(index * frame)..<((index + 1) * frame)] {
          sum += Double(sample) * Double(sample)
        }
        return 10 * log10(sum / Double(frame) + 1e-10)
      }
    }
    let a = envelope(lhs)
    let b = envelope(rhs)
    // Frames quieter than -60 dBFS in both carry no speech.
    let pairs = zip(a, b).filter { $0.0 > -60 || $0.1 > -60 }
    guard pairs.count >= 2 else { return .nan }
    let meanA = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
    let meanB = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
    var covariance = 0.0
    var varianceA = 0.0
    var varianceB = 0.0
    for (x, y) in pairs {
      covariance += (x - meanA) * (y - meanB)
      varianceA += (x - meanA) * (x - meanA)
      varianceB += (y - meanB) * (y - meanB)
    }
    guard varianceA > 1e-9, varianceB > 1e-9 else { return .nan }
    return covariance / (varianceA * varianceB).squareRoot()
  }

  // MARK: - Sample formats

  public static func samples(int16LittleEndian data: Data) -> [Float] {
    var output = [Float]()
    output.reserveCapacity(data.count / 2)
    data.withUnsafeBytes { raw in
      var index = 0
      while index + 1 < data.count {
        let bits = raw.loadUnaligned(fromByteOffset: index, as: UInt16.self).littleEndian
        output.append(Float(Int16(bitPattern: bits)) / 32_768)
        index += 2
      }
    }
    return output
  }

  /// The inverse of `samples(int16LittleEndian:)` (both scale by 32,768, as
  /// Core Audio does), so 16-bit samples survive a round trip exactly.
  public static func int16LittleEndian(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
      let scaled = (sample * 32_768).rounded()
      let value = Int16(max(-32_768, min(32_767, scaled)))
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  public static func float32LittleEndian(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
      withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func fileDigest(_ url: URL) throws -> String {
    digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
  }
}

/// A recording that has no journal of its own and keeps its audio as the
/// file it arrived in — the Typeless dictations, kept byte for byte as Ogg
/// Opus — played through the same player as everything else: one track of
/// 16 kHz mono, one range covering the file, decoded on demand by
/// `RetainedAudioCodec.pcmBytes`.
public enum RetainedOriginalPlayback {
  public static func source(
    sessionID: UUID,
    assetID: UUID,
    assetReference: String,
    digest: String,
    mediaType: String,
    durationNanoseconds: UInt64?
  ) -> (descriptor: CaptureTrackDescriptor, ranges: [AudioRangeInput])? {
    guard mediaType.lowercased().hasPrefix("audio/"),
      RetainedAudioContainer(reference: assetReference) == .compressedOriginal,
      let durationNanoseconds, durationNanoseconds > 0
    else { return nil }
    let descriptor = CaptureTrackDescriptor(
      id: TrackID(assetID), role: .importedSource, deviceUID: "retained-original",
      sampleRateHertz: RetainedAudioCodec.sampleRateHertz, channelCount: 1,
      encoding: .int16LittleEndian, interleaved: true)
    let range = AudioRangeInput(
      sourceID: sessionID, trackID: assetID, assetReference: assetReference,
      contentDigest: digest.lowercased(), monotonicStartNanoseconds: 0,
      monotonicEndNanoseconds: durationNanoseconds,
      sampleRateHertz: RetainedAudioCodec.sampleRateHertz, channelCount: 1)
    return (descriptor, [range])
  }
}
