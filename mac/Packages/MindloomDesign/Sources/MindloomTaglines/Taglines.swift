import Foundation

// The brand's taglines (docs/TAGLINES.md): the curated Chinese and English sets, bundled as `taglines.json`, and
// which line each six-hour period shows. No view here; the Mac draws them on the welcome window's first screen and at
// the foot of the main window's sidebar.

// MARK: - The data

/// Which set: the App's interface language decides (a Chinese interface shows the Chinese set, any other the
/// English one).
public enum TaglineLanguage: String, CaseIterable, Codable, Sendable {
  case zh
  case en

  /// "zh-Hans", "zh_CN", "zh" → `.zh`; "en", "en-US", "ja", "" → `.en`.
  public init(interfaceLanguage identifier: String) {
    let code = identifier.lowercased()
      .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
    self = code == "zh" ? .zh : .en
  }
}

public enum TaglineKind: String, Codable, Sendable {
  /// A quotation from a classic (public domain); it carries its source.
  case classic
  /// A quotation from a modern author in the public domain; it carries its source.
  case modernPublicDomain = "modern-pd"
  /// An original line in plain words.
  case plain
  /// An original line in the shape of a common game message ("Quest log updated.").
  case gameIdiom = "game-idiom"
  /// An original line that nods to a work it does not quote (`inspiration` names it).
  case homage

  /// Quotations show their source under the line.
  public var isQuotation: Bool { self == .classic || self == .modernPublicDomain }
}

/// When a line is meant to be seen. Lines without one are everyday lines.
public enum TaglineMoment: String, Codable, Sendable {
  /// The first line a new install shows (it is also an everyday line afterwards).
  case first
  /// Coming back after more than three days without opening Mindloom.
  case `return`
  /// The period from 06:00 in the product time zone (06:00–11:59).
  case morning
  /// The period from 18:00 (18:00–23:59).
  case evening
  /// The period from 00:00 (00:00–05:59).
  case lateNight = "late-night"

  /// The period of the day (`TaglineClock.periodOfDay`) a time-of-day line shows in: 0 from 00:00, 1 from 06:00,
  /// 3 from 18:00; nil for `first` and `return`.
  public var periodOfDay: Int? {
    switch self {
    case .lateNight: 0
    case .morning: 1
    case .evening: 3
    case .first, .return: nil
    }
  }
}

/// One line of a set.
public struct Tagline: Codable, Hashable, Identifiable, Sendable {
  /// "zh-01" … "en-41": stable, never reused for another line.
  public let id: String
  public let text: String
  /// For quotations: author and work ("韩愈《进学解》", "William Shakespeare, The Tempest").
  public let source: String?
  public let kind: TaglineKind
  /// The id of the corresponding line in the other language, when there is one.
  public let counterpart: String?
  public let moment: TaglineMoment?
  /// For original lines: what they nod to (not shown).
  public let inspiration: String?
  /// For quotations: where the wording was checked (not shown).
  public let checked: String?

  public init(
    id: String, text: String, source: String? = nil, kind: TaglineKind,
    counterpart: String? = nil, moment: TaglineMoment? = nil, inspiration: String? = nil,
    checked: String? = nil
  ) {
    self.id = id
    self.text = text
    self.source = source
    self.kind = kind
    self.counterpart = counterpart
    self.moment = moment
    self.inspiration = inspiration
    self.checked = checked
  }

  /// The source shown under the line: only for quotations.
  public var shownSource: String? { kind.isQuotation ? source : nil }

  /// The set the line belongs to (its id says).
  public var language: TaglineLanguage { id.hasPrefix("zh-") ? .zh : .en }

  var isTimeOfDay: Bool { moment?.periodOfDay != nil }
  /// Everyday lines fill the cycle's periods; time-of-day lines take a period of their own time of day in it;
  /// `return` lines stay out of it.
  var isEveryday: Bool { moment == nil || moment == .first }
}

/// Both sets.
public struct TaglineCatalog: Codable, Equatable, Sendable {
  public let version: Int
  public let zh: [Tagline]
  public let en: [Tagline]

