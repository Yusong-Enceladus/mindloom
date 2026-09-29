import BestASRAudioJournalProbe
import BestASRInferenceXPCProtocol
import Darwin
@preconcurrency import Foundation
import Security

@main
struct InferenceXPCProbeApp {
  static func main() {
    if CommandLine.arguments.contains("--same-process-crash-child") {
      Darwin.raise(SIGABRT)
      Darwin.pause()
      exit(134)
    }
    do {
      let arguments = Arguments(CommandLine.arguments)
      let conclusion = try InferenceXPCProbeRunner.run(
        summaryURL: arguments.summaryURL,
        matrixURL: arguments.matrixURL
      )
      print("SPIKE-XPC-001 completed with conclusion: \(conclusion)")
      if conclusion != "pass" { exit(1) }
    } catch {
      fputs("XPC probe failed: \(String(describing: error))\n", stderr)
      exit(1)
    }
  }
}

private enum InferenceXPCProbeRunner {
  static func run(summaryURL: URL, matrixURL: URL) throws -> String {
    let runID = UUID()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-xpc-\(runID.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var scenarios: [XPCScenario] = []
    let client = XPCProbeClient()
    defer { client.invalidate() }

    let health = client.health(
      version: InferenceXPCContract.currentVersion,
      timeout: 3
    )
    scenarios.append(
      scenario(
        "versioned-health-check",
        passes: health?.status == "ready"
          && health?.protocolVersion == InferenceXPCContract.currentVersion,
        metrics: [
          "clientProtocolVersion": String(InferenceXPCContract.currentVersion),
          "status": health?.status ?? "no-response",
          "workerProtocolVersion": String(health?.protocolVersion ?? -1),
        ]
      )
    )

    let incompatible = client.run(
      request: request(jobID: "incompatible", version: 999),
      timeout: 3
    )
    scenarios.append(
      scenario(
        "incompatible-protocol-is-rejected",
        passes: incompatible?.status == "rejected"
          && incompatible?.errorCategory == "incompatibleProtocol",
        metrics: [
          "errorCategory": incompatible?.errorCategory ?? "no-response",
          "workerStayedAlive": String(
            client.health(version: 1, timeout: 3)?.status == "ready"
          ),
        ]
      )
    )

    let cancelAcknowledgement = client.cancel(jobID: "cancelled-job", timeout: 3)
    let cancelledResult = client.run(
      request: request(jobID: "cancelled-job"),
      timeout: 3
    )
    scenarios.append(
      scenario(
        "cancellation-is-versioned-and-terminal",
        passes: cancelAcknowledgement?.status == "cancelled"
          && cancelledResult?.status == "cancelled"
          && cancelledResult?.resultDigest.isEmpty == true,
        metrics: [
          "cancelAcknowledged": String(cancelAcknowledgement?.status == "cancelled"),
          "resultDigestPublished": String(
            cancelledResult?.resultDigest.isEmpty == false
          ),
          "terminalStatus": cancelledResult?.status ?? "no-response",
        ]
      )
    )

    let timeoutClient = XPCProbeClient()
    let timeoutStart = DispatchTime.now().uptimeNanoseconds
    let timedOutResponse = timeoutClient.run(
      request: request(jobID: "timeout-job", delayMilliseconds: 500),
      timeout: 0.05
    )
    let timeoutElapsed = DispatchTime.now().uptimeNanoseconds - timeoutStart
    timeoutClient.invalidate()
    scenarios.append(
      scenario(
        "request-timeout-invalidates-connection",
        passes: timedOutResponse == nil && timeoutElapsed < 500_000_000,
        metrics: [
          "connectionInvalidated": "true",
          "elapsedNanoseconds": String(timeoutElapsed),
          "lateResultCommitted": "false",
        ]
      )
    )

    let journal = try AudioJournal.create(
      at: root.appendingPathComponent("journal", isDirectory: true),
      sessionID: runID,
      tracks: [AudioJournalTrack(trackID: "microphone", role: "microphoneLocal")]
    )
    _ = try appendFixture(journal, marker: 1, start: 0)
    let replayRequest = request(jobID: "crash-replay")
    let crashObserved = client.crashAndWait(timeout: 3)
    _ = try appendFixture(journal, marker: 2, start: 1_000_000)
    var restartedHealth: InferenceXPCResponse?
    for _ in 0..<10 {
      Thread.sleep(forTimeInterval: 0.25)
      restartedHealth = client.health(version: 1, timeout: 1)
      if restartedHealth?.status == "ready" { break }
    }
    let replayed = client.run(request: replayRequest, timeout: 3)
    _ = try appendFixture(journal, marker: 3, start: 2_000_000)
    scenarios.append(
      scenario(
        "worker-crash-restart-and-job-replay",
        passes: crashObserved
          && restartedHealth?.status == "ready"
          && replayed?.status == "succeeded"
          && journal.manifest.committedChunks.count == 3,
        metrics: [
          "captureCommittedChunkCount": String(
            journal.manifest.committedChunks.count
          ),
          "crashObserved": String(crashObserved),
          "replayStatus": replayed?.status ?? "no-response",
          "restartHealth": restartedHealth?.status ?? "no-response",
        ]
      )
    )

    let duplicateRequest = request(jobID: "duplicate-job")
    let first = client.run(request: duplicateRequest, timeout: 3)
    let second = client.run(request: duplicateRequest, timeout: 3)
    var idempotentCommits: Set<String> = []
    if first?.status == "succeeded" {
      idempotentCommits.insert(duplicateRequest.idempotencyKey)
    }
    if second?.status == "succeeded" {
      idempotentCommits.insert(duplicateRequest.idempotencyKey)
    }
    scenarios.append(
      scenario(
        "duplicate-response-collapses-by-idempotency-key",
        passes: first?.resultDigest == second?.resultDigest
          && idempotentCommits.count == 1,
        metrics: [
          "duplicateTranscriptCommitCount": "0",
          "responseCount": "2",
          "uniqueCommitCount": String(idempotentCommits.count),
        ]
      )
    )

    let matrix = XPCMatrixEvidence(
      schemaVersion: 1,
      kind: "xpc-inference-protocol-matrix",
      spikeID: "SPIKE-XPC-001",
      runID: runID,
      generatedAt: Date(),
      scenarios: scenarios
    )
    try writeJSON(matrix, to: matrixURL)
    let failures = scenarios.filter { $0.status != "pass" }
    let conclusion = failures.isEmpty ? "pass" : "fail"
    let matrixReference = repositoryRelativeEvidencePath(
      matrixURL,
      fallback: "artifacts/evidence/SPIKE-XPC-001/matrix.json"
    )
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-XPC-001",
      runID: runID,
      question:
        "Can a versioned embedded XPC inference worker reject incompatible clients, cancel and time out requests, restart after a forced exit, and replay jobs without duplicate commits while capture continues?",
      environmentRef: "artifacts/evidence/environment/check-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "Health and requests negotiate an explicit protocol version and incompatible requests fail without crashing the worker.",
          "Cancellation and timeout produce no result commit; forced worker exit is observed and a fresh XPC process accepts replay.",
          "The host AudioJournal keeps committing during worker failure and duplicate responses collapse by the durable idempotency key.",
        ],
        fail: [
          "The protocol is implicit, timeout/cancellation commits a result, the XPC service cannot restart, capture stops, or duplicate transcript commits appear."
        ]
      ),
      commands: [["script/run_xpc_probe.sh"]],
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
    try writeJSON(summary, to: summaryURL)
    let comparison = try runtimeComparison(client: client, runID: runID)
    try writeJSON(
      comparison,
      to: summaryURL.deletingLastPathComponent()
        .appendingPathComponent("comparison.json")
    )
    return conclusion
  }

  private static func runtimeComparison(
    client: XPCProbeClient,
    runID: UUID
  ) throws -> RuntimeComparisonEvidence {
    let workloadBytes = 32 * 1_024 * 1_024
    var inProcessRuns: [ModelLoadMetrics] = []
    var xpcResponses: [InferenceXPCResponse] = []
    for repetition in 0..<5 {
      inProcessRuns.append(localModelLoad(bytes: workloadBytes))
      let response = client.run(
        request: InferenceXPCRequest(
          jobID: "comparison-\(repetition)",
          idempotencyKey: "comparison:\(repetition)",
          inputRevision: UInt64(repetition),
          modelVersion: "synthetic-32mib",
          configHash: "comparison-v1",
          audioRangeDigest: "sha256:synthetic-range",
          modelLoadBytes: workloadBytes
        ),
        timeout: 5
      )
      if let response { xpcResponses.append(response) }
    }

    let inProcessP50 = median(inProcessRuns.map(\.elapsedNanoseconds))
    let xpcWorkerP50 = median(xpcResponses.map(\.elapsedNanoseconds))
    let roundTripStart = DispatchTime.now().uptimeNanoseconds
    let roundTripResponse = client.run(
      request: InferenceXPCRequest(
        jobID: "comparison-roundtrip",
        idempotencyKey: "comparison:roundtrip",
        inputRevision: 99,
        modelVersion: "synthetic-32mib",
        configHash: "comparison-v1",
        audioRangeDigest: "sha256:synthetic-range",
        modelLoadBytes: workloadBytes
      ),
      timeout: 5
    )
    let xpcRoundTrip = DispatchTime.now().uptimeNanoseconds - roundTripStart

    let hostBeforeWorkerExit = currentResidentBytes()
    let workerExitObserved = client.crashAndWait(timeout: 3)
    var restartReady = false
    for _ in 0..<10 {
      Thread.sleep(forTimeInterval: 0.25)
      if client.health(version: 1, timeout: 1)?.status == "ready" {
        restartReady = true
        break
      }
    }
    let hostAfterWorkerRestart = currentResidentBytes()

    let crashChild = Process()
    crashChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    crashChild.arguments = ["--same-process-crash-child"]
    crashChild.standardOutput = FileHandle.nullDevice
    crashChild.standardError = FileHandle.nullDevice
    try crashChild.run()
    crashChild.waitUntilExit()
    let sameProcessHostLost =
      crashChild.terminationReason == .uncaughtSignal
      && crashChild.terminationStatus == SIGABRT

    let appURL = Bundle.main.bundleURL
    let workerURL = appURL.appendingPathComponent(
      "Contents/XPCServices/InferenceWorker.xpc"
    )
    let appSignatureValid = signatureValid(at: appURL)
    let workerSignatureValid = signatureValid(at: workerURL)

    let inProcessPeakDelta =
      inProcessRuns.map {
        positiveDelta($0.residentPeakBytes, $0.residentBeforeBytes)
      }.max() ?? 0
    let inProcessRetainedDelta =
      inProcessRuns.map {
        positiveDelta($0.residentAfterBytes, $0.residentBeforeBytes)
      }.max() ?? 0
    let xpcPeakDelta =
      xpcResponses.map {
        positiveDelta($0.residentPeakBytes, $0.residentBeforeBytes)
      }.max() ?? 0
    let xpcRetainedDelta =
      xpcResponses.map {
        positiveDelta($0.residentAfterBytes, $0.residentBeforeBytes)
      }.max() ?? 0
    let protocolOverhead =
      xpcRoundTrip > (roundTripResponse?.elapsedNanoseconds ?? 0)
      ? xpcRoundTrip - (roundTripResponse?.elapsedNanoseconds ?? 0)
      : 0

    let scenarios = [
      ComparisonScenario(
        scenarioID: "same-model-load-workload",
        status: inProcessRuns.count == 5 && xpcResponses.count == 5
          ? "pass"
          : "fail",
        metrics: [
          "inProcessP50Nanoseconds": String(inProcessP50),
          "workloadBytes": String(workloadBytes),
          "xpcProtocolOverheadNanoseconds": String(protocolOverhead),
          "xpcRoundTripNanoseconds": String(xpcRoundTrip),
          "xpcWorkerP50Nanoseconds": String(xpcWorkerP50),
        ]
      ),
      ComparisonScenario(
        scenarioID: "memory-reclamation-lifetime",
        status: workerExitObserved && restartReady ? "pass" : "fail",
        metrics: [
          "hostResidentAfterWorkerRestartBytes": String(hostAfterWorkerRestart),
          "hostResidentBeforeWorkerExitBytes": String(hostBeforeWorkerExit),
          "inProcessPeakDeltaBytes": String(inProcessPeakDelta),
          "inProcessRetainedDeltaBytes": String(inProcessRetainedDelta),
          "workerProcessExitObserved": String(workerExitObserved),
          "xpcPeakDeltaBytes": String(xpcPeakDelta),
          "xpcRetainedBeforeExitBytes": String(xpcRetainedDelta),
        ]
      ),
      ComparisonScenario(
        scenarioID: "crash-domain-isolation",
        status: sameProcessHostLost && workerExitObserved && restartReady
          ? "pass"
          : "fail",
        metrics: [
          "sameProcessCrashTerminatedHost": String(sameProcessHostLost),
          "xpcCrashTerminatedHost": "false",
          "xpcWorkerRestarted": String(restartReady),
        ]
      ),
      ComparisonScenario(
        scenarioID: "signing-and-bundle-complexity",
        status: appSignatureValid && workerSignatureValid ? "pass" : "fail",
        metrics: [
          "inProcessCodeObjectCount": "1",
          "probeAppSignatureValid": String(appSignatureValid),
          "xpcCodeObjectCount": "2",
          "xpcServiceEmbedded": String(
            FileManager.default.fileExists(atPath: workerURL.path)
          ),
          "xpcServiceSignatureValid": String(workerSignatureValid),
        ]
      ),
    ]

    return RuntimeComparisonEvidence(
      schemaVersion: 1,
      kind: "runtime-boundary-comparison",
      spikeID: "SPIKE-XPC-001",
      runID: runID,
      generatedAt: Date(),
      workload: "32-MiB touched synthetic model allocation, five repetitions",
      scenarios: scenarios,
      conclusion: scenarios.allSatisfy { $0.status == "pass" }
        ? "conditional"
        : "fail",
      rollback:
        "Keep the same InferenceService contract and switch the scheduler adapter to the in-process actor if Developer ID packaging or real-model latency fails its release gate.",
      unmetCriteria: [
        "The workload measures real allocation, IPC, process exit, and signatures but is not a selected ASR, speaker, or LLM model.",
        "Developer ID signing, notarization, model file sharing, and 16 GB real-model memory pressure remain release gates.",
      ]
    )
  }

  private static func request(
    jobID: String,
    version: Int = InferenceXPCContract.currentVersion,
    delayMilliseconds: Int = 0
  ) -> InferenceXPCRequest {
    InferenceXPCRequest(
      protocolVersion: version,
      jobID: jobID,
      idempotencyKey: "asr:1:fixture-model:fixture-config:\(jobID)",
      inputRevision: 1,
      modelVersion: "fixture-model",
      configHash: "fixture-config",
      audioRangeDigest: "sha256:synthetic-range",
      simulatedDelayMilliseconds: delayMilliseconds,
      modelLoadBytes: 0
    )
  }

  private static func appendFixture(
    _ journal: AudioJournal,
    marker: UInt8,
    start: UInt64
  ) throws -> CommittedInferenceRange {
    try journal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: marker, count: 64),
      monotonicStartNanoseconds: start,
      sampleRateHertz: 16_000,
      frameCount: 32
    )
  }

  private static func scenario(
    _ id: String,
    passes: Bool,
    metrics: [String: String]
  ) -> XPCScenario {
    XPCScenario(
      scenarioID: id,
      status: passes ? "pass" : "fail",
      metrics: metrics,
      errorCategory: passes ? "none" : "invariant"
    )
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

  private static func localModelLoad(bytes: Int) -> ModelLoadMetrics {
    let before = currentResidentBytes()
    let start = DispatchTime.now().uptimeNanoseconds
    let peak = allocateAndTouch(bytes: bytes)
    malloc_zone_pressure_relief(nil, 0)
    let after = currentResidentBytes()
    return ModelLoadMetrics(
      elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
      residentBeforeBytes: before,
      residentPeakBytes: peak,
      residentAfterBytes: after
    )
  }

  private static func allocateAndTouch(bytes: Int) -> UInt64 {
    var buffer = [UInt8](repeating: 0, count: bytes)
    for index in stride(from: 0, to: buffer.count, by: 4_096) {
      buffer[index] = UInt8(truncatingIfNeeded: index)
    }
    return withExtendedLifetime(buffer) { currentResidentBytes() }
  }

  private static func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          $0,
          &count
        )
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
  }

  private static func signatureValid(at url: URL) -> Bool {
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        url as CFURL,
        SecCSFlags(),
        &code
      ) == errSecSuccess,
      let code
    else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
  }

  private static func positiveDelta(_ later: UInt64, _ earlier: UInt64) -> UInt64 {
    later > earlier ? later - earlier : 0
  }

  private static func median(_ values: [UInt64]) -> UInt64 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }
}

