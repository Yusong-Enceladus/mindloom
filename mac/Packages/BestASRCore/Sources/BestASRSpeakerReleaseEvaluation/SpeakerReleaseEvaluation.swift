import BestASRBenchmark
import BestASRFluidRuntime
import BestASRInference
import CryptoKit
import Darwin
import Dispatch
import Foundation

public struct SpeakerFrozenIdentityProfile: Codable, Equatable, Sendable {
  public let personID: String
  public let enrollmentCount: Int
  public let vector: [Float]
}

public struct SpeakerFrozenIdentityModel: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let privacyClass: String
  public let candidate: String
  public let modelArtifactID: String
  public let modelArtifactSHA256: String
  public let embeddingSpaceID: String
  public let calibrationCorpusManifestID: String
  public let calibrationCorpusVersion: String
  public let thresholdPolicy: String
  public let thresholdMargin: Double
  public let threshold: Double
  public let separationFeasible: Bool
  public let minimumGenuineSimilarity: Double
  public let maximumImpostorSimilarity: Double
  public let profiles: [SpeakerFrozenIdentityProfile]

  public init(
    calibrationCorpusManifestID: String,
    calibrationCorpusVersion: String,
    thresholdMargin: Double,
    threshold: Double,
    separationFeasible: Bool,
    minimumGenuineSimilarity: Double,
    maximumImpostorSimilarity: Double,
    profiles: [SpeakerFrozenIdentityProfile]
  ) {
    schemaVersion = 1
    kind = "local-only-speaker-identity-calibration"
    privacyClass = "biometric-local-only-never-commit"
    candidate = "fluid"
    modelArtifactID = FluidSpeakerPinnedArtifact.artifactID
    modelArtifactSHA256 = FluidSpeakerPinnedArtifact.treeSHA256
    embeddingSpaceID = FluidSpeakerPinnedArtifact.embeddingSpaceID
    self.calibrationCorpusManifestID = calibrationCorpusManifestID
    self.calibrationCorpusVersion = calibrationCorpusVersion
    thresholdPolicy = "enrollment-only-impostor-protected-conservative"
    self.thresholdMargin = thresholdMargin
    self.threshold = threshold
    self.separationFeasible = separationFeasible
    self.minimumGenuineSimilarity = minimumGenuineSimilarity
    self.maximumImpostorSimilarity = maximumImpostorSimilarity
    self.profiles = profiles
  }

  public static func decode(_ data: Data) throws -> Self {
    let model: Self
    do {
      model = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw SpeakerReleaseEvaluationError.invalidFrozenModel
    }
    try model.validate()
    return model
  }

  public func validate() throws {
    guard schemaVersion == 1,
      kind == "local-only-speaker-identity-calibration",
      privacyClass == "biometric-local-only-never-commit",
      candidate == "fluid",
      modelArtifactID == FluidSpeakerPinnedArtifact.artifactID,
      modelArtifactSHA256 == FluidSpeakerPinnedArtifact.treeSHA256,
      embeddingSpaceID == FluidSpeakerPinnedArtifact.embeddingSpaceID,
      !calibrationCorpusManifestID.isEmpty,
      !calibrationCorpusVersion.isEmpty,
      thresholdPolicy == "enrollment-only-impostor-protected-conservative",
      thresholdMargin > 0,
      thresholdMargin < 0.5,
      threshold.isFinite,
      (-1...1).contains(threshold),
      minimumGenuineSimilarity.isFinite,
      maximumImpostorSimilarity.isFinite,
      profiles.count >= 2,
      Set(profiles.map(\.personID)).count == profiles.count,
      profiles.allSatisfy({
        !$0.personID.isEmpty
          && $0.enrollmentCount >= 2
          && !$0.vector.isEmpty
          && $0.vector.allSatisfy(\.isFinite)
      }),
      Set(profiles.map(\.vector.count)).count == 1
    else {
      throw SpeakerReleaseEvaluationError.invalidFrozenModel
    }
  }
}

public struct SpeakerEvaluationGate: Codable, Equatable, Sendable {
  public let id: String
  public let status: String
  public let observed: Double
  public let requirement: String

  public init(
    id: String,
    passed: Bool,
    observed: Double,
    requirement: String
  ) {
    self.id = id
    status = passed ? "pass" : "fail"
    self.observed = observed
    self.requirement = requirement
  }
}

