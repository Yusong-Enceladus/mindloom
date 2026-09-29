import BestASRAudioJournalProbe
import Foundation

public struct ResourcePolicyProbeConfiguration: Sendable {
  public let summaryURL: URL
  public let matrixURL: URL

  public init(summaryURL: URL, matrixURL: URL) {
    self.summaryURL = summaryURL
    self.matrixURL = matrixURL
  }
}

public struct ResourcePolicyScenario: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let status: String
  public let snapshot: ResourcePressureSnapshot
  public let state: ResourcePolicyState
  public let transition: ResourcePolicyTransition
  public let observableReasonCodes: [String]
  public let directives: [ResourceWorkDirective]
  public let committedChunksDuringScenario: Int
  public let sourceAudioLost: Bool

  public init(
    scenarioID: String,
    status: String,
    snapshot: ResourcePressureSnapshot,
    state: ResourcePolicyState,
    transition: ResourcePolicyTransition,
    observableReasonCodes: [String],
    directives: [ResourceWorkDirective],
    committedChunksDuringScenario: Int,
    sourceAudioLost: Bool
  ) {
    self.scenarioID = scenarioID
    self.status = status
    self.snapshot = snapshot
    self.state = state
    self.transition = transition
    self.observableReasonCodes = observableReasonCodes
    self.directives = directives
    self.committedChunksDuringScenario = committedChunksDuringScenario
    self.sourceAudioLost = sourceAudioLost
  }
}

public struct ResourcePolicyMatrix: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let priorityOrder: [ResourceWorkClass]
  public let scenarios: [ResourcePolicyScenario]
  public let attemptedCaptureChunkCount: Int
  public let committedCaptureChunkCount: Int
  public let recoveredReadableChunkCount: Int
  public let gapCount: Int
  public let conclusion: String

  public init(
    runID: UUID,
    priorityOrder: [ResourceWorkClass],
    scenarios: [ResourcePolicyScenario],
    attemptedCaptureChunkCount: Int,
    committedCaptureChunkCount: Int,
    recoveredReadableChunkCount: Int,
    gapCount: Int,
    conclusion: String
  ) {
    schemaVersion = 1
    kind = "resource-policy-matrix"
    spikeID = "SPIKE-RES-001"
    self.runID = runID
    self.priorityOrder = priorityOrder
    self.scenarios = scenarios
    self.attemptedCaptureChunkCount = attemptedCaptureChunkCount
    self.committedCaptureChunkCount = committedCaptureChunkCount
    self.recoveredReadableChunkCount = recoveredReadableChunkCount
    self.gapCount = gapCount
    self.conclusion = conclusion
  }
}

