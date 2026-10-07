import BestASRDomain
import Foundation

// v12 people (ALIGNMENT 理3-1, 理3-5): the voices this Mac knows, the one
// numbering of the people nobody named yet (「没起名 1、2…」, the same number
// on every page), and the short stretch of a voice the pages play.

/// A person this Mac knows from its own recordings (the library's `persons`
/// table): a voice heard here, named or not. The pages list them even when
/// no matter holds them yet (a voice heard only in a dictation, or with the
/// DGX Spark not connected).
public struct MemoryLocalPerson: Equatable, Sendable {
  /// Upper-case UUID, as records and the organizer write it.
  public let personID: String
  /// Nil while nobody named them.
  public let name: String?
  public let aliases: [String]
  /// When this Mac first made them (orders the unnamed numbering).
  public let createdAt: Date
  /// Records they speak in.
  public let recordCount: Int
  /// The latest record they speak in.
  public let lastHeardAt: Date?
  /// Heard in a recording (speech evidence or a voiceprint on this Mac).
  public let hasVoice: Bool

  public init(
    personID: String, name: String?, aliases: [String] = [], createdAt: Date,
    recordCount: Int = 0, lastHeardAt: Date? = nil, hasVoice: Bool = true
  ) {
    self.personID = personID.uppercased()
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.name = trimmed.isEmpty ? nil : trimmed
    self.aliases = aliases
    self.createdAt = createdAt
    self.recordCount = recordCount
    self.lastHeardAt = lastHeardAt
    self.hasVoice = hasVoice
  }

  /// The same person under another name (nil: unnamed).
  public func renamed(_ name: String?) -> MemoryLocalPerson {
    MemoryLocalPerson(
      personID: personID, name: name, aliases: aliases, createdAt: createdAt,
      recordCount: recordCount, lastHeardAt: lastHeardAt, hasVoice: hasVoice)
  }
}

/// One stretch of a recording on its monotonic clock.
public struct MemoryVoiceStretch: Equatable, Sendable {
  public let itemID: String
  public let start: UInt64
  public let end: UInt64

  public init(itemID: String, start: UInt64, end: UInt64) {
    self.itemID = itemID
    self.start = start
    self.end = max(start, end)
  }

  public var nanoseconds: UInt64 { end - start }
}

/// What 「听一段」 plays of a voice: about three seconds of them alone.
public enum MemoryVoiceSample {
  /// Three seconds.
  public static let length: UInt64 = 3_000_000_000
  /// A stretch shorter than this is passed over while a longer one exists.
  static let shortest: UInt64 = 1_500_000_000

  /// The earliest stretch of at least 1.5 s (else the longest one), cut to
  /// `length` from its start: their own words only, never into the next
  /// speaker's. Nil when there is none.
  public static func choose(_ stretches: [MemoryVoiceStretch], length: UInt64 = length)
    -> MemoryVoiceStretch?
  {
    let usable = stretches.filter { $0.end > $0.start }
    guard
      let pick = usable.first(where: { $0.nanoseconds >= shortest })
        ?? usable.max(by: { $0.nanoseconds < $1.nanoseconds })
    else { return nil }
    return MemoryVoiceStretch(
      itemID: pick.itemID, start: pick.start, end: pick.start + min(pick.nanoseconds, length))
  }
}

/// The global numbering of people nobody named: one number per person, the
/// same on every page (按人, the person page, 原文's speaker names, copied
/// text). Ordered by when this Mac first knew them, then by ID, so the
/// numbers stay put while nobody is named; naming one moves the later ones
/// up by one.
public enum MemoryUnnamedNumbers {
  public struct Candidate: Equatable, Sendable {
    /// Upper-case canonical ID.
    public let personID: String
    public let firstKnown: Date?

    public init(personID: String, firstKnown: Date?) {
      self.personID = personID.uppercased()
      self.firstKnown = firstKnown
    }
  }

  /// Upper-case person ID → 1, 2, 3 …
  public static func assign(_ candidates: [Candidate]) -> [String: Int] {
    var earliest: [String: Date?] = [:]
    for candidate in candidates {
      if let known = earliest[candidate.personID] {
        switch (known, candidate.firstKnown) {
        case (nil, let date?): earliest[candidate.personID] = date
        case (let a?, let b?) where b < a: earliest[candidate.personID] = b
        default: break
        }
      } else {
        earliest[candidate.personID] = candidate.firstKnown
      }
    }
    let ordered = earliest.sorted { a, b in
      let left = a.value ?? .distantFuture
      let right = b.value ?? .distantFuture
      return left != right ? left < right : a.key < b.key
    }
    var numbers: [String: Int] = [:]
    for (index, entry) in ordered.enumerated() { numbers[entry.key] = index + 1 }
    return numbers
  }

