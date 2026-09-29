import AVFoundation
import BestASRBenchmark
import Darwin
import Foundation

public struct AlphaDangerousTokenSpec: Codable, Equatable, Sendable {
  public let category: DangerousTokenCategory
  public let canonicalValue: String
  public let acceptedSurfaceForms: [String]

  public init(
    category: DangerousTokenCategory,
    canonicalValue: String,
    acceptedSurfaceForms: [String]
  ) {
    self.category = category
    self.canonicalValue = canonicalValue
    self.acceptedSurfaceForms = acceptedSurfaceForms
  }
}

public struct AlphaASRLocalSample: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let relativeAudioPath: String
  public let languages: [String]
  public let tags: [String]
  public let reference: String
  public let dictionaryTerms: [String]
  public let dangerousTokens: [AlphaDangerousTokenSpec]

  public init(
    sampleUUID: UUID,
    relativeAudioPath: String,
    languages: [String],
    tags: [String],
    reference: String,
    dictionaryTerms: [String] = [],
    dangerousTokens: [AlphaDangerousTokenSpec] = []
  ) {
    self.sampleUUID = sampleUUID
    self.relativeAudioPath = relativeAudioPath
    self.languages = languages
    self.tags = tags
    self.reference = reference
    self.dictionaryTerms = dictionaryTerms
    self.dangerousTokens = dangerousTokens
  }
}

public struct AlphaASRLocalRun: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let manifestID: String
  public let version: String
  public let samples: [AlphaASRLocalSample]

  public init(
    schemaVersion: Int = 1,
    kind: String = "alpha-asr-local-corpus-run",
    runID: UUID,
    manifestID: String,
    version: String,
    samples: [AlphaASRLocalSample]
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.runID = runID
    self.manifestID = manifestID
    self.version = version
    self.samples = samples
  }

  public static func decode(_ data: Data) throws -> Self {
    let run: Self
    do {
      run = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw AlphaASREvaluationError.invalidLocalRun
    }
    try run.validate()
    return run
  }

  public func validate() throws {
    guard schemaVersion == 1,
      kind == "alpha-asr-local-corpus-run",
      !manifestID.isEmpty,
      !version.isEmpty,
      !samples.isEmpty,
      Set(samples.map(\.sampleUUID)).count == samples.count
    else {
      throw AlphaASREvaluationError.invalidLocalRun
    }
    for sample in samples {
      let isSilenceLike =
        sample.tags.contains("silence")
        || sample.tags.contains("noise")
      guard Self.safeRelativePath(sample.relativeAudioPath),
        !sample.languages.isEmpty,
        sample.languages.allSatisfy({
          $0.range(
            of: "^[a-z]{2}(-[A-Z]{2})?$",
            options: .regularExpression
          ) != nil
        }),
        !sample.tags.isEmpty,
        Set(sample.tags).count == sample.tags.count,
        sample.dictionaryTerms.count <= 64,
        sample.dictionaryTerms.allSatisfy({
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.count <= 128
        }),
        isSilenceLike || !sample.reference.isEmpty,
        sample.dangerousTokens.allSatisfy({ token in
          !token.canonicalValue.isEmpty
            && !token.acceptedSurfaceForms.isEmpty
            && token.acceptedSurfaceForms.allSatisfy { !$0.isEmpty }
        })
      else {
        throw AlphaASREvaluationError.invalidLocalRun
      }
    }
  }

  private static func safeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), URL(string: path)?.scheme == nil
    else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

public protocol AlphaASRFileTranscribing: Sendable {
  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String
}

public protocol AlphaASRAudioInspecting: Sendable {
  func durationNanoseconds(audioURL: URL) throws -> UInt64
}

public struct AVFoundationAlphaAudioInspector: AlphaASRAudioInspecting {
  public init() {}

  public func durationNanoseconds(audioURL: URL) throws -> UInt64 {
    let file = try AVAudioFile(forReading: audioURL)
    let sampleRate = file.processingFormat.sampleRate
    guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
      throw AlphaASREvaluationError.invalidAudio
    }
    let seconds = Double(file.length) / sampleRate
    guard seconds.isFinite, seconds > 0, seconds <= 600 else {
      throw AlphaASREvaluationError.invalidAudio
    }
    return UInt64((seconds * 1_000_000_000).rounded())
  }
}

public protocol AlphaASRResourceSampling: Sendable {
  func peakResidentBytes() -> UInt64
}

public struct ProcessAlphaASRResourceSampler: AlphaASRResourceSampling {
  public init() {}

  public func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
  }
}