public enum ResourcePolicyProbeRunner {
  public static func run(
    configuration: ResourcePolicyProbeConfiguration
  ) async throws -> ResourcePolicyMatrix {
    let runID = UUID(uuidString: "6a000000-0000-4000-8000-000000000001")!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-resource-policy-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try AudioJournal.create(
      at: root.appendingPathComponent("journal", isDirectory: true),
      sessionID: runID,
      tracks: [AudioJournalTrack(trackID: "microphone", role: "microphoneLocal")]
    )
    var scenarios: [ResourcePolicyScenario] = []

    let nominal = snapshot(index: 1)
    scenarios.append(
      try await evaluateScenario(
        "nominal-priority-order",
        snapshot: nominal,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        decision.state == .normal
          && decision.transition == .noChange
          && decision.directives.map(\.priorityRank) == [0, 1, 2, 3, 4, 4]
          && decision.directives.allSatisfy { $0.action == .run }
      }
    )

    let memoryWarning = snapshot(index: 2, memory: .warning)
    scenarios.append(
      try await evaluateScenario(
        "memory-warning-sheds-heavy-work",
        snapshot: memoryWarning,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        preservesCapture(decision)
          && action(decision, .liveASR) == .throttle
          && action(decision, .finalASR) == .deferDurably
          && action(decision, .speaker) == .unloadAndDefer
          && action(decision, .localText) == .unloadAndDefer
      }
    )

    let memoryCritical = snapshot(index: 3, memory: .critical)
    scenarios.append(
      try await evaluateScenario(
        "memory-critical-preserves-capture-journal",
        snapshot: memoryCritical,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        preservesCapture(decision)
          && action(decision, .liveASR) == .deferDurably
          && action(decision, .finalASR) == .deferDurably
          && action(decision, .speaker) == .unloadAndDefer
          && action(decision, .localText) == .unloadAndDefer
      }
    )

    let thermalSerious = snapshot(index: 4, thermal: .serious)
    scenarios.append(
      try await evaluateScenario(
        "thermal-serious-throttles-by-priority",
        snapshot: thermalSerious,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        preservesCapture(decision)
          && action(decision, .liveASR) == .throttle
          && action(decision, .finalASR) == .deferDurably
          && action(decision, .speaker) == .deferDurably
          && action(decision, .localText) == .deferDurably
      }
    )

    let thermalCritical = snapshot(index: 5, thermal: .critical)
    scenarios.append(
      try await evaluateScenario(
        "thermal-critical-defers-all-inference",
        snapshot: thermalCritical,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        preservesCapture(decision)
          && [.liveASR, .finalASR, .speaker, .localText].allSatisfy {
            action(decision, $0) == .deferDurably
          }
      }
    )

    let backlogFull = snapshot(index: 6, backlog: 4, backlogCapacity: 4)
    scenarios.append(
      try await evaluateScenario(
        "backlog-cap-enters-observable-degraded-live",
        snapshot: backlogFull,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        preservesCapture(decision)
          && decision.state == .degradedLive
          && decision.observableReasonCodes == ["backlog-full"]
          && action(decision, .liveASR) == .deferDurably
      }
    )

    let combined = snapshot(
      index: 7,
      memory: .critical,
      thermal: .critical,
      backlog: 4,
      backlogCapacity: 4
    )
    scenarios.append(
      try await evaluateScenario(
        "combined-pressure-remains-bounded",
        snapshot: combined,
        controller: ResourcePolicyController(),
        journal: journal
      ) { decision in
        preservesCapture(decision)
          && Set(decision.observableReasonCodes)
            == ["memory-critical", "thermal-critical", "backlog-full"]
          && decision.directives.filter {
            $0.workClass != .capture && $0.workClass != .journal
          }.allSatisfy { $0.action != .run }
      }
    )

    let recoveryController = ResourcePolicyController()
    _ = try await recoveryController.evaluate(memoryCritical)
    let recovered = snapshot(index: 8)
    scenarios.append(
      try await evaluateScenario(
        "normal-snapshot-recovers-deferred-work",
        snapshot: recovered,
        controller: recoveryController,
        journal: journal
      ) { decision in
        decision.state == .normal
          && decision.transition == .recovered
          && decision.observableReasonCodes.isEmpty
          && decision.directives.allSatisfy { $0.action == .run }
      }
    )

    let reopened = try AudioJournal.open(at: journal.rootURL)
    let recovery = try reopened.recover()
    let attemptedChunks = scenarios.count * 2
    let committedChunks = journal.manifest.committedChunks.count
    let allScenariosPassed = scenarios.allSatisfy { $0.status == "pass" }
    let sourcePreserved =
      committedChunks == attemptedChunks
      && recovery.readableCommittedChunkCount == attemptedChunks
      && recovery.gaps.isEmpty
    let conclusion = allScenariosPassed && sourcePreserved ? "pass" : "fail"
    let priorityOrder = ResourceWorkClass.allCases.sorted {
      if $0.priorityRank == $1.priorityRank {
        return $0.rawValue < $1.rawValue
      }
      return $0.priorityRank < $1.priorityRank
    }
    let matrix = ResourcePolicyMatrix(
      runID: runID,
      priorityOrder: priorityOrder,
      scenarios: scenarios,
      attemptedCaptureChunkCount: attemptedChunks,
      committedCaptureChunkCount: committedChunks,
      recoveredReadableChunkCount: recovery.readableCommittedChunkCount,
      gapCount: recovery.gaps.count,
      conclusion: conclusion
    )
    try writeJSON(matrix, to: configuration.matrixURL)
    try writeSummary(
      runID: runID,
      scenarios: scenarios,
      conclusion: conclusion,
      to: configuration.summaryURL
    )
    return matrix
  }