  public init(version: Int = 1, zh: [Tagline], en: [Tagline]) {
    self.version = version
    self.zh = zh
    self.en = en
  }

  public init(data: Data) throws {
    self = try JSONDecoder().decode(Self.self, from: data)
  }

  /// The bundled `taglines.json`. Unreadable (never in a correct build; the tests read it), it is empty and the
  /// surfaces show no line.
  public static let bundled: TaglineCatalog = {
    guard let url = Bundle.module.url(forResource: "taglines", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let catalog = try? TaglineCatalog(data: data)
    else { return TaglineCatalog(version: 0, zh: [], en: []) }
    return catalog
  }()

  public func lines(_ language: TaglineLanguage) -> [Tagline] {
    switch language {
    case .zh: zh
    case .en: en
    }
  }

  /// The line a new install shows first.
  public func first(_ language: TaglineLanguage) -> Tagline? {
    let lines = lines(language)
    return lines.first { $0.moment == .first } ?? lines.first
  }

  /// A line of either set by id.
  public func line(id: String) -> Tagline? {
    (zh + en).first { $0.id == id }
  }
}

// MARK: - Periods

/// Time as the product counts it: in the product time zone, whatever zone the Mac is in. The line changes every six
/// hours, at 00:00, 06:00, 12:00 and 18:00 there.
public enum TaglineClock {
  public static let hoursPerPeriod = 6
  public static let periodsPerDay = 24 / hoursPerPeriod

  /// Periods since 1970-01-01 00:00 in `zone` (four a day).
  public static func period(_ date: Date, in zone: TimeZone) -> Int {
    Int((local(date, in: zone) / Double(hoursPerPeriod * 3600)).rounded(.down))
  }

  /// The day a period falls on: days since 1970-01-01 in the zone the period was counted in.
  public static func day(ofPeriod period: Int) -> Int {
    period >= 0 ? period / periodsPerDay : -((periodsPerDay - 1 - period) / periodsPerDay)
  }

  /// 0 for the period from 00:00, 1 from 06:00, 2 from 12:00, 3 from 18:00.
  public static func periodOfDay(ofPeriod period: Int) -> Int {
    period - periodsPerDay * day(ofPeriod: period)
  }

  private static func local(_ date: Date, in zone: TimeZone) -> Double {
    date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
  }
}

// MARK: - Rotation

/// This install's place in the rotation. Stored with the App's preferences (`TaglineStore`).
public struct TaglineInstall: Codable, Equatable, Sendable {
  /// Shuffles every cycle in this install's own order.
  public var seed: UInt64
  /// The period (`TaglineClock.period`) the install first showed a line: position 0 of the first cycle.
  public var firstPeriod: Int
  /// The last period a line was shown.
  public var lastShownPeriod: Int?
  /// A period that began after more than three days without a line on screen: it shows a `return` line.
  public var returnPeriod: Int?

  /// A showing this many days (product time zone) after the day of the last one is a return ("more than three
  /// days").
  public static let awayDays = 4

  public init(seed: UInt64, firstPeriod: Int, lastShownPeriod: Int? = nil, returnPeriod: Int? = nil) {
    self.seed = seed
    self.firstPeriod = firstPeriod
    self.lastShownPeriod = lastShownPeriod
    self.returnPeriod = returnPeriod
  }

  /// A new install: a random seed that survives any JSON reader (below 2^53), and this period as position 0.
  public static func new(period: Int, seed: UInt64 = .random(in: 0..<(1 << 53))) -> TaglineInstall {
    TaglineInstall(seed: seed, firstPeriod: period)
  }

  /// Records a showing in `period`. The first showing on a day four or more days after the day of the last one
  /// makes `period` a return. A clock set back never moves `lastShownPeriod` back.
  public mutating func shown(in period: Int) {
    if let last = lastShownPeriod,
      TaglineClock.day(ofPeriod: period) - TaglineClock.day(ofPeriod: last) >= Self.awayDays
    {
      returnPeriod = period
    }
    if lastShownPeriod.map({ period > $0 }) ?? true { lastShownPeriod = period }
  }