public struct SpeakerEvaluationModeSummary: Codable, Equatable, Sendable {
  public let mode: SpeakerEvaluationEntryMode
  public let knownCount: Int
  public let knownCorrectCount: Int
  public let knownWrongCount: Int
  public let knownRejectedCount: Int
  public let unknownCount: Int
  public let unknownRejectedCount: Int
}

public struct SpeakerReleaseEvaluationDecision: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let phase: String
  public let status: String
  public let eligibleForHoldout: Bool
  public let selectionEligible: Bool
  public let candidate: String
  public let corpusManifestID: String
  public let corpusVersion: String
  public let sampleCount: Int
  public let requiredModes: [SpeakerEvaluationEntryMode]
  public let observedModes: [SpeakerEvaluationEntryMode]
  public let thresholdPolicy: String
  public let threshold: Double
  public let enrollmentSeparationFeasible: Bool
  public let knownQueryCount: Int
  public let knownCorrectCount: Int
  public let knownWrongCount: Int
  public let knownRejectedCount: Int
  public let unknownQueryCount: Int
  public let unknownRejectedCount: Int
  public let falseMergeCount: Int
  public let falseSplitCount: Int
  public let falseRejectCount: Int
  public let modeSummaries: [SpeakerEvaluationModeSummary]
  public let metrics: [BenchmarkMetric]
  public let gates: [SpeakerEvaluationGate]
  public let failedSampleUUIDs: [UUID]
  public let networkDeniedByParentSandbox: Bool
}

public struct SpeakerIdentityLocalDiagnostic: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let expectedPersonID: String
  public let predictedPersonID: String?
  public let evidenceSufficient: Bool
  public let mode: SpeakerEvaluationEntryMode
  public let nearestSimilarity: Double
}

public struct SpeakerReleaseLocalDiagnostics: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let privacyClass: String
  public let assignments: [SpeakerIdentityLocalDiagnostic]

  public init(assignments: [SpeakerIdentityLocalDiagnostic]) {
    schemaVersion = 1
    kind = "speaker-release-local-diagnostics"
    privacyClass = "local-only-pseudonymous-no-embeddings"
    self.assignments = assignments
  }
}

public struct SpeakerEvaluationOutput: Sendable {
  public let benchmark: BenchmarkResult
  public let decision: SpeakerReleaseEvaluationDecision
  public let diagnostics: SpeakerReleaseLocalDiagnostics
  public let frozenModel: SpeakerFrozenIdentityModel?
}

public enum SpeakerReleaseEvaluationError: Error, Equatable, Sendable {
  case corpusMismatch
  case inconsistentEmbeddingDimension
  case insufficientEnrollment(String)
  case invalidFrozenModel
  case invalidThresholdMargin
  case missingProfile
  case noQueries
}

public protocol ProductionSpeakerEvaluationEngine: Sendable {
  func diarize(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID,
    expectedSpeakerRange: ClosedRange<Int>?
  ) async throws -> [SpeakerSegment]

  func embed(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID
  ) async throws -> [Float]
}

public actor FluidProductionSpeakerEvaluationEngine:
  ProductionSpeakerEvaluationEngine
{
  private let runtime: FluidSpeakerRuntime

  public init(runtime: FluidSpeakerRuntime) {
    self.runtime = runtime
  }

  public func diarize(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID,
    expectedSpeakerRange: ClosedRange<Int>?
  ) async throws -> [SpeakerSegment] {
    let analysis = try await runtime.analyze(
      DiarizationRequest(
        metadata: metadata(jobID: jobID),
        audio: [input(audio: audio, jobID: jobID)],
        expectedSpeakerRange: expectedSpeakerRange
      )
    )
    return analysis.diarization.turns.map {
      SpeakerSegment(
        speakerID: $0.speakerClusterID,
        startNanoseconds: $0.monotonicStartNanoseconds,
        endNanoseconds: $0.monotonicEndNanoseconds
      )
    }
  }

  public func embed(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID
  ) async throws -> [Float] {
    (try await runtime.embed(
      SpeakerEmbeddingRequest(
        metadata: metadata(jobID: jobID),
        audio: input(audio: audio, jobID: jobID),
        embeddingSpaceID: FluidSpeakerPinnedArtifact.embeddingSpaceID
      )
    )).vector
  }

  private func metadata(jobID: UUID) -> InferenceRequestMetadata {
    InferenceRequestMetadata(
      jobID: jobID,
      inputRevision: 1,
      modelArtifactID: FluidSpeakerPinnedArtifact.artifactID,
      configHash: "ami-public-speaker-release-v1|\(FluidSpeakerPinnedArtifact.pipelineRevision)"
    )
  }

  private func input(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID
  ) -> AudioRangeInput {
    AudioRangeInput(
      sourceID: jobID,
      trackID: jobID,
      assetReference: audio.relativePath,
      contentDigest: audio.contentDigest,
      monotonicStartNanoseconds: 0,
      monotonicEndNanoseconds: audio.durationNanoseconds,
      sampleRateHertz: 16_000,
      channelCount: 1
    )
  }
}

