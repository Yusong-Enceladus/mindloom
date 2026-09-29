import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRProcessing
import Foundation

public struct DeterministicDictationClock: DictationClock {
  public let wallDate: Date
  public let monotonicValue: UInt64

  public init(
    wallDate: Date = Date(timeIntervalSince1970: 1_753_286_400),
    monotonicValue: UInt64 = 1_000_000
  ) {
    self.wallDate = wallDate
    self.monotonicValue = monotonicValue
  }

  public func wallTime() -> Date { wallDate }
  public func monotonicNanoseconds() -> UInt64 { monotonicValue }
}

public actor DeterministicMicrophoneCaptureAdapter: MicrophoneCapturePort {
  private let configuredChunks: [CapturedPCMChunk]
  private let configuredFailure: DictationFailure?
  private var stream: AsyncStream<CapturedPCMChunk>?
  private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
  private var preparedSessionID: SessionID?
  private var paused = false

  public init(
    chunks: [CapturedPCMChunk],
    terminalFailure: DictationFailure? = nil
  ) {
    configuredChunks = chunks
    configuredFailure = terminalFailure
  }

  public func prepare(
    sessionID: SessionID
  ) async throws -> MicrophoneCaptureDescriptor {
    preparedSessionID = sessionID
    let pair = AsyncStream.makeStream(
      of: CapturedPCMChunk.self,
      bufferingPolicy: .bufferingOldest(max(1, configuredChunks.count + 1))
    )
    stream = pair.stream
    continuation = pair.continuation
    return MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "builtin-fixture",
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
  }

  public func start() async throws {
    guard preparedSessionID != nil else {
      throw try DictationAdapterFailure(
        category: .invalidState,
        code: "fixture-not-prepared",
        retryable: false
      )
    }
    for chunk in configuredChunks { continuation?.yield(chunk) }
    continuation?.finish()
  }

  public func chunks() async -> AsyncStream<CapturedPCMChunk> {
    stream ?? AsyncStream { $0.finish() }
  }

  public func pause() async throws { paused = true }
  public func resume() async throws { paused = false }
  public func stop() async throws { continuation?.finish() }
  public func cancel() async { continuation?.finish() }
  public func terminalFailure() async -> DictationFailure? { configuredFailure }
  public func isPaused() -> Bool { paused }
}

public enum DeterministicASROutcome: Sendable {
  case result(DictationTranscriptResult)
  case failure(DictationAdapterFailure)
}

public actor DeterministicASRAdapter: DictationASRPort {
  private let outcomes: [DeterministicASROutcome]
  private var callIndex = 0
  private var receivedRequests: [DictationASRRequest] = []

  public init(outcomes: [DeterministicASROutcome]) {
    precondition(!outcomes.isEmpty)
    self.outcomes = outcomes
  }

  public func recognize(
    _ request: DictationASRRequest
  ) async throws -> DictationTranscriptResult {
    receivedRequests.append(request)
    let index = min(callIndex, outcomes.count - 1)
    callIndex += 1
    switch outcomes[index] {
    case .result(let result): return result
    case .failure(let failure): throw failure
    }
  }

  public func callCount() -> Int { callIndex }
  public func requests() -> [DictationASRRequest] { receivedRequests }
}

public enum DeterministicPolishOutcome: Sendable {
  case result(DictationPolishResult)
  case failure(DictationAdapterFailure)
}

public actor DeterministicPolishAdapter: DictationPolishPort {
  private let outcomes: [DeterministicPolishOutcome]
  private var callIndex = 0

  public init(outcomes: [DeterministicPolishOutcome]) {
    precondition(!outcomes.isEmpty)
    self.outcomes = outcomes
  }

  public func polish(
    _ request: DictationPolishRequest
  ) async throws -> DictationPolishResult {
    let index = min(callIndex, outcomes.count - 1)
    callIndex += 1
    switch outcomes[index] {
    case .result(let result): return result
    case .failure(let failure): throw failure
    }
  }

  public func callCount() -> Int { callIndex }
}

public enum DeterministicInsertionOutcome: Sendable {
  case result(method: DictationInsertionMethod, inserted: Bool)
  case failure(DictationAdapterFailure, externalMutationOccurred: Bool)
}

public actor DeterministicInsertionAdapter: DictationInsertionPort {
  private let target: DictationTargetSnapshot
  private let outcomes: [DeterministicInsertionOutcome]
  private var callIndex = 0
  private var externalMutationCount = 0

  public init(
    target: DictationTargetSnapshot,
    outcomes: [DeterministicInsertionOutcome]
  ) {
    precondition(!outcomes.isEmpty)
    self.target = target
    self.outcomes = outcomes
  }

  public func captureTarget() async throws -> DictationTargetSnapshot { target }

  public func insert(
    _ request: DictationInsertionRequest
  ) async throws -> DictationInsertionResult {
    let index = min(callIndex, outcomes.count - 1)
    callIndex += 1
    switch outcomes[index] {
    case .result(let method, let inserted):
      if inserted { externalMutationCount += 1 }
      return DictationInsertionResult(
        idempotencyKey: request.idempotencyKey,
        method: method,
        inserted: inserted
      )
    case .failure(let failure, let externalMutationOccurred):
      if externalMutationOccurred { externalMutationCount += 1 }
      throw failure
    }
  }

  public func callCount() -> Int { callIndex }
  public func mutationCount() -> Int { externalMutationCount }
}

public enum DeterministicSpeakerOutcome: Sendable {
  case success
  case failure(DictationAdapterFailure)
}

public actor DeterministicSpeakerScheduler: DictationSpeakerSchedulingPort {
  private let outcomes: [DeterministicSpeakerOutcome]
  private var callIndex = 0
  private var scheduledKeys = Set<String>()

  public init(outcomes: [DeterministicSpeakerOutcome] = [.success]) {
    precondition(!outcomes.isEmpty)
    self.outcomes = outcomes
  }

  public func scheduleFinalSpeakerWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64
  ) async throws {
    let index = min(callIndex, outcomes.count - 1)
    callIndex += 1
    switch outcomes[index] {
    case .success:
      scheduledKeys.insert(
        "\(sessionID.rawValue.uuidString):\(inputRevision)"
      )
    case .failure(let failure):
      throw failure
    }
  }

  public func callCount() -> Int { callIndex }
  public func uniqueScheduleCount() -> Int { scheduledKeys.count }
}

public actor DeterministicNetworkAttemptRecorder {
  private var attempts = 0

  public init() {}
  public func recordAttempt() { attempts += 1 }
  public func attemptCount() -> Int { attempts }
}