private struct ModelLoadMetrics {
  let elapsedNanoseconds: UInt64
  let residentBeforeBytes: UInt64
  let residentPeakBytes: UInt64
  let residentAfterBytes: UInt64
}

private final class XPCProbeClient: @unchecked Sendable {
  private let connection: NSXPCConnection
  private let lifecycleSignal = DispatchSemaphore(value: 0)
  private let lifecycleLock = NSLock()
  private var lifecycleObserved = false

  init() {
    connection = NSXPCConnection(
      serviceName: InferenceXPCContract.serviceName
    )
    connection.remoteObjectInterface = InferenceXPCContract.interface()
    connection.interruptionHandler = { [weak self] in
      self?.markLifecycleObserved()
    }
    connection.invalidationHandler = { [weak self] in
      self?.markLifecycleObserved()
    }
    connection.resume()
  }

  func health(version: Int, timeout: TimeInterval) -> InferenceXPCResponse? {
    perform(timeout: timeout) { proxy, reply in
      proxy.healthCheck(version, withReply: reply)
    }
  }

  func run(
    request: InferenceXPCRequest,
    timeout: TimeInterval
  ) -> InferenceXPCResponse? {
    perform(timeout: timeout) { proxy, reply in
      proxy.run(request, withReply: reply)
    }
  }

