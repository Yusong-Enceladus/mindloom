import Foundation

public struct DictionaryEntry: Codable, Equatable, Sendable {
  public let id: DictionaryEntryID
  public let revision: Revision
  public let canonicalForm: String
  public let spokenForms: [String]
  public let enabled: Bool
  public let createdAt: Date
  public let updatedAt: Date
  public let tombstonedAt: Date?

  public init(
    id: DictionaryEntryID = DictionaryEntryID(),
    revision: Revision,
    canonicalForm: String,
    spokenForms: [String],
    enabled: Bool,
    createdAt: Date,
    updatedAt: Date,
    tombstonedAt: Date? = nil
  ) throws {
    guard Self.isValidTerm(canonicalForm), spokenForms.count <= 32,
      spokenForms.allSatisfy(Self.isValidTerm),
      Set(spokenForms.map(Self.comparisonKey)).count == spokenForms.count,
      createdAt <= updatedAt,
      tombstonedAt.map({ $0 >= createdAt }) ?? true,
      tombstonedAt == nil || !enabled
    else {
      throw DomainValidationError.invalidDictionaryEntry
    }
    self.id = id
    self.revision = revision
    self.canonicalForm = canonicalForm
    self.spokenForms = spokenForms
    self.enabled = enabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.tombstonedAt = tombstonedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case revision
    case canonicalForm
    case spokenForms
    case enabled
    case createdAt
    case updatedAt
    case tombstonedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(DictionaryEntryID.self, forKey: .id),
      revision: container.decode(Revision.self, forKey: .revision),
      canonicalForm: container.decode(String.self, forKey: .canonicalForm),
      spokenForms: container.decode([String].self, forKey: .spokenForms),
      enabled: container.decode(Bool.self, forKey: .enabled),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt),
      tombstonedAt: container.decodeIfPresent(Date.self, forKey: .tombstonedAt)
    )
  }

  private static func isValidTerm(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty
      && value == trimmed
      && value.utf8.count <= 256
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func comparisonKey(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased()
  }
}

public struct DictionaryContextProjection: Codable, Equatable, Sendable {
  public let entries: [DictionaryEntry]
  public let utf8ByteCount: Int

  public init(entries: [DictionaryEntry]) throws {
    guard entries.allSatisfy({ $0.enabled && $0.tombstonedAt == nil }) else {
      throw DomainValidationError.invalidDictionaryEntry
    }
    self.entries = entries
    utf8ByteCount = entries.reduce(into: 0) { count, entry in
      count += entry.canonicalForm.utf8.count
      count += entry.spokenForms.reduce(0) { $0 + $1.utf8.count }
    }
  }

  public var canonicalTerms: [String] {
    entries.map(\.canonicalForm)
  }
}