public enum SpeakerReleaseEvaluator {
  public static func calibrate(
    tuningRoot: URL,
    releaseHoldoutRoot: URL,
    engine: any ProductionSpeakerEvaluationEngine,
    thresholdMargin: Double = 0.03,
    hardware: BenchmarkHardwareContext,
    networkDeniedByParentSandbox: Bool
  ) async throws -> SpeakerEvaluationOutput {
    guard thresholdMargin > 0, thresholdMargin < 0.5 else {
      throw SpeakerReleaseEvaluationError.invalidThresholdMargin
    }
    let loaded = try load(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseHoldoutRoot,
      split: .tuning
    )
    let measured = try await measure(run: loaded.run, engine: engine)
    let frozen = try freeze(
      run: loaded.run,
      observations: measured.identity,
      thresholdMargin: thresholdMargin
    )
    let predictions = try predict(
      samples: measured.identity.filter { $0.sample.role == .query },
      model: frozen
    )
    return try output(
      phase: "tuning-calibration",
      run: loaded.run,
      measured: measured,
      predictions: predictions,
      frozenModel: frozen,
      hardware: hardware,
      networkDeniedByParentSandbox: networkDeniedByParentSandbox
    )
  }

  public static func evaluateReleaseHoldout(
    tuningRoot: URL,
    releaseHoldoutRoot: URL,
    frozenModel: SpeakerFrozenIdentityModel,
    engine: any ProductionSpeakerEvaluationEngine,
    hardware: BenchmarkHardwareContext,
    networkDeniedByParentSandbox: Bool
  ) async throws -> SpeakerEvaluationOutput {
    try frozenModel.validate()
    let loaded = try load(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseHoldoutRoot,
      split: .releaseHoldout
    )
    let measured = try await measure(run: loaded.run, engine: engine)
    let predictions = try predict(
      samples: measured.identity,
      model: frozenModel
    )
    return try output(
      phase: "release-holdout",
      run: loaded.run,
      measured: measured,
      predictions: predictions,
      frozenModel: frozenModel,
      hardware: hardware,
      networkDeniedByParentSandbox: networkDeniedByParentSandbox
    )
  }

  private static func load(
    tuningRoot: URL,
    releaseHoldoutRoot: URL,
    split: SpeakerEvaluationSplit
  ) throws -> (manifest: CorpusManifest, run: AMISpeakerLocalRun) {
    let store = try IsolatedCorpusStore(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseHoldoutRoot
    )
    let root = split == .tuning ? tuningRoot : releaseHoldoutRoot
    let manifest = try store.loadManifest(
      at: root.appendingPathComponent("manifest.json"),
      mode: split == .tuning ? .tuning : .releaseEvaluation
    )
    let run = try AMISpeakerLocalRun.decode(
      Data(contentsOf: root.appendingPathComponent("local-run.json"))
    )
    guard run.split == split,
      run.corpusManifestID == manifest.manifestID,
      run.corpusVersion == manifest.version
    else {
      throw SpeakerReleaseEvaluationError.corpusMismatch
    }
    return (manifest, run)
  }

