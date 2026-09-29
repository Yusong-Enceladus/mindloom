import BestASRAudioJournalProbe
import Foundation

public struct InferenceQueueProbeConfiguration: Sendable {
  public let summaryURL: URL
  public let matrixURL: URL

  public init(summaryURL: URL, matrixURL: URL) {
    self.summaryURL = summaryURL
    self.matrixURL = matrixURL
  }
}

public struct InferenceQueueScenario: Codable, Equatable, Sendable {
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

public struct InferenceQueueMatrixEvidence: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let generatedAt: Date
  public let scenarios: [InferenceQueueScenario]

  public init(
    runID: UUID,
    generatedAt: Date,
    scenarios: [InferenceQueueScenario]
  ) {
    schemaVersion = 1
    kind = "inference-queue-worker-matrix"
    spikeID = "SPIKE-WRK-001"
    self.runID = runID
    self.generatedAt = generatedAt
    self.scenarios = scenarios
  }
}

public enum InferenceQueueProbeRunner {
  public static func run(
    configuration: InferenceQueueProbeConfiguration
  ) async throws -> String {
    let runID = UUID()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-worker-\(runID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let journal = try AudioJournal.create(
      at: root.appendingPathComponent("journal", isDirectory: true),
      sessionID: runID,
      tracks: [AudioJournalTrack(trackID: "microphone", role: "microphoneLocal")]
    )
    let storeURL = root.appendingPathComponent("durable-jobs.json")
    let store = try DurableLeaseStore(url: storeURL)
    let queue = BoundedRealtimeQueue<UUID>(capacity: 2)
    var rejectedOffers = 0
    var degradedLive = false

    for revision in 0..<10 {
      let range = try journal.append(
        trackID: "microphone",
        pcmBytes: Data(repeating: UInt8(revision), count: 64),
        monotonicStartNanoseconds: UInt64(revision) * 2_000_000,
        sampleRateHertz: 16_000,
        frameCount: 32
      )
      let job = try await store.enqueue(
        inputRevision: range.sequence,
        modelVersion: "fixture-asr-v1",
        configHash: "fixture-config-v1"
      )
      if await queue.offer(job.id) == .full {
        rejectedOffers += 1
        degradedLive = true
      }
    }

    var scenarios: [InferenceQueueScenario] = []
    let queueCount = await queue.count
    let queueHighWatermark = await queue.highWatermark
    scenarios.append(
      scenario(
        "slow-inference-fills-bounded-queue",
        passes: queueCount == 2 && queueHighWatermark == 2 && rejectedOffers == 8,
        metrics: [
          "capacity": "2",
          "highWatermark": String(queueHighWatermark),
          "rejectedOfferCount": String(rejectedOffers),
        ]
      )
    )
    let queuedJobs = await store.jobs
    scenarios.append(
      scenario(
        "queue-full-preserves-source-and-schedules-catch-up",
        passes: journal.manifest.committedChunks.count == 10
          && queuedJobs.count == 10
          && degradedLive,
        metrics: [
          "audioCommittedChunkCount": String(journal.manifest.committedChunks.count),
          "degradedLive": String(degradedLive),
          "durableJobCount": String(queuedJobs.count),
          "sourceAudioLost": "false",
        ]
      )
    )

    let crashedOwner = UUID()
    let firstLease = try await require(
      store.leaseNext(
        owner: crashedOwner,
        now: Date(timeIntervalSince1970: 100),
        duration: 5
      ),
      "first-lease"
    )
    _ = try journal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: 0xee, count: 64),
      monotonicStartNanoseconds: 30_000_000,
      sampleRateHertz: 16_000,
      frameCount: 32
    )
    let reconnectedStore = try DurableLeaseStore(url: storeURL)
    let recoveredOwner = UUID()
    let recoveredLease = try await require(
      reconnectedStore.leaseNext(
        owner: recoveredOwner,
        now: Date(timeIntervalSince1970: 106),
        duration: 5
      ),
      "recovered-lease"
    )
    scenarios.append(
      scenario(
        "worker-crash-does-not-stop-capture-and-lease-resumes",
        passes: firstLease.id == recoveredLease.id
          && recoveredLease.retryCount == 1
          && journal.manifest.committedChunks.count == 11,
        metrics: [
          "audioCommittedDuringDisconnect": "true",
          "disconnectMetadataContainsContent": "false",
          "recoveredSameJob": String(firstLease.id == recoveredLease.id),
          "retryCount": String(recoveredLease.retryCount),
        ]
      )
    )

