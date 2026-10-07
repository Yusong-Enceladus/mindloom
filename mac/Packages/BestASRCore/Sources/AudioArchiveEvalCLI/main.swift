import BestASRAudioJournal
import BestASRFluidRuntime
import BestASRInference
import BestASRModelManager
import BestASRSpeakerRouting
import CryptoKit
import Foundation

/// Measures what the 30-day Opus step does to recognition and to the speaker
/// model, before that step is allowed to run (TECHNICAL_DESIGN.md「录音压缩」).
///
///   prepare  --manifest m.json --out dir [--format opus|lossless]
///            [--bitrate 24000] [--limit n]
///     Stores every item the way the App keeps a recording (16 kHz, 16-bit),
///     encodes it with the App's own Opus encoder (`RetainedAudioCodec`),
///     decodes it back the way playback and re-recognition would, and writes
///     two DictationEvalCLI manifests (`manifest-pcm.json`,
///     `manifest-opus.json`) plus `prepare-stats.json` (sizes, length
///     differences, loudness correlation).
///
///   speakers --pcm manifest-pcm.json --opus manifest-opus.json
///            --registry config/model-artifacts.json --models-root dir
///            --out speakers.json [--labels labels.json] [--limit n]
///     Embeds each item from both copies with the App's speaker runtime and
///     compares: the same clip before and after, same-speaker pairs and
///     different-speaker pairs (labels map item id → speaker; without them
///     every item is one speaker), against the App's automatic match
///     threshold.
///
///   diarize  --pcm … --opus … --registry … --models-root … --out diarize.json
///     Runs the App's whole-recording speaker analysis on both copies of each
///     item and compares the number of voices found and who spoke when.
///
/// Audio, references and transcripts stay where the caller put them; the
/// tool prints and writes only counts, sizes and similarities.
@main
enum AudioArchiveEvalCLI {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard let command = arguments.first else { throw Failure.usage }
      let options = try parse(Array(arguments.dropFirst()))
      switch command {
      case "prepare": try prepare(options)
      case "speakers": try await speakers(options)
      case "diarize": try await diarize(options)
      default: throw Failure.usage
      }
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }

  enum Failure: Error {
    case usage
    case missing(String)
  }

  struct Manifest: Codable {
    var schemaVersion: Int
    var name: String
    var seed: Int?
    var source: String?
    var items: [Item]
  }

  struct Item: Codable {
    var id: String
    var bucket: String
    var durationSeconds: Double
    var audioPath: String
    var reference: String
    var referenceKind: String?
  }

  // MARK: - prepare

  struct PrepareItemStats: Codable {
    let id: String
    let frames: Int
    let pcmBytes: Int
    let opusBytes: Int
    let lengthDifferenceFrames: Int
    let envelopeCorrelation: Double?
  }

  struct PrepareStats: Codable {
    let format: String
    /// Items whose decoded copy has exactly the master's 16-bit samples.
    let exactItems: Int
    let bitRate: Int
    let items: Int
    let failed: Int
    let totalSeconds: Double
    let pcmBytes: Int
    let opusBytes: Int
    let ratio: Double
    let maximumLengthDifferenceFrames: Int
    let minimumEnvelopeCorrelation: Double?
    let medianEnvelopeCorrelation: Double?
    let belowVerificationThreshold: Int
    let perItem: [PrepareItemStats]
  }

  static func prepare(_ options: [String: String]) throws {
    let manifestURL = try url("--manifest", options)
    let out = try url("--out", options)
    let bitRate = Int(options["--bitrate"] ?? "") ?? RetainedAudioCodec.archiveBitRate
    guard let format = RetainedAudioArchiveFormat(rawValue: options["--format"] ?? "opus") else {
      throw Failure.usage
    }
    var exact = 0
    var manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    if let limit = options["--limit"].flatMap(Int.init) {
      manifest.items = Array(manifest.items.prefix(limit))
    }
    let fileManager = FileManager.default
    for directory in ["pcm", "opus"] {
      try fileManager.createDirectory(
        at: out.appendingPathComponent(directory), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    var pcmItems: [Item] = []
    var opusItems: [Item] = []
    var stats: [PrepareItemStats] = []
    var failed = 0
    for (index, item) in manifest.items.enumerated() {
      do {
        let source = URL(fileURLWithPath: item.audioPath)
        // The master the App keeps: 16 kHz, quantized to 16 bits.
        let master = RetainedAudioCodec.samples(
          int16LittleEndian: RetainedAudioCodec.int16LittleEndian(
            try RetainedAudioCodec.decodeMono16k(source)))
        let pcmURL = out.appendingPathComponent("pcm/\(item.id).wav")
        try writeWave(master, to: pcmURL)
        let cafURL = out.appendingPathComponent("opus/\(item.id)\(format.fileSuffix)")
        try? fileManager.removeItem(at: cafURL)
        try RetainedAudioCodec.encode(samples: master, to: cafURL, format: format, bitRate: bitRate)
        // What playback and re-recognition would read.
        let decoded = try RetainedAudioCodec.decodeMono16k(cafURL)
        if RetainedAudioCodec.int16LittleEndian(decoded)
          == RetainedAudioCodec.int16LittleEndian(master)
        {
          exact += 1
        }
        let decodedURL = out.appendingPathComponent("opus/\(item.id).wav")
        try writeWave(decoded, to: decodedURL)
        let correlation = RetainedAudioCodec.envelopeCorrelation(master, decoded)
        stats.append(
          PrepareItemStats(
            id: item.id, frames: master.count, pcmBytes: master.count * 2,
            opusBytes: try size(cafURL),
            lengthDifferenceFrames: decoded.count - master.count,
            envelopeCorrelation: correlation.isNaN ? nil : correlation))
        var pcm = item
        pcm.audioPath = pcmURL.path
        pcmItems.append(pcm)
        var opus = item
        opus.audioPath = decodedURL.path
        opusItems.append(opus)
      } catch {
        failed += 1
        FileHandle.standardError.write(Data("item \(index + 1) failed: \(error)\n".utf8))
      }
      if (index + 1) % 25 == 0 { print("prepared \(index + 1)/\(manifest.items.count)") }
    }
    for (name, items) in [("manifest-pcm.json", pcmItems), ("manifest-opus.json", opusItems)] {
      var copy = manifest
      copy.items = items
      copy.name =
        "\(manifest.name)-\(name.hasPrefix("manifest-pcm") ? "pcm16" : format == .opus ? "opus\(bitRate / 1000)" : "lossless")"
      try write(copy, to: out.appendingPathComponent(name))
    }
    let correlations = stats.compactMap(\.envelopeCorrelation).sorted()
    let pcmBytes = stats.reduce(0) { $0 + $1.pcmBytes }
    let opusBytes = stats.reduce(0) { $0 + $1.opusBytes }
    let summary = PrepareStats(
      format: format.rawValue, exactItems: exact,
      bitRate: bitRate, items: stats.count, failed: failed,
      totalSeconds: Double(stats.reduce(0) { $0 + $1.frames }) / 16_000,
      pcmBytes: pcmBytes, opusBytes: opusBytes,
      ratio: opusBytes > 0 ? Double(pcmBytes) / Double(opusBytes) : 0,
      maximumLengthDifferenceFrames: stats.map { abs($0.lengthDifferenceFrames) }.max() ?? 0,
      minimumEnvelopeCorrelation: correlations.first,
      medianEnvelopeCorrelation: correlations.isEmpty ? nil : correlations[correlations.count / 2],
      belowVerificationThreshold: correlations.filter {
        $0 < RetainedAudioCodec.minimumEnvelopeCorrelation
      }.count,
      perItem: stats)
    try write(summary, to: out.appendingPathComponent("prepare-stats.json"))
    print(
      "prepare (\(format.rawValue)): \(stats.count) items, \(failed) failed, \(exact) exact, \(String(format: "%.1f", summary.totalSeconds / 60)) min, "
        + "PCM \(pcmBytes / 1024) KB → \(format.rawValue) \(opusBytes / 1024) KB (\(String(format: "%.1f", summary.ratio))×), "
        + "max length diff \(summary.maximumLengthDifferenceFrames) frames, "
        + "envelope r min \(fmt(summary.minimumEnvelopeCorrelation)) median \(fmt(summary.medianEnvelopeCorrelation)), "
        + "below \(RetainedAudioCodec.minimumEnvelopeCorrelation): \(summary.belowVerificationThreshold)"
    )
  }

  // MARK: - speakers

  struct Distribution: Codable {
    let count: Int
    let mean: Double
    let p05: Double
    let p50: Double
    let minimum: Double
    let belowThreshold: Int
    let atOrAboveThreshold: Int

    init(_ values: [Double], threshold: Double) {
      let sorted = values.sorted()
      count = sorted.count
      mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
      func percentile(_ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
      }
      p05 = percentile(0.05)
      p50 = percentile(0.5)
      minimum = sorted.first ?? 0
      belowThreshold = sorted.filter { $0 < threshold }.count
      atOrAboveThreshold = sorted.count - belowThreshold
    }
  }

  struct SpeakerReport: Codable {
    let threshold: Double
    let items: Int
    let failed: Int
    let failedPCM: Int
    let failedOpus: Int
    /// The same clip, master against its Opus copy.
    let sameClip: Distribution
    /// Two clips of the same speaker, both masters.
    let sameSpeakerPCM: Distribution
    /// Two clips of the same speaker, both Opus.
    let sameSpeakerOpus: Distribution
    /// A stored master voice against a new Opus clip of the same speaker.
    let sameSpeakerCross: Distribution
    let differentSpeakerPCM: Distribution
    let differentSpeakerOpus: Distribution
    let differentSpeakerCross: Distribution
    let meanDropSameSpeakerOpus: Double
    let meanDropSameSpeakerCross: Double
    /// Each clip against the voice of its speaker made from the other
    /// clips' 16-bit masters (leave one out): the clip as 16-bit, then as
    /// Opus. This is how a recording meets a person the App already knows.
    let centroidSamePCM: Distribution
    let centroidSameOpus: Distribution
    /// Each clip against the voice of every other speaker (16-bit masters).
    let centroidDifferentPCM: Distribution
    let centroidDifferentOpus: Distribution
  }

  static func speakers(_ options: [String: String]) async throws {
    var pcm = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url("--pcm", options)))
    let opus = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: url("--opus", options)))
    if let limit = options["--limit"].flatMap(Int.init) {
      pcm.items = Array(pcm.items.prefix(limit))
    }
    let labels: [String: String] =
      try options["--labels"].map {
        try JSONDecoder().decode(
          [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
      } ?? [:]
    let out = try url("--out", options)
    let scratch = out.deletingLastPathComponent().appendingPathComponent(
      ".speaker-scratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let runtime = try await makeRuntime(options, audioRoot: scratch)
    let opusByID = Dictionary(uniqueKeysWithValues: opus.items.map { ($0.id, $0) })

    var vectors: [(id: String, label: String, pcm: [Float], opus: [Float])] = []
    var failed = 0
    var failedPCM = 0
    var failedOpus = 0
    for (index, item) in pcm.items.enumerated() {
      guard let other = opusByID[item.id] else { continue }
      // The speaker model finds no speech in some short takes; counted per
      // copy, so a take Opus alone loses shows.
      let a = try? await embed(item.audioPath, runtime: runtime, scratch: scratch)
      let b = try? await embed(other.audioPath, runtime: runtime, scratch: scratch)
      if a == nil { failedPCM += 1 }
      if b == nil { failedOpus += 1 }
      if let a, let b {
        vectors.append((item.id, labels[item.id] ?? "self", a, b))
      } else {
        failed += 1
      }
      if (index + 1) % 25 == 0 { print("embedded \(index + 1)/\(pcm.items.count)") }
    }
    let threshold = try SpeakerRoutingPolicy.local().automaticMatchThreshold.value
    var sameClip: [Double] = []
    var samePCM: [Double] = []
    var sameOpus: [Double] = []
    var sameCross: [Double] = []
    var diffPCM: [Double] = []
    var diffOpus: [Double] = []
    var diffCross: [Double] = []
    for (i, a) in vectors.enumerated() {
      sameClip.append(cosine(a.pcm, a.opus))
      for b in vectors[(i + 1)...] {
        let same = a.label == b.label
        let values = (
          cosine(a.pcm, b.pcm), cosine(a.opus, b.opus),
          (cosine(a.pcm, b.opus) + cosine(a.opus, b.pcm)) / 2
        )
        if same {
          samePCM.append(values.0)
          sameOpus.append(values.1)
          sameCross.append(values.2)
        } else {
          diffPCM.append(values.0)
          diffOpus.append(values.1)
          diffCross.append(values.2)
        }
      }
    }
    func mean(_ values: [Double]) -> Double {
      values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    // Voices made from 16-bit masters, by speaker.
    func normalized(_ v: [Float]) -> [Double] {
      let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
      return v.map { norm > 0 ? Double($0) / norm : 0 }
    }
    var sums: [String: [Double]] = [:]
    var counts: [String: Int] = [:]
    for item in vectors {
      let n = normalized(item.pcm)
      sums[item.label] = zip(sums[item.label] ?? Array(repeating: 0, count: n.count), n).map(+)
      counts[item.label, default: 0] += 1
    }
    func similarity(_ a: [Float], _ voice: [Double]) -> Double {
      AudioArchiveEvalCLI.cosine(a, voice.map(Float.init))
    }
    var centroidSamePCM: [Double] = []
    var centroidSameOpus: [Double] = []
    var centroidDifferentPCM: [Double] = []
    var centroidDifferentOpus: [Double] = []
    for item in vectors {
      guard let sum = sums[item.label], let count = counts[item.label], count >= 3 else { continue }
      let own = zip(sum, normalized(item.pcm)).map { $0 - $1 }
      centroidSamePCM.append(similarity(item.pcm, own))
      centroidSameOpus.append(similarity(item.opus, own))
      for (label, other) in sums where label != item.label {
        centroidDifferentPCM.append(similarity(item.pcm, other))
        centroidDifferentOpus.append(similarity(item.opus, other))
      }
    }
    let report = SpeakerReport(
      threshold: threshold, items: vectors.count, failed: failed, failedPCM: failedPCM,
      failedOpus: failedOpus,
      sameClip: Distribution(sameClip, threshold: threshold),
      sameSpeakerPCM: Distribution(samePCM, threshold: threshold),
      sameSpeakerOpus: Distribution(sameOpus, threshold: threshold),
      sameSpeakerCross: Distribution(sameCross, threshold: threshold),
      differentSpeakerPCM: Distribution(diffPCM, threshold: threshold),
      differentSpeakerOpus: Distribution(diffOpus, threshold: threshold),
      differentSpeakerCross: Distribution(diffCross, threshold: threshold),
      meanDropSameSpeakerOpus: mean(samePCM) - mean(sameOpus),
      meanDropSameSpeakerCross: mean(samePCM) - mean(sameCross),
      centroidSamePCM: Distribution(centroidSamePCM, threshold: threshold),
      centroidSameOpus: Distribution(centroidSameOpus, threshold: threshold),
      centroidDifferentPCM: Distribution(centroidDifferentPCM, threshold: threshold),
      centroidDifferentOpus: Distribution(centroidDifferentOpus, threshold: threshold))
    try write(report, to: out)
    print(
      """
      speakers: \(vectors.count) items (\(failed) failed: 16-bit \(failedPCM), Opus \(failedOpus)), threshold \(fmt(threshold))
        same clip PCM↔Opus: mean \(fmt(report.sameClip.mean)) min \(fmt(report.sameClip.minimum)) below \(report.sameClip.belowThreshold)
        same speaker mean PCM \(fmt(report.sameSpeakerPCM.mean)) Opus \(fmt(report.sameSpeakerOpus.mean)) cross \(fmt(report.sameSpeakerCross.mean)); drop \(fmt(report.meanDropSameSpeakerOpus)) / \(fmt(report.meanDropSameSpeakerCross))
        different speaker ≥ threshold: PCM \(report.differentSpeakerPCM.atOrAboveThreshold) Opus \(report.differentSpeakerOpus.atOrAboveThreshold) cross \(report.differentSpeakerCross.atOrAboveThreshold) of \(report.differentSpeakerPCM.count)
        own voice (leave one out) ≥ threshold: 16-bit \(report.centroidSamePCM.atOrAboveThreshold) Opus \(report.centroidSameOpus.atOrAboveThreshold) of \(report.centroidSamePCM.count); mean \(fmt(report.centroidSamePCM.mean)) → \(fmt(report.centroidSameOpus.mean))
        other voices ≥ threshold: 16-bit \(report.centroidDifferentPCM.atOrAboveThreshold) Opus \(report.centroidDifferentOpus.atOrAboveThreshold) of \(report.centroidDifferentPCM.count)
      """)
  }

  // MARK: - diarize

  struct DiarizeItem: Codable {
    let id: String
    let seconds: Double
    let voicesPCM: Int
    let voicesOpus: Int
    /// Speech seconds of each voice found, largest first.
    let voiceSecondsPCM: [Double]
    let voiceSecondsOpus: [Double]
    /// Share of speech time (PCM turns) given the same voice in the Opus copy,
    /// after matching voices by their embeddings.
    let agreement: Double
    let matchedVoiceCosines: [Double]
  }

  static func diarize(_ options: [String: String]) async throws {
    let pcm = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url("--pcm", options)))
    let opus = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: url("--opus", options)))
    let out = try url("--out", options)
    let scratch = out.deletingLastPathComponent().appendingPathComponent(
      ".diarize-scratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let runtime = try await makeRuntime(options, audioRoot: scratch)
    let opusByID = Dictionary(uniqueKeysWithValues: opus.items.map { ($0.id, $0) })
    var results: [DiarizeItem] = []
    for item in pcm.items {
      guard let other = opusByID[item.id] else { continue }
      let a: (analysis: FluidSpeakerAnalysis, seconds: Double)
      let b: (analysis: FluidSpeakerAnalysis, seconds: Double)
      do {
        a = try await analyze(item.audioPath, runtime: runtime, scratch: scratch)
        b = try await analyze(other.audioPath, runtime: runtime, scratch: scratch)
      } catch {
        print("diarize: one recording skipped (\(error))")
        continue
      }
      func voiceSeconds(_ analysis: FluidSpeakerAnalysis) -> [Double] {
        analysis.clusters.map { Double($0.speechDurationNanoseconds) / 1e9 }.sorted(by: >)
      }
      // Match each PCM voice to the Opus voice with the closest embedding.
      var mapping: [String: String] = [:]
      var cosines: [Double] = []
      for cluster in a.analysis.clusters {
        let best = b.analysis.clusters.max {
          cosine(cluster.vector, $0.vector) < cosine(cluster.vector, $1.vector)
        }
        if let best {
          mapping[cluster.speakerClusterID] = best.speakerClusterID
          cosines.append(cosine(cluster.vector, best.vector))
        }
      }
      // Speech time on which the matched voice is speaking in both.
      let step: UInt64 = 100_000_000
      var total = 0
      var agreeing = 0
      for turn in a.analysis.diarization.turns {
        var t = turn.monotonicStartNanoseconds
        while t < turn.monotonicEndNanoseconds {
          total += 1
          let expected = mapping[turn.speakerClusterID]
          if b.analysis.diarization.turns.contains(where: {
            $0.monotonicStartNanoseconds <= t && t < $0.monotonicEndNanoseconds
              && $0.speakerClusterID == expected
          }) {
            agreeing += 1
          }
          t += step
        }
      }
      results.append(
        DiarizeItem(
          id: item.id, seconds: a.seconds, voicesPCM: a.analysis.clusters.count,
          voicesOpus: b.analysis.clusters.count,
          voiceSecondsPCM: voiceSeconds(a.analysis), voiceSecondsOpus: voiceSeconds(b.analysis),
          agreement: total == 0 ? 1 : Double(agreeing) / Double(total),
          matchedVoiceCosines: cosines))
      let last = results.last!
      print(
        "diarize: \(String(format: "%.0f", a.seconds)) s, voices \(a.analysis.clusters.count) → \(b.analysis.clusters.count), "
          + "agreement \(fmt(last.agreement)), voice seconds \(last.voiceSecondsPCM.map { String(format: "%.1f", $0) }) → "
          + "\(last.voiceSecondsOpus.map { String(format: "%.1f", $0) }), matched cosine \(last.matchedVoiceCosines.map { String(format: "%.2f", $0) })"
      )
    }
    try write(results, to: out)
  }

  // MARK: - Speaker runtime

  static func makeRuntime(
    _ options: [String: String], audioRoot: URL
  ) async throws -> FluidSpeakerRuntime {
    let registry = try ManagedModelRegistry.decode(Data(contentsOf: url("--registry", options)))
    let manager = try LocalModelManager(
      rootDirectory: try url("--models-root", options), registry: registry)
    return try await FluidSpeakerRuntimeFactory.make(
      modelManager: manager, audioAssetRoot: audioRoot)
  }

  static func stage(_ path: String, scratch: URL) throws -> (AudioRangeInput, Double) {
    let samples = try RetainedAudioCodec.decodeMono16k(URL(fileURLWithPath: path))
    let bytes = RetainedAudioCodec.float32LittleEndian(samples)
    let name = "\(UUID().uuidString).f32le"
    try bytes.write(to: scratch.appendingPathComponent(name))
    let nanoseconds = UInt64(samples.count) * 62_500
    return (
      AudioRangeInput(
        sourceID: UUID(), trackID: UUID(), assetReference: name,
        contentDigest: RetainedAudioCodec.digest(bytes), monotonicStartNanoseconds: 0,
        monotonicEndNanoseconds: max(1, nanoseconds), sampleRateHertz: 16_000, channelCount: 1),
      Double(samples.count) / 16_000
    )
  }

  static func metadata() -> InferenceRequestMetadata {
    InferenceRequestMetadata(
      jobID: UUID(), inputRevision: 1, modelArtifactID: FluidSpeakerPinnedArtifact.artifactID,
      configHash: String(repeating: "a", count: 64))
  }

  static func embed(_ path: String, runtime: FluidSpeakerRuntime, scratch: URL) async throws
    -> [Float]
  {
    let (range, _) = try stage(path, scratch: scratch)
    defer {
      try? FileManager.default.removeItem(at: scratch.appendingPathComponent(range.assetReference))
    }
    return try await runtime.embed(
      SpeakerEmbeddingRequest(
        metadata: metadata(), audio: range,
        embeddingSpaceID: FluidSpeakerPinnedArtifact.embeddingSpaceID)
    ).vector
  }

  static func analyze(_ path: String, runtime: FluidSpeakerRuntime, scratch: URL) async throws
    -> (analysis: FluidSpeakerAnalysis, seconds: Double)
  {
    let (range, seconds) = try stage(path, scratch: scratch)
    defer {
      try? FileManager.default.removeItem(at: scratch.appendingPathComponent(range.assetReference))
    }
    let analysis = try await runtime.analyze(
      DiarizationRequest(metadata: metadata(), audio: [range], expectedSpeakerRange: nil))
    return (analysis, seconds)
  }

  static func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    for index in a.indices {
      dot += Double(a[index]) * Double(b[index])
      na += Double(a[index]) * Double(a[index])
      nb += Double(b[index]) * Double(b[index])
    }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
  }

  // MARK: - Files

  static func writeWave(_ samples: [Float], to url: URL) throws {
    let pcm = RetainedAudioCodec.int16LittleEndian(samples)
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(Data("RIFF".utf8))
    append(UInt32(36 + pcm.count))
    data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(16_000))
    append(UInt32(32_000))
    append(UInt16(2))
    append(UInt16(16))
    data.append(Data("data".utf8))
    append(UInt32(pcm.count))
    data.append(pcm)
    try data.write(to: url, options: .atomic)
  }

  static func size(_ url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  }

  static func write(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  static func url(_ name: String, _ options: [String: String]) throws -> URL {
    guard let value = options[name] else { throw Failure.missing(name) }
    return URL(fileURLWithPath: value)
  }

  static func parse(_ arguments: [String]) throws -> [String: String] {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard key.hasPrefix("--") else { throw Failure.usage }
      if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
        options[key] = arguments[index + 1]
        index += 2
      } else {
        options[key] = "true"
        index += 1
      }
    }
    return options
  }

  static func fmt(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.4f", value)
  }
}
