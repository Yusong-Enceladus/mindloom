import BestASRDomain
import Foundation

public struct DictationInsertionCommand: Codable, Equatable, Sendable {
  public let idempotencyKey: String
  public let sessionID: SessionID
  public let transcriptRevisionID: TranscriptRevisionID
  public let text: String
  public let speakerLabelsIncluded: Bool
  public let waitsForSpeakerResolution: Bool

  fileprivate init(
    sessionID: SessionID,
    transcriptRevisionID: TranscriptRevisionID,
    text: String
  ) {
    idempotencyKey = [
      "dictation-insertion-v1",
      sessionID.rawValue.uuidString.lowercased(),
      transcriptRevisionID.rawValue.uuidString.lowercased(),
    ].joined(separator: ":")
    self.sessionID = sessionID
    self.transcriptRevisionID = transcriptRevisionID
    self.text = text
    speakerLabelsIncluded = false
    waitsForSpeakerResolution = false
  }
}

public struct DictationInsertionProjection: Codable, Equatable, Sendable {
  public let commands: [DictationInsertionCommand]

  public init(commands: [DictationInsertionCommand]) {
    self.commands = commands
  }
}

public enum DefaultDictationInsertionRenderer {
  public static func render(
    session: Session,
    transcript: TranscriptRevision
  ) -> DictationInsertionProjection {
    guard
      session.inputMode == .dictation,
      transcript.sessionID == session.id,
      !transcript.content.isEmpty
    else {
      return DictationInsertionProjection(commands: [])
    }
    return DictationInsertionProjection(
      commands: [
        DictationInsertionCommand(
          sessionID: session.id,
          transcriptRevisionID: transcript.id,
          text: transcript.content
        )
      ]
    )
  }
}
