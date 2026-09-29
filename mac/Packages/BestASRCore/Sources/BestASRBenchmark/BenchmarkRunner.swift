import CryptoKit
import Foundation

public enum BenchmarkConfigurationHasher {
  public static func hash(_ configuration: [String: String]) throws -> String {
    guard !configuration.isEmpty,
      configuration.keys.allSatisfy({ !$0.isEmpty })
    else {
      throw BenchmarkError.invalidConfiguration
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(configuration)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum BenchmarkRunner {
  public static func evaluate(_ input: BenchmarkRunInput) throws -> BenchmarkResult {
    try validate(input)

    var characterErrors = 0
    var characterUnits = 0
    var wordErrors = 0
    var wordUnits = 0
    var mixedErrors = 0
    var mixedUnits = 0
    var dangerousErrors = 0
    var dangerousErrorsByCategory = Dictionary(
      uniqueKeysWithValues: DangerousTokenCategory.allCases.map { ($0, 0) }
    )
    var diarizationErrorNanoseconds = 0.0
    var diarizationMissedNanoseconds = 0.0
    var diarizationFalseAlarmNanoseconds = 0.0
    var diarizationConfusedNanoseconds = 0.0
    var diarizationReferenceNanoseconds = 0.0
    var jaccardErrorRates: [Double] = []
    var identityAssignments: [IdentityAssignment] = []
    var latencies: [UInt64] = []
    var totalAudioDuration: UInt64 = 0
    var totalInferenceDuration: UInt64 = 0
    var peakResidentBytes: UInt64 = 0
    var backlogHighWatermark: UInt64 = 0
    var failedSampleUUIDs: [UUID] = []

    for sample in input.samples {
      totalAudioDuration += sample.audioDurationNanoseconds
      totalInferenceDuration += sample.inferenceDurationNanoseconds
      latencies.append(sample.latencyNanoseconds)
      peakResidentBytes = max(peakResidentBytes, sample.peakResidentBytes)
      backlogHighWatermark = max(
        backlogHighWatermark,
        sample.backlogHighWatermark
      )
      if sample.failureCategory != nil {
        failedSampleUUIDs.append(sample.sampleUUID)
      }

      if let transcript = sample.transcript {
        let score = TranscriptScorer.score(
          reference: transcript.reference,
          hypothesis: transcript.hypothesis
        )
        characterErrors += score.character.errors
        characterUnits += score.character.referenceUnits
        wordErrors += score.word.errors
        wordUnits += score.word.referenceUnits
        mixedErrors += score.mixed.errors
        mixedUnits += score.mixed.referenceUnits
        let dangerousTokenMetrics = TranscriptScorer.dangerousTokenMetrics(
          reference: transcript.referenceDangerousTokens,
          hypothesis: transcript.hypothesisDangerousTokens
        )
        dangerousErrors += dangerousTokenMetrics.totalErrors
        for category in DangerousTokenCategory.allCases {
          dangerousErrorsByCategory[category, default: 0] +=
            dangerousTokenMetrics.errorsByCategory[category, default: 0]
        }
      }

      if let diarization = sample.diarization {
        let score = try SpeakerScorer.diarization(
          reference: diarization.reference,
          hypothesis: diarization.hypothesis
        )
        diarizationErrorNanoseconds +=
          score.missedSpeakerNanoseconds
          + score.falseAlarmSpeakerNanoseconds
          + score.confusedSpeakerNanoseconds
        diarizationMissedNanoseconds += score.missedSpeakerNanoseconds
        diarizationFalseAlarmNanoseconds += score.falseAlarmSpeakerNanoseconds
        diarizationConfusedNanoseconds += score.confusedSpeakerNanoseconds
        diarizationReferenceNanoseconds += score.referenceSpeakerNanoseconds
        jaccardErrorRates.append(score.jaccardErrorRate)
      }
      identityAssignments.append(contentsOf: sample.identityAssignments)
    }

    let identity = SpeakerScorer.identity(identityAssignments)
    let metrics = [
      metric("cer", rate(characterErrors, characterUnits), "ratio"),
      metric("wer", rate(wordErrors, wordUnits), "ratio"),
      metric("mer", rate(mixedErrors, mixedUnits), "ratio"),
      metric("dangerous-token-errors", Double(dangerousErrors), "count"),
      metric(
        "dangerous-token-errors.action-owner",
        Double(dangerousErrorsByCategory[.actionOwner, default: 0]),
        "count"
      ),
      metric(
        "dangerous-token-errors.date",
        Double(dangerousErrorsByCategory[.date, default: 0]),
        "count"
      ),
      metric(
        "dangerous-token-errors.negation",
        Double(dangerousErrorsByCategory[.negation, default: 0]),
        "count"
      ),
      metric(
        "dangerous-token-errors.number",
        Double(dangerousErrorsByCategory[.number, default: 0]),
        "count"
      ),
      metric(
        "dangerous-token-errors.person",
        Double(dangerousErrorsByCategory[.person, default: 0]),
        "count"
      ),
      metric(
        "der",
        diarizationReferenceNanoseconds == 0
          ? 0
          : diarizationErrorNanoseconds / diarizationReferenceNanoseconds,
        "ratio"
      ),
      metric(
        "jer",
        jaccardErrorRates.isEmpty
          ? 0
          : jaccardErrorRates.reduce(0, +) / Double(jaccardErrorRates.count),
        "ratio"
      ),
      metric(
        "speaker-miss-rate",
        diarizationReferenceNanoseconds == 0
          ? 0
          : diarizationMissedNanoseconds / diarizationReferenceNanoseconds,
        "ratio"
      ),
      metric(
        "speaker-false-alarm-rate",
        diarizationReferenceNanoseconds == 0
          ? 0
          : diarizationFalseAlarmNanoseconds / diarizationReferenceNanoseconds,
        "ratio"
      ),
      metric(
        "speaker-confusion-rate",
        diarizationReferenceNanoseconds == 0
          ? 0
          : diarizationConfusedNanoseconds / diarizationReferenceNanoseconds,
        "ratio"
      ),
      metric("false-merge-count", Double(identity.falseMergeCount), "count"),
      metric("false-split-count", Double(identity.falseSplitCount), "count"),
      metric("false-reject-count", Double(identity.falseRejectCount), "count"),
      metric(
        "latency-p50",
        Double(percentile(latencies, percentile: 0.50)) / 1_000_000,
        "milliseconds"
      ),
      metric(
        "latency-p95",
        Double(percentile(latencies, percentile: 0.95)) / 1_000_000,
        "milliseconds"
      ),
      metric(
        "realtime-factor",
        Double(totalInferenceDuration) / Double(totalAudioDuration),
        "ratio"
      ),
      metric("peak-rss", Double(peakResidentBytes), "bytes", .informational),
      metric(
        "backlog-high-watermark",
        Double(backlogHighWatermark),
        "jobs",
        .informational
      ),
    ]

    return BenchmarkResult(
      benchmarkID: input.benchmarkID,
      runID: input.runID,
      task: input.task,
      protocolVersion: input.protocolVersion,
      implementationRevision: input.implementationRevision,
      modelArtifact: input.modelArtifact,
      configHash: try BenchmarkConfigurationHasher.hash(input.configuration),
      corpus: input.corpus,
      environmentRef: input.environmentRef,
      hardware: input.hardware,
      metrics: metrics,
      failedSampleUUIDs: failedSampleUUIDs.sorted {
        $0.uuidString < $1.uuidString
      }
    )
  }

  private static func validate(_ input: BenchmarkRunInput) throws {
    guard input.schemaVersion == 1 else {
      throw BenchmarkError.unsupportedSchemaVersion
    }
    guard input.kind == "benchmark-run" else {
      throw BenchmarkError.unsupportedKind
    }
    guard !input.benchmarkID.isEmpty else {
      throw BenchmarkError.invalidBenchmarkID
    }
    guard
      input.modelArtifact.sha256.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil
    else {
      throw BenchmarkError.invalidArtifactDigest
    }
    guard
      input.environmentRef.range(
        of: "^(artifacts/evidence/|fixture://)[A-Za-z0-9._/-]+$",
        options: .regularExpression
      ) != nil
    else {
      throw BenchmarkError.invalidEnvironmentReference
    }
    guard !input.samples.isEmpty else {
      throw BenchmarkError.emptySamples
    }
    guard input.samples.allSatisfy({ $0.audioDurationNanoseconds > 0 }) else {
      throw BenchmarkError.invalidDuration
    }
    _ = try BenchmarkConfigurationHasher.hash(input.configuration)
  }

  private static func metric(
    _ name: String,
    _ value: Double,
    _ unit: String,
    _ direction: BenchmarkMetricDirection = .lowerIsBetter
  ) -> BenchmarkMetric {
    BenchmarkMetric(name: name, value: value, unit: unit, direction: direction)
  }

  private static func rate(_ errors: Int, _ units: Int) -> Double {
    if units == 0 { return errors == 0 ? 0 : 1 }
    return Double(errors) / Double(units)
  }

  private static func percentile(
    _ values: [UInt64],
    percentile: Double
  ) -> UInt64 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[min(rank - 1, sorted.count - 1)]
  }
}
