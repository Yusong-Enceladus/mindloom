import Foundation

public struct AudioTimelineProbeConfiguration: Sendable {
  public let summaryURL: URL
  public let matrixURL: URL

  public init(summaryURL: URL, matrixURL: URL) {
    self.summaryURL = summaryURL
    self.matrixURL = matrixURL
  }
}

public enum AudioTimelineProbeRunner {
  public static func run(
    configuration: AudioTimelineProbeConfiguration
  ) throws -> String {
    let runID = UUID()
    let fixture = try makeFixture()
    var scenarios: [AudioTimelineScenario] = []

    scenarios.append(
      evaluate("independent-source-track-metadata") {
        try AudioTimelineValidator.validate(
          tracks: fixture.tracks,
          chunks: fixture.chunks,
          boundaries: fixture.boundaries
        )
        guard
          fixture.tracks.map(\.sourceRole).sorted(by: { $0.rawValue < $1.rawValue })
            == [.microphoneLocal, .systemRemote]
        else { throw ProbeRunnerError.invariant("source-role-set") }
        guard
          fixture.chunks.allSatisfy({
            $0.hostTime > 0 && $0.monotonicStartNanoseconds > 0
              && $0.sampleRateHertz > 0 && $0.frameCount > 0
              && $0.contentDigest.count == 64
          })
        else { throw ProbeRunnerError.invariant("required-chunk-metadata") }
        return [
          "chunkCount": String(fixture.chunks.count),
          "independentClockDomains": String(Set(fixture.tracks.map(\.clockDomain)).count),
          "trackCount": String(fixture.tracks.count),
        ]
      }
    )

    scenarios.append(
      evaluate("synthetic-pulses-align-by-monotonic-host-time") {
        let maximumError = fixture.pulses.map(\.absoluteErrorNanoseconds).max() ?? .max
        let oneFrameAtLowestRate = UInt64(
          (1_000_000_000.0 / 44_100.0).rounded(.up)
        )
        guard fixture.pulses.count == 6,
          maximumError <= oneFrameAtLowestRate
        else { throw ProbeRunnerError.invariant("pulse-alignment") }

        let grouped = Dictionary(grouping: fixture.pulses, by: \.pulseID)
        let maximumCrossTrackSkew =
          grouped.values.compactMap { observations -> UInt64? in
            guard observations.count == 2 else { return nil }
            let values = observations.map(\.observedMonotonicNanoseconds)
            return (values.max() ?? 0) - (values.min() ?? 0)
          }.max() ?? .max
        guard maximumCrossTrackSkew <= oneFrameAtLowestRate * 2 else {
          throw ProbeRunnerError.invariant("cross-track-skew")
        }
        return [
          "maximumAbsoluteErrorNanoseconds": String(maximumError),
          "maximumCrossTrackSkewNanoseconds": String(maximumCrossTrackSkew),
          "pulseObservationCount": String(fixture.pulses.count),
        ]
      }
    )

    scenarios.append(
      evaluate("known-clock-drift-is-measured") {
        let error = abs(
          fixture.drift.measuredPartsPerMillion
            - fixture.drift.expectedPartsPerMillion
        )
        guard error < 0.001 else {
          throw ProbeRunnerError.invariant("drift-estimate")
        }
        return [
          "expectedPartsPerMillion": decimal(fixture.drift.expectedPartsPerMillion),
          "measuredPartsPerMillion": decimal(fixture.drift.measuredPartsPerMillion),
          "measurementErrorPartsPerMillion": decimal(error),
        ]
      }
    )

    scenarios.append(
      evaluate("sample-rate-change-opens-new-segment") {
        let rateBoundary = try require(
          fixture.boundaries.first { $0.reason == .sampleRateChanged },
          "missing-rate-boundary"
        )
        let nextChunk = try require(
          fixture.chunks.first {
            $0.trackID == rateBoundary.trackID
              && $0.segment == rateBoundary.toSegment
          },
          "missing-rate-segment"
        )
        guard rateBoundary.priorSampleRateHertz != rateBoundary.nextSampleRateHertz,
          nextChunk.discontinuity == .sampleRateChanged,
          nextChunk.sampleRateHertz == rateBoundary.nextSampleRateHertz
        else { throw ProbeRunnerError.invariant("rate-boundary-semantics") }
        return [
          "fromSampleRateHertz": String(rateBoundary.priorSampleRateHertz),
          "newSegment": String(rateBoundary.toSegment),
          "toSampleRateHertz": String(rateBoundary.nextSampleRateHertz),
        ]
      }
    )

    scenarios.append(
      evaluate("device-hotplug-records-gap-and-boundary") {
        let deviceBoundary = try require(
          fixture.boundaries.first { $0.reason == .deviceReconnected },
          "missing-device-boundary"
        )
        guard deviceBoundary.gapDurationNanoseconds == 150_000_000,
          fixture.chunks.contains(where: {
            $0.trackID == deviceBoundary.trackID
              && $0.segment == deviceBoundary.toSegment
              && $0.discontinuity == .deviceReconnected
          })
        else { throw ProbeRunnerError.invariant("device-gap-semantics") }
        return [
          "gapDurationNanoseconds": String(deviceBoundary.gapDurationNanoseconds),
          "newSegment": String(deviceBoundary.toSegment),
          "sourceTrackPreserved": "true",
        ]
      }
    )

    let matrix = AudioTimelineMatrixEvidence(
      runID: runID,
      generatedAt: Date(),
      tracks: fixture.tracks,
      chunks: fixture.chunks,
      boundaries: fixture.boundaries,
      pulseObservations: fixture.pulses,
      drift: fixture.drift,
      scenarios: scenarios
    )
    try writeJSON(matrix, to: configuration.matrixURL)

    let failures = scenarios.filter { $0.status != "pass" }
    let conclusion = failures.isEmpty ? "conditional" : "fail"
    let matrixReference = repositoryRelativeEvidencePath(
      configuration.matrixURL,
      fallback: "artifacts/evidence/SPIKE-TIM-001/matrix.json"
    )
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-TIM-001",
      runID: runID,
      question:
        "Can independent microphone and system tracks align on monotonic host time while making drift, sample-rate changes, and device gaps explicit?",
      environmentRef: "artifacts/evidence/environment/check-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "Every source chunk records independent track identity, sequence, host time, monotonic nanoseconds, sample rate, frame count, and SHA-256 digest.",
          "Synthetic pulses align within one source frame and a known drift fixture is measured within 0.001 ppm.",
          "Sample-rate changes and microphone hotplug gaps create explicit segment boundaries rather than silently changing time conversion.",
        ],
        fail: [
          "A sequence or digest is invalid, cross-track pulse skew exceeds two lowest-rate frames, or a rate/device transition lacks a boundary."
        ]
      ),
      commands: [
        [
          "script/run_audio_timeline_probe.sh"
        ]
      ],
      matrix: scenarios.map {
        SpikeMatrixReference(
          scenarioID: $0.scenarioID,
          status: $0.status,
          evidenceRefs: [matrixReference]
        )
      },
      conclusion: conclusion,
      unmetCriteria: failures.isEmpty
        ? [
          "The alignment and drift cases use deterministic synthetic clocks; simultaneous live microphone and Process Tap capture remains a device-lab run.",
          "A physical sample-rate switch and microphone unplug/replug remain part of the mandatory two-hour stability matrix in task 4.5.",
        ]
        : failures.map { "Failed scenario: \($0.scenarioID)" }
    )
    try writeJSON(summary, to: configuration.summaryURL)
    return conclusion
  }

  private static func makeFixture() throws -> ProbeFixture {
    let base: UInt64 = 10_000_000_000
    let pulseOffset: UInt64 = 237_123_456
    let tracks = [
      ProbeTrack(
        trackID: "microphone-track",
        sourceRole: .microphoneLocal,
        clockDomain: "synthetic-microphone-clock"
      ),
      ProbeTrack(
        trackID: "system-track",
        sourceRole: .systemRemote,
        clockDomain: "synthetic-process-tap-clock"
      ),
    ]
    var chunks: [ProbeAudioChunk] = []
    var pulses: [ProbePulseObservation] = []

    let systemRates: [UInt32] = [44_100, 44_100, 44_100, 44_100]
    for sequence in 0..<4 {
      let start = base + UInt64(sequence) * 1_000_000_000
      let expectedPulse = sequence < 3 ? start + pulseOffset : nil
      let signal = AudioProbeSignal.pulseChunk(
        frameCount: systemRates[sequence],
        sampleRateHertz: systemRates[sequence],
        chunkStartNanoseconds: start,
        pulseNanoseconds: expectedPulse
      )
      chunks.append(
        ProbeAudioChunk(
          trackID: "system-track",
          segment: 0,
          sequence: UInt64(sequence),
          hostTime: start,
          monotonicStartNanoseconds: start,
          sampleRateHertz: systemRates[sequence],
          frameCount: systemRates[sequence],
          contentDigest: AudioProbeSignal.digest(samples: signal.samples)
        )
      )
      if let expectedPulse, let observed = signal.observedPulseNanoseconds {
        pulses.append(
          pulseObservation(
            pulseID: "pulse-\(sequence)",
            trackID: "system-track",
            expected: expectedPulse,
            observed: observed
          )
        )
      }
    }

    let microphoneStarts: [UInt64] = [
      base + 51_000,
      base + 1_000_000_000 + 39_000,
      base + 2_000_000_000 + 28_000,
      base + 3_150_000_000,
    ]
    let microphoneRates: [UInt32] = [48_000, 48_000, 44_100, 44_100]
    let microphoneSegments: [UInt32] = [0, 0, 1, 2]
    let discontinuities: [ProbeDiscontinuityReason?] = [
      nil, nil, .sampleRateChanged, .deviceReconnected,
    ]
    for sequence in 0..<4 {
      let start = microphoneStarts[sequence]
      let expectedPulse =
        sequence < 3
        ? base + UInt64(sequence) * 1_000_000_000 + pulseOffset
        : nil
      let signal = AudioProbeSignal.pulseChunk(
        frameCount: microphoneRates[sequence],
        sampleRateHertz: microphoneRates[sequence],
        chunkStartNanoseconds: start,
        pulseNanoseconds: expectedPulse
      )
      chunks.append(
        ProbeAudioChunk(
          trackID: "microphone-track",
          segment: microphoneSegments[sequence],
          sequence: UInt64(sequence),
          hostTime: start,
          monotonicStartNanoseconds: start,
          sampleRateHertz: microphoneRates[sequence],
          frameCount: microphoneRates[sequence],
          contentDigest: AudioProbeSignal.digest(samples: signal.samples),
          discontinuity: discontinuities[sequence]
        )
      )
      if let expectedPulse, let observed = signal.observedPulseNanoseconds {
        pulses.append(
          pulseObservation(
            pulseID: "pulse-\(sequence)",
            trackID: "microphone-track",
            expected: expectedPulse,
            observed: observed
          )
        )
      }
    }

    let boundaries = [
      ProbeTimelineBoundary(
        trackID: "microphone-track",
        fromSegment: 0,
        toSegment: 1,
        monotonicNanoseconds: base + 2_000_000_000,
        reason: .sampleRateChanged,
        priorSampleRateHertz: 48_000,
        nextSampleRateHertz: 44_100
      ),
      ProbeTimelineBoundary(
        trackID: "microphone-track",
        fromSegment: 1,
        toSegment: 2,
        monotonicNanoseconds: base + 3_000_000_000,
        reason: .deviceReconnected,
        priorSampleRateHertz: 44_100,
        nextSampleRateHertz: 44_100,
        gapDurationNanoseconds: 150_000_000
      ),
    ]
    let drift = try ClockDriftEstimator.observation(
      nominalSampleRateHertz: 48_000,
      startFrame: 0,
      endFrame: 47_997_600,
      startMonotonicNanoseconds: base,
      endMonotonicNanoseconds: base + 1_000_000_000_000,
      expectedPartsPerMillion: -50
    )
    return ProbeFixture(
      tracks: tracks,
      chunks: chunks,
      boundaries: boundaries,
      pulses: pulses,
      drift: drift
    )
  }

  private static func pulseObservation(
    pulseID: String,
    trackID: String,
    expected: UInt64,
    observed: UInt64
  ) -> ProbePulseObservation {
    ProbePulseObservation(
      pulseID: pulseID,
      trackID: trackID,
      expectedMonotonicNanoseconds: expected,
      observedMonotonicNanoseconds: observed,
      absoluteErrorNanoseconds: expected > observed
        ? expected - observed
        : observed - expected
    )
  }

  private static func evaluate(
    _ scenarioID: String,
    body: () throws -> [String: String]
  ) -> AudioTimelineScenario {
    do {
      return AudioTimelineScenario(
        scenarioID: scenarioID,
        status: "pass",
        metrics: try body()
      )
    } catch {
      return AudioTimelineScenario(
        scenarioID: scenarioID,
        status: "fail",
        metrics: [:],
        errorCategory: String(describing: error)
      )
    }
  }

  private static func require<T>(_ value: T?, _ detail: String) throws -> T {
    guard let value else { throw ProbeRunnerError.invariant(detail) }
    return value
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static func repositoryRelativeEvidencePath(
    _ url: URL,
    fallback: String
  ) -> String {
    let path = url.standardizedFileURL.path
    guard let range = path.range(of: "/artifacts/evidence/") else {
      return fallback
    }
    return "artifacts/evidence/" + path[range.upperBound...]
  }

  private static func decimal(_ value: Double) -> String {
    String(format: "%.8f", value)
  }
}

private struct ProbeFixture {
  let tracks: [ProbeTrack]
  let chunks: [ProbeAudioChunk]
  let boundaries: [ProbeTimelineBoundary]
  let pulses: [ProbePulseObservation]
  let drift: ProbeDriftObservation
}

private enum ProbeRunnerError: Error {
  case invariant(String)
}

private struct SpikeCriteria: Codable {
  let pass: [String]
  let fail: [String]
}

private struct SpikeMatrixReference: Codable {
  let scenarioID: String
  let status: String
  let evidenceRefs: [String]
}

private struct SpikeSummary: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let question: String
  let environmentRef: String
  let criteria: SpikeCriteria
  let commands: [[String]]
  let matrix: [SpikeMatrixReference]
  let conclusion: String
  let unmetCriteria: [String]
}