public struct AlphaASRGate: Codable, Equatable, Sendable {
  public let id: String
  public let status: String
  public let observed: Double
  public let maximum: Double

  public init(id: String, passed: Bool, observed: Double, maximum: Double) {
    self.id = id
    status = passed ? "pass" : "fail"
    self.observed = observed
    self.maximum = maximum
  }
}

public struct AlphaASREvaluationDecision: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let status: String
  public let selectionEligible: Bool
  public let corpusManifestID: String
  public let corpusVersion: String
  public let sampleCount: Int
  public let requiredTags: [String]
  public let observedTags: [String]
  public let modelArtifact: BenchmarkModelArtifact
  public let metrics: [BenchmarkMetric]
  public let gates: [AlphaASRGate]
  public let failedSampleUUIDs: [UUID]
  public let networkDeniedByParentSandbox: Bool
  public let evaluationProfile: String?

  public init(
    status: String,
    selectionEligible: Bool,
    corpusManifestID: String,
    corpusVersion: String,
    sampleCount: Int,
    requiredTags: [String],
    observedTags: [String],
    modelArtifact: BenchmarkModelArtifact,
    metrics: [BenchmarkMetric],
    gates: [AlphaASRGate],
    failedSampleUUIDs: [UUID],
    networkDeniedByParentSandbox: Bool,
    evaluationProfile: String? = nil
  ) {
    schemaVersion = 1
    kind = "alpha-asr-evaluation-decision"
    self.status = status
    self.selectionEligible = selectionEligible
    self.corpusManifestID = corpusManifestID
    self.corpusVersion = corpusVersion
    self.sampleCount = sampleCount
    self.requiredTags = requiredTags
    self.observedTags = observedTags
    self.modelArtifact = modelArtifact
    self.metrics = metrics
    self.gates = gates
    self.failedSampleUUIDs = failedSampleUUIDs
    self.networkDeniedByParentSandbox = networkDeniedByParentSandbox
    self.evaluationProfile = evaluationProfile
  }
}

public struct AlphaASREvaluationOutput: Equatable, Sendable {
  public let benchmark: BenchmarkResult
  public let decision: AlphaASREvaluationDecision
  public let localDiagnostics: AlphaASRLocalDiagnostics
}

public struct AlphaASRLocalDiagnostic: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let relativeAudioPath: String
  public let reference: String
  public let hypothesis: String
  public let failureCategory: String?

  public init(
    sampleUUID: UUID,
    relativeAudioPath: String,
    reference: String,
    hypothesis: String,
    failureCategory: String?
  ) {
    self.sampleUUID = sampleUUID
    self.relativeAudioPath = relativeAudioPath
    self.reference = reference
    self.hypothesis = hypothesis
    self.failureCategory = failureCategory
  }
}

public struct AlphaASRLocalDiagnostics: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let samples: [AlphaASRLocalDiagnostic]

  public init(samples: [AlphaASRLocalDiagnostic]) {
    schemaVersion = 1
    kind = "alpha-asr-local-diagnostics"
    self.samples = samples
  }
}

public enum AlphaASREvaluationProfile: String, Codable, Sendable {
  case combined
  case english
  case mandarin

  fileprivate var requiredTags: [String] {
    switch self {
    case .combined:
      AlphaASREvaluationPolicy.requiredTags
    case .english:
      ["english", "numbers-dates-negation", "real-human", "silence"]
    case .mandarin:
      ["mandarin", "numbers-dates-negation", "real-human", "silence"]
    }
  }
}

public struct AlphaASREvaluationPolicy: Sendable {
  public static let requiredTags = [
    "english",
    "mandarin",
    "mixed-language",
    "names-terms",
    "numbers-dates-negation",
    "pace",
    "self-correction",
    "silence",
  ]

  public let maximumCER: Double
  public let maximumWER: Double
  public let maximumMER: Double
  public let maximumDangerousTokenErrors: Double
  public let maximumLatencyP95Milliseconds: Double
  public let maximumRealtimeFactor: Double
  public let maximumPeakResidentBytes: Double
  public let profile: AlphaASREvaluationProfile

  public init(
    maximumCER: Double = 0.15,
    maximumWER: Double = 0.25,
    maximumMER: Double = 0.20,
    maximumDangerousTokenErrors: Double = 0,
    maximumLatencyP95Milliseconds: Double = 3_000,
    maximumRealtimeFactor: Double = 0.75,
    maximumPeakResidentBytes: Double = 1_610_612_736,
    profile: AlphaASREvaluationProfile = .combined
  ) {
    self.maximumCER = maximumCER
    self.maximumWER = maximumWER
    self.maximumMER = maximumMER
    self.maximumDangerousTokenErrors = maximumDangerousTokenErrors
    self.maximumLatencyP95Milliseconds = maximumLatencyP95Milliseconds
    self.maximumRealtimeFactor = maximumRealtimeFactor
    self.maximumPeakResidentBytes = maximumPeakResidentBytes
    self.profile = profile
  }
}

