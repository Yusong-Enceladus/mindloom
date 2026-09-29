import AVFoundation
import BestASRModelManager
import BestASRQwenRuntime
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXNN

struct AlignmentWord: Codable, Sendable {
  let text: String
  let startSeconds: Double
  let endSeconds: Double
}

struct AlignmentSample: Codable, Sendable {
  let sampleUUID: UUID
  let relativeAudioPath: String
  let sourceMeeting: String
  let sourceSpeaker: String
  let sourceStartSeconds: Double
  let durationSeconds: Double
  let words: [AlignmentWord]
}

struct AlignmentCorpusRun: Codable, Sendable {
  let schemaVersion: Int
  let manifestID: String
  let version: String
  let datasetVersion: String
  let releaseHoldout: Bool
  let samples: [AlignmentSample]
}

enum AlignmentEvaluationError: Error {
  case invalidArguments
  case invalidCorpus
  case invalidModel
  case invalidAudio
  case invalidTokenizer
  case missingMetalResources
  case wordCoverageMismatch
}

actor QwenAlignmentBackend {
  static let artifactID = "qwen3-forced-aligner-0.6b-8bit-0e1a68e9"
  static let revision = "0e1a68e91d815300c7c9754b2a7639378b23db15"
  private var model: Qwen3ForcedAlignerModel?

  func prepare(directory: URL) throws {
    guard model == nil else { return }
    try Task.checkCancellation()
    guard
      FileManager.default.fileExists(
        atPath: Bundle.main.bundleURL.appendingPathComponent(
          "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
        ).path
      )
    else { throw AlignmentEvaluationError.missingMetalResources }
    let config = try JSONDecoder().decode(
      Qwen3ASRConfig.self,
      from: Data(contentsOf: directory.appendingPathComponent("config.json"))
    )
    guard config.isForcedAligner, config.perLayerQuantization != nil,
      let timestampID = config.timestampTokenId,
      let step = config.timestampSegmentTime, step.isFinite, step > 0
    else { throw AlignmentEvaluationError.invalidModel }
    let tokenizer = try QwenLocalTokenizer.load(from: directory)
    // The upstream parser indexes two timestamp tokens per word without a
    // bounds check. Reject a tokenizer mismatch before entering that path.
    guard tokenizer.encode(text: "<timestamp>") == [timestampID] else {
      throw AlignmentEvaluationError.invalidTokenizer
    }
    let loaded = Qwen3ForcedAlignerModel(config)
    loaded.tokenizer = tokenizer
    let weights = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
    let sanitized = Qwen3ForcedAlignerModel.sanitize(weights: weights)
    quantize(model: loaded) { path, _ in
      guard !path.hasPrefix("audio_tower"), sanitized["\(path).scales"] != nil
      else { return nil }
      return config.perLayerQuantization?.quantization(layer: path)?.asTuple
    }
    try loaded.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
    eval(loaded)
    try Task.checkCancellation()
    model = loaded
  }

  func align(audioURL: URL, text: String, language: String = "English") throws -> [AlignmentWord] {
    guard let model, !text.isEmpty, text.count <= 4_000 else {
      throw AlignmentEvaluationError.invalidArguments
    }
    try Task.checkCancellation()
    let file = try AVAudioFile(forReading: audioURL)
    guard file.processingFormat.channelCount == 1,
      file.processingFormat.sampleRate == 16_000,
      file.length > 0, file.length <= 30 * 16_000
    else { throw AlignmentEvaluationError.invalidAudio }
    let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
    let result = model.generate(audio: audio, text: text, language: language)
    try Task.checkCancellation()
    return result.items.map {
      AlignmentWord(text: $0.text, startSeconds: $0.startTime, endSeconds: $0.endTime)
    }
  }

  func align(samples: [Float], text: String, language: String) throws -> [AlignmentWord] {
    guard let model, !text.isEmpty, text.count <= 4_000,
      !samples.isEmpty, samples.count <= 30 * 16_000, samples.allSatisfy(\.isFinite)
    else { throw AlignmentEvaluationError.invalidArguments }
    try Task.checkCancellation()
    let result = model.generate(audio: MLXArray(samples), text: text, language: language)
    try Task.checkCancellation()
    return result.items.map {
      AlignmentWord(text: $0.text, startSeconds: $0.startTime, endSeconds: $0.endTime)
    }
  }
}

