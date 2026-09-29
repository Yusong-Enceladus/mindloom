import Foundation

public struct AudioJournalProbeConfiguration: Sendable {
  public let summaryURL: URL
  public let matrixURL: URL

  public init(summaryURL: URL, matrixURL: URL) {
    self.summaryURL = summaryURL
    self.matrixURL = matrixURL
  }
}

public struct JournalKillPlan: Equatable, Sendable {
  public let seed: UInt64
  public let trackID: String
  public let faultPoint: AudioJournalFaultPoint
  public let pcmBytes: Data
  public let frameCount: UInt32

  public init(seed: UInt64) {
    var random = SeededRandom(seed: seed)
    self.seed = seed
    trackID = random.next() & 1 == 0 ? "microphone" : "system"
    let points: [AudioJournalFaultPoint] = [
      .afterPartialStagingWrite,
      .afterStagingSync,
      .afterChunkRename,
      .afterManifestCommit,
    ]
    faultPoint = points[Int(random.next() % UInt64(points.count))]
    let byteCount = 2_048 + Int(random.next() % 4_096)
    pcmBytes = Data(
      (0..<byteCount).map {
        UInt8((UInt64($0) &+ seed) % 251)
      })
    frameCount = UInt32(byteCount / 2)
  }
}

public enum AudioJournalKillFixture {
  public static func performWrite(rootURL: URL, seed: UInt64) throws {
    let plan = JournalKillPlan(seed: seed)
    let journal = try AudioJournal.open(at: rootURL)
    try journal.append(
      trackID: plan.trackID,
      pcmBytes: plan.pcmBytes,
      monotonicStartNanoseconds: 1_000_000_000,
      sampleRateHertz: 16_000,
      frameCount: plan.frameCount,
      faultPoint: plan.faultPoint
    )
  }
}

public struct AudioJournalScenario: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let status: String
  public let metrics: [String: String]
  public let errorCategory: String

  public init(
    scenarioID: String,
    status: String,
    metrics: [String: String],
    errorCategory: String = "none"
  ) {
    self.scenarioID = scenarioID
    self.status = status
    self.metrics = metrics
    self.errorCategory = errorCategory
  }
}

public struct AudioJournalMatrixEvidence: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let generatedAt: Date
  public let randomSeedCount: Int
  public let maximumUncommittedLossBytes: UInt64
  public let maximumUncommittedLossNanoseconds: UInt64
  public let scenarios: [AudioJournalScenario]

  public init(
    runID: UUID,
    generatedAt: Date,
    randomSeedCount: Int,
    maximumUncommittedLossBytes: UInt64,
    maximumUncommittedLossNanoseconds: UInt64,
    scenarios: [AudioJournalScenario]
  ) {
    schemaVersion = 1
    kind = "audio-journal-recovery-matrix"
    spikeID = "SPIKE-JRN-001"
    self.runID = runID
    self.generatedAt = generatedAt
    self.randomSeedCount = randomSeedCount
    self.maximumUncommittedLossBytes = maximumUncommittedLossBytes
    self.maximumUncommittedLossNanoseconds = maximumUncommittedLossNanoseconds
    self.scenarios = scenarios
  }
}

public enum AudioJournalProbeRunner {
  public static let killSeeds: [UInt64] = [
    7, 8, 9, 10, 19, 20, 21, 22, 31, 32, 33, 34,
  ]

