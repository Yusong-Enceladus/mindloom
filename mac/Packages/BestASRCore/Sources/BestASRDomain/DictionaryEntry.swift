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
  /// Words learned from a correction the user has made only once
  /// (ALIGNMENT 收1-8): their misheard forms are replaced, but the
  /// recognizer is not told to expect them until the same correction is
  /// seen again.
  public let replacementOnlyEntryIDs: Set<DictionaryEntryID>
  /// Words learning made (自动添加), however often their corrections were
  /// seen: their forms are replaced only as whole words and the word is
  /// never searched for among similar text (review 10-6 S7).
  public let learnedEntryIDs: Set<DictionaryEntryID>
  /// Forms learning added to a word the user made (「识别为」 forms from a
  /// correction), by word: replaced only as whole words, like a learned
  /// word's; the user's own forms of that word keep their replacement.
  public let learnedForms: [DictionaryEntryID: [String]]

  public init(
    entries: [DictionaryEntry], replacementOnlyEntryIDs: Set<DictionaryEntryID> = [],
    learnedEntryIDs: Set<DictionaryEntryID> = [],
    learnedForms: [DictionaryEntryID: [String]] = [:]
  ) throws {
    guard entries.allSatisfy({ $0.enabled && $0.tombstonedAt == nil }) else {
      throw DomainValidationError.invalidDictionaryEntry
    }
    self.entries = entries
    let ids = Set(entries.map(\.id))
    self.replacementOnlyEntryIDs = replacementOnlyEntryIDs.intersection(ids)
    self.learnedEntryIDs = learnedEntryIDs.intersection(ids)
    self.learnedForms = learnedForms.filter { ids.contains($0.key) && !$0.value.isEmpty }
    utf8ByteCount = entries.reduce(into: 0) { count, entry in
      count += entry.canonicalForm.utf8.count
      count += entry.spokenForms.reduce(0) { $0 + $1.utf8.count }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case entries
    case utf8ByteCount
    case replacementOnlyEntryIDs
    case learnedEntryIDs
    case learnedForms
  }

  private struct LearnedFormsEntry: Codable {
    let id: DictionaryEntryID
    let forms: [String]
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let forms =
      try container.decodeIfPresent([LearnedFormsEntry].self, forKey: .learnedForms) ?? []
    try self.init(
      entries: container.decode([DictionaryEntry].self, forKey: .entries),
      replacementOnlyEntryIDs: container.decodeIfPresent(
        Set<DictionaryEntryID>.self, forKey: .replacementOnlyEntryIDs) ?? [],
      learnedEntryIDs: container.decodeIfPresent(
        Set<DictionaryEntryID>.self, forKey: .learnedEntryIDs) ?? [],
      learnedForms: Dictionary(forms.map { ($0.id, $0.forms) }, uniquingKeysWith: { $1 }))
  }

  /// Fields added after V1.12 are written only when they hold something, so
  /// a projection without learned words encodes exactly as before.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entries, forKey: .entries)
    try container.encode(utf8ByteCount, forKey: .utf8ByteCount)
    func sorted(_ ids: Set<DictionaryEntryID>) -> [DictionaryEntryID] {
      ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
    if !replacementOnlyEntryIDs.isEmpty {
      try container.encode(sorted(replacementOnlyEntryIDs), forKey: .replacementOnlyEntryIDs)
    }
    if !learnedEntryIDs.isEmpty {
      try container.encode(sorted(learnedEntryIDs), forKey: .learnedEntryIDs)
    }
    if !learnedForms.isEmpty {
      try container.encode(
        sorted(Set(learnedForms.keys)).map { LearnedFormsEntry(id: $0, forms: learnedForms[$0]!) },
        forKey: .learnedForms)
    }
  }

  /// What the recognizer is told to expect: every word except those still
  /// used as replacements only.
  public var canonicalTerms: [String] {
    entries.filter { !replacementOnlyEntryIDs.contains($0.id) }.map(\.canonicalForm)
  }
}