public struct AlphaASREvaluator: Sendable {
  private let transcriber: any AlphaASRFileTranscribing
  private let audioInspector: any AlphaASRAudioInspecting
  private let resourceSampler: any AlphaASRResourceSampling
  private let policy: AlphaASREvaluationPolicy

  public init(
    transcriber: any AlphaASRFileTranscribing,
    audioInspector: any AlphaASRAudioInspecting = AVFoundationAlphaAudioInspector(),
    resourceSampler: any AlphaASRResourceSampling = ProcessAlphaASRResourceSampler(),
    policy: AlphaASREvaluationPolicy = AlphaASREvaluationPolicy()
  ) {
    self.transcriber = transcriber
    self.audioInspector = audioInspector
    self.resourceSampler = resourceSampler
    self.policy = policy
  }

  public func evaluate(
    run: AlphaASRLocalRun,
    audioRoot: URL,
    benchmarkID: String,
    implementationRevision: String,
    modelArtifact: BenchmarkModelArtifact,
    configuration: [String: String],
    environmentRef: String,
    hardware: BenchmarkHardwareContext,
    networkDeniedByParentSandbox: Bool
  ) async throws -> AlphaASREvaluationOutput {
    try run.validate()
    let resolvedRoot = audioRoot.resolvingSymlinksInPath().standardizedFileURL
    var inputs: [BenchmarkSampleInput] = []
    inputs.reserveCapacity(run.samples.count)
    var diagnostics: [AlphaASRLocalDiagnostic] = []
    diagnostics.reserveCapacity(run.samples.count)

    for sample in run.samples {
      try Task.checkCancellation()
      let audioURL =
        resolvedRoot
        .appendingPathComponent(sample.relativeAudioPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
      guard Self.isInside(audioURL, root: resolvedRoot) else {
        throw AlphaASREvaluationError.unsafeAudioPath
      }
      let audioDuration = try audioInspector.durationNanoseconds(
        audioURL: audioURL
      )
      let start = DispatchTime.now().uptimeNanoseconds
      let hypothesis: String
      var failureCategory: String?
      do {
        hypothesis = try await transcriber.transcribe(
          audioURL: audioURL,
          dictionaryTerms: sample.dictionaryTerms
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if sample.tags.contains("silence") || sample.tags.contains("noise"),
          !hypothesis.isEmpty
        {
          failureCategory = "silence-or-noise-hallucination"
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        hypothesis = ""
        failureCategory = "local-asr-runtime"
      }
      let elapsed = max(1, DispatchTime.now().uptimeNanoseconds - start)
      let referenceTokens = sample.dangerousTokens.map {
        DangerousToken(category: $0.category, value: $0.canonicalValue)
      }
      let hypothesisTokens = sample.dangerousTokens.compactMap { spec in
        let normalizedHypothesis = Self.normalizedTokenText(hypothesis)
        let matched = spec.acceptedSurfaceForms.contains {
          normalizedHypothesis.contains(Self.normalizedTokenText($0))
        }
        return matched
          ? DangerousToken(category: spec.category, value: spec.canonicalValue)
          : nil
      }
      inputs.append(
        BenchmarkSampleInput(
          sampleUUID: sample.sampleUUID,
          transcript: TranscriptEvaluation(
            reference: sample.reference,
            hypothesis: hypothesis,
            referenceDangerousTokens: referenceTokens,
            hypothesisDangerousTokens: hypothesisTokens
          ),
          audioDurationNanoseconds: audioDuration,
          inferenceDurationNanoseconds: elapsed,
          latencyNanoseconds: elapsed,
          peakResidentBytes: resourceSampler.peakResidentBytes(),
          backlogHighWatermark: 1,
          failureCategory: failureCategory
        )
      )
      diagnostics.append(
        AlphaASRLocalDiagnostic(
          sampleUUID: sample.sampleUUID,
          relativeAudioPath: sample.relativeAudioPath,
          reference: sample.reference,
          hypothesis: hypothesis,
          failureCategory: failureCategory
        )
      )
    }

    let benchmark = try BenchmarkRunner.evaluate(
      BenchmarkRunInput(
        benchmarkID: benchmarkID,
        runID: run.runID,
        task: .asr,
        protocolVersion: 1,
        implementationRevision: implementationRevision,
        modelArtifact: modelArtifact,
        configuration: configuration,
        corpus: BenchmarkCorpusReference(
          manifestID: run.manifestID,
          version: run.version,
          split: .tuning
        ),
        environmentRef: environmentRef,
        hardware: hardware,
        samples: inputs
      )
    )
    let decision = try decision(
      benchmark: benchmark,
      run: run,
      networkDeniedByParentSandbox: networkDeniedByParentSandbox
    )
    return AlphaASREvaluationOutput(
      benchmark: benchmark,
      decision: decision,
      localDiagnostics: AlphaASRLocalDiagnostics(samples: diagnostics)
    )
  }

  private func decision(
    benchmark: BenchmarkResult,
    run: AlphaASRLocalRun,
    networkDeniedByParentSandbox: Bool
  ) throws -> AlphaASREvaluationDecision {
    let observedTags = Array(Set(run.samples.flatMap(\.tags))).sorted()
    let requiredTags = policy.profile.requiredTags
    let coveragePassed = Set(requiredTags)
      .isSubset(of: Set(observedTags))
    let failedCount = Double(benchmark.failedSampleUUIDs.count)
    var gates = [
      gate("coverage", observed: coveragePassed ? 0 : 1, maximum: 0),
      gate("failed-samples", observed: failedCount, maximum: 0),
    ]
    switch policy.profile {
    case .combined:
      gates.append(
        try metricGate("cer", benchmark: benchmark, maximum: policy.maximumCER)
      )
      gates.append(
        try metricGate("wer", benchmark: benchmark, maximum: policy.maximumWER)
      )
      gates.append(
        try metricGate("mer", benchmark: benchmark, maximum: policy.maximumMER)
      )
    case .english:
      gates.append(
        try metricGate("wer", benchmark: benchmark, maximum: policy.maximumWER)
      )
    case .mandarin:
      gates.append(
        try metricGate("cer", benchmark: benchmark, maximum: policy.maximumCER)
      )
    }
    gates.append(contentsOf: [
      try metricGate(
        "dangerous-token-errors",
        benchmark: benchmark,
        maximum: policy.maximumDangerousTokenErrors
      ),
      try metricGate(
        "latency-p95",
        benchmark: benchmark,
        maximum: policy.maximumLatencyP95Milliseconds
      ),
      try metricGate(
        "realtime-factor",
        benchmark: benchmark,
        maximum: policy.maximumRealtimeFactor
      ),
      try metricGate(
        "peak-rss",
        benchmark: benchmark,
        maximum: policy.maximumPeakResidentBytes
      ),
      gate(
        "network-denied",
        observed: networkDeniedByParentSandbox ? 0 : 1,
        maximum: 0
      ),
    ])
    let eligible = gates.allSatisfy { $0.status == "pass" }
    return AlphaASREvaluationDecision(
      status: eligible ? "pass" : "fail",
      selectionEligible: eligible,
      corpusManifestID: run.manifestID,
      corpusVersion: run.version,
      sampleCount: run.samples.count,
      requiredTags: requiredTags,
      observedTags: observedTags,
      modelArtifact: benchmark.modelArtifact,
      metrics: benchmark.metrics,
      gates: gates,
      failedSampleUUIDs: benchmark.failedSampleUUIDs,
      networkDeniedByParentSandbox: networkDeniedByParentSandbox,
      evaluationProfile: policy.profile.rawValue
    )
  }

  private func metricGate(
    _ name: String,
    benchmark: BenchmarkResult,
    maximum: Double
  ) throws -> AlphaASRGate {
    guard let value = benchmark.metrics.first(where: { $0.name == name })?.value
    else {
      throw AlphaASREvaluationError.missingMetric
    }
    return gate(name, observed: value, maximum: maximum)
  }

  private func gate(
    _ id: String,
    observed: Double,
    maximum: Double
  ) -> AlphaASRGate {
    AlphaASRGate(
      id: id,
      passed: observed.isFinite && observed <= maximum,
      observed: observed,
      maximum: maximum
    )
  }

  private static func normalizedTokenText(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
      .lowercased()
      .unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
  }

  private static func isInside(_ url: URL, root: URL) -> Bool {
    url.path == root.path || url.path.hasPrefix(root.path + "/")
  }
}

public enum AlphaASREvaluationError: Error, Equatable, Sendable {
  case invalidAudio
  case invalidLocalRun
  case missingMetric
  case unsafeAudioPath
}