  public static func run(
    configuration: AudioJournalProbeConfiguration,
    executableURL: URL
  ) throws -> String {
    let runID = UUID()
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-journal-\(runID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    var scenarios: [AudioJournalScenario] = []
    scenarios.append(normalFinalizeScenario(root: temporaryRoot))
    scenarios.append(durablePublicationScenario(root: temporaryRoot))
    scenarios.append(truncatedChunkScenario(root: temporaryRoot))
    scenarios.append(corruptDigestScenario(root: temporaryRoot))
    scenarios.append(duplicateSequenceScenario(root: temporaryRoot))
    scenarios.append(missingChunkScenario(root: temporaryRoot))

    var maximumLossBytes: UInt64 = 0
    var maximumLossNanoseconds: UInt64 = 0
    for seed in killSeeds {
      let result = killScenario(
        root: temporaryRoot,
        executableURL: executableURL,
        seed: seed
      )
      maximumLossBytes = max(
        maximumLossBytes,
        UInt64(result.metrics["uncommittedLossBytes"] ?? "0") ?? 0
      )
      maximumLossNanoseconds = max(
        maximumLossNanoseconds,
        UInt64(result.metrics["uncommittedLossNanoseconds"] ?? "0") ?? 0
      )
      scenarios.append(result)
    }

    let matrix = AudioJournalMatrixEvidence(
      runID: runID,
      generatedAt: Date(),
      randomSeedCount: killSeeds.count,
      maximumUncommittedLossBytes: maximumLossBytes,
      maximumUncommittedLossNanoseconds: maximumLossNanoseconds,
      scenarios: scenarios
    )
    try writeJSON(matrix, to: configuration.matrixURL)

    let failures = scenarios.filter { $0.status != "pass" }
    let conclusion = failures.isEmpty ? "conditional" : "fail"
    let matrixReference = repositoryRelativeEvidencePath(
      configuration.matrixURL,
      fallback: "artifacts/evidence/SPIKE-JRN-001/matrix.json"
    )
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-JRN-001",
      runID: runID,
      question:
        "Can a two-track short-chunk AudioJournal survive real SIGKILL at deterministic randomized write points while publishing only durably committed ranges?",
      environmentRef: "artifacts/evidence/environment/check-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "Inference ranges appear only after the chunk rename and manifest fsync/atomic rename complete.",
          "Truncation, digest corruption, duplicate sequence, and missing files create recovery issues/gaps and cannot be finalized as complete.",
          "Across deterministic SIGKILL seeds, every manifest-committed chunk remains readable and uncommitted loss is bounded by the single chunk being written.",
        ],
        fail: [
          "A committed chunk becomes unreadable, a corrupt journal finalizes successfully, a pre-manifest chunk is published to inference, or loss exceeds one in-flight chunk."
        ]
      ),
      commands: [["script/run_audio_journal_probe.sh"]],
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
          "The probe uses short synthetic PCM files on the current filesystem; final PCM/CAF/ALAC encoding and production chunk duration remain unfrozen.",
          "Physical disk exhaustion, two-hour dual-track capture, sleep/wake, and real device changes remain mandatory in task 4.5.",
        ]
        : failures.map { "Failed scenario: \($0.scenarioID)" }
    )
    try writeJSON(summary, to: configuration.summaryURL)
    return conclusion
  }

  private static func normalFinalizeScenario(root: URL) -> AudioJournalScenario {
    evaluate("normal-two-track-finalize") {
      let journal = try makeJournal(root: root, name: "normal")
      _ = try appendFixture(journal, trackID: "microphone", marker: 1)
      _ = try appendFixture(journal, trackID: "system", marker: 2)
      try journal.finalize()
      guard journal.manifest.state == .finalized,
        journal.availableInferenceRanges().count == 2
      else { throw RunnerError.invariant("normal-finalize") }
      return [
        "committedChunkCount": "2",
        "finalState": journal.manifest.state.rawValue,
        "inferenceRangeCount": "2",
      ]
    }
  }

  private static func durablePublicationScenario(root: URL) -> AudioJournalScenario {
    evaluate("inference-range-publishes-after-durable-manifest") {
      let journal = try makeJournal(root: root, name: "publication")
      _ = try appendFixture(journal, trackID: "microphone", marker: 3)
      let before = journal.availableInferenceRanges().count
      do {
        _ = try appendFixture(
          journal,
          trackID: "system",
          marker: 4,
          faultPoint: .afterChunkRename
        )
        throw RunnerError.invariant("fault-not-injected")
      } catch AudioJournalError.injectedCrash(.afterChunkRename) {
        // Expected: file exists, but no durable manifest entry was published.
      }
      let after = journal.availableInferenceRanges().count
      guard before == 1, after == 1 else {
        throw RunnerError.invariant("premature-inference-publication")
      }
      return [
        "durableRangeCount": String(after),
        "orphanRangePublished": "false",
      ]
    }
  }

  private static func truncatedChunkScenario(root: URL) -> AudioJournalScenario {
    evaluate("truncated-committed-chunk-is-a-gap") {
      let journal = try makeJournal(root: root, name: "truncated")
      _ = try appendFixture(journal, trackID: "microphone", marker: 5)
      _ = try appendFixture(journal, trackID: "system", marker: 6)
      let entry = try require(journal.manifest.committedChunks.first, "entry")
      let data = try Data(contentsOf: journal.chunkURL(for: entry))
      try Data(data.prefix(data.count / 2)).write(
        to: journal.chunkURL(for: entry)
      )
      let reopened = try AudioJournal.open(at: journal.rootURL)
      let report = try reopened.recover()
      guard report.issues.contains(where: { $0.kind == .truncatedChunk }),
        report.gaps.count == 1,
        reopened.availableInferenceRanges().count == 1,
        finalizeIsRejected(reopened)
      else { throw RunnerError.invariant("truncation-recovery") }
      return recoveryMetrics(report)
    }
  }

  private static func corruptDigestScenario(root: URL) -> AudioJournalScenario {
    evaluate("digest-corruption-is-quarantined") {
      let journal = try makeJournal(root: root, name: "digest")
      _ = try appendFixture(journal, trackID: "microphone", marker: 7)
      _ = try appendFixture(journal, trackID: "system", marker: 8)
      let entry = try require(journal.manifest.committedChunks.last, "entry")
      let url = journal.chunkURL(for: entry)
      var data = try Data(contentsOf: url)
      data[0] ^= 0xff
      try data.write(to: url)
      let reopened = try AudioJournal.open(at: journal.rootURL)
      let report = try reopened.recover()
      guard report.issues.contains(where: { $0.kind == .corruptDigest }),
        report.gaps.count == 1,
        reopened.availableInferenceRanges().count == 1,
        finalizeIsRejected(reopened)
      else { throw RunnerError.invariant("digest-recovery") }
      return recoveryMetrics(report)
    }
  }

  private static func duplicateSequenceScenario(root: URL) -> AudioJournalScenario {
    evaluate("duplicate-sequence-is-not-published-twice") {
      let journal = try makeJournal(root: root, name: "duplicate")
      _ = try appendFixture(journal, trackID: "microphone", marker: 9)
      _ = try appendFixture(journal, trackID: "system", marker: 10)
      var manifest = journal.manifest
      manifest.committedChunks.append(
        try require(manifest.committedChunks.first, "entry")
      )
      try persistFixtureManifest(manifest, to: journal.manifestURL)
      let reopened = try AudioJournal.open(at: journal.rootURL)
      let report = try reopened.recover()
      guard report.issues.contains(where: { $0.kind == .duplicateSequence }),
        reopened.availableInferenceRanges().count == 2,
        finalizeIsRejected(reopened)
      else { throw RunnerError.invariant("duplicate-recovery") }
      return recoveryMetrics(report)
    }
  }

  private static func missingChunkScenario(root: URL) -> AudioJournalScenario {
    evaluate("missing-committed-chunk-is-a-gap") {
      let journal = try makeJournal(root: root, name: "missing")
      _ = try appendFixture(journal, trackID: "microphone", marker: 11)
      _ = try appendFixture(journal, trackID: "system", marker: 12)
      let entry = try require(journal.manifest.committedChunks.first, "entry")
      try FileManager.default.removeItem(at: journal.chunkURL(for: entry))
      let reopened = try AudioJournal.open(at: journal.rootURL)
      let report = try reopened.recover()
      guard report.issues.contains(where: { $0.kind == .missingChunk }),
        report.gaps.count == 1,
        reopened.availableInferenceRanges().count == 1,
        finalizeIsRejected(reopened)
      else { throw RunnerError.invariant("missing-recovery") }
      return recoveryMetrics(report)
    }
  }

  private static func killScenario(
    root: URL,
    executableURL: URL,
    seed: UInt64
  ) -> AudioJournalScenario {
    evaluate(String(format: "sigkill-seed-%03llu", seed)) {
      let journal = try makeJournal(root: root, name: "kill-\(seed)")
      _ = try appendFixture(journal, trackID: "microphone", marker: 21)
      _ = try appendFixture(journal, trackID: "system", marker: 22)
      let plan = JournalKillPlan(seed: seed)

      let process = Process()
      process.executableURL = executableURL
      process.arguments = [
        "--kill-child",
        "--root", journal.rootURL.path,
        "--seed", String(seed),
      ]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationReason == .uncaughtSignal,
        process.terminationStatus == 9
      else { throw RunnerError.invariant("child-not-sigkilled") }

      let reopened = try AudioJournal.open(at: journal.rootURL)
      let report = try reopened.recover()
      let readable = reopened.manifest.committedChunks.allSatisfy {
        (try? reopened.readCommittedChunk($0)) != nil
      }
      let boundedLoss = report.quarantinedByteCount <= UInt64(plan.pcmBytes.count)
      let notComplete = reopened.manifest.state != .finalized
      guard readable, boundedLoss, notComplete, report.gaps.isEmpty else {
        throw RunnerError.invariant("kill-recovery-invariant")
      }
      let lossFrames = report.quarantinedByteCount / 2
      let lossNanoseconds = UInt64(
        (Double(lossFrames) * 1_000_000_000 / 16_000).rounded()
      )
      return [
        "committedChunkCount": String(reopened.manifest.committedChunks.count),
        "committedChunksReadable": String(readable),
        "faultPoint": plan.faultPoint.rawValue,
        "markedComplete": String(!notComplete),
        "seed": String(seed),
        "trackID": plan.trackID,
        "uncommittedLossBytes": String(report.quarantinedByteCount),
        "uncommittedLossNanoseconds": String(lossNanoseconds),
      ]
    }
  }

  private static func makeJournal(root: URL, name: String) throws -> AudioJournal {
    try AudioJournal.create(
      at: root.appendingPathComponent(name, isDirectory: true),
      sessionID: UUID(),
      tracks: [
        AudioJournalTrack(trackID: "microphone", role: "microphoneLocal"),
        AudioJournalTrack(trackID: "system", role: "systemRemote"),
      ]
    )
  }

  @discardableResult
  private static func appendFixture(
    _ journal: AudioJournal,
    trackID: String,
    marker: UInt8,
    faultPoint: AudioJournalFaultPoint = .none
  ) throws -> CommittedInferenceRange {
    try journal.append(
      trackID: trackID,
      pcmBytes: Data(repeating: marker, count: 4_096),
      monotonicStartNanoseconds: 0,
      sampleRateHertz: 16_000,
      frameCount: 2_048,
      faultPoint: faultPoint
    )
  }

  private static func persistFixtureManifest(
    _ manifest: AudioJournalManifest,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try DurableFileIO.atomicWrite(encoder.encode(manifest), to: url)
  }

  private static func finalizeIsRejected(_ journal: AudioJournal) -> Bool {
    do {
      try journal.finalize()
      return false
    } catch {
      return true
    }
  }

  private static func recoveryMetrics(
    _ report: AudioJournalRecoveryReport
  ) -> [String: String] {
    [
      "gapCount": String(report.gaps.count),
      "issueCount": String(report.issues.count),
      "markedComplete": String(report.state == .finalized),
      "readableCommittedChunkCount": String(report.readableCommittedChunkCount),
    ]
  }

  private static func evaluate(
    _ scenarioID: String,
    body: () throws -> [String: String]
  ) -> AudioJournalScenario {
    do {
      return AudioJournalScenario(
        scenarioID: scenarioID,
        status: "pass",
        metrics: try body()
      )
    } catch {
      return AudioJournalScenario(
        scenarioID: scenarioID,
        status: "fail",
        metrics: [:],
        errorCategory: String(describing: error)
      )
    }
  }

  private static func require<T>(_ value: T?, _ detail: String) throws -> T {
    guard let value else { throw RunnerError.invariant(detail) }
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
}

private struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

private enum RunnerError: Error {
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
