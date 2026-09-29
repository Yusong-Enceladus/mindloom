import Foundation

public enum DiagnosticValueError: Error, Equatable, Sendable {
  case invalidToken
  case nonFiniteMetric
}

public struct SafeDiagnosticToken: Codable, Equatable, Hashable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
    guard !value.isEmpty,
      value.count <= 128,
      value.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw DiagnosticValueError.invalidToken
    }
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public enum DiagnosticErrorCategory: String, Codable, CaseIterable, Sendable {
  case capture
  case inference
  case migration
  case modelArtifact
  case none
  case permissions
  case persistence
  case resource
  case unknown
}

public enum DiagnosticEventState: String, Codable, CaseIterable, Sendable {
  case cancelled
  case degraded
  case failed
  case recovered
  case retrying
  case succeeded
}

public enum DiagnosticMetricName: String, Codable, CaseIterable, Sendable {
  case backlogCount
  case droppedFrameCount
  case gapDurationMilliseconds
  case peakRSSBytes
  case realtimeFactor
}

public struct PrivacySafeMetric: Codable, Equatable, Sendable {
  public let name: DiagnosticMetricName
  public let value: Double

  public init(name: DiagnosticMetricName, value: Double) throws {
    guard value.isFinite else {
      throw DiagnosticValueError.nonFiniteMetric
    }
    self.name = name
    self.value = value
  }
}

public struct PrivacySafeLogEvent: Codable, Equatable, Sendable {
  public let correlationID: UUID
  public let recordedAt: Date
  public let category: DiagnosticErrorCategory
  public let state: DiagnosticEventState
  public let durationMilliseconds: Double
  public let retryCount: Int
  public let metrics: [PrivacySafeMetric]

  public init(
    correlationID: UUID,
    recordedAt: Date,
    category: DiagnosticErrorCategory,
    state: DiagnosticEventState,
    durationMilliseconds: Double,
    retryCount: Int,
    metrics: [PrivacySafeMetric]
  ) throws {
    guard durationMilliseconds.isFinite, durationMilliseconds >= 0, retryCount >= 0 else {
      throw DiagnosticValueError.nonFiniteMetric
    }
    self.correlationID = correlationID
    self.recordedAt = recordedAt
    self.category = category
    self.state = state
    self.durationMilliseconds = durationMilliseconds
    self.retryCount = retryCount
    self.metrics = metrics
  }
}

public actor PrivacySafeLogger {
  private let capacity: Int
  private var events: [PrivacySafeLogEvent] = []

  public init(capacity: Int = 500) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public func record(_ event: PrivacySafeLogEvent) {
    if events.count == capacity {
      events.removeFirst()
    }
    events.append(event)
  }

  public func snapshot() -> [PrivacySafeLogEvent] {
    events
  }
}

public enum DiagnosticModelCapability: String, Codable, CaseIterable, Sendable {
  case asr
  case diarization
  case localText
  case speakerEmbedding
}

public struct DiagnosticModelVersion: Codable, Equatable, Sendable {
  public let capability: DiagnosticModelCapability
  public let artifactID: SafeDiagnosticToken
  public let version: SafeDiagnosticToken

  public init(
    capability: DiagnosticModelCapability,
    artifactID: SafeDiagnosticToken,
    version: SafeDiagnosticToken
  ) {
    self.capability = capability
    self.artifactID = artifactID
    self.version = version
  }
}

public enum DiagnosticRedactedField: String, Codable, CaseIterable, Sendable {
  case audioPath
  case participantName
  case speakerEmbedding
  case transcriptText
  case windowTitle
}

public struct DiagnosticSourceInput: Sendable {
  public let appVersion: SafeDiagnosticToken
  public let osVersion: SafeDiagnosticToken
  public let models: [DiagnosticModelVersion]
  public let events: [PrivacySafeLogEvent]

  public let participantName: String?
  public let windowTitle: String?
  public let transcriptText: String?
  public let audioPath: String?
  public let speakerEmbedding: [Float]?

  public init(
    appVersion: SafeDiagnosticToken,
    osVersion: SafeDiagnosticToken,
    models: [DiagnosticModelVersion],
    events: [PrivacySafeLogEvent],
    participantName: String?,
    windowTitle: String?,
    transcriptText: String?,
    audioPath: String?,
    speakerEmbedding: [Float]?
  ) {
    self.appVersion = appVersion
    self.osVersion = osVersion
    self.models = models
    self.events = events
    self.participantName = participantName
    self.windowTitle = windowTitle
    self.transcriptText = transcriptText
    self.audioPath = audioPath
    self.speakerEmbedding = speakerEmbedding
  }
}

public struct DiagnosticBundle: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let bundleID: UUID
  public let createdAt: Date
  public let appVersion: SafeDiagnosticToken
  public let osVersion: SafeDiagnosticToken
  public let models: [DiagnosticModelVersion]
  public let events: [PrivacySafeLogEvent]
  public let redactedFields: [DiagnosticRedactedField]
}

public enum DiagnosticBundleBuilder {
  public static func build(
    input: DiagnosticSourceInput,
    bundleID: UUID = UUID(),
    createdAt: Date = Date()
  ) -> DiagnosticBundle {
    DiagnosticBundle(
      schemaVersion: 1,
      kind: "diagnostic-bundle",
      bundleID: bundleID,
      createdAt: createdAt,
      appVersion: input.appVersion,
      osVersion: input.osVersion,
      models: input.models,
      events: input.events,
      redactedFields: DiagnosticRedactedField.allCases
    )
  }
}
