import AVFoundation
import BestASRAudioJournal
import BestASRCandidateAdapters
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRMLXRuntime
import BestASRModelManager
import BestASRProcessing
import BestASRQwenRuntime
import CryptoKit
import Foundation

/// Runs the production dictation text path (native Qwen final ASR, then MLX
/// polish, the protected-fact gate, and the deterministic fallback) over a
/// local evaluation manifest. Like the App's dictation since 2026-10-06 it
/// asks the recognizer for text without word timings
/// (`ASRRecognitionContext.deferWordAlignment`); `--aligned-words` aligns
/// and joins phrases as before.
///
/// Usage: DictationEvalCLI --manifest m.json --output r.json --registry
///   config/model-artifacts.json [--models-root dir] [--limit n] [--no-polish]
///   [--fixed-windows] [--context-terms terms.json] [--polish-budget-ms 0]
///   [--dictionary dictionary.json] [--prior prior.json]
///   [--recognizer-dir dir] [--cache-limit-mb n] [--terms-max-seconds s|none]
///   [--near-match-max-seconds s|none] [--aligned-words]
///
/// `--dictionary` is the App's dictionary context exactly as the App builds
/// it (`{"terms": [...], "hints": [{"canonicalForm", "spokenForms"}]}`), so
/// both the prompt terms and the spoken-form replacements match. `--prior`
/// maps item IDs to the text dictated just before (previous-utterance
/// context experiment). `--recognizer-dir` loads another quantization of
/// the recognizer from a local folder. The two length limits default to the
/// App's (`QwenASRPinnedArtifact.dictionaryPromptMaximumSamples`); `none`
/// applies the dictionary at every length, as before 2026-10-06.
///
/// Every result file records how it was made (`EvalConfiguration`): the
/// arguments, the dictionary's SHA-256, the recognizer folder, the limits in
/// effect, the build configuration, the executable's SHA-256, and the
/// source checkout's revision with a dirty flag. A resumed run must match
/// it. Two runs compare only when their executables match (review
/// 2026-10-06: a debug-to-release switch once passed as a prompt win).
///
/// Audio, references, and results stay on disk where the caller put them;
/// the tool prints only progress counts and timings, never text.
@main
struct DictationEvalCLI {
  static func main() async {
    do {
      try await run(Arguments(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run(_ arguments: Arguments) async throws {
    let manifest = try JSONDecoder().decode(
      EvalManifest.self, from: Data(contentsOf: arguments.manifest))
    if let megabytes = arguments.cacheLimitMegabytes {
      QwenRuntimeMemory.limitIdleBuffers(toBytes: megabytes * 1_048_576)
    }
    let registry = try ManagedModelRegistry.decode(Data(contentsOf: arguments.registry))
    let manager = try LocalModelManager(rootDirectory: arguments.modelsRoot, registry: registry)
    let loader = PreloadedSampleLoader()
    let configuration = EvalConfiguration(arguments)
    let asr = try await QwenASRRuntimeFactory.makeForEvaluation(
      modelManager: manager, audioLoader: loader, usesPriorContext: !arguments.prior.isEmpty,
      recognizerDirectory: arguments.recognizerDirectory,
      dictionaryPromptMaximumSamples: arguments.termsMaximumSamples,
      dictionaryNearMatchMaximumSamples: arguments.nearMatchMaximumSamples)
    let polish =
      arguments.polish
      ? try await makePolish(manager, budget: .milliseconds(arguments.polishBudgetMilliseconds))
      : nil

    var items = manifest.items
    if let limit = arguments.limit { items = Array(items.prefix(limit)) }
    // Resume: keep finished items from an earlier, interrupted run of the
    // same configuration; never mix two builds or two settings in one file.
    let earlier = try? JSONDecoder().decode(
      EvalRunInput.self, from: Data(contentsOf: arguments.output))
    if let earlier, !earlier.items.isEmpty, earlier.configuration != configuration {
      throw EvalError.configurationChanged
    }
    var results = earlier?.items ?? []
    let finished = Set(results.map(\.id))
    for (index, item) in items.enumerated() where !finished.contains(item.id) {
      FileHandle.standardError.write(Data("item \(index + 1) \(item.id)\n".utf8))
      var result: EvalResult
      do {
        let samples = try loadMono16k(URL(fileURLWithPath: item.audioPath))
        let decodeStarted = ContinuousClock.now
        let raw = try await recognize(
          samples: samples, id: item.id, runtime: asr, loader: loader,
          pauseAligned: arguments.pauseAlignedWindows, contextTerms: arguments.contextTerms,
          hints: arguments.hints, prior: arguments.prior[item.id],
          defersWordAlignment: arguments.defersWordAlignment)
        // Without model polish the App inserts the rule-cleaned transcript.
        result = EvalResult(
          id: item.id, rawText: raw.text, finalText: DictationTextCleanup.apply(raw.text),
          windows: raw.windows, decodeMs: milliseconds(since: decodeStarted))
        if let polish, !raw.text.isEmpty {
          let outcome = await polish.run(raw.text)
          result.polishMs = outcome.modelMilliseconds
          result.modelText = outcome.modelText
          result.polishDisposition = outcome.disposition
          result.finalText = outcome.insertedText
        }
      } catch {
        // The App would fall back to its older recognizers here; record the
        // failure instead of aborting the whole run.
        result = EvalResult(
          id: item.id, rawText: "", finalText: "", windows: 0, decodeMs: 0,
          error: String(describing: error))
      }
      results.append(result)
      if results.count % 10 == 0 || index + 1 == items.count {
        try save(results, configuration: configuration, to: arguments.output)
        print("\(results.count)/\(items.count) done")
      }
    }
    try save(results, configuration: configuration, to: arguments.output)
    let usage = QwenRuntimeMemory.usage()
    FileHandle.standardError.write(
      Data(
        "mlx memory MB active=\(usage.active >> 20) cached=\(usage.cached >> 20) peak=\(usage.peak >> 20)\n"
          .utf8))
  }

  static func save(
    _ results: [EvalResult], configuration: EvalConfiguration, to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    try encoder.encode(EvalRun(configuration: configuration, items: results))
      .write(to: url, options: .atomic)
  }

  /// Mirrors the App's bounded final path: windows of at most 30 s (pause
  /// aligned like the journal, or the previous fixed cut), each through the
  /// runtime, joined with the production joiner.
  static func recognize(
    samples: [Float], id: String, runtime: QwenASRRuntime, loader: PreloadedSampleLoader,
    pauseAligned: Bool, contextTerms: [String], hints: [ASRDictionaryHint] = [],
    prior: String? = nil, defersWordAlignment: Bool = true
  ) async throws -> (text: String, windows: Int) {
    let limit = QwenASRPinnedArtifact.maximumSamples
    let ranges =
      pauseAligned
      ? PauseAlignedWindowing.windows(samples, limit: limit)
      : stride(from: 0, to: samples.count, by: limit).map {
        $0..<min(samples.count, $0 + limit)
      }
    var pieces: [String] = []
    var windows = 0
    for range in ranges {
      let start = range.lowerBound
      let end = range.upperBound
      let reference = "eval/\(id)/\(start)"
      await loader.store(Array(samples[start..<end]), for: reference)
      let output = try await runtime.transcribe(
        evaluationRequest(
          reference: reference, sampleCount: end - start, contextTerms: contextTerms,
          hints: hints, prior: prior, defersWordAlignment: defersWordAlignment),
        candidateID: QwenASRPinnedArtifact.candidateID)
      pieces += output.segments.map(\.text)
      await loader.remove(reference)
      windows += 1
    }
    return (TranscriptTextJoiner.join(pieces), windows)
  }

  static func evaluationRequest(
    reference: String, sampleCount: Int, contextTerms: [String],
    hints: [ASRDictionaryHint] = [], prior: String? = nil, defersWordAlignment: Bool = true
  ) -> ASRRequest {
    let nanoseconds = UInt64(sampleCount) * 1_000_000_000 / 16_000
    let digest = SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return ASRRequest(
      metadata: InferenceRequestMetadata(
        jobID: UUID(), inputRevision: 1,
        modelArtifactID: QwenASRPinnedArtifact.artifactID, configHash: digest),
      audio: AudioRangeInput(
        sourceID: UUID(), trackID: UUID(), assetReference: reference,
        contentDigest: digest, monotonicStartNanoseconds: 0,
        monotonicEndNanoseconds: max(1, nanoseconds), sampleRateHertz: 16_000,
        channelCount: 1),
      mode: .final,
      languageHints: [],
      recognitionContext: ASRRecognitionContext(
        dictionaryTerms: contextTerms, dictionaryHints: hints,
        priorStableSegments: prior.map { [ASRContextSegment(text: $0, monotonicEndNanoseconds: 0)] }
          ?? [], deferWordAlignment: defersWordAlignment)
    )
  }

  static func makePolish(
    _ manager: LocalModelManager, budget: Duration
  ) async throws -> EvalPolish {
    let artifact = MLXLocalTextArtifact.qwen3Selected
    let engine = try await MLXLocalTextRuntimeFactory.make(
      modelManager: manager, artifact: artifact, prepare: true)
    let configHash = SHA256.hash(data: Data("dictation-eval-polish".utf8))
      .map { String(format: "%02x", $0) }.joined()
    return EvalPolish(
      insertionBudget: budget,
      model: try MLXDictationPolishAdapter(
        engine: engine, artifactID: artifact.artifactID, configHash: configHash))
  }

  static func loadMono16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw EvalError.audioFormat(url.lastPathComponent) }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else {
      throw EvalError.audioFormat(url.lastPathComponent)
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }
}

/// Applies the App's insertion rule: model polish within the insertion budget
/// and through the protected-fact gate, otherwise the deterministic cleanup.
/// The budget mirrors `LocalDictationRuntime.polishInsertionBudget`; pass
/// `--polish-budget-ms 800` to measure the earlier time-boxed rule.
struct EvalPolish {
  let insertionBudget: Duration
  let model: MLXDictationPolishAdapter

  func run(_ source: String) async -> (
    insertedText: String, modelText: String?, modelMilliseconds: Int?, disposition: String
  ) {
    let request = DictationPolishRequest(
      sessionID: SessionID(),
      transcript: DictationTranscriptResult(
        revisionID: TranscriptRevisionID(), segmentIDs: [], text: source,
        modelArtifactID: QwenASRPinnedArtifact.artifactID),
      dictionaryTerms: [],
      targetBundleIdentifier: nil
    )
    let started = ContinuousClock.now
    let proposed = try? await model.polish(request)
    let elapsed = ContinuousClock.now - started
    let modelMs = milliseconds(of: elapsed)
    if let proposed,
      DictationProtectedFactValidator.validate(
        source: source, candidate: proposed.text, dictionaryTerms: []
      ).passed
    {
      if elapsed <= insertionBudget {
        return (proposed.text, proposed.text, modelMs, "model")
      }
      return (await fallback(request, source), proposed.text, modelMs, "model-late")
    }
    return (await fallback(request, source), nil, modelMs, "model-rejected")
  }

  private func fallback(_ request: DictationPolishRequest, _ source: String) async -> String {
    guard let punctuation = try? await DeterministicPunctuationPolishAdapter().polish(request),
      DictationProtectedFactValidator.validate(
        source: source, candidate: punctuation.text, dictionaryTerms: []
      ).passed
    else { return source }
    return punctuation.text
  }
}

actor PreloadedSampleLoader: SenseVoiceAudioSampleLoading {
  private var samplesByReference: [String: [Float]] = [:]

  func store(_ samples: [Float], for reference: String) { samplesByReference[reference] = samples }
  func remove(_ reference: String) { samplesByReference[reference] = nil }

  func loadSamples(for input: AudioRangeInput) async throws -> [Float] {
    guard let samples = samplesByReference[input.assetReference] else {
      throw EvalError.missingSamples
    }
    return samples
  }
}

struct Arguments {
  /// Everything after the executable's name, as given.
  let raw: [String]
  let manifest: URL
  let output: URL
  let registry: URL
  let modelsRoot: URL
  let limit: Int?
  let polish: Bool
  let pauseAlignedWindows: Bool
  let contextTerms: [String]
  let polishBudgetMilliseconds: Int
  let cacheLimitMegabytes: Int?
  let hints: [ASRDictionaryHint]
  let prior: [String: String]
  let recognizerDirectory: URL?
  /// The dictionary file as given (`--dictionary`), for its digest.
  let dictionaryFile: URL?
  /// `--terms-max-seconds`: dictionary terms in the prompt only for audio
  /// shorter than this; the App's limit unless given, nil for `none`.
  let termsMaximumSamples: Int?
  /// `--near-match-max-seconds`: near-match dictionary rewriting only for
  /// audio shorter than this; the App's limit unless given, nil for `none`.
  let nearMatchMaximumSamples: Int?
  /// Text without word timings, as the App's dictation asks for it; false
  /// with `--aligned-words`.
  let defersWordAlignment: Bool

  init(_ raw: ArraySlice<String>) throws {
    self.raw = Array(raw)
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var iterator = raw.makeIterator()
    while let key = iterator.next() {
      if key == "--no-polish" || key == "--fixed-windows" || key == "--aligned-words" {
        flags.insert(key)
        continue
      }
      guard let value = iterator.next() else { throw EvalError.usage }
      values[key] = value
    }
    guard let manifest = values["--manifest"], let output = values["--output"],
      let registry = values["--registry"]
    else { throw EvalError.usage }
    self.manifest = URL(fileURLWithPath: manifest)
    self.output = URL(fileURLWithPath: output)
    self.registry = URL(fileURLWithPath: registry)
    modelsRoot = URL(
      fileURLWithPath: values["--models-root"]
        ?? (NSHomeDirectory() + "/Library/Application Support/Mindloom/models"))
    limit = values["--limit"].flatMap(Int.init)
    polishBudgetMilliseconds = values["--polish-budget-ms"].flatMap(Int.init) ?? 0
    cacheLimitMegabytes = values["--cache-limit-mb"].flatMap(Int.init)
    polish = !flags.contains("--no-polish")
    pauseAlignedWindows = !flags.contains("--fixed-windows")
    defersWordAlignment = !flags.contains("--aligned-words")
    dictionaryFile = values["--dictionary"].map { URL(fileURLWithPath: $0) }
    let dictionary = try dictionaryFile.map {
      try JSONDecoder().decode(EvalDictionary.self, from: Data(contentsOf: $0))
    }
    contextTerms =
      try values["--context-terms"].map {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
      } ?? dictionary?.terms ?? []
    hints = dictionary?.hints ?? []
    prior =
      try values["--prior"].map {
        try JSONDecoder().decode(
          [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
      } ?? [:]
    recognizerDirectory = values["--recognizer-dir"].map { URL(fileURLWithPath: $0) }
    termsMaximumSamples = try QwenASRPinnedArtifact.dictionaryLimitSamples(
      argument: values["--terms-max-seconds"])
    nearMatchMaximumSamples = try QwenASRPinnedArtifact.dictionaryLimitSamples(
      argument: values["--near-match-max-seconds"])
  }
}

/// How a result file was made, so two runs are compared only when they ran
/// the same build with the same settings.
struct EvalConfiguration: Codable, Equatable {
  var arguments: [String]
  /// SHA-256 of the `--dictionary` file's bytes; nil without one.
  var dictionarySHA256: String?
  /// The recognizer folder (`--recognizer-dir`), or nil for the verified
  /// active artifact.
  var recognizerDirectory: String?
  var recognizerArtifactID: String
  var pipelineRevision: String
  /// The dictionary length limits in effect, in samples (nil: every length).
  var termsMaximumSamples: Int?
  var nearMatchMaximumSamples: Int?
  /// Text without word timings, as the App's dictation since 2026-10-06;
  /// nil in results written before.
  var wordAlignmentDeferred: Bool?
  /// "debug" or "release".
  var buildConfiguration: String
  /// SHA-256 of this executable: equal for two runs of the same build.
  var executableSHA256: String?
  /// The source checkout this executable was built from, read when it runs.
  var sourceRevision: String?
  var sourceDirty: Bool?

  init(_ arguments: Arguments) {
    self.arguments = arguments.raw
    dictionarySHA256 = arguments.dictionaryFile.flatMap(Self.sha256(of:))
    recognizerDirectory = arguments.recognizerDirectory?.path
    recognizerArtifactID = QwenASRPinnedArtifact.artifactID
    pipelineRevision = QwenASRPinnedArtifact.pipelineRevision
    termsMaximumSamples = arguments.termsMaximumSamples
    nearMatchMaximumSamples = arguments.nearMatchMaximumSamples
    wordAlignmentDeferred = arguments.defersWordAlignment
    #if DEBUG
      buildConfiguration = "debug"
    #else
      buildConfiguration = "release"
    #endif
    executableSHA256 = Bundle.main.executableURL.flatMap(Self.sha256(of:))
    let checkout = Self.checkout()
    sourceRevision = checkout?.revision
    sourceDirty = checkout?.dirty
  }

  static func sha256(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The repository this file was compiled from (the folder above
  /// `Packages/BestASRCore`): its HEAD and whether tracked files differ.
  static func checkout() -> (revision: String, dirty: Bool)? {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let revision = git(root, ["rev-parse", "HEAD"]),
      let status = git(root, ["status", "--porcelain", "--untracked-files=no"])
    else { return nil }
    return (revision, !status.isEmpty)
  }

  static func git(_ root: URL, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// The App's dictionary context (`GRDBDictationStore.dictionaryContext`).
struct EvalDictionary: Decodable {
  let terms: [String]
  let hints: [ASRDictionaryHint]
}

struct EvalManifest: Decodable {
  struct Item: Decodable {
    let id: String
    let audioPath: String
  }
  let items: [Item]
}

struct EvalResult: Codable {
  let id: String
  let rawText: String
  var finalText: String
  let windows: Int
  let decodeMs: Int
  var polishMs: Int?
  var modelText: String?
  var polishDisposition: String?
  var error: String?
}

struct EvalRun: Encodable {
  var schemaVersion = 2
  let configuration: EvalConfiguration
  let items: [EvalResult]
}

struct EvalRunInput: Decodable {
  /// Absent in files written before schema 2.
  let configuration: EvalConfiguration?
  let items: [EvalResult]
}

enum EvalError: Error {
  case usage
  case audioFormat(String)
  case missingSamples
  /// The output file holds results of another build or other settings.
  case configurationChanged
}

func milliseconds(since start: ContinuousClock.Instant) -> Int {
  milliseconds(of: ContinuousClock.now - start)
}

func milliseconds(of duration: Duration) -> Int {
  Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
}
