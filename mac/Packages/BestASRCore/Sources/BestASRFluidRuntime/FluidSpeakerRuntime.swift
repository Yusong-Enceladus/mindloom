import BestASRInference
import BestASRModelManager
@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation

public enum FluidSpeakerPinnedArtifact {
  public static let artifactID = "fluid-speaker-diarization-coreml-1ed7a662"
  public static let sourceRevision =
    "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
  public static let treeSHA256 =
    "664824fe8a2d387aad8ad7965191a90b9b290c5ea5470c3bd13a86a8cc8bf9ab"
  public static let runtimeRevision =
    "19600a485baa4998812e4654b70d2bab8f2c9949"
  public static let embeddingSpaceID =
    "fluid-community1-embedding-256-v1"
  public static let pipelineRevision =
    "fluid-speaker-final-v2-community-distance-0.6"

  public static let descriptor = ModelArtifactDescriptor(
    artifactID: artifactID,
    version: sourceRevision,
    sha256: treeSHA256,
    runtimeID: InferenceRuntimeID("fluid-audio.offline-diarizer"),
    capabilities: [.diarizationBatch, .speakerEmbedding],
    minimumOS: InferenceOSVersion(major: 14, minor: 2),
    supportedArchitectures: ["arm64"],
    minimumUnifiedMemoryBytes: 17_179_869_184,
    licenseIdentifier: "CC-BY-4.0",
    networkRequired: false,
    metadata: [
      "embeddingDimensions": "256",
      "embeddingSpaceID": embeddingSpaceID,
      "runtimeRevision": runtimeRevision,
      "sourceRevision": sourceRevision,
      "pipelineRevision": pipelineRevision,
    ]
  )

  fileprivate static let requiredRuntimePaths = [
    "Embedding.mlmodelc",
    "FBank.mlmodelc",
    "PldaRho.mlmodelc",
    "Segmentation.mlmodelc",
    "plda-parameters.json",
  ]
}

enum FluidSpeakerClusteringPolicy {
  static let communityDistanceThreshold = 0.6

  static func configuration(
    expectedSpeakerRange: ClosedRange<Int>?
  ) -> OfflineDiarizerConfig {
    var config = OfflineDiarizerConfig.default
    // The pinned SDK documents a Euclidean threshold but AHC interprets the
    // argument as cosine similarity, then applies sqrt(2 - 2 * similarity).
    // Convert community-1's distance explicitly; passing 0.6 directly widens
    // the distance to ~0.894 and can merge distinct voices after capture.
    config.clustering.threshold =
      1 - communityDistanceThreshold * communityDistanceThreshold / 2
    if let expectedSpeakerRange {
      config = config.withSpeakers(
        min: max(1, expectedSpeakerRange.lowerBound),
        max: max(1, expectedSpeakerRange.upperBound)
      )
    }
    config.exposeChunkEmbeddings = true
    return config
  }
}

public struct FluidSpeakerModelHealthCheck: ManagedModelHealthChecking {
  public init() {}

  public func check(modelDirectory: URL) async throws {
    try FluidSpeakerRuntime.validateRuntimeFiles(in: modelDirectory)
    _ = try FluidSpeakerRuntime.loadVerifiedModels(from: modelDirectory)
  }
}

public enum FluidSpeakerRuntimeFactory {
  public static func make(
    modelManager: LocalModelManager,
    audioAssetRoot: URL
  ) async throws -> FluidSpeakerRuntime {
    let active = try await modelManager.discoverActive(
      artifactID: FluidSpeakerPinnedArtifact.artifactID,
      healthCheck: FileSetModelHealthCheck()
    )
    guard
      active.descriptor.exactVersion == FluidSpeakerPinnedArtifact.sourceRevision,
      active.descriptor.treeSHA256 == FluidSpeakerPinnedArtifact.treeSHA256
    else {
      throw FluidSpeakerRuntime.failure(
        .incompatibleArtifact,
        "fluid-speaker-active-artifact-mismatch"
      )
    }
    try FluidSpeakerRuntime.validateRuntimeFiles(in: active.directory)
    let models = try FluidSpeakerRuntime.loadVerifiedModels(from: active.directory)
    return try FluidSpeakerRuntime(
      verifiedAudioAssetRoot: audioAssetRoot,
      models: models
    )
  }
}

