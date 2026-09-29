import CoreML
import Darwin
import Foundation

private struct IdentityManifest: Decodable {
  let entries: [IdentityEntry]
}

private struct IdentityEntry: Decodable {
  let sampleID: String
}

private struct EmbeddingRecord: Encodable {
  let sampleID: String
  let embedding: [Float]
}

private struct ProbeOutput: Encodable {
  let schemaVersion: Int
  let kind: String
  let modelFamily: String
  let dimension: Int
  let records: [EmbeddingRecord]
}

private struct PCMBuffer {
  let sampleRate: Int
  let samples: [Float]
}

private enum ProbeError: Error {
  case invalidArguments
  case invalidModelShape(String)
  case invalidOutput(String)
  case invalidWave(String)
}

private func value(after name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return nil }
  return arguments[index + 1]
}

private func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
  String(decoding: data[offset..<(offset + count)], as: UTF8.self)
}

private func uint16LE(_ data: Data, _ offset: Int) -> UInt16 {
  UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func uint32LE(_ data: Data, _ offset: Int) -> UInt32 {
  UInt32(data[offset])
    | (UInt32(data[offset + 1]) << 8)
    | (UInt32(data[offset + 2]) << 16)
    | (UInt32(data[offset + 3]) << 24)
}

private func readWave(_ url: URL) throws -> PCMBuffer {
  let data = try Data(contentsOf: url)
  guard data.count >= 44, ascii(data, 0, 4) == "RIFF",
    ascii(data, 8, 4) == "WAVE"
  else {
    throw ProbeError.invalidWave(url.lastPathComponent)
  }
  var offset = 12
  var format: UInt16?
  var channels: UInt16?
  var rate: UInt32?
  var bits: UInt16?
  var payload: Data?
  while offset + 8 <= data.count {
    let chunkID = ascii(data, offset, 4)
    let size = Int(uint32LE(data, offset + 4))
    let start = offset + 8
    let end = start + size
    guard end <= data.count else {
      throw ProbeError.invalidWave(url.lastPathComponent)
    }
    if chunkID == "fmt ", size >= 16 {
      format = uint16LE(data, start)
      channels = uint16LE(data, start + 2)
      rate = uint32LE(data, start + 4)
      bits = uint16LE(data, start + 14)
    } else if chunkID == "data" {
      payload = data.subdata(in: start..<end)
    }
    offset = end + (size % 2)
  }
  guard format == 1, channels == 1, let rate, rate == 16_000, bits == 16,
    let payload, payload.count.isMultiple(of: 2)
  else {
    throw ProbeError.invalidWave(url.lastPathComponent)
  }
  var samples: [Float] = []
  samples.reserveCapacity(payload.count / 2)
  var index = 0
  while index < payload.count {
    samples.append(
      Float(Int16(bitPattern: uint16LE(payload, index))) / 32_768
    )
    index += 2
  }
  return PCMBuffer(sampleRate: Int(rate), samples: samples)
}

private func activityBounds(_ samples: [Float]) -> Range<Int> {
  let frameSize = 320
  let frames = (samples.count + frameSize - 1) / frameSize
  var rms = [Float](repeating: 0, count: frames)
  for frame in 0..<frames {
    let start = frame * frameSize
    let end = min(samples.count, start + frameSize)
    guard start < end else { continue }
    var sum: Float = 0
    for index in start..<end { sum += samples[index] * samples[index] }
    rms[frame] = sqrt(sum / Float(end - start))
  }
  let threshold = max(0.0025, (rms.max() ?? 0) * 0.04)
  let active = rms.indices.filter { rms[$0] >= threshold }
  guard let first = active.first, let last = active.last else {
    return 0..<samples.count
  }
  return (first * frameSize)..<min(samples.count, (last + 1) * frameSize)
}

private func normalized(_ vector: [Float]) -> [Float] {
  let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
  guard norm > 0 else { return vector }
  return vector.map { $0 / norm }
}

private final class Embedder {
  private let preprocessor: MLModel
  private let embedder: MLModel
  private let waveformLength: Int
  private let maskCount: Int
  private let maskFrameCount: Int
  private let embeddingDimension: Int

  init(preprocessorURL: URL, embedderURL: URL) throws {
    let preprocessorConfiguration = MLModelConfiguration()
    preprocessorConfiguration.computeUnits = .cpuOnly
    preprocessor = try MLModel(
      contentsOf: preprocessorURL,
      configuration: preprocessorConfiguration
    )
    let embedderConfiguration = MLModelConfiguration()
    embedderConfiguration.computeUnits = .cpuAndNeuralEngine
    embedder = try MLModel(
      contentsOf: embedderURL,
      configuration: embedderConfiguration
    )
    guard
      let waveformShape = preprocessor.modelDescription
        .inputDescriptionsByName["waveforms"]?.multiArrayConstraint?.shape,
      waveformShape.count == 2,
      let maskShape = embedder.modelDescription
        .inputDescriptionsByName["speaker_masks"]?.multiArrayConstraint?.shape,
      maskShape.count == 3,
      let outputShape = embedder.modelDescription
        .outputDescriptionsByName["speaker_embeddings"]?.multiArrayConstraint?.shape,
      outputShape.count == 3
    else {
      throw ProbeError.invalidModelShape("missing expected arrays")
    }
    waveformLength = waveformShape[1].intValue
    maskCount = maskShape[1].intValue
    maskFrameCount = maskShape[2].intValue
    embeddingDimension = outputShape[2].intValue
  }

  var dimension: Int { embeddingDimension }

  func embedding(_ audio: PCMBuffer) throws -> [Float] {
    guard audio.samples.count <= waveformLength else {
      throw ProbeError.invalidModelShape("audio exceeds model window")
    }
    let waveforms = try MLMultiArray(
      shape: [1, NSNumber(value: waveformLength)],
      dataType: .float16
    )
    memset(
      waveforms.dataPointer,
      0,
      waveforms.count * MemoryLayout<UInt16>.size
    )
    for index in audio.samples.indices {
      waveforms[[0, NSNumber(value: index)] as [NSNumber]] = NSNumber(
        value: audio.samples[index])
    }
    let preprocessorInput = try MLDictionaryFeatureProvider(dictionary: [
      "waveforms": MLFeatureValue(multiArray: waveforms)
    ])
    let preprocessorResult = try preprocessor.prediction(from: preprocessorInput)
    guard
      let features =
        preprocessorResult
        .featureValue(for: "preprocessor_output_1")?.multiArrayValue
    else {
      throw ProbeError.invalidOutput("preprocessor_output_1")
    }

    let masks = try MLMultiArray(
      shape: [1, NSNumber(value: maskCount), NSNumber(value: maskFrameCount)],
      dataType: .float16
    )
    memset(
      masks.dataPointer,
      0,
      masks.count * MemoryLayout<UInt16>.size
    )
    let activity = activityBounds(audio.samples)
    let firstFrame = max(
      0,
      Int(
        floor(
          Double(activity.lowerBound) / Double(waveformLength)
            * Double(maskFrameCount)))
    )
    let lastFrame = min(
      maskFrameCount,
      Int(
        ceil(
          Double(activity.upperBound) / Double(waveformLength)
            * Double(maskFrameCount)))
    )
    for frame in firstFrame..<lastFrame {
      masks[[0, 0, NSNumber(value: frame)] as [NSNumber]] = 1
    }
    let input = try MLDictionaryFeatureProvider(dictionary: [
      "preprocessor_output_1": MLFeatureValue(multiArray: features),
      "speaker_masks": MLFeatureValue(multiArray: masks),
    ])
    let result = try embedder.prediction(from: input)
    guard
      let embeddings =
        result
        .featureValue(for: "speaker_embeddings")?.multiArrayValue
    else {
      throw ProbeError.invalidOutput("speaker_embeddings")
    }
    let vector = (0..<embeddingDimension).map {
      embeddings[[0, 0, NSNumber(value: $0)] as [NSNumber]].floatValue
    }
    return normalized(vector)
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard
    let preprocessorPath = value(after: "--preprocessor", in: arguments),
    let embedderPath = value(after: "--embedder", in: arguments),
    let manifestPath = value(after: "--manifest", in: arguments),
    let audioDirectoryPath = value(after: "--audio-dir", in: arguments),
    let outputPath = value(after: "--output", in: arguments)
  else {
    throw ProbeError.invalidArguments
  }
  let manifest = try JSONDecoder().decode(
    IdentityManifest.self,
    from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
  )
  let model = try Embedder(
    preprocessorURL: URL(fileURLWithPath: preprocessorPath),
    embedderURL: URL(fileURLWithPath: embedderPath)
  )
  let audioDirectory = URL(
    fileURLWithPath: audioDirectoryPath,
    isDirectory: true
  )
  var records: [EmbeddingRecord] = []
  for entry in manifest.entries {
    let audio = try readWave(
      audioDirectory.appendingPathComponent("\(entry.sampleID).wav")
    )
    records.append(
      EmbeddingRecord(
        sampleID: entry.sampleID,
        embedding: try model.embedding(audio)
      ))
  }
  let output = ProbeOutput(
    schemaVersion: 1,
    kind: "speaker-embedding-probe-output",
    modelFamily: "argmax-speakerkit-coreml",
    dimension: model.dimension,
    records: records
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(output).write(
    to: URL(fileURLWithPath: outputPath),
    options: .atomic
  )
} catch {
  FileHandle.standardError.write(Data("ArgmaxEmbeddingProbe failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