  private static func measure(
    run: AMISpeakerLocalRun,
    engine: any ProductionSpeakerEvaluationEngine
  ) async throws -> MeasuredRun {
    var diarization: [MeasuredDiarization] = []
    for sample in run.diarizationSamples {
      try Task.checkCancellation()
      let start = DispatchTime.now().uptimeNanoseconds
      let hypothesis = try await engine.diarize(
        audio: sample.audio,
        jobID: sample.sampleUUID,
        // Match the App's final pipeline. AMI's annotated participant count
        // is evaluation truth, not a permissible hint to the clustering SDK.
        expectedSpeakerRange: nil
      )
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      diarization.append(
        MeasuredDiarization(
          sample: sample,
          hypothesis: hypothesis,
          inferenceDurationNanoseconds: elapsed,
          peakResidentBytes: peakResidentBytes()
        )
      )
    }

    var identity: [MeasuredIdentity] = []
    for sample in run.identitySamples {
      try Task.checkCancellation()
      let start = DispatchTime.now().uptimeNanoseconds
      let vector = try await engine.embed(
        audio: sample.audio,
        jobID: sample.sampleUUID
      )
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      identity.append(
        MeasuredIdentity(
          sample: sample,
          vector: try normalized(vector),
          inferenceDurationNanoseconds: elapsed,
          peakResidentBytes: peakResidentBytes()
        )
      )
    }
    return MeasuredRun(diarization: diarization, identity: identity)
  }

  private static func freeze(
    run: AMISpeakerLocalRun,
    observations: [MeasuredIdentity],
    thresholdMargin: Double
  ) throws -> SpeakerFrozenIdentityModel {
    let enrollment = observations.filter { $0.sample.role == .enrollment }
    let grouped = Dictionary(grouping: enrollment) {
      $0.sample.expectedPersonID
    }
    guard grouped.count >= 2 else {
      throw SpeakerReleaseEvaluationError.missingProfile
    }
    for (personID, values) in grouped where values.count < 2 {
      throw SpeakerReleaseEvaluationError.insufficientEnrollment(personID)
    }
    let profiles = try grouped.map { personID, values in
      SpeakerFrozenIdentityProfile(
        personID: personID,
        enrollmentCount: values.count,
        vector: try average(values.map(\.vector)).map(Float.init)
      )
    }.sorted { $0.personID < $1.personID }

    var genuine: [Double] = []
    var impostor: [Double] = []
    for leftIndex in enrollment.indices {
      for rightIndex in enrollment.indices where rightIndex > leftIndex {
        let left = enrollment[leftIndex]
        let right = enrollment[rightIndex]
        let similarity = try cosine(left.vector, right.vector)
        if left.sample.expectedPersonID == right.sample.expectedPersonID {
          genuine.append(similarity)
        } else {
          impostor.append(similarity)
        }
      }
    }
    guard let minimumGenuine = genuine.min(),
      let maximumImpostor = impostor.max()
    else {
      throw SpeakerReleaseEvaluationError.missingProfile
    }
    let lowerBound = maximumImpostor + thresholdMargin
    let upperBound = minimumGenuine - thresholdMargin
    let feasible = lowerBound <= upperBound
    let threshold = max(-1, min(1, feasible ? upperBound : lowerBound))
    let model = SpeakerFrozenIdentityModel(
      calibrationCorpusManifestID: run.corpusManifestID,
      calibrationCorpusVersion: run.corpusVersion,
      thresholdMargin: thresholdMargin,
      threshold: threshold,
      separationFeasible: feasible,
      minimumGenuineSimilarity: minimumGenuine,
      maximumImpostorSimilarity: maximumImpostor,
      profiles: profiles
    )
    try model.validate()
    return model
  }

  private static func predict(
    samples: [MeasuredIdentity],
    model: SpeakerFrozenIdentityModel
  ) throws -> [IdentityPrediction] {
    guard !samples.isEmpty else { throw SpeakerReleaseEvaluationError.noQueries }
    let profiles = try model.profiles.map {
      ($0.personID, try normalized($0.vector))
    }
    return try samples.map { observation in
      let nearest = try profiles.map { personID, profile in
        (personID, try cosine(observation.vector, profile))
      }.max { left, right in
        if left.1 == right.1 { return left.0 > right.0 }
        return left.1 < right.1
      }
      guard let nearest else {
        throw SpeakerReleaseEvaluationError.missingProfile
      }
      return IdentityPrediction(
        observation: observation,
        predictedPersonID: nearest.1 >= model.threshold ? nearest.0 : nil,
        nearestSimilarity: nearest.1
      )
    }
  }