public struct FluidSpeakerClusterEvidence: Equatable, Sendable {
  public let speakerClusterID: String
  public let vector: [Float]
  public let speechDurationNanoseconds: UInt64
  public let signalQuality: Double

  public init(
    speakerClusterID: String,
    vector: [Float],
    speechDurationNanoseconds: UInt64,
    signalQuality: Double
  ) {
    self.speakerClusterID = speakerClusterID
    self.vector = vector
    self.speechDurationNanoseconds = speechDurationNanoseconds
    self.signalQuality = signalQuality
  }
}

public struct FluidSpeakerAnalysis: Equatable, Sendable {
  public let diarization: BestASRInference.DiarizationResult
  public let clusters: [FluidSpeakerClusterEvidence]

  public init(
    diarization: BestASRInference.DiarizationResult,
    clusters: [FluidSpeakerClusterEvidence]
  ) {
    self.diarization = diarization
    self.clusters = clusters
  }
}

/// Exact-pinned, offline-only speaker diarization and embedding runtime.
///
/// Model discovery and every file digest are completed by `LocalModelManager`
/// before construction. Unlike FluidAudio's convenience preparation API, this
/// runtime never invokes an automatic model download path.
public actor FluidSpeakerRuntime: DiarizationEngine, SpeakerEmbeddingEngine {
  private let audioAssetRoot: URL
  private let models: OfflineDiarizerModels

  fileprivate init(
    verifiedAudioAssetRoot: URL,
    models: OfflineDiarizerModels
  ) throws {
    let root = verifiedAudioAssetRoot.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      root.path != "/"
    else {
      throw Self.failure(.corruptInput, "fluid-speaker-audio-root-missing")
    }
    audioAssetRoot = root
    self.models = models
  }

  public func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: FluidSpeakerPinnedArtifact.descriptor)
  }

  public func diarize(
    _ request: BestASRInference.DiarizationRequest
  ) async throws -> BestASRInference.DiarizationResult {
    try await analyze(request).diarization
  }

  public func analyze(
    _ request: BestASRInference.DiarizationRequest
  ) async throws -> FluidSpeakerAnalysis {
    try validate(metadata: request.metadata)
    let source = try VerifiedFloat32RangeSource(
      rootDirectory: audioAssetRoot,
      inputs: request.audio
    )
    try InferenceCancellation.check()

    let config = FluidSpeakerClusteringPolicy.configuration(
      expectedSpeakerRange: request.expectedSpeakerRange
    )
    let manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: models)
    let result = try await {
      do {
        return try await manager.process(
          audioSource: source,
          audioLoadingSeconds: 0
        )
      } catch is CancellationError {
        throw InferenceEngineError.cancelled
      } catch let error as InferenceEngineError {
        throw error
      } catch let error as OfflineDiarizationError {
        throw Self.failure(for: error)
      } catch {
        throw Self.failure(
          .transientRuntime,
          "fluid-speaker-diarization-failed",
          true
        )
      }
    }()
    try InferenceCancellation.check()

    let turns = result.segments.flatMap { segment in
      source.timeline.map(
        segment: segment,
        jobID: request.metadata.jobID,
        allSegments: result.segments
      )
    }.sorted {
      if $0.monotonicStartNanoseconds == $1.monotonicStartNanoseconds {
        return $0.turnID.uuidString < $1.turnID.uuidString
      }
      return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
    }
    let diarization = BestASRInference.DiarizationResult(
      modelArtifactID: FluidSpeakerPinnedArtifact.artifactID,
      turns: turns
    )
    let clusters = try Set(result.segments.map(\.speakerId)).sorted().map {
      clusterID -> FluidSpeakerClusterEvidence in
      let segments = result.segments.filter { $0.speakerId == clusterID }
      let clusterTurns = turns.filter { $0.speakerClusterID == clusterID }
      let speechDuration = clusterTurns.reduce(UInt64(0)) {
        $0 + ($1.monotonicEndNanoseconds - $1.monotonicStartNanoseconds)
      }
      guard speechDuration > 0 else {
        throw Self.failure(.invalidRequest, "fluid-speaker-empty-cluster")
      }
      let weightedQuality =
        clusterTurns.reduce(0.0) { partial, turn in
          let duration = Double(
            turn.monotonicEndNanoseconds - turn.monotonicStartNanoseconds
          )
          return partial + (turn.confidence ?? 0) * duration
        } / Double(speechDuration)
      return FluidSpeakerClusterEvidence(
        speakerClusterID: clusterID,
        vector: try Self.weightedEmbedding(from: segments),
        speechDurationNanoseconds: speechDuration,
        signalQuality: max(0, min(1, weightedQuality))
      )
    }
    return FluidSpeakerAnalysis(diarization: diarization, clusters: clusters)
  }

  public func embed(
    _ request: SpeakerEmbeddingRequest
  ) async throws -> SpeakerEmbeddingResult {
    try validate(metadata: request.metadata)
    guard request.embeddingSpaceID == FluidSpeakerPinnedArtifact.embeddingSpaceID else {
      throw Self.failure(
        .invalidRequest,
        "fluid-speaker-embedding-space-mismatch"
      )
    }
    let source = try VerifiedFloat32RangeSource(
      rootDirectory: audioAssetRoot,
      inputs: [request.audio]
    )
    var config = OfflineDiarizerConfig.default.withSpeakers(exactly: 1)
    config.exposeChunkEmbeddings = true
    let manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: models)
    let result = try await {
      do {
        return try await manager.process(
          audioSource: source,
          audioLoadingSeconds: 0
        )
      } catch is CancellationError {
        throw InferenceEngineError.cancelled
      } catch {
        throw Self.failure(
          .transientRuntime,
          "fluid-speaker-embedding-failed",
          true
        )
      }
    }()
    try InferenceCancellation.check()
    let vector = try Self.weightedEmbedding(from: result.segments)
    return SpeakerEmbeddingResult(
      modelArtifactID: FluidSpeakerPinnedArtifact.artifactID,
      embeddingSpaceID: FluidSpeakerPinnedArtifact.embeddingSpaceID,
      vector: vector
    )
  }

  private func validate(metadata: InferenceRequestMetadata) throws {
    guard metadata.contractVersion == InferenceContract.currentVersion else {
      throw Self.failure(
        .unsupportedContractVersion,
        "fluid-speaker-contract-version"
      )
    }
    guard metadata.modelArtifactID == FluidSpeakerPinnedArtifact.artifactID else {
      throw Self.failure(
        .incompatibleArtifact,
        "fluid-speaker-request-artifact-mismatch"
      )
    }
    guard metadata.inputRevision > 0, !metadata.configHash.isEmpty else {
      throw Self.failure(.invalidRequest, "fluid-speaker-invalid-request-metadata")
    }
  }

  fileprivate static func validateRuntimeFiles(in directory: URL) throws {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      root.path != "/"
    else {
      throw failure(.modelUnavailable, "fluid-speaker-model-directory-missing")
    }
    for relativePath in FluidSpeakerPinnedArtifact.requiredRuntimePaths {
      let candidate = root.appendingPathComponent(relativePath)
      var candidateIsDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: candidate.path,
          isDirectory: &candidateIsDirectory
        ),
        relativePath.hasSuffix(".mlmodelc")
          ? candidateIsDirectory.boolValue
          : !candidateIsDirectory.boolValue
      else {
        throw failure(.modelUnavailable, "fluid-speaker-required-file-missing")
      }
    }
  }

  /// Loads only the exact ModelManager-verified local files. FluidAudio's
  /// `OfflineDiarizerModels.load` is intentionally not used because its
  /// ModelHub path treats a missing cache subdirectory as permission to
  /// download and may purge the caller's directory after a load failure.
  fileprivate static func loadVerifiedModels(
    from directory: URL
  ) throws -> OfflineDiarizerModels {
    try validateRuntimeFiles(in: directory)
    ModelHub.offlineMode = true
    let started = Date()
    let inferenceConfiguration = MLModelConfiguration()
    inferenceConfiguration.computeUnits = .all
    inferenceConfiguration.allowLowPrecisionAccumulationOnGPU = true
    let fbankConfiguration = MLModelConfiguration()
    fbankConfiguration.computeUnits = .cpuOnly
    fbankConfiguration.allowLowPrecisionAccumulationOnGPU = true

    let segmentation = try MLModel(
      contentsOf: directory.appendingPathComponent("Segmentation.mlmodelc"),
      configuration: inferenceConfiguration
    )
    let embedding = try MLModel(
      contentsOf: directory.appendingPathComponent("Embedding.mlmodelc"),
      configuration: inferenceConfiguration
    )
    let pldaRho = try MLModel(
      contentsOf: directory.appendingPathComponent("PldaRho.mlmodelc"),
      configuration: inferenceConfiguration
    )
    let fbank = try MLModel(
      contentsOf: directory.appendingPathComponent("FBank.mlmodelc"),
      configuration: fbankConfiguration
    )
    return OfflineDiarizerModels(
      segmentationModel: segmentation,
      fbankModel: fbank,
      embeddingModel: embedding,
      pldaRhoModel: pldaRho,
      pldaPsi: try loadPLDAPsi(
        from: directory.appendingPathComponent("plda-parameters.json")
      ),
      compilationDuration: Date().timeIntervalSince(started)
    )
  }

  private static func loadPLDAPsi(from url: URL) throws -> [Double] {
    let data = try Data(contentsOf: url)
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tensors = root["tensors"] as? [String: Any],
      let psi = tensors["psi"] as? [String: Any],
      let encoded = psi["data_base64"] as? String,
      let decoded = Data(
        base64Encoded: encoded,
        options: [.ignoreUnknownCharacters]
      ),
      !decoded.isEmpty,
      decoded.count.isMultiple(of: MemoryLayout<Float>.size)
    else {
      throw failure(.modelUnavailable, "fluid-speaker-plda-parameters-invalid")
    }
    var values = [Float](
      repeating: 0,
      count: decoded.count / MemoryLayout<Float>.size
    )
    _ = values.withUnsafeMutableBytes { destination in
      decoded.copyBytes(to: destination)
    }
    guard values.allSatisfy(\.isFinite) else {
      throw failure(.modelUnavailable, "fluid-speaker-plda-parameters-invalid")
    }
    return values.map(Double.init)
  }

  fileprivate static func failure(
    _ category: InferenceFailureCategory,
    _ code: String,
    _ retryable: Bool = false
  ) -> InferenceEngineError {
    InferenceEngineError(category: category, code: code, retryable: retryable)
  }

  static func failure(
    for error: OfflineDiarizationError
  ) -> InferenceEngineError {
    switch error {
    case .noSpeechDetected:
      failure(.corruptInput, "fluid-speaker-no-speech-detected")
    case .modelNotLoaded:
      failure(.modelUnavailable, "fluid-speaker-model-not-loaded", true)
    case .invalidConfiguration, .invalidBatchSize:
      failure(.incompatibleArtifact, "fluid-speaker-runtime-configuration")
    case .processingFailed, .exportFailed:
      failure(.transientRuntime, "fluid-speaker-diarization-failed", true)
    }
  }

  private static func weightedEmbedding(
    from segments: [TimedSpeakerSegment]
  ) throws -> [Float] {
    let usable = segments.filter {
      !$0.embedding.isEmpty
        && $0.endTimeSeconds > $0.startTimeSeconds
        && $0.embedding.allSatisfy(\.isFinite)
    }
    guard let dimensions = usable.first?.embedding.count, dimensions > 0,
      usable.allSatisfy({ $0.embedding.count == dimensions })
    else {
      throw failure(.invalidRequest, "fluid-speaker-no-embedding-evidence")
    }
    var result = [Double](repeating: 0, count: dimensions)
    var totalWeight = 0.0
    for segment in usable {
      let duration = Double(segment.endTimeSeconds - segment.startTimeSeconds)
      let quality = max(0.05, min(1, Double(segment.qualityScore)))
      let weight = duration * quality
      totalWeight += weight
      for index in result.indices {
        result[index] += Double(segment.embedding[index]) * weight
      }
    }
    guard totalWeight > 0 else {
      throw failure(.invalidRequest, "fluid-speaker-no-embedding-evidence")
    }
    var normalized = result.map { Float($0 / totalWeight) }
    let norm = sqrt(normalized.reduce(0.0) { $0 + Double($1 * $1) })
    guard norm.isFinite, norm > 0 else {
      throw failure(.transientRuntime, "fluid-speaker-invalid-embedding")
    }
    for index in normalized.indices {
      normalized[index] /= Float(norm)
    }
    return normalized
  }
}

