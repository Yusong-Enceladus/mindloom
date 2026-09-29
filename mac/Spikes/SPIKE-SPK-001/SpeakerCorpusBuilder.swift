import Foundation

private struct Recipe: Decodable {
  let schemaVersion: Int
  let sampleID: String
  let sampleRate: Int
  let mode: String
  let clips: [Clip]
  let effects: Effects?
}

private struct Clip: Decodable {
  let assetID: String
  let path: String
  let speakerID: String
  let startMilliseconds: Double
  let gain: Float
  let sourceStartMilliseconds: Double?
  let sourceDurationMilliseconds: Double?
}

private struct Effects: Decodable {
  let noiseAmplitude: Float?
  let noiseSeed: UInt64?
  let echoDelayMilliseconds: Double?
  let echoGain: Float?
  let lowPassAlpha: Float?
  let quantizationBits: Int?
}

private struct PCMBuffer {
  let sampleRate: Int
  let samples: [Float]
}

private struct ActiveRange: Codable {
  let speakerID: String
  let startSample: Int
  let endSample: Int
}

private struct ClipReceipt: Codable {
  let assetID: String
  let speakerID: String
  let sourceSampleCount: Int
  let mixedStartSample: Int
  let activeRangeCount: Int
}

private struct BuildReceipt: Codable {
  let schemaVersion: Int
  let kind: String
  let sampleID: String
  let mode: String
  let sampleRate: Int
  let sampleCount: Int
  let speakerCount: Int
  let overlapPresent: Bool
  let clips: [ClipReceipt]
  let reference: [ActiveRange]
}

private enum BuilderError: Error, CustomStringConvertible {
  case invalidArguments
  case invalidRecipe(String)
  case invalidWave(String)

  var description: String {
    switch self {
    case .invalidArguments:
      return "usage: SpeakerCorpusBuilder --recipe <recipe.json> --output-dir <directory>"
    case .invalidRecipe(let reason):
      return "invalid recipe: \(reason)"
    case .invalidWave(let reason):
      return "invalid WAV: \(reason)"
    }
  }
}