  enum CodingKeys: String, CodingKey {
    case seed
    case firstPeriod = "first_period"
    case lastShownPeriod = "last_shown_period"
    case returnPeriod = "return_period"
  }
}

/// Which line a surface shows (docs/TAGLINES.md §2):
///
/// - A day in the product time zone has four periods, from 00:00, 06:00, 12:00 and 18:00, and each period has one
///   line. All lines but the `return` ones make a per-install shuffled cycle, one line per period: every line once
///   before any repeats; the next cycle is shuffled again and never starts with the line that ended the last one.
///   Position 0 of a new install is the line marked `first`.
/// - A time-of-day line takes a period of its own time of day in each cycle (late-night lines one from 00:00,
///   morning lines one from 06:00, evening lines one from 18:00), never a cycle's position 0; the everyday lines
///   fill the other periods.
/// - A return (the first showing four or more days after the day of the last one) shows a `return` line for that
///   period instead.
///
/// A pure function of the install, the moment and the zone: the App asks only when a surface comes on screen, so
/// a line never changes while it is shown.
public struct TaglineRotation: Sendable {
  public let catalog: TaglineCatalog

  public init(catalog: TaglineCatalog = .bundled) {
    self.catalog = catalog
  }

  public func line(
    _ language: TaglineLanguage, install: TaglineInstall, now: Date, zone: TimeZone
  ) -> Tagline? {
    let period = TaglineClock.period(now, in: zone)
    let index = max(0, period - install.firstPeriod)
    if index > 0, install.returnPeriod == period {
      let returns = sorted(language).filter { $0.moment == .return }
      if !returns.isEmpty {
        let pick = Self.mix(install.seed, Self.unsigned(period), salt: 3) % UInt64(returns.count)
        return returns[Int(pick)]
      }
    }
    let length = cycleLength(language)
    guard length > 0 else { return catalog.lines(language).first }
    return cycle(language, install: install, number: index / length)[index % length]
  }

  /// The lines of a set by id, so the order does not depend on the file's order.
  func sorted(_ language: TaglineLanguage) -> [Tagline] {
    catalog.lines(language).sorted { $0.id < $1.id }
  }

  func everyday(_ language: TaglineLanguage) -> [Tagline] {
    sorted(language).filter(\.isEveryday)
  }

  func timeOfDay(_ language: TaglineLanguage) -> [Tagline] {
    sorted(language).filter(\.isTimeOfDay)
  }

  /// Periods in a cycle: one per everyday and time-of-day line (0 when the set has no everyday line).
  func cycleLength(_ language: TaglineLanguage) -> Int {
    let everyday = everyday(language).count
    return everyday == 0 ? 0 : everyday + timeOfDay(language).count
  }

  /// Cycle `number` of an install, period by period.
  func cycle(_ language: TaglineLanguage, install: TaglineInstall, number: Int) -> [Tagline] {
    let timed = timed(language, install: install, cycle: number)
    var everyday = order(language, seed: install.seed, cycle: number).makeIterator()
    return (0..<cycleLength(language)).compactMap { timed[$0] ?? everyday.next() }
  }

  /// A cycle's order of the everyday lines (they take the cycle's periods no time-of-day line takes, in turn).
  func order(_ language: TaglineLanguage, seed: UInt64, cycle: Int) -> [Tagline] {
    var lines = raw(language, seed: seed, cycle: cycle)
    if cycle == 0 {
      if let first = lines.firstIndex(where: { $0.moment == .first }) { lines.swapAt(0, first) }
    } else if lines.count > 1 {
      // Never the same line twice running across the boundary: the last cycle ended with its last everyday line
      // or with a time-of-day line, and a time-of-day line never starts a cycle.
      if lines[0] == lastLine(language, seed: seed, cycle: cycle - 1) { lines.swapAt(0, 1) }
    }
    return lines
  }