private struct VerifiedFloat32RangeSource: AudioSampleSource {
  struct Part: @unchecked Sendable {
    let input: AudioRangeInput
    let samples: Data
    let startSample: Int
    let endSample: Int
  }

  let parts: [Part]
  let sampleCount: Int
  let timeline: FluidSpeakerTimeline

  init(rootDirectory: URL, inputs: [AudioRangeInput]) throws {
    guard !inputs.isEmpty else {
      throw FluidSpeakerRuntime.failure(
        .invalidRequest,
        "fluid-speaker-empty-audio"
      )
    }
    let trackIDs = Set(inputs.map(\.trackID))
    guard trackIDs.count == 1 else {
      throw FluidSpeakerRuntime.failure(
        .invalidRequest,
        "fluid-speaker-mixed-track-request"
      )
    }
    var loaded: [Part] = []
    var nextSample = 0
    var previousEnd: UInt64?
    for input in inputs {
      guard
        input.sampleRateHertz == 16_000,
        input.channelCount == 1,
        input.monotonicStartNanoseconds < input.monotonicEndNanoseconds,
        previousEnd.map({ input.monotonicStartNanoseconds >= $0 }) ?? true,
        input.contentDigest.range(
          of: "^[0-9a-f]{64}$",
          options: .regularExpression
        ) != nil,
        let url = Self.safeURL(root: rootDirectory, reference: input.assetReference)
      else {
        throw FluidSpeakerRuntime.failure(
          .corruptInput,
          "fluid-speaker-invalid-audio-range"
        )
      }
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let byteCount = values.fileSize,
        byteCount > 0,
        byteCount.isMultiple(of: MemoryLayout<Float>.size)
      else {
        throw FluidSpeakerRuntime.failure(
          .corruptInput,
          "fluid-speaker-audio-file-invalid"
        )
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      let digest = SHA256.hash(data: data).map {
        String(format: "%02x", $0)
      }.joined()
      guard digest == input.contentDigest else {
        throw FluidSpeakerRuntime.failure(
          .corruptInput,
          "fluid-speaker-audio-digest-mismatch"
        )
      }
      let count = byteCount / MemoryLayout<Float>.size
      guard count <= Int.max - nextSample else {
        throw FluidSpeakerRuntime.failure(
          .resourcePressure,
          "fluid-speaker-audio-too-large"
        )
      }
      loaded.append(
        Part(
          input: input,
          samples: data,
          startSample: nextSample,
          endSample: nextSample + count
        )
      )
      nextSample += count
      previousEnd = input.monotonicEndNanoseconds
    }
    parts = loaded
    sampleCount = nextSample
    timeline = FluidSpeakerTimeline(parts: loaded)
  }

  func copySamples(
    into destination: UnsafeMutablePointer<Float>,
    offset: Int,
    count: Int
  ) throws {
    guard count > 0, offset >= 0, offset < sampleCount else { return }
    let end = min(sampleCount, offset + count)
    var written = 0
    for part in parts where part.endSample > offset && part.startSample < end {
      let partStart = max(offset, part.startSample)
      let partEnd = min(end, part.endSample)
      let sampleOffset = partStart - part.startSample
      let copyCount = partEnd - partStart
      part.samples.withUnsafeBytes { raw in
        let source = raw.baseAddress!.advanced(
          by: sampleOffset * MemoryLayout<Float>.size
        )
        let target = UnsafeMutableRawPointer(destination.advanced(by: written))
        target.copyMemory(
          from: source,
          byteCount: copyCount * MemoryLayout<Float>.size
        )
      }
      written += copyCount
    }
  }

  private static func safeURL(root: URL, reference: String) -> URL? {
    guard
      !reference.isEmpty,
      !reference.hasPrefix("/"),
      !reference.contains(".."),
      URL(string: reference)?.scheme == nil
    else { return nil }
    let resolved = root.appendingPathComponent(reference)
      .resolvingSymlinksInPath().standardizedFileURL
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard resolved.path.hasPrefix(prefix) else { return nil }
    return resolved
  }
}

private struct FluidSpeakerTimeline: Sendable {
  struct Span: Sendable {
    let input: AudioRangeInput
    let startSample: Int
    let endSample: Int
  }