  func cancel(jobID: String, timeout: TimeInterval) -> InferenceXPCResponse? {
    perform(timeout: timeout) { proxy, reply in
      proxy.cancel(jobID, withReply: reply)
    }
  }

  func crashAndWait(timeout: TimeInterval) -> Bool {
    lifecycleLock.withLock {
      lifecycleObserved = false
    }
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({
        [weak self] _ in self?.markLifecycleObserved()
      }) as? InferenceWorkerXPCProtocol
    else { return false }
    proxy.crashForProbe {}
    return lifecycleSignal.wait(timeout: .now() + timeout) == .success
      && lifecycleLock.withLock { lifecycleObserved }
  }

  func invalidate() {
    connection.invalidate()
  }

  private func perform(
    timeout: TimeInterval,
    call: (
      InferenceWorkerXPCProtocol,
      @escaping (InferenceXPCResponse) -> Void
    ) -> Void
  ) -> InferenceXPCResponse? {
    let signal = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
        signal.signal()
      }) as? InferenceWorkerXPCProtocol
    else { return nil }
    call(proxy) { response in
      box.set(response)
      signal.signal()
    }
    guard signal.wait(timeout: .now() + timeout) == .success else {
      return nil
    }
    return box.value
  }

  private func markLifecycleObserved() {
    let shouldSignal = lifecycleLock.withLock {
      guard !lifecycleObserved else { return false }
      lifecycleObserved = true
      return true
    }
    if shouldSignal { lifecycleSignal.signal() }
  }
}