enum QwenAlignmentEvaluation {
  private struct SampleResult: Codable {
    let sampleUUID: UUID
    let reference: [AlignmentWord]
    let aligned: [AlignmentWord]
    let elapsedSeconds: Double
    let invalidRangeWords: Int
  }

  static func run(options: [String: String]) async throws {
    guard options["--network-denied"] == "true" else {
      throw AlignmentEvaluationError.invalidArguments
    }
    let input = try path("--local-run", options)
    let audioRoot = try path("--audio-root", options).standardizedFileURL
    let outputRoot = try externalPath("--output-root", options)
    let modelSource = try path("--model-source", options)
    let registry = try ManagedModelRegistry.decode(
      Data(contentsOf: path("--model-registry", options))
    )
    let manager = try LocalModelManager(
      rootDirectory: externalPath("--model-store", options), registry: registry
    )
    let corpus = try JSONDecoder().decode(AlignmentCorpusRun.self, from: Data(contentsOf: input))
    guard corpus.schemaVersion == 1, corpus.manifestID == "ami-public-alignment-tuning-v1",
      !corpus.releaseHoldout, !corpus.samples.isEmpty,
      Set(corpus.samples.map(\.sampleUUID)).count == corpus.samples.count
    else { throw AlignmentEvaluationError.invalidCorpus }
    let active: ActiveManagedModel
    do {
      active = try await manager.discoverActive(
        artifactID: QwenAlignmentBackend.artifactID, healthCheck: FileSetModelHealthCheck()
      )
    } catch {
      _ = try await manager.activate(
        artifactID: QwenAlignmentBackend.artifactID, version: QwenAlignmentBackend.revision,
        from: modelSource, healthCheck: FileSetModelHealthCheck()
      )
      active = try await manager.discoverActive(
        artifactID: QwenAlignmentBackend.artifactID, healthCheck: FileSetModelHealthCheck()
      )
    }
    let backend = QwenAlignmentBackend()
    try await backend.prepare(directory: active.directory)
    var results: [SampleResult] = []
    var errors: [Double] = []
    var invalidRanges = 0
    var totalWords = 0
    let limit: Int
    if let raw = options["--limit"] {
      guard let parsed = Int(raw), parsed > 0 else {
        throw AlignmentEvaluationError.invalidArguments
      }
      limit = parsed
    } else {
      limit = corpus.samples.count
    }
    for sample in corpus.samples.prefix(limit) {
      guard !sample.words.isEmpty, sample.words.count <= 128,
        sample.durationSeconds.isFinite, sample.durationSeconds > 0,
        sample.durationSeconds <= 30, !sample.relativeAudioPath.hasPrefix("/"),
        !sample.relativeAudioPath.split(separator: "/").contains("..")
      else { throw AlignmentEvaluationError.invalidCorpus }
      let url = audioRoot.appendingPathComponent(sample.relativeAudioPath).standardizedFileURL
      guard
        url.resolvingSymlinksInPath().path.hasPrefix(audioRoot.resolvingSymlinksInPath().path + "/")
      else { throw AlignmentEvaluationError.invalidCorpus }
      let start = ProcessInfo.processInfo.systemUptime
      let output = try await backend.align(
        audioURL: url, text: sample.words.map(\.text).joined(separator: " "))
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      guard output.map(\.text) == sample.words.map(\.text) else {
        throw AlignmentEvaluationError.wordCoverageMismatch
      }
      var sampleInvalid = 0
      for (gold, aligned) in zip(sample.words, output) {
        guard gold.startSeconds.isFinite, gold.endSeconds.isFinite,
          aligned.startSeconds.isFinite, aligned.endSeconds.isFinite
        else { throw AlignmentEvaluationError.invalidCorpus }
        // Report invalid predictions instead of clamping them into a pass.
        if aligned.startSeconds < 0 || aligned.endSeconds < aligned.startSeconds
          || aligned.endSeconds > sample.durationSeconds + 1.0 / 16_000
        {
          sampleInvalid += 1
        }
        errors.append(abs(gold.startSeconds - aligned.startSeconds) * 1_000)
        errors.append(abs(gold.endSeconds - aligned.endSeconds) * 1_000)
      }
      totalWords += output.count
      invalidRanges += sampleInvalid
      results.append(
        SampleResult(
          sampleUUID: sample.sampleUUID, reference: sample.words, aligned: output,
          elapsedSeconds: elapsed, invalidRangeWords: sampleInvalid
        ))
    }
    errors.sort()
    let percentile: (Double) -> Double = { p in
      errors[min(errors.count - 1, max(0, Int(ceil(Double(errors.count) * p)) - 1))]
    }
    let summary: [String: Any] = [
      "schemaVersion": 1, "kind": "forced-alignment-tuning-measurement",
      "manifestID": corpus.manifestID, "corpusVersion": corpus.version,
      "datasetVersion": corpus.datasetVersion, "releaseHoldout": false,
      "referenceTimingProvenance":
        "AMI manual transcripts with automatically forced-aligned word timings; not human phonetic boundary ground truth",
      "referenceTimingDocumentation": "https://groups.inf.ed.ac.uk/ami/corpus/transcription.shtml",
      "containsPrivateContent": false, "networkDenied": true,
      "runtimeRevision": QwenASREvaluationArtifact.runtimeRevision,
      "modelArtifactID": QwenAlignmentBackend.artifactID,
      "modelRevision": QwenAlignmentBackend.revision,
      "modelTreeSHA256": active.descriptor.treeSHA256,
      "samples": results.count, "words": totalWords,
      "invalidRangeWords": invalidRanges,
      "meanBoundaryErrorMilliseconds": errors.reduce(0, +) / Double(errors.count),
      "medianBoundaryErrorMilliseconds": percentile(0.5),
      "p95BoundaryErrorMilliseconds": percentile(0.95),
      "maximumBoundaryErrorMilliseconds": errors.last ?? 0,
      "boundaryFractionWithin200Milliseconds": Double(errors.filter { $0 <= 200 }.count)
        / Double(errors.count),
      "totalInferenceSeconds": results.map(\.elapsedSeconds).reduce(0, +),
      "selectionEligible": false,
      "limitations": [
        "English AMI tuning only; reference text is supplied, so this measures alignment rather than ASR accuracy.",
        "AMI word timings are themselves automatically forced-aligned; deviations alone do not establish absolute word-boundary accuracy.",
        "One meeting / four speakers; no Chinese timestamp accuracy or release-holdout claim.",
        "200 ms fraction is descriptive, not a newly invented product acceptance threshold.",
        "Raw out-of-range predictions are counted, not silently clamped.",
      ],
    ]
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(results).write(
      to: outputRoot.appendingPathComponent("local-diagnostics.json"), options: .atomic)
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      .write(to: outputRoot.appendingPathComponent("summary.json"), options: .atomic)
    print(
      "alignment measured: \(results.count) samples, \(totalWords) reference words; not a release selection"
    )
  }

  static func path(_ key: String, _ options: [String: String]) throws -> URL {
    guard let value = options[key], value.hasPrefix("/") else {
      throw AlignmentEvaluationError.invalidArguments
    }
    return URL(fileURLWithPath: value)
  }

  static func externalPath(_ key: String, _ options: [String: String]) throws -> URL {
    let url = try path(key, options).standardizedFileURL
    // The build root script/build_storage.sh exported, or its default.
    let buildRoot =
      ProcessInfo.processInfo.environment["BESTASR_BUILD_ROOT"] ?? "/Volumes/BestASRBuild/bestASR"
    guard buildRoot.hasPrefix("/Volumes/"),
      url.resolvingSymlinksInPath().path.hasPrefix(buildRoot + "/"),
      FileManager.default.fileExists(atPath: buildRoot)
    else { throw AlignmentEvaluationError.invalidArguments }
    return url
  }
}