  let spans: [Span]

  init(parts: [VerifiedFloat32RangeSource.Part]) {
    spans = parts.map {
      Span(
        input: $0.input,
        startSample: $0.startSample,
        endSample: $0.endSample
      )
    }
  }

  func map(
    segment: TimedSpeakerSegment,
    jobID: UUID,
    allSegments: [TimedSpeakerSegment]
  ) -> [DiarizationTurn] {
    let rawStart = max(0, Int(floor(Double(segment.startTimeSeconds) * 16_000)))
    let rawEnd = max(rawStart + 1, Int(ceil(Double(segment.endTimeSeconds) * 16_000)))
    let overlaps = allSegments.contains { other in
      other.id != segment.id
        && other.startTimeSeconds < segment.endTimeSeconds
        && other.endTimeSeconds > segment.startTimeSeconds
    }
    var mapped: [DiarizationTurn] = []
    for (index, span) in spans.enumerated()
    where span.endSample > rawStart && span.startSample < rawEnd {
      let start = max(rawStart, span.startSample)
      let end = min(rawEnd, span.endSample)
      let localStart = start - span.startSample
      let localEnd = end - span.startSample
      let startNS =
        span.input.monotonicStartNanoseconds
        + Self.nanoseconds(forSamples: localStart)
      let endNS = min(
        span.input.monotonicEndNanoseconds,
        span.input.monotonicStartNanoseconds
          + Self.nanoseconds(forSamples: localEnd)
      )
      guard endNS > startNS else { continue }
      mapped.append(
        DiarizationTurn(
          turnID: Self.deterministicUUID(
            [
              jobID.uuidString.lowercased(),
              segment.speakerId,
              String(startNS),
              String(endNS),
              String(index),
            ].joined(separator: "\u{1f}")
          ),
          speakerClusterID: segment.speakerId,
          monotonicStartNanoseconds: startNS,
          monotonicEndNanoseconds: endNS,
          confidence: Double(max(0, min(1, segment.qualityScore))),
          overlapsAnotherSpeaker: overlaps
        )
      )
    }
    return mapped
  }

  private static func nanoseconds(forSamples samples: Int) -> UInt64 {
    UInt64((Double(samples) * 1_000_000_000 / 16_000).rounded())
  }

  private static func deterministicUUID(_ seed: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}
