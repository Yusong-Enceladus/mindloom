import Darwin
import Foundation

public enum ProbeJobState: String, Codable, Sendable {
  case queued
  case running
  case succeeded
}

public struct ProbeDurableJob: Codable, Equatable, Sendable {
  public let id: UUID
  public let idempotencyKey: String
  public let inputRevision: UInt64
  public let modelVersion: String
  public let configHash: String
  public var state: ProbeJobState
  public var retryCount: UInt32
  public var leaseOwner: UUID?
  public var leaseExpiresAt: Date?

  public init(
    id: UUID,
    idempotencyKey: String,
    inputRevision: UInt64,
    modelVersion: String,
    configHash: String,
    state: ProbeJobState,
    retryCount: UInt32,
    leaseOwner: UUID?,
    leaseExpiresAt: Date?
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.inputRevision = inputRevision
    self.modelVersion = modelVersion
    self.configHash = configHash
    self.state = state
    self.retryCount = retryCount
    self.leaseOwner = leaseOwner
    self.leaseExpiresAt = leaseExpiresAt
  }
}

public struct ProbeTranscriptCommit: Codable, Equatable, Sendable {
  public let idempotencyKey: String
  public let resultDigest: String
  public let jobID: UUID

  public init(idempotencyKey: String, resultDigest: String, jobID: UUID) {
    self.idempotencyKey = idempotencyKey
    self.resultDigest = resultDigest
    self.jobID = jobID
  }
}

public enum ProbeCommitOutcome: String, Codable, Sendable {
  case duplicate
  case inserted
}

public enum DurableLeaseStoreError: Error, Equatable {
  case incompatibleStore
  case jobNotFound
  case leaseOwnerMismatch
}

public actor DurableLeaseStore {
  private struct State: Codable {
    let schemaVersion: Int
    var jobs: [ProbeDurableJob]
    var commits: [ProbeTranscriptCommit]
  }

  private let url: URL
  private var state: State

  public init(url: URL) throws {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) {
      let decoded = try JSONDecoder().decode(
        State.self,
        from: Data(contentsOf: url)
      )
      guard decoded.schemaVersion == 1 else {
        throw DurableLeaseStoreError.incompatibleStore
      }
      state = decoded
    } else {
      state = State(schemaVersion: 1, jobs: [], commits: [])
      try Self.persist(state, to: url)
    }
  }

  @discardableResult
  public func enqueue(
    inputRevision: UInt64,
    modelVersion: String,
    configHash: String
  ) throws -> ProbeDurableJob {
    let key = "asrLive:\(inputRevision):\(modelVersion):\(configHash)"
    if let existing = state.jobs.first(where: { $0.idempotencyKey == key }) {
      return existing
    }
    let job = ProbeDurableJob(
      id: UUID(),
      idempotencyKey: key,
      inputRevision: inputRevision,
      modelVersion: modelVersion,
      configHash: configHash,
      state: .queued,
      retryCount: 0,
      leaseOwner: nil,
      leaseExpiresAt: nil
    )
    state.jobs.append(job)
    try persist()
    return job
  }

  public func leaseNext(
    owner: UUID,
    now: Date,
    duration: TimeInterval
  ) throws -> ProbeDurableJob? {
    guard
      let index = state.jobs.firstIndex(where: { job in
        job.state == .queued
          || (job.state == .running && (job.leaseExpiresAt ?? .distantPast) <= now)
      })
    else { return nil }
    if state.jobs[index].state == .running {
      state.jobs[index].retryCount += 1
    }
    state.jobs[index].state = .running
    state.jobs[index].leaseOwner = owner
    state.jobs[index].leaseExpiresAt = now.addingTimeInterval(duration)
    try persist()
    return state.jobs[index]
  }

  public func commit(
    jobID: UUID,
    owner: UUID,
    resultDigest: String
  ) throws -> ProbeCommitOutcome {
    guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else {
      throw DurableLeaseStoreError.jobNotFound
    }
    let job = state.jobs[index]
    if state.commits.contains(where: {
      $0.idempotencyKey == job.idempotencyKey
    }) {
      state.jobs[index].state = .succeeded
      state.jobs[index].leaseOwner = nil
      state.jobs[index].leaseExpiresAt = nil
      try persist()
      return .duplicate
    }
    guard job.leaseOwner == owner else {
      throw DurableLeaseStoreError.leaseOwnerMismatch
    }
    state.commits.append(
      ProbeTranscriptCommit(
        idempotencyKey: job.idempotencyKey,
        resultDigest: resultDigest,
        jobID: jobID
      )
    )
    state.jobs[index].state = .succeeded
    state.jobs[index].leaseOwner = nil
    state.jobs[index].leaseExpiresAt = nil
    try persist()
    return .inserted
  }

  public var jobs: [ProbeDurableJob] { state.jobs }
  public var commits: [ProbeTranscriptCommit] { state.commits }

  private func persist() throws {
    try Self.persist(state, to: url)
  }

  private static func persist(_ state: State, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp")
    let data = try encoder.encode(state)
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      let result = temporary.path.withCString { source in
        url.path.withCString { destination in
          Darwin.rename(source, destination)
        }
      }
      guard result == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}