  private static func output(
    phase: String,
    run: AMISpeakerLocalRun,
    measured: MeasuredRun,
    predictions: [IdentityPrediction],
    frozenModel: SpeakerFrozenIdentityModel,
    hardware: BenchmarkHardwareContext,
    networkDeniedByParentSandbox: Bool
  ) throws -> SpeakerEvaluationOutput {
    let assignments = predictions.enumerated().map { index, prediction in
      IdentityAssignment(
        occurrenceID: deterministicUUID(
          "ami\u{1f}\(phase)\u{1f}\(prediction.observation.sample.sampleID)\u{1f}\(index)"
        ),
        expectedPersonID: prediction.observation.sample.expectedPersonID,
        predictedPersonID: prediction.predictedPersonID,
        evidenceSufficient: prediction.observation.sample.evidenceSufficient
      )
    }
    let assignmentsByUUID = Dictionary(
      uniqueKeysWithValues: zip(predictions, assignments).map {
        ($0.0.observation.sample.sampleUUID, $0.1)
      }
    )
    var benchmarkSamples = measured.diarization.map { measured in
      BenchmarkSampleInput(
        sampleUUID: measured.sample.sampleUUID,
        diarization: DiarizationEvaluation(
          reference: measured.sample.reference,
          hypothesis: measured.hypothesis
        ),
        audioDurationNanoseconds: measured.sample.audio.durationNanoseconds,
        inferenceDurationNanoseconds: measured.inferenceDurationNanoseconds,
        latencyNanoseconds: measured.inferenceDurationNanoseconds,
        peakResidentBytes: measured.peakResidentBytes,
        backlogHighWatermark: 0
      )
    }
    benchmarkSamples.append(
      contentsOf: measured.identity.map { measured in
        BenchmarkSampleInput(
          sampleUUID: measured.sample.sampleUUID,
          identityAssignments: assignmentsByUUID[measured.sample.sampleUUID].map { [$0] } ?? [],
          audioDurationNanoseconds: measured.sample.audio.durationNanoseconds,
          inferenceDurationNanoseconds: measured.inferenceDurationNanoseconds,
          latencyNanoseconds: measured.inferenceDurationNanoseconds,
          peakResidentBytes: measured.peakResidentBytes,
          backlogHighWatermark: 0
        )
      })
    let benchmark = try BenchmarkRunner.evaluate(
      BenchmarkRunInput(
        benchmarkID: phase == "release-holdout"
          ? "speaker-fluid-ami-release-holdout-v1"
          : "speaker-fluid-ami-tuning-v1",
        runID: deterministicUUID(
          "ami\u{1f}\(phase)\u{1f}\(run.corpusManifestID)\u{1f}\(FluidSpeakerPinnedArtifact.treeSHA256)\u{1f}\(FluidSpeakerPinnedArtifact.pipelineRevision)"
        ),
        task: .speaker,
        protocolVersion: InferenceContract.currentVersion,
        implementationRevision: FluidSpeakerPinnedArtifact.runtimeRevision,
        modelArtifact: BenchmarkModelArtifact(
          artifactID: FluidSpeakerPinnedArtifact.artifactID,
          sha256: FluidSpeakerPinnedArtifact.treeSHA256
        ),
        configuration: [
          "corpus": "ami-1.6.2-public-real-human",
          "diarizationSpeakerPolicy": "automatic-unbounded",
          "embeddingSpaceID": FluidSpeakerPinnedArtifact.embeddingSpaceID,
          "identityThreshold": String(format: "%.9f", frozenModel.threshold),
          "identityThresholdPolicy": frozenModel.thresholdPolicy,
          "networkPolicy": "parent-sandbox-deny-all",
          "runtimeRevision": FluidSpeakerPinnedArtifact.runtimeRevision,
          "pipelineRevision": FluidSpeakerPinnedArtifact.pipelineRevision,
        ],
        corpus: BenchmarkCorpusReference(
          manifestID: run.corpusManifestID,
          version: run.corpusVersion,
          split: run.split == .tuning ? .tuning : .releaseHoldout
        ),
        environmentRef: "artifacts/evidence/environment/check-summary.json",
        hardware: hardware,
        samples: benchmarkSamples
      )
    )

    let identity = SpeakerScorer.identity(assignments)
    let known = predictions.filter { $0.observation.sample.evidenceSufficient }
    let unknown = predictions.filter { !$0.observation.sample.evidenceSufficient }
    let knownCorrect = known.filter {
      $0.predictedPersonID == $0.observation.sample.expectedPersonID
    }.count
    let knownRejected = known.filter { $0.predictedPersonID == nil }.count
    let knownWrong = known.count - knownCorrect - knownRejected
    let unknownRejected = unknown.filter { $0.predictedPersonID == nil }.count
    let observedModes = Array(Set(run.identitySamples.map(\.mode))).sorted {
      $0.rawValue < $1.rawValue
    }
    let requiredModes = SpeakerEvaluationEntryMode.allCases.sorted {
      $0.rawValue < $1.rawValue
    }
    let modeSummaries = Dictionary(grouping: predictions) {
      $0.observation.sample.mode
    }.map { mode, values in
      let modeKnown = values.filter { $0.observation.sample.evidenceSufficient }
      let modeUnknown = values.filter { !$0.observation.sample.evidenceSufficient }
      let correct = modeKnown.filter {
        $0.predictedPersonID == $0.observation.sample.expectedPersonID
      }.count
      let rejected = modeKnown.filter { $0.predictedPersonID == nil }.count
      return SpeakerEvaluationModeSummary(
        mode: mode,
        knownCount: modeKnown.count,
        knownCorrectCount: correct,
        knownWrongCount: modeKnown.count - correct - rejected,
        knownRejectedCount: rejected,
        unknownCount: modeUnknown.count,
        unknownRejectedCount: modeUnknown.filter {
          $0.predictedPersonID == nil
        }.count
      )
    }.sorted { $0.mode.rawValue < $1.mode.rawValue }

    let metricValues = Dictionary(
      uniqueKeysWithValues: benchmark.metrics.map { ($0.name, $0.value) }
    )
    let realtimeFactor = metricValues["realtime-factor"] ?? .infinity
    let speakerConfusion = metricValues["speaker-confusion-rate"] ?? .infinity
    let peakRSS = metricValues["peak-rss"] ?? .infinity
    let knownCoverage = known.isEmpty ? 0 : Double(knownCorrect) / Double(known.count)
    let unknownRejectRate =
      unknown.isEmpty
      ? (phase == "release-holdout" ? 0 : 1)
      : Double(unknownRejected) / Double(unknown.count)
    var gates = [
      SpeakerEvaluationGate(
        id: "parent-network-sandbox",
        passed: networkDeniedByParentSandbox,
        observed: networkDeniedByParentSandbox ? 1 : 0,
        requirement: "equal-to-1"
      ),
      SpeakerEvaluationGate(
        id: "four-entry-mode-coverage",
        passed: observedModes == requiredModes,
        observed: Double(observedModes.count),
        requirement: "equal-to-4"
      ),
      SpeakerEvaluationGate(
        id: "enrollment-impostor-margin-protected",
        passed: frozenModel.threshold + 0.000_000_001
          >= frozenModel.maximumImpostorSimilarity
          + frozenModel.thresholdMargin,
        observed: frozenModel.threshold
          - frozenModel.maximumImpostorSimilarity,
        requirement: "greater-than-or-equal-to-threshold-margin"
      ),
      SpeakerEvaluationGate(
        id: "known-wrong-identity-count",
        passed: knownWrong == 0,
        observed: Double(knownWrong),
        requirement: "equal-to-0"
      ),
      SpeakerEvaluationGate(
        id: "false-merge-count",
        passed: identity.falseMergeCount == 0,
        observed: Double(identity.falseMergeCount),
        requirement: "equal-to-0"
      ),
      SpeakerEvaluationGate(
        id: "realtime-factor",
        passed: realtimeFactor <= 1,
        observed: realtimeFactor,
        requirement: "less-than-or-equal-to-1"
      ),
      SpeakerEvaluationGate(
        id: "known-correct-coverage",
        passed: knownCoverage >= 0.5,
        observed: knownCoverage,
        requirement: "greater-than-or-equal-to-0.5"
      ),
    ]
    if phase == "release-holdout" {
      gates.append(contentsOf: [
        SpeakerEvaluationGate(
          id: "speaker-confusion-rate",
          passed: speakerConfusion <= 0.05,
          observed: speakerConfusion,
          requirement: "less-than-or-equal-to-0.05"
        ),
        SpeakerEvaluationGate(
          id: "unknown-reject-rate",
          passed: unknownRejectRate == 1,
          observed: unknownRejectRate,
          requirement: "equal-to-1"
        ),
        SpeakerEvaluationGate(
          id: "peak-rss",
          passed: peakRSS <= 2_147_483_648,
          observed: peakRSS,
          requirement: "less-than-or-equal-to-2147483648"
        ),
      ])
    }
    let passed =
      gates.allSatisfy { $0.status == "pass" }
      && benchmark.failedSampleUUIDs.isEmpty
    let decision = SpeakerReleaseEvaluationDecision(
      schemaVersion: 1,
      kind: "speaker-release-evaluation-decision",
      phase: phase,
      status: passed ? "pass" : "fail",
      eligibleForHoldout: phase != "release-holdout" && passed,
      selectionEligible: phase == "release-holdout" && passed,
      candidate: "fluid",
      corpusManifestID: run.corpusManifestID,
      corpusVersion: run.corpusVersion,
      sampleCount: benchmarkSamples.count,
      requiredModes: requiredModes,
      observedModes: observedModes,
      thresholdPolicy: frozenModel.thresholdPolicy,
      threshold: frozenModel.threshold,
      enrollmentSeparationFeasible: frozenModel.separationFeasible,
      knownQueryCount: known.count,
      knownCorrectCount: knownCorrect,
      knownWrongCount: knownWrong,
      knownRejectedCount: knownRejected,
      unknownQueryCount: unknown.count,
      unknownRejectedCount: unknownRejected,
      falseMergeCount: identity.falseMergeCount,
      falseSplitCount: identity.falseSplitCount,
      falseRejectCount: identity.falseRejectCount,
      modeSummaries: modeSummaries,
      metrics: benchmark.metrics,
      gates: gates,
      failedSampleUUIDs: benchmark.failedSampleUUIDs,
      networkDeniedByParentSandbox: networkDeniedByParentSandbox
    )
    let diagnostics = SpeakerReleaseLocalDiagnostics(
      assignments: predictions.map {
        SpeakerIdentityLocalDiagnostic(
          sampleUUID: $0.observation.sample.sampleUUID,
          expectedPersonID: $0.observation.sample.expectedPersonID,
          predictedPersonID: $0.predictedPersonID,
          evidenceSufficient: $0.observation.sample.evidenceSufficient,
          mode: $0.observation.sample.mode,
          nearestSimilarity: $0.nearestSimilarity
        )
      }
    )
    return SpeakerEvaluationOutput(
      benchmark: benchmark,
      decision: decision,
      diagnostics: diagnostics,
      frozenModel: phase == "release-holdout" ? nil : frozenModel
    )
  }

