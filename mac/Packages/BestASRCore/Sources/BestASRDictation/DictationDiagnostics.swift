import BestASRDomain
import Foundation

public enum DictationDiagnosticReason: String, Codable, Sendable {
  case ambientSilence
  case commandRejected
  case failure
  case recovered
  case stateTransition
}

public struct DictationDiagnosticEvent: Codable, Equatable, Sendable {
  public let sessionID: SessionID?
  public let phase: DictationPhase
  public let reason: DictationDiagnosticReason
  public let monotonicNanoseconds: UInt64
  public let durationNanoseconds: UInt64?
  public let byteCount: UInt64?
  public let frameCount: UInt64?
  public let reasonCode: String?
  public let deviceID: String?
  public let modelArtifactID: String?

  public init(
    sessionID: SessionID?,
    phase: DictationPhase,
    reason: DictationDiagnosticReason,
    monotonicNanoseconds: UInt64,
    durationNanoseconds: UInt64? = nil,
    byteCount: UInt64? = nil,
    frameCount: UInt64? = nil,
    reasonCode: String? = nil,
    deviceID: String? = nil,
    modelArtifactID: String? = nil
  ) throws {
    try PrivacySafeDictationDiagnosticSchema.validateToken(reasonCode)
    try PrivacySafeDictationDiagnosticSchema.validateToken(deviceID)
    try PrivacySafeDictationDiagnosticSchema.validateToken(modelArtifactID)
    self.sessionID = sessionID
    self.phase = phase
    self.reason = reason
    self.monotonicNanoseconds = monotonicNanoseconds
    self.durationNanoseconds = durationNanoseconds
    self.byteCount = byteCount
    self.frameCount = frameCount
    self.reasonCode = reasonCode
    self.deviceID = deviceID
    self.modelArtifactID = modelArtifactID
  }
}

public enum DictationDiagnosticSchemaError: Error, Equatable, Sendable {
  case forbiddenField(String)
  case invalidToken
}

public enum PrivacySafeDictationDiagnosticSchema {
  public static let allowedFieldNames: Set<String> = [
    "sessionID",
    "phase",
    "reason",
    "monotonicNanoseconds",
    "durationNanoseconds",
    "byteCount",
    "frameCount",
    "reasonCode",
    "deviceID",
    "modelArtifactID",
  ]

  private static let forbiddenFragments = [
    "audio",
    "clipboard",
    "dictionary",
    "embedding",
    "name",
    "participant",
    "payload",
    "surrounding",
    "text",
    "title",
    "transcript",
    "window",
  ]

  public static func validate(fieldNames: some Sequence<String>) throws {
    for field in fieldNames {
      let normalized = field.lowercased()
      guard allowedFieldNames.contains(field),
        !forbiddenFragments.contains(where: normalized.contains)
      else {
        throw DictationDiagnosticSchemaError.forbiddenField(field)
      }
    }
  }

  public static func validateToken(_ token: String?) throws {
    guard let token else { return }
    guard token.count <= 128,
      token.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    else {
      throw DictationDiagnosticSchemaError.invalidToken
    }
  }
}