  private static func evaluateScenario(
    _ scenarioID: String,
    snapshot: ResourcePressureSnapshot,
    controller: ResourcePolicyController,
    journal: AudioJournal,
    validator: (ResourcePolicyDecision) -> Bool
  ) async throws -> ResourcePolicyScenario {
    let before = journal.manifest.committedChunks.count
    try appendChunk(to: journal, index: before)
    let decision = try await controller.evaluate(snapshot)
    try appendChunk(to: journal, index: before + 1)
    let committed = journal.manifest.committedChunks.count - before
    let sourceAudioLost = committed != 2
    let passes =
      validator(decision)
      && preservesCapture(decision)
      && !sourceAudioLost
      && (!decision.observableReasonCodes.isEmpty
        || decision.state == .normal)
    return ResourcePolicyScenario(
      scenarioID: scenarioID,
      status: passes ? "pass" : "fail",
      snapshot: snapshot,
      state: decision.state,
      transition: decision.transition,
      observableReasonCodes: decision.observableReasonCodes,
      directives: decision.directives,
      committedChunksDuringScenario: committed,
      sourceAudioLost: sourceAudioLost
    )
  }

  private static func appendChunk(to journal: AudioJournal, index: Int) throws {
    _ = try journal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: UInt8(index % 251), count: 64),
      monotonicStartNanoseconds: UInt64(index) * 2_000_000,
      sampleRateHertz: 16_000,
      frameCount: 32
    )
  }

  private static func snapshot(
    index: UInt64,
    memory: ResourceMemoryPressure = .normal,
    thermal: ResourceThermalPressure = .nominal,
    backlog: Int = 0,
    backlogCapacity: Int = 4
  ) -> ResourcePressureSnapshot {
    ResourcePressureSnapshot(
      snapshotID: UUID(
        uuidString: String(
          format: "6a000000-0000-4000-8000-%012llx",
          index
        )
      )!,
      memoryPressure: memory,
      thermalPressure: thermal,
      inferenceBacklog: backlog,
      inferenceBacklogCapacity: backlogCapacity,
      recordingActive: true
    )
  }

  private static func preservesCapture(_ decision: ResourcePolicyDecision) -> Bool {
    action(decision, .capture) == .run
      && action(decision, .journal) == .run
  }

  private static func action(
    _ decision: ResourcePolicyDecision,
    _ workClass: ResourceWorkClass
  ) -> ResourceDirectiveAction? {
    decision.directive(for: workClass)?.action
  }

  private static func writeSummary(
    runID: UUID,
    scenarios: [ResourcePolicyScenario],
    conclusion: String,
    to url: URL
  ) throws {
    let reference = repositoryRelativeEvidencePath(
      url.deletingLastPathComponent().appendingPathComponent("matrix.json"),
      fallback: "artifacts/evidence/SPIKE-RES-001/matrix.json"
    )
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-RES-001",
      runID: runID,
      question:
        "Does capture and journal remain durable while memory, thermal, and backlog pressure degrade lower-priority inference and then recover observably?",
      environmentRef: "artifacts/evidence/environment/workspace-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "capture and journal always run before live ASR, final ASR, speaker, and local text work",
          "memory, thermal, and backlog injections produce observable bounded degradation without source loss",
          "normal resource state resumes deferred work and every committed chunk remains recoverable",
        ],
        fail: [
          "any pressure condition stops source journaling, runs lower-priority work ahead of capture, grows backlog beyond capacity, or fails to recover"
        ]
      ),
      commands: [["script/run_resource_policy_probe.sh"]],
      matrix: scenarios.map {
        SpikeMatrixReference(
          scenarioID: $0.scenarioID,
          status: $0.status,
          evidenceRefs: [reference]
        )
      },
      conclusion: conclusion,
      unmetCriteria: scenarios.filter { $0.status != "pass" }.map(\.scenarioID)
    )
    try writeJSON(summary, to: url)
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
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