  /// 「没起名 3」.
  public static func label(_ number: Int) -> String { "未命名 \(number)" }
}

/// A sentence a person said in a recording on this Mac (the person page's
/// 「说过的话」).
public struct MemoryPersonLine: Equatable, Identifiable, Sendable {
  /// Upper-case item ID.
  public let itemID: String
  public let startedAt: Date
  public let source: MemorySourceWords
  public let words: String
  /// The sentence in its recording (to play it, or to say 「不是他」); nil
  /// when the recording cannot be played here.
  public let voice: MemoryQuoteVoice?
  /// The person ID the sentence carries (the one 「不是他」 changes).
  public let speakerID: String
  /// Its start on the recording's clock (for 「不是他」).
  public let start: UInt64?

  public var id: String { itemID + "#" + String(start ?? 0) + "#" + words.prefix(8) }
}

extension MemoryProjection {
  /// What a person said in the recordings the pages hold: newest recording
  /// first, at most `perRecord` sentences each (in order), `limit` in all.
  public func spokenLines(of personID: String, limit: Int = 6, perRecord: Int = 2)
    -> [MemoryPersonLine]
  {
    let wanted = canonicalPersonID(personID).uppercased()
    let newest = records.values.filter { $0.inputMode != .userItem }.sorted {
      ($0.startedAt, Self.key($0.sessionID)) > ($1.startedAt, Self.key($1.sessionID))
    }
    var lines: [MemoryPersonLine] = []
    for record in newest {
      var here = 0
      for segment in record.segments where here < perRecord && lines.count < limit {
        guard let raw = segment.personID?.rawValue.uuidString,
          canonicalPersonID(raw).uppercased() == wanted
        else { continue }
        let words = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { continue }
        var voice: MemoryQuoteVoice?
        if record.playbackAvailable, let start = segment.monotonicStartNanoseconds,
          let end = segment.monotonicEndNanoseconds, end > start
        {
          voice = MemoryQuoteVoice(
            itemID: Self.key(record.sessionID), personID: raw.uppercased(), start: start, end: end)
        }
        lines.append(
          MemoryPersonLine(
            itemID: Self.key(record.sessionID), startedAt: record.startedAt,
            source: MemoryItemSource.words(record), words: words, voice: voice,
            speakerID: raw.uppercased(), start: segment.monotonicStartNanoseconds))
        here += 1
      }
      if lines.count >= limit { break }
    }
    return lines
  }
}

/// 不是他 in the library (v12, 理3-1): which of a person's speaker turns make
/// the chosen sentences theirs. A sentence is said by the turn of theirs
/// that overlaps it most — the rule the library uses to name a sentence's
/// speaker — so moving those turns moves exactly the sentences shown.
public enum MemorySpeakerSplit {
  public struct Turn: Equatable, Sendable {
    public let id: String
    public let start: UInt64
    public let end: UInt64
    /// Upper-case person ID the turn is counted for (nil: nobody).
    public let personID: String?

    public init(id: String, start: UInt64, end: UInt64, personID: String?) {
      self.id = id
      self.start = start
      self.end = max(start, end)
      self.personID = personID?.uppercased()
    }
  }

  /// The turn IDs (each once, in time order) for `sentences` (start, end).
  public static func turns(
    for sentences: [(start: UInt64, end: UInt64)], among turns: [Turn], person: String
  ) -> [String] {
    let wanted = person.uppercased()
    let theirs = turns.filter { $0.personID == wanted }
    var picked: [Turn] = []
    for sentence in sentences {
      let best = theirs.compactMap { turn -> (Turn, UInt64)? in
        let low = max(turn.start, sentence.start)
        let high = min(turn.end, sentence.end)
        return high > low ? (turn, high - low) : nil
      }.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.id > b.0.id }
      if let turn = best?.0, !picked.contains(turn) { picked.append(turn) }
    }
    return picked.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.map(\.id)
  }
}

/// 合并到… as the organizer applies it (`same_person`): the one who stays.
/// A voice heard on a Mac stays over a person read from texts (the
/// organizer takes voices as the person); otherwise the one chosen.
public enum MemoryPersonMerge {
  /// - Returns: who stays and who joins them.
  public static func outcome(
    person: String, into: String, persons: [RemoteOrganizerPerson]
  ) -> (stays: String, joins: String) {
    func find(_ id: String) -> RemoteOrganizerPerson? {
      persons.first { $0.personID.caseInsensitiveCompare(id) == .orderedSame }
    }
    if let target = find(into), let joining = find(person), target.origin != "voice",
      joining.origin == "voice"
    {
      return (person, into)
    }
    return (into, person)
  }
}
