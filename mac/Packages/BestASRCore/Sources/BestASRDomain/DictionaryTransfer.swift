import Foundation

/// Content-only dictionary row used by explicit local CSV/JSON transfer. It
/// carries no database identity or revision, so imports merge by normalized
/// canonical form instead of overwriting unrelated records.
public struct DictionaryTransferEntry: Codable, Equatable, Sendable {
  public let canonicalForm: String
  public let spokenForms: [String]
  public let enabled: Bool

  public init(
    canonicalForm: String,
    spokenForms: [String],
    enabled: Bool
  ) throws {
    _ = try DictionaryEntry(
      revision: Revision(1),
      canonicalForm: canonicalForm,
      spokenForms: spokenForms,
      enabled: enabled,
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    self.canonicalForm = canonicalForm
    self.spokenForms = spokenForms
    self.enabled = enabled
  }
}

public struct DictionaryTransferDocument: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let entries: [DictionaryTransferEntry]

  public init(schemaVersion: Int = 1, entries: [DictionaryTransferEntry]) throws {
    guard schemaVersion == 1, entries.count <= 100_000 else {
      throw DomainValidationError.invalidDictionaryEntry
    }
    self.schemaVersion = schemaVersion
    self.entries = entries
  }
}
