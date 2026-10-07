import BestASRDomain
import Foundation
import GRDB

/// What Settings › 储存空间 groups the library's files by (收3-5).
public enum LibraryStorageKind: String, CaseIterable, Codable, Sendable {
  /// Dictations recorded here.
  case dictation
  /// Room-microphone and system-audio recordings.
  case meetings
  /// Recordings and videos imported from files.
  case imported
  /// Dictations brought across from Typeless, with their recordings.
  case typeless
  /// Pasted and dropped text, screenshots, documents and other files.
  case items
}

/// One session's kind and when it was made, for the storage report.
public struct SessionStorageClass: Equatable, Sendable {
  public let sessionID: SessionID
  public let kind: LibraryStorageKind
  public let createdAt: Date
}

extension GRDBDictationStore {
  static func storageKind(mode: String, sourceKind: String?) -> LibraryStorageKind {
    if sourceKind == "typeless-import" { return .typeless }
    switch mode {
    case "dictation": return .dictation
    case "roomMicrophone", "systemAudio": return .meetings
    case "importedMedia": return .imported
    default: return .items
    }
  }

  /// Every session with the kind its files count under.
  public func sessionStorageClasses() async throws -> [SessionStorageClass] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT s.id, s.input_mode, s.created_at, m.source_kind
          FROM sessions s LEFT JOIN session_metadata m ON m.session_id = s.id
          """
      ).compactMap { row in
        guard let uuid = UUID(uuidString: row["id"]) else { return nil }
        return SessionStorageClass(
          sessionID: SessionID(uuid),
          kind: Self.storageKind(mode: row["input_mode"], sourceKind: row["source_kind"]),
          createdAt: Date(timeIntervalSince1970: row["created_at"]))
      }
    }
  }
}