  private static func normalized(_ vector: [Float]) throws -> [Double] {
    let doubles = vector.map(Double.init)
    guard !doubles.isEmpty, doubles.allSatisfy(\.isFinite) else {
      throw SpeakerReleaseEvaluationError.inconsistentEmbeddingDimension
    }
    let norm = sqrt(doubles.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else {
      throw SpeakerReleaseEvaluationError.inconsistentEmbeddingDimension
    }
    return doubles.map { $0 / norm }
  }

  private static func average(_ vectors: [[Double]]) throws -> [Double] {
    guard let dimension = vectors.first?.count,
      dimension > 0,
      vectors.allSatisfy({ $0.count == dimension })
    else {
      throw SpeakerReleaseEvaluationError.inconsistentEmbeddingDimension
    }
    var sum = [Double](repeating: 0, count: dimension)
    for vector in vectors {
      for index in sum.indices { sum[index] += vector[index] }
    }
    let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else {
      throw SpeakerReleaseEvaluationError.inconsistentEmbeddingDimension
    }
    return sum.map { $0 / norm }
  }

  private static func cosine(
    _ left: [Double],
    _ right: [Double]
  ) throws -> Double {
    guard left.count == right.count else {
      throw SpeakerReleaseEvaluationError.inconsistentEmbeddingDimension
    }
    return zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
  }

  private static func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
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

private struct MeasuredDiarization: Sendable {
  let sample: SpeakerDiarizationLocalSample
  let hypothesis: [SpeakerSegment]
  let inferenceDurationNanoseconds: UInt64
  let peakResidentBytes: UInt64
}

private struct MeasuredIdentity: Sendable {
  let sample: SpeakerIdentityLocalSample
  let vector: [Double]
  let inferenceDurationNanoseconds: UInt64
  let peakResidentBytes: UInt64
}

private struct MeasuredRun: Sendable {
  let diarization: [MeasuredDiarization]
  let identity: [MeasuredIdentity]
}

private struct IdentityPrediction: Sendable {
  let observation: MeasuredIdentity
  let predictedPersonID: String?
  let nearestSimilarity: Double
}
