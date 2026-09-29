import BestASRDomain
import CryptoKit
import Foundation

public enum SourceAudioExportMode: String, Codable, Sendable {
  case byteIdenticalWholeSource
  case losslessPCM16WaveRange
}

public enum SourceAudioExportError: Error, Equatable, Sendable {
  case destinationExists
  case invalidFrameRange
  case unsupportedWave
}

public struct SourceAudioExportResult: Codable, Equatable, Sendable {
  public let mode: SourceAudioExportMode
  public let origin: ArchiveAudioOrigin
  public let sourceBytes: Int
  public let exportedBytes: Int
  public let sourceDigestBefore: BestASRDomain.SHA256Digest
  public let sourceDigestAfter: BestASRDomain.SHA256Digest
  public let exportDigest: BestASRDomain.SHA256Digest

  public var sourceUnchanged: Bool {
    sourceDigestBefore == sourceDigestAfter
  }
}

public enum SourceAudioExporter {
  public static func exportWholeSource(
    from source: URL,
    to destination: URL,
    origin: ArchiveAudioOrigin,
    fileManager: FileManager = .default
  ) throws -> SourceAudioExportResult {
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw SourceAudioExportError.destinationExists
    }
    let sourceData = try Data(contentsOf: source)
    let before = try digest(sourceData)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try sourceData.write(to: destination, options: .withoutOverwriting)
    let afterData = try Data(contentsOf: source)
    let exported = try Data(contentsOf: destination)
    return SourceAudioExportResult(
      mode: .byteIdenticalWholeSource,
      origin: origin,
      sourceBytes: sourceData.count,
      exportedBytes: exported.count,
      sourceDigestBefore: before,
      sourceDigestAfter: try digest(afterData),
      exportDigest: try digest(exported)
    )
  }

  public static func exportPCM16WaveRange(
    from source: URL,
    to destination: URL,
    startFrame: Int,
    endFrame: Int,
    origin: ArchiveAudioOrigin,
    fileManager: FileManager = .default
  ) throws -> SourceAudioExportResult {
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw SourceAudioExportError.destinationExists
    }
    let sourceData = try Data(contentsOf: source)
    let before = try digest(sourceData)
    let wave = try PCM16Wave(data: sourceData)
    guard startFrame >= 0, endFrame > startFrame, endFrame <= wave.frameCount
    else {
      throw SourceAudioExportError.invalidFrameRange
    }
    let exported = wave.data(frameRange: startFrame..<endFrame)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try exported.write(to: destination, options: .withoutOverwriting)
    let afterData = try Data(contentsOf: source)
    return SourceAudioExportResult(
      mode: .losslessPCM16WaveRange,
      origin: origin,
      sourceBytes: sourceData.count,
      exportedBytes: exported.count,
      sourceDigestBefore: before,
      sourceDigestAfter: try digest(afterData),
      exportDigest: try digest(exported)
    )
  }

  private static func digest(_ data: Data) throws
    -> BestASRDomain.SHA256Digest
  {
    try BestASRDomain.SHA256Digest(
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
  }
}

private struct PCM16Wave {
  let channelCount: UInt16
  let sampleRate: UInt32
  let blockAlign: UInt16
  let samples: Data

  init(data: Data) throws {
    guard data.count >= 44,
      data.ascii(at: 0, count: 4) == "RIFF",
      data.ascii(at: 8, count: 4) == "WAVE"
    else {
      throw SourceAudioExportError.unsupportedWave
    }
    var cursor = 12
    var format: (UInt16, UInt32, UInt16, UInt16)?
    var sampleData: Data?
    while cursor + 8 <= data.count {
      let chunkID = data.ascii(at: cursor, count: 4)
      let chunkSize = Int(data.uint32LE(at: cursor + 4))
      let contentStart = cursor + 8
      let contentEnd = contentStart + chunkSize
      guard contentEnd <= data.count else {
        throw SourceAudioExportError.unsupportedWave
      }
      if chunkID == "fmt ", chunkSize >= 16 {
        let audioFormat = data.uint16LE(at: contentStart)
        let channels = data.uint16LE(at: contentStart + 2)
        let rate = data.uint32LE(at: contentStart + 4)
        let alignment = data.uint16LE(at: contentStart + 12)
        let bits = data.uint16LE(at: contentStart + 14)
        guard audioFormat == 1, channels > 0, bits == 16,
          alignment == channels * 2
        else {
          throw SourceAudioExportError.unsupportedWave
        }
        format = (channels, rate, alignment, bits)
      } else if chunkID == "data" {
        sampleData = data.subdata(in: contentStart..<contentEnd)
      }
      cursor = contentEnd + (chunkSize.isMultiple(of: 2) ? 0 : 1)
    }
    guard let format, let sampleData,
      sampleData.count.isMultiple(of: Int(format.2))
    else {
      throw SourceAudioExportError.unsupportedWave
    }
    channelCount = format.0
    sampleRate = format.1
    blockAlign = format.2
    samples = sampleData
  }

  var frameCount: Int {
    samples.count / Int(blockAlign)
  }

  func data(frameRange: Range<Int>) -> Data {
    let start = frameRange.lowerBound * Int(blockAlign)
    let end = frameRange.upperBound * Int(blockAlign)
    let selected = samples.subdata(in: start..<end)
    let byteRate = sampleRate * UInt32(blockAlign)
    var output = Data()
    output.appendASCII("RIFF")
    output.appendUInt32LE(UInt32(36 + selected.count))
    output.appendASCII("WAVE")
    output.appendASCII("fmt ")
    output.appendUInt32LE(16)
    output.appendUInt16LE(1)
    output.appendUInt16LE(channelCount)
    output.appendUInt32LE(sampleRate)
    output.appendUInt32LE(byteRate)
    output.appendUInt16LE(blockAlign)
    output.appendUInt16LE(16)
    output.appendASCII("data")
    output.appendUInt32LE(UInt32(selected.count))
    output.append(selected)
    return output
  }
}

extension Data {
  fileprivate func ascii(at offset: Int, count: Int) -> String {
    String(decoding: self[offset..<(offset + count)], as: UTF8.self)
  }

  fileprivate func uint16LE(at offset: Int) -> UInt16 {
    UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
  }

  fileprivate func uint32LE(at offset: Int) -> UInt32 {
    UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }

  fileprivate mutating func appendASCII(_ string: String) {
    append(contentsOf: string.utf8)
  }

  fileprivate mutating func appendUInt16LE(_ value: UInt16) {
    append(UInt8(value & 0xff))
    append(UInt8((value >> 8) & 0xff))
  }

  fileprivate mutating func appendUInt32LE(_ value: UInt32) {
    append(UInt8(value & 0xff))
    append(UInt8((value >> 8) & 0xff))
    append(UInt8((value >> 16) & 0xff))
    append(UInt8((value >> 24) & 0xff))
  }
}