  /// The last everyday line of a cycle: past cycle 0 only positions 0 and 1 move, so with three or more lines the
  /// shuffle's last line is the cycle's.
  private func lastLine(_ language: TaglineLanguage, seed: UInt64, cycle: Int) -> Tagline? {
    if cycle == 0 || everyday(language).count < 3 {
      return order(language, seed: seed, cycle: cycle).last
    }
    return raw(language, seed: seed, cycle: cycle).last
  }

  private func raw(_ language: TaglineLanguage, seed: UInt64, cycle: Int) -> [Tagline] {
    var generator = SplitMix64(state: Self.mix(seed, Self.unsigned(cycle), salt: 1))
    return Self.shuffled(everyday(language), with: &generator)
  }

  /// A cycle's periods for the time-of-day lines: position in the cycle → line. Each line once, in a period of its
  /// own time of day (where the cycle starts decides which positions those are); never position 0.
  func timed(_ language: TaglineLanguage, install: TaglineInstall, cycle: Int) -> [Int: Tagline] {
    let lines = timeOfDay(language)
    let length = cycleLength(language)
    guard !lines.isEmpty, length > 1 else { return [:] }
    var generator = SplitMix64(state: Self.mix(install.seed, Self.unsigned(cycle), salt: 2))
    var free = Self.shuffled(Array(1..<length), with: &generator)
    let start = install.firstPeriod + cycle * length
    var result: [Int: Tagline] = [:]
    for line in lines {
      // Any free period only if a set had more lines of one time of day than a cycle has such periods (the data
      // tests rule that out); the cycle keeps every line either way.
      let own = free.firstIndex {
        TaglineClock.periodOfDay(ofPeriod: start + $0) == line.moment?.periodOfDay
      }
      guard let slot = own ?? free.indices.first else { continue }
      result[free.remove(at: slot)] = line
    }
    return result
  }

  // MARK: Deterministic randomness (the same on every Mac and every OS version)

  static func unsigned(_ value: Int) -> UInt64 { UInt64(bitPattern: Int64(value)) }

  static func mix(_ seed: UInt64, _ value: UInt64, salt: UInt64) -> UInt64 {
    var generator = SplitMix64(
      state: seed ^ (value &* 0x9E37_79B9_7F4A_7C15) ^ (salt &* 0xD1B5_4A32_D192_ED03))
    return generator.next()
  }

  static func shuffled<T>(_ items: [T], with generator: inout SplitMix64) -> [T] {
    var items = items
    guard items.count > 1 else { return items }
    for i in stride(from: items.count - 1, to: 0, by: -1) {
      let j = Int(generator.next() % UInt64(i + 1))
      items.swapAt(i, j)
    }
    return items
  }
}

/// SplitMix64 (Steele, Lea, Flood 2014): small, fast and fully specified, unlike the system's generator.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

// MARK: - Storage

/// The install's place in the rotation, kept in the App's preferences under `key` as one JSON string (a check run
/// may write it with `defaults write … -string`).
public struct TaglineStore {
  public static let key = "mindloom.taglines.install"
  let defaults: UserDefaults
  let rotation: TaglineRotation

  public init(defaults: UserDefaults, rotation: TaglineRotation = TaglineRotation()) {
    self.defaults = defaults
    self.rotation = rotation
  }

  /// The stored place; nil before the first showing (or when unreadable, which starts again like a new install;
  /// so does a place stored by the one-line-a-day rotation of the first 10-6 build, which never shipped).
  public var install: TaglineInstall? {
    guard let text = defaults.string(forKey: Self.key) else { return nil }
    return try? JSONDecoder().decode(TaglineInstall.self, from: Data(text.utf8))
  }

  /// The line for a surface coming on screen now; records the showing. The first call of an install starts its
  /// rotation in this period, with the line marked `first`.
  public func show(
    _ language: TaglineLanguage, now: Date = Date(), zone: TimeZone
  ) -> Tagline? {
    let period = TaglineClock.period(now, in: zone)
    var place = install ?? .new(period: period)
    place.shown(in: period)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(place), let text = String(data: data, encoding: .utf8) {
      defaults.set(text, forKey: Self.key)
    }
    return rotation.line(language, install: place, now: now, zone: zone)
  }
}