private func argument(_ name: String, in arguments: [String]) -> String? {
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

private func readWave(at url: URL) throws -> PCMBuffer {
  let data = try Data(contentsOf: url)
  guard data.count >= 44,
    ascii(data, 0, 4) == "RIFF",
    ascii(data, 8, 4) == "WAVE"
  else {
    throw BuilderError.invalidWave("missing RIFF/WAVE header at \(url.lastPathComponent)")
  }

  var offset = 12
  var audioFormat: UInt16?
  var channelCount: UInt16?
  var sampleRate: UInt32?
  var bitsPerSample: UInt16?
  var pcmData: Data?

  while offset + 8 <= data.count {
    let chunkID = ascii(data, offset, 4)
    let chunkSize = Int(uint32LE(data, offset + 4))
    let payloadStart = offset + 8
    let payloadEnd = payloadStart + chunkSize
    guard payloadEnd <= data.count else {
      throw BuilderError.invalidWave("truncated \(chunkID) chunk")
    }

    if chunkID == "fmt " {
      guard chunkSize >= 16 else {
        throw BuilderError.invalidWave("short fmt chunk")
      }
      audioFormat = uint16LE(data, payloadStart)
      channelCount = uint16LE(data, payloadStart + 2)
      sampleRate = uint32LE(data, payloadStart + 4)
      bitsPerSample = uint16LE(data, payloadStart + 14)
    } else if chunkID == "data" {
      pcmData = data.subdata(in: payloadStart..<payloadEnd)
    }

    offset = payloadEnd + (chunkSize % 2)
  }

  guard audioFormat == 1,
    channelCount == 1,
    bitsPerSample == 16,
    let sampleRate,
    let pcmData
  else {
    throw BuilderError.invalidWave("only mono 16-bit PCM is supported")
  }
  guard pcmData.count.isMultiple(of: 2) else {
    throw BuilderError.invalidWave("odd PCM payload length")
  }

  var samples: [Float] = []
  samples.reserveCapacity(pcmData.count / 2)
  var index = 0
  while index < pcmData.count {
    let unsigned = uint16LE(pcmData, index)
    let signed = Int16(bitPattern: unsigned)
    samples.append(Float(signed) / 32_768)
    index += 2
  }
  return PCMBuffer(sampleRate: Int(sampleRate), samples: samples)
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
  data.append(UInt8(value & 0xff))
  data.append(UInt8((value >> 8) & 0xff))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
  data.append(UInt8(value & 0xff))
  data.append(UInt8((value >> 8) & 0xff))
  data.append(UInt8((value >> 16) & 0xff))
  data.append(UInt8((value >> 24) & 0xff))
}

private func writeWave(_ samples: [Float], sampleRate: Int, to url: URL) throws {
  guard samples.count <= (Int(UInt32.max) - 44) / 2 else {
    throw BuilderError.invalidRecipe("output exceeds RIFF size limit")
  }
  var payload = Data(capacity: samples.count * 2)
  for sample in samples {
    let clamped = min(0.999_969_5, max(-1, sample))
    let integer = Int16((clamped * 32_768).rounded())
    appendUInt16LE(UInt16(bitPattern: integer), to: &payload)
  }

  var wave = Data()
  wave.append(Data("RIFF".utf8))
  appendUInt32LE(UInt32(36 + payload.count), to: &wave)
  wave.append(Data("WAVE".utf8))
  wave.append(Data("fmt ".utf8))
  appendUInt32LE(16, to: &wave)
  appendUInt16LE(1, to: &wave)
  appendUInt16LE(1, to: &wave)
  appendUInt32LE(UInt32(sampleRate), to: &wave)
  appendUInt32LE(UInt32(sampleRate * 2), to: &wave)
  appendUInt16LE(2, to: &wave)
  appendUInt16LE(16, to: &wave)
  wave.append(Data("data".utf8))
  appendUInt32LE(UInt32(payload.count), to: &wave)
  wave.append(payload)
  try wave.write(to: url, options: .atomic)
}

private func detectedActivity(in samples: [Float], sampleRate: Int) -> [(Int, Int)] {
  let frameSize = max(1, sampleRate / 50)
  let frameCount = (samples.count + frameSize - 1) / frameSize
  var rms = [Float](repeating: 0, count: frameCount)
  for frame in 0..<frameCount {
    let start = frame * frameSize
    let end = min(samples.count, start + frameSize)
    guard start < end else { continue }
    var sum: Float = 0
    for index in start..<end {
      sum += samples[index] * samples[index]
    }
    rms[frame] = sqrt(sum / Float(end - start))
  }

  let threshold = max(0.0025, (rms.max() ?? 0) * 0.04)
  var active = rms.map { $0 >= threshold }

  let maximumGapFrames = 12
  var cursor = 0
  while cursor < active.count {
    guard !active[cursor] else {
      cursor += 1
      continue
    }
    let gapStart = cursor
    while cursor < active.count, !active[cursor] { cursor += 1 }
    let touchesActiveOnBothSides = gapStart > 0 && cursor < active.count
    if touchesActiveOnBothSides, cursor - gapStart <= maximumGapFrames {
      for index in gapStart..<cursor { active[index] = true }
    }
  }

  let minimumActiveFrames = 5
  let paddingFrames = 3
  var ranges: [(Int, Int)] = []
  cursor = 0
  while cursor < active.count {
    guard active[cursor] else {
      cursor += 1
      continue
    }
    let rangeStart = cursor
    while cursor < active.count, active[cursor] { cursor += 1 }
    guard cursor - rangeStart >= minimumActiveFrames else { continue }
    let paddedStart = max(0, rangeStart - paddingFrames) * frameSize
    let paddedEnd = min(samples.count, (cursor + paddingFrames) * frameSize)
    ranges.append((paddedStart, paddedEnd))
  }
  return ranges
}

private func rangesOverlap(_ ranges: [ActiveRange]) -> Bool {
  for left in ranges.indices {
    for right in ranges.indices where right > left {
      guard ranges[left].speakerID != ranges[right].speakerID else { continue }
      if ranges[left].startSample < ranges[right].endSample,
        ranges[right].startSample < ranges[left].endSample
      {
        return true
      }
    }
  }
  return false
}

private func applyEffects(_ effects: Effects?, to samples: inout [Float], sampleRate: Int) {
  guard let effects else { return }

  if let delayMilliseconds = effects.echoDelayMilliseconds,
    let echoGain = effects.echoGain,
    delayMilliseconds > 0,
    echoGain != 0
  {
    let delay = Int((delayMilliseconds * Double(sampleRate) / 1_000).rounded())
    if delay > 0, delay < samples.count {
      let dry = samples
      for index in delay..<samples.count {
        samples[index] += dry[index - delay] * echoGain
      }
    }
  }

  if let alpha = effects.lowPassAlpha {
    let clampedAlpha = min(1, max(0.001, alpha))
    var previous: Float = 0
    for index in samples.indices {
      previous = clampedAlpha * samples[index] + (1 - clampedAlpha) * previous
      samples[index] = previous
    }
  }

  if let amplitude = effects.noiseAmplitude, amplitude > 0 {
    var state = effects.noiseSeed ?? 1
    for index in samples.indices {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let unit = Float(UInt32(truncatingIfNeeded: state >> 32)) / Float(UInt32.max)
      samples[index] += (unit * 2 - 1) * amplitude
    }
  }

  if let bits = effects.quantizationBits {
    let clampedBits = min(16, max(4, bits))
    let levels = Float((1 << (clampedBits - 1)) - 1)
    for index in samples.indices {
      samples[index] = (samples[index] * levels).rounded() / levels
    }
  }

  let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
  if peak > 0.92 {
    let scale = 0.92 / peak
    for index in samples.indices { samples[index] *= scale }
  }
}

private func writeRTTM(
  _ ranges: [ActiveRange], sampleID: String, sampleRate: Int, to url: URL
) throws {
  let lines = ranges.map { range in
    let start = Double(range.startSample) / Double(sampleRate)
    let duration = Double(range.endSample - range.startSample) / Double(sampleRate)
    return String(
      format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
      sampleID,
      start,
      duration,
      range.speakerID
    )
  }
  try (lines.joined(separator: "\n") + "\n").write(
    to: url, atomically: true, encoding: .utf8)
}

private func build(recipe: Recipe, outputDirectory: URL) throws {
  guard recipe.schemaVersion == 1 else {
    throw BuilderError.invalidRecipe("unsupported schemaVersion")
  }
  guard
    recipe.sampleID.range(
      of: "^[A-Za-z0-9._-]+$", options: .regularExpression
    ) != nil
  else {
    throw BuilderError.invalidRecipe("unsafe sampleID")
  }
  guard recipe.sampleRate == 16_000 else {
    throw BuilderError.invalidRecipe("speaker probes require 16000 Hz")
  }
  guard !recipe.clips.isEmpty else {
    throw BuilderError.invalidRecipe("clips must not be empty")
  }

  var loaded: [(Clip, PCMBuffer, [(Int, Int)], Int)] = []
  var outputCount = recipe.sampleRate / 2
  for clip in recipe.clips {
    guard clip.startMilliseconds >= 0, clip.gain > 0 else {
      throw BuilderError.invalidRecipe("invalid placement for \(clip.assetID)")
    }
    let source = try readWave(at: URL(fileURLWithPath: clip.path))
    guard source.sampleRate == recipe.sampleRate else {
      throw BuilderError.invalidRecipe(
        "sample-rate mismatch for \(clip.assetID): \(source.sampleRate)")
    }
    let sourceStartMilliseconds = clip.sourceStartMilliseconds ?? 0
    guard sourceStartMilliseconds >= 0 else {
      throw BuilderError.invalidRecipe("negative source offset for \(clip.assetID)")
    }
    let sourceStart = Int(
      (sourceStartMilliseconds * Double(recipe.sampleRate) / 1_000).rounded())
    let sourceDuration = clip.sourceDurationMilliseconds.map {
      Int(($0 * Double(recipe.sampleRate) / 1_000).rounded())
    }
    guard sourceStart < source.samples.count,
      sourceDuration.map({ $0 > 0 }) ?? true
    else {
      throw BuilderError.invalidRecipe("empty source slice for \(clip.assetID)")
    }
    let sourceEnd = min(
      source.samples.count,
      sourceStart + (sourceDuration ?? (source.samples.count - sourceStart))
    )
    let buffer = PCMBuffer(
      sampleRate: source.sampleRate,
      samples: Array(source.samples[sourceStart..<sourceEnd])
    )
    let activity = detectedActivity(in: buffer.samples, sampleRate: buffer.sampleRate)
    guard !activity.isEmpty else {
      throw BuilderError.invalidRecipe("no activity detected for \(clip.assetID)")
    }
    let startSample = Int(
      (clip.startMilliseconds * Double(recipe.sampleRate) / 1_000).rounded())
    outputCount = max(outputCount, startSample + buffer.samples.count + recipe.sampleRate / 2)
    loaded.append((clip, buffer, activity, startSample))
  }

  var output = [Float](repeating: 0, count: outputCount)
  var reference: [ActiveRange] = []
  var receipts: [ClipReceipt] = []
  for (clip, buffer, activity, startSample) in loaded {
    for index in buffer.samples.indices {
      output[startSample + index] += buffer.samples[index] * clip.gain
    }
    for (start, end) in activity {
      reference.append(
        ActiveRange(
          speakerID: clip.speakerID,
          startSample: startSample + start,
          endSample: startSample + end
        ))
    }
    receipts.append(
      ClipReceipt(
        assetID: clip.assetID,
        speakerID: clip.speakerID,
        sourceSampleCount: buffer.samples.count,
        mixedStartSample: startSample,
        activeRangeCount: activity.count
      ))
  }

  reference.sort {
    ($0.startSample, $0.endSample, $0.speakerID)
      < ($1.startSample, $1.endSample, $1.speakerID)
  }
  applyEffects(recipe.effects, to: &output, sampleRate: recipe.sampleRate)

  try FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true)
  let waveURL = outputDirectory.appendingPathComponent("\(recipe.sampleID).wav")
  let rttmURL = outputDirectory.appendingPathComponent("\(recipe.sampleID).rttm")
  let receiptURL = outputDirectory.appendingPathComponent("\(recipe.sampleID).receipt.json")
  try writeWave(output, sampleRate: recipe.sampleRate, to: waveURL)
  try writeRTTM(
    reference,
    sampleID: recipe.sampleID,
    sampleRate: recipe.sampleRate,
    to: rttmURL
  )

  let receipt = BuildReceipt(
    schemaVersion: 1,
    kind: "synthetic-speaker-corpus-receipt",
    sampleID: recipe.sampleID,
    mode: recipe.mode,
    sampleRate: recipe.sampleRate,
    sampleCount: output.count,
    speakerCount: Set(reference.map(\.speakerID)).count,
    overlapPresent: rangesOverlap(reference),
    clips: receipts,
    reference: reference
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let recipePath = argument("--recipe", in: arguments),
    let outputPath = argument("--output-dir", in: arguments)
  else {
    throw BuilderError.invalidArguments
  }
  let recipe = try JSONDecoder().decode(
    Recipe.self,
    from: Data(contentsOf: URL(fileURLWithPath: recipePath))
  )
  try build(
    recipe: recipe,
    outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true)
  )
} catch {
  FileHandle.standardError.write(Data("SpeakerCorpusBuilder failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