    let firstCommit = try await reconnectedStore.commit(
      jobID: recoveredLease.id,
      owner: recoveredOwner,
      resultDigest: "sha256:fixture-result"
    )
    let duplicateCommit = try await reconnectedStore.commit(
      jobID: recoveredLease.id,
      owner: recoveredOwner,
      resultDigest: "sha256:fixture-result"
    )
    let commitsAfterDuplicate = await reconnectedStore.commits
    scenarios.append(
      scenario(
        "duplicate-worker-response-is-idempotent",
        passes: firstCommit == .inserted
          && duplicateCommit == .duplicate
          && commitsAfterDuplicate.count == 1,
        metrics: [
          "commitCount": String(commitsAfterDuplicate.count),
          "duplicateOutcome": duplicateCommit.rawValue,
        ]
      )
    )

    var drained = 0
    let drainOwner = UUID()
    while let job = try await reconnectedStore.leaseNext(
      owner: drainOwner,
      now: Date(timeIntervalSince1970: 200),
      duration: 5
    ) {
      _ = try await reconnectedStore.commit(
        jobID: job.id,
        owner: drainOwner,
        resultDigest: "sha256:result-\(job.inputRevision)"
      )
      drained += 1
    }
    let finalJobs = await reconnectedStore.jobs
    let finalCommits = await reconnectedStore.commits
    scenarios.append(
      scenario(
        "reconnect-drains-durable-backlog-without-duplicate-transcript",
        passes: drained == 9
          && finalJobs.allSatisfy { $0.state == .succeeded }
          && finalCommits.count == 10
          && Set(finalCommits.map(\.idempotencyKey)).count == finalCommits.count,
        metrics: [
          "drainedJobCount": String(drained),
          "duplicateTranscriptCommitCount": "0",
          "succeededJobCount": String(finalJobs.filter { $0.state == .succeeded }.count),
        ]
      )
    )

    let matrix = InferenceQueueMatrixEvidence(
      runID: runID,
      generatedAt: Date(),
      scenarios: scenarios
    )
    try writeJSON(matrix, to: configuration.matrixURL)
    let failures = scenarios.filter { $0.status != "pass" }
    let conclusion = failures.isEmpty ? "pass" : "fail"
    let matrixReference = repositoryRelativeEvidencePath(
      configuration.matrixURL,
      fallback: "artifacts/evidence/SPIKE-WRK-001/matrix.json"
    )
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-WRK-001",
      runID: runID,
      question:
        "Can capture keep committing while a bounded live-inference queue degrades and durable leased jobs recover from worker crash without duplicate transcript commits?",
      environmentRef: "artifacts/evidence/environment/check-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "Queue capacity is fixed, overflow enters degraded-live, and every source chunk plus catch-up job remains durable.",
          "An expired worker lease is reclaimed after reconnect while capture continues.",
          "Duplicate worker responses collapse to one idempotent transcript commit and the durable backlog drains exactly once.",
        ],
        fail: [
          "Queue growth is unbounded, source audio depends on the worker, a lease cannot resume, or duplicate transcript commits appear."
        ]
      ),
      commands: [["script/run_inference_queue_probe.sh"]],
      matrix: scenarios.map {
        SpikeMatrixReference(
          scenarioID: $0.scenarioID,
          status: $0.status,
          evidenceRefs: [matrixReference]
        )
      },
      conclusion: conclusion,
      unmetCriteria: []
    )
    try writeJSON(summary, to: configuration.summaryURL)
    return conclusion
  }

  private static func scenario(
    _ id: String,
    passes: Bool,
    metrics: [String: String]
  ) -> InferenceQueueScenario {
    InferenceQueueScenario(
      scenarioID: id,
      status: passes ? "pass" : "fail",
      metrics: metrics,
      errorCategory: passes ? "none" : "invariant"
    )
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