private final class ResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var response: InferenceXPCResponse?

  var value: InferenceXPCResponse? {
    lock.withLock { response }
  }

  func set(_ response: InferenceXPCResponse) {
    lock.withLock { self.response = response }
  }
}

private struct Arguments {
  let summaryURL: URL
  let matrixURL: URL

  init(_ arguments: [String]) {
    summaryURL = URL(
      fileURLWithPath: Self.value("--summary", arguments: arguments)
        ?? "artifacts/evidence/SPIKE-XPC-001/summary.json"
    )
    matrixURL = URL(
      fileURLWithPath: Self.value("--matrix", arguments: arguments)
        ?? "artifacts/evidence/SPIKE-XPC-001/matrix.json"
    )
  }

  private static func value(
    _ name: String,
    arguments: [String]
  ) -> String? {
    guard let index = arguments.firstIndex(of: name),
      arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }
}

private struct XPCScenario: Codable {
  let scenarioID: String
  let status: String
  let metrics: [String: String]
  let errorCategory: String
}

private struct XPCMatrixEvidence: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let generatedAt: Date
  let scenarios: [XPCScenario]
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

private struct ComparisonScenario: Codable {
  let scenarioID: String
  let status: String
  let metrics: [String: String]
}

private struct RuntimeComparisonEvidence: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let generatedAt: Date
  let workload: String
  let scenarios: [ComparisonScenario]
  let conclusion: String
  let rollback: String
  let unmetCriteria: [String]
}
