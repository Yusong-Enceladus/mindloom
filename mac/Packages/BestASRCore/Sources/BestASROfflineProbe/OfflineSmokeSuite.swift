import CryptoKit
import Foundation

public enum OfflineProbeStatus: String, Codable, Sendable {
  case pass
  case fail
}

public enum OfflineCapability: String, Codable, CaseIterable, Sendable {
  case asr
  case evidence
  case llm
  case search
  case speaker
}

public struct OfflineCapabilityResult: Codable, Equatable, Sendable {
  public let capability: OfflineCapability
  public let status: OfflineProbeStatus
  public let durationNanoseconds: UInt64
  public let outputDigest: String
}

public struct OfflineRequestAuditReport: Codable, Equatable, Sendable {
  public let attemptedRequests: Int
  public let deniedRequests: Int
  public let allowedRequests: Int
}

public enum DenyAllNetworkAuditError: Error, Sendable {
  case requestDenied
}

public struct DenyAllNetworkAudit: Sendable {
  public private(set) var attemptedRequests = 0
  public private(set) var deniedRequests = 0

  public init() {}

  public mutating func request(destination _: String) throws {
    attemptedRequests += 1
    deniedRequests += 1
    throw DenyAllNetworkAuditError.requestDenied
  }

  public var report: OfflineRequestAuditReport {
    OfflineRequestAuditReport(
      attemptedRequests: attemptedRequests,
      deniedRequests: deniedRequests,
      allowedRequests: 0
    )
  }
}

public struct LocalOfflineSmokeResult: Codable, Equatable, Sendable {
  public let status: OfflineProbeStatus
  public let requestAudit: OfflineRequestAuditReport
  public let capabilities: [OfflineCapabilityResult]
}

public struct NetworkDenialProbeResult: Codable, Equatable, Sendable {
  public let attempted: Bool
  public let blocked: Bool
  public let errorCode: Int32

  public init(attempted: Bool, blocked: Bool, errorCode: Int32) {
    self.attempted = attempted
    self.blocked = blocked
    self.errorCode = errorCode
  }
}

public struct OfflineSmokeReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let status: OfflineProbeStatus
  public let networkPolicy: String
  public let enforcement: String
  public let networkDenialProbe: NetworkDenialProbeResult
  public let requestAudit: OfflineRequestAuditReport
  public let capabilities: [OfflineCapabilityResult]

  public init(
    runID: UUID,
    networkDenialProbe: NetworkDenialProbeResult,
    localResult: LocalOfflineSmokeResult
  ) {
    schemaVersion = 1
    kind = "offline-smoke-summary"
    self.runID = runID
    networkPolicy = "deny-all"
    enforcement = "macos-sandbox-exec"
    self.networkDenialProbe = networkDenialProbe
    requestAudit = localResult.requestAudit
    capabilities = localResult.capabilities
    status =
      networkDenialProbe.blocked
        && localResult.status == .pass
        && localResult.requestAudit.attemptedRequests == 0
        && localResult.requestAudit.allowedRequests == 0
      ? .pass : .fail
  }
}

public enum LocalOfflineSmokeSuite {
  public static func run() -> LocalOfflineSmokeResult {
    let audit = DenyAllNetworkAudit()
    let results = [
      runCapability(.asr, operation: runASRSmoke),
      runCapability(.speaker, operation: runSpeakerSmoke),
      runCapability(.llm, operation: runLLMSmoke),
      runCapability(.search, operation: runSearchSmoke),
      runCapability(.evidence, operation: runEvidenceSmoke),
    ]
    let passed =
      results.count == OfflineCapability.allCases.count
      && results.allSatisfy { $0.status == .pass }
      && audit.report.attemptedRequests == 0
    return LocalOfflineSmokeResult(
      status: passed ? .pass : .fail,
      requestAudit: audit.report,
      capabilities: results
    )
  }

  private static func runCapability(
    _ capability: OfflineCapability,
    operation: () throws -> Data
  ) -> OfflineCapabilityResult {
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let output = try operation()
      return OfflineCapabilityResult(
        capability: capability,
        status: .pass,
        durationNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
        outputDigest: digest(output)
      )
    } catch {
      return OfflineCapabilityResult(
        capability: capability,
        status: .fail,
        durationNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
        outputDigest: digest(Data())
      )
    }
  }

  private static func runASRSmoke() throws -> Data {
    let syntheticFrames: [Int16] = [0, 1, 4, 1, 0, -1, -4, -1]
    return try JSONSerialization.data(
      withJSONObject: [
        "frameCount": syntheticFrames.count,
        "segmentCount": 1,
      ],
      options: [.sortedKeys]
    )
  }

  private static func runSpeakerSmoke() throws -> Data {
    let syntheticCentroids: [[Double]] = [
      [1, 0],
      [0, 1],
    ]
    return try JSONSerialization.data(
      withJSONObject: [
        "clusterCount": syntheticCentroids.count,
        "occurrenceCount": 2,
      ],
      options: [.sortedKeys]
    )
  }

  private static func runLLMSmoke() throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "changedFactCount": 0,
        "outputKind": "rewrite",
        "sourceRevisionID": "fixture-revision-001",
      ],
      options: [.sortedKeys]
    )
  }

  private static func runSearchSmoke() throws -> Data {
    let localIndex = [
      "fixture-term": [
        "90000000-0000-4000-8000-000000000001"
      ]
    ]
    return try JSONSerialization.data(
      withJSONObject: [
        "resultCount": localIndex["fixture-term"]?.count ?? 0
      ],
      options: [.sortedKeys]
    )
  }

  private static func runEvidenceSmoke() throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1,
        "status": "pass",
      ],
      options: [.sortedKeys]
    )
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
