import Foundation
import Testing

@testable import MindloomTaglines

/// The bundled sets and the rotation (docs/TAGLINES.md).
@Suite struct TaglineDataTests {
  let catalog = TaglineCatalog.bundled

  @Test func theBundledFileLoads() throws {
    #expect(catalog.version == 1)
    #expect(catalog.zh.count >= 30)
    #expect(catalog.en.count >= 30)
    // The file in the source tree is the one bundled.
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(
        "Sources/MindloomTaglines/Resources/taglines.json")
    #expect(try TaglineCatalog(data: Data(contentsOf: url)) == catalog)
  }

  @Test func idsAreUniqueAndNameTheirLanguage() {
    for language in TaglineLanguage.allCases {
      let lines = catalog.lines(language)
      #expect(Set(lines.map(\.id)).count == lines.count)
      for line in lines { #expect(line.id.hasPrefix("\(language.rawValue)-"), "\(line.id)") }
    }
  }

  /// Welcome draws the line at 17 pt in 552 pt, the sidebar at 12 pt in 192 pt: a Chinese line stays on one
  /// welcome line and two sidebar lines; an English line on two welcome lines and three sidebar lines.
  @Test func linesAndSourcesFitTheirPlaces() {
    for line in catalog.zh {
      #expect(line.text.count <= 24, "\(line.id) \(line.text.count)")
      #expect((line.source ?? "").count <= 16, "\(line.id) source")
    }
    for line in catalog.en {
      #expect(line.text.count <= 72, "\(line.id) \(line.text.count)")
      #expect((line.source ?? "").count <= 56, "\(line.id) source")
    }
  }

  @Test func quotationsCarryTheirSourcesAndOthersDoNot() {
    for line in catalog.zh + catalog.en {
      if line.kind.isQuotation {
        #expect(!(line.source ?? "").isEmpty, "\(line.id) has no source")
        #expect(line.checked?.hasPrefix("https://") == true, "\(line.id) was not checked")
        #expect(line.shownSource == line.source)
      } else {
        #expect(line.source == nil, "\(line.id) is not a quotation")
        #expect(line.shownSource == nil)
      }
      if line.kind == .homage || line.kind == .gameIdiom {
        #expect(!(line.inspiration ?? "").isEmpty, "\(line.id) names no inspiration")
      }
    }
  }

  @Test func eachSetHasItsFirstReturnAndTimeOfDayLines() {
    for language in TaglineLanguage.allCases {
      let lines = catalog.lines(language)
      #expect(lines.filter { $0.moment == .first }.count == 1)
      #expect(!lines.filter { $0.moment == .return }.isEmpty)
      for moment in [TaglineMoment.morning, .evening, .lateNight] {
        #expect(lines.contains { $0.moment == moment }, "\(language) has no \(moment)")
      }
      // Every time-of-day line gets a period of its own time of day in each cycle: positions 1..<length go round
      // the four periods of the day, so each time of day has at least (length - 1) / 4 of them.
      let rotation = TaglineRotation(catalog: catalog)
      let length = rotation.cycleLength(language)
      #expect(length == rotation.everyday(language).count + lines.filter(\.isTimeOfDay).count)
      for periodOfDay in 0..<TaglineClock.periodsPerDay {
        let own = lines.filter { $0.moment?.periodOfDay == periodOfDay }.count
        #expect(own <= (length - 1) / TaglineClock.periodsPerDay, "\(language) \(periodOfDay)")
      }
    }
    #expect(catalog.first(.zh)?.text == "编织你的史诗。")
    #expect(catalog.first(.en)?.text == "Weave your epic.")
  }

  @Test func counterpartsAreMutual() throws {
    for language in TaglineLanguage.allCases {
      for line in catalog.lines(language) {
        guard let id = line.counterpart else { continue }
        let other = try #require(catalog.line(id: id), "\(line.id) → \(id)")
        #expect(!other.id.hasPrefix("\(language.rawValue)-"), "\(line.id) points into its own set")
        #expect(other.counterpart == line.id, "\(line.id) ↔ \(id)")
      }
    }
  }

  /// Lines taken out in review keep their ids out of use (an id is never reused for another line).
  static let retiredIDs = ["zh-12", "zh-15", "zh-26", "en-08", "en-25"]

  @Test func retiredIdsStayRetired() {
    for id in Self.retiredIDs { #expect(catalog.line(id: id) == nil, "\(id) is retired") }
  }

  /// docs/TAGLINES.md §4: a tagline never reassures (nothing is lost, nothing leaves the Mac) and never presses
  /// (deadlines, reminders, "don't forget"). Review 10-6 took out 「都还在你放下的地方。」 / "Right where you left
  /// it." and "Try to be one of the people on whom nothing is lost!" on these grounds.
  @Test func noLineReassuresOrPresses() {
    let zh = [
      "都还在", "不会丢", "不会上传", "不丢", "安全", "放心", "别担心", "别忘", "截止", "赶紧", "抓紧", "到期", "务必",
    ]
    let en = [
      "safe", "secure", "never lose", "nothing is lost", "where you left", "don’t worry",
      "don’t forget", "deadline", "hurry", "overdue", "must ",
    ]
    for line in catalog.zh {
      for phrase in zh { #expect(!line.text.contains(phrase), "\(line.id) says \(phrase)") }
    }
    for line in catalog.en {
      for phrase in en {
        #expect(!line.text.lowercased().contains(phrase), "\(line.id) says \(phrase)")
      }
    }
  }

  @Test func punctuationFollowsEachLanguage() {
    for line in catalog.zh {
      #expect(line.text == line.text.trimmingCharacters(in: .whitespacesAndNewlines))
      // Full-width punctuation and “ ” (docs/UI-COPY.md §1.8); a space only around Latin words.
      for bad in [",", ".", ";", ":", "!", "?", "\"", "'", "「", "」", "\n"] {
        #expect(!line.text.contains(bad), "\(line.id) contains \(bad)")
      }
    }
    for line in catalog.en {
      #expect(line.text == line.text.trimmingCharacters(in: .whitespacesAndNewlines))
      // Typographic apostrophes and quotes.
      for bad in ["\"", "'", "\n"] {
        #expect(!line.text.contains(bad), "\(line.id) contains \(bad)")
      }
    }
  }
}

@Suite struct TaglineLanguageTests {
  @Test func theInterfaceLanguageChoosesTheSet() {
    for zh in ["zh-Hans", "zh_CN", "zh-Hant-TW", "zh", "ZH-hans"] {
      #expect(TaglineLanguage(interfaceLanguage: zh) == .zh, "\(zh)")
    }
    for en in ["en", "en-US", "en_GB", "ja", "fr-FR", ""] {
      #expect(TaglineLanguage(interfaceLanguage: en) == .en, "\(en)")
    }
  }

  @Test func eachLanguageShowsOnlyItsOwnSet() {
    let rotation = TaglineRotation()
    let zone = TimeZone(identifier: "Asia/Singapore")!
    let start = TaglineClock.period(Date(timeIntervalSince1970: 1_791_000_000), in: zone)
    for seed: UInt64 in [1, 7, 42] {
      let install = TaglineInstall(seed: seed, firstPeriod: start)
      for offset in 0..<480 {
        let now = Date(timeIntervalSince1970: 1_791_000_000 + Double(offset) * 21_600)
        #expect(
          rotation.line(.zh, install: install, now: now, zone: zone)?.id.hasPrefix("zh-") == true)
        #expect(
          rotation.line(.en, install: install, now: now, zone: zone)?.id.hasPrefix("en-") == true)
      }
    }
  }
}

@Suite struct TaglineRotationTests {
  let rotation = TaglineRotation()
  let singapore = TimeZone(identifier: "Asia/Singapore")!
  let utc = TimeZone(secondsFromGMT: 0)!

  /// 2026-10-06 00:00 in Singapore (UTC+8).
  let midnight = Date(timeIntervalSince1970: 1_791_216_000)

  func at(_ day: Int, hour: Int, minute: Int = 0, second: Int = 0) -> Date {
    midnight.addingTimeInterval(Double(day * 86_400 + hour * 3600 + minute * 60 + second))
  }

  /// The local day (days since 1970-01-01) and hour in `zone` by the Gregorian calendar, independent of
  /// `TaglineClock`.
  func local(_ date: Date, in zone: TimeZone) -> (day: Int, hour: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    let day = calendar.dateComponents(
      [.day], from: DateComponents(year: 1970, month: 1, day: 1),
      to: DateComponents(year: parts.year, month: parts.month, day: parts.day)
    ).day!
    return (day, parts.hour!)
  }

  /// `seconds` into period `period` in UTC.
  func utcMoment(_ period: Int, seconds: Int = 0) -> Date {
    Date(timeIntervalSince1970: Double(period * 21_600 + seconds))
  }

  @Test func periodsChangeAtZeroSixTwelveAndEighteenInTheProductTimeZone() {
    #expect(local(midnight, in: singapore).hour == 0)
    let p0 = TaglineClock.period(midnight, in: singapore)
    #expect(TaglineClock.periodOfDay(ofPeriod: p0) == 0)
    #expect(TaglineClock.day(ofPeriod: p0) == local(midnight, in: singapore).day)
    #expect(TaglineClock.period(midnight.addingTimeInterval(-1), in: singapore) == p0 - 1)
    for (k, hour) in [0, 6, 12, 18].enumerated() {
      #expect(TaglineClock.period(at(0, hour: hour), in: singapore) == p0 + k)
      #expect(TaglineClock.period(at(0, hour: hour + 5, minute: 59, second: 59), in: singapore) == p0 + k)
      #expect(TaglineClock.periodOfDay(ofPeriod: p0 + k) == k)
      #expect(TaglineClock.day(ofPeriod: p0 + k) == local(midnight, in: singapore).day)
    }
    #expect(TaglineClock.period(at(1, hour: 0), in: singapore) == p0 + 4)
    // Before 1970 too (floor, not truncation).
    for (period, day, periodOfDay) in [(-1, -1, 3), (-4, -1, 0), (-5, -2, 3), (3, 0, 3), (4, 1, 0)] {
      #expect(TaglineClock.day(ofPeriod: period) == day, "\(period)")
      #expect(TaglineClock.periodOfDay(ofPeriod: period) == periodOfDay, "\(period)")
    }
    // The same instants in Los Angeles (UTC-7) are inside one period there (08:59:59 and 09:00).
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    #expect(
      TaglineClock.period(midnight.addingTimeInterval(-1), in: losAngeles)
        == TaglineClock.period(midnight, in: losAngeles))
    #expect(local(midnight, in: losAngeles).hour == 9)

    // The line changes at Singapore's 06:00, 12:00, 18:00 and 00:00, not at the Mac's.
    let install = TaglineInstall(seed: 11, firstPeriod: p0)
    let cycle = rotation.cycle(.zh, install: install, number: 0)
    let first = rotation.catalog.first(.zh)
    #expect(cycle[0] == first)
    #expect(
      rotation.line(.zh, install: install, now: at(0, hour: 5, minute: 59, second: 59), zone: singapore)
        == first)
    for (k, hour) in [(1, 6), (2, 12), (3, 18)] {
      let shown = rotation.line(.zh, install: install, now: at(0, hour: hour), zone: singapore)
      #expect(shown == cycle[k])
      #expect(shown != first)
    }
    #expect(rotation.line(.zh, install: install, now: at(1, hour: 0), zone: singapore) == cycle[4])
  }

  /// Singapore has no daylight saving: every period is exactly six hours.
  @Test func singaporePeriodsAreSixHoursLong() {
    let p0 = TaglineClock.period(midnight, in: singapore)
    for k in 0..<(4 * 400) {
      let start = midnight.addingTimeInterval(Double(k) * 21_600)
      #expect(TaglineClock.period(start, in: singapore) == p0 + k)
      #expect(TaglineClock.period(start.addingTimeInterval(-1), in: singapore) == p0 + k - 1)
      #expect(local(start, in: singapore).hour == (k % 4) * 6)
      #expect(TaglineClock.periodOfDay(ofPeriod: p0 + k) == k % 4)
      #expect(TaglineClock.day(ofPeriod: p0 + k) == local(start, in: singapore).day)
    }
  }

  /// In a zone with daylight saving, periods still start at the local 00:00, 06:00, 12:00 and 18:00 (the day the
  /// clocks change, the period from 00:00 is an hour shorter or longer).
  @Test func periodsFollowTheLocalClockAcrossDaylightSavingChanges() {
    let newYork = TimeZone(identifier: "America/New_York")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = newYork
    var date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    var previous = TaglineClock.period(date, in: newYork) - 1
    var lengths = Set<TimeInterval>()
    for _ in 0..<366 {
      for (k, hour) in [0, 6, 12, 18].enumerated() {
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        let period = TaglineClock.period(start, in: newYork)
        #expect(period == previous + 1, "\(start)")
        #expect(TaglineClock.periodOfDay(ofPeriod: period) == k)
        #expect(TaglineClock.day(ofPeriod: period) == local(start, in: newYork).day)
        #expect(TaglineClock.period(start.addingTimeInterval(-1), in: newYork) == previous)
        #expect(local(start, in: newYork).hour == hour)
        if k == 0 {
          let six = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: date)!
          lengths.insert(six.timeIntervalSince(start))
        }
        previous = period
      }
      date = calendar.date(byAdding: .day, value: 1, to: date)!
    }
    // 2026-03-08 and 2026-11-01: five and seven hours from 00:00 to 06:00.
    let hours = lengths.map { Int($0) / 3600 }.sorted()
    #expect(hours == [5, 6, 7])
  }

  @Test func aNewInstallStartsWithTheFirstLine() {
    let p0 = TaglineClock.period(midnight, in: singapore)
    for seed in UInt64(0)..<200 {
      // Installed in each period of the day, shown at its start, inside it and at its last second.
      for k in 0..<4 {
        let install = TaglineInstall.new(period: p0 + k, seed: seed)
        for offset in [0, 3 * 3600, 6 * 3600 - 1] {
          let now = at(0, hour: 6 * k, second: offset)
          #expect(rotation.line(.zh, install: install, now: now, zone: singapore)?.moment == .first)
          #expect(rotation.line(.en, install: install, now: now, zone: singapore)?.moment == .first)
        }
      }
    }
  }

  @Test func selectionIsDeterministicPerPeriodAndInstall() {
    let p0 = TaglineClock.period(midnight, in: singapore)
    let install = TaglineInstall(seed: 2026, firstPeriod: p0)
    // The file's order does not matter, only the ids.
    let reversed = TaglineRotation(
      catalog: TaglineCatalog(
        zh: rotation.catalog.zh.reversed(), en: rotation.catalog.en.reversed()))
    for k in 0..<400 {
      let start = midnight.addingTimeInterval(Double(k) * 21_600)
      let a = rotation.line(.zh, install: install, now: start, zone: singapore)
      #expect(a != nil)
      // The same line all period long, from any rotation of the same catalog.
      for offset: TimeInterval in [1, 3600, 4 * 3600, 6 * 3600 - 1] {
        let now = start.addingTimeInterval(offset)
        #expect(rotation.line(.zh, install: install, now: now, zone: singapore) == a)
        #expect(TaglineRotation().line(.zh, install: install, now: now, zone: singapore) == a)
        #expect(reversed.line(.zh, install: install, now: now, zone: singapore) == a)
      }
    }
    // Another install has another order.
    let orders = Set(
      (UInt64(1)...20).map {
        rotation.cycle(.zh, install: TaglineInstall(seed: $0, firstPeriod: p0), number: 1).map(\.id)
      })
    #expect(orders.count == 20)
    // Pinned: the first periods of one install (a change here changes every install's order).
    let pinned = (0..<8).map {
      rotation.line(
        .zh, install: TaglineInstall(seed: 1, firstPeriod: p0),
        now: midnight.addingTimeInterval(Double($0) * 21_600 + 3600), zone: singapore
      )!.id
    }
    #expect(pinned.first == "zh-16")
    #expect(pinned == Self.pinnedSeedOne, "\(pinned)")
  }

  /// `selectionIsDeterministicPerPeriodAndInstall` pins these (seed 1, from 2026-10-06 00:00 in Singapore,
  /// periods 0–7).
  static let pinnedSeedOne = ["zh-16", "zh-05", "zh-11", "zh-37", "zh-19", "zh-39", "zh-13", "zh-35"]

  @Test func everyLineOnceBeforeAnyRepeats() {
    for language in TaglineLanguage.allCases {
      let lines = Set(rotation.everyday(language) + rotation.timeOfDay(language))
      let length = rotation.cycleLength(language)
      #expect(lines.count == length)
      #expect(lines.allSatisfy { $0.moment != .return })
      for seed in UInt64(0)..<60 {
        // Installs that began in each period of the day.
        for firstPeriod in 0..<4 {
          let install = TaglineInstall(seed: seed, firstPeriod: firstPeriod)
          var previousLast: Tagline?
          for number in 0..<5 {
            let cycle = rotation.cycle(language, install: install, number: number)
            #expect(cycle.count == length)
            #expect(Set(cycle) == lines, "seed \(seed) cycle \(number)")
            #expect(Set(rotation.order(language, seed: seed, cycle: number)) == Set(rotation.everyday(language)))
            if let previousLast {
              #expect(cycle.first != previousLast, "seed \(seed) first \(firstPeriod) cycle \(number)")
            }
            previousLast = cycle.last
          }
          // As shown, period by period: each line once per cycle.
          for number in 0..<3 {
            let shown = (0..<length).map { position in
              rotation.line(
                language, install: install,
                now: utcMoment(firstPeriod + number * length + position, seconds: 3600), zone: utc)!
            }
            #expect(Set(shown) == lines, "seed \(seed) first \(firstPeriod) cycle \(number)")
          }
        }
      }
    }
  }

  @Test func eachTimeOfDayLineTakesAPeriodOfItsOwnTimeOfDay() {
    for language in TaglineLanguage.allCases {
      let timedLines = rotation.timeOfDay(language)
      let length = rotation.cycleLength(language)
      for seed in UInt64(0)..<40 {
        for firstPeriod in 0..<4 {
          let install = TaglineInstall(seed: seed, firstPeriod: firstPeriod)
          for number in 0..<3 {
            let positions = rotation.timed(language, install: install, cycle: number)
            #expect(Set(positions.values) == Set(timedLines))
            #expect(positions.count == timedLines.count)
            #expect(positions[0] == nil)
            for (position, line) in positions {
              let period = firstPeriod + number * length + position
              #expect(
                TaglineClock.periodOfDay(ofPeriod: period) == line.moment?.periodOfDay,
                "\(line.id) in period \(TaglineClock.periodOfDay(ofPeriod: period)) of the day")
              // Shown the whole period.
              for seconds in [0, 3600, 21_599] {
                #expect(
                  rotation.line(language, install: install, now: utcMoment(period, seconds: seconds), zone: utc)
                    == line)
              }
            }
          }
        }
      }
    }
  }

  @Test func timeOfDayLinesHaveTheirPeriodOfTheDay() {
    #expect(TaglineMoment.lateNight.periodOfDay == 0)
    #expect(TaglineMoment.morning.periodOfDay == 1)
    #expect(TaglineMoment.evening.periodOfDay == 3)
    #expect(TaglineMoment.first.periodOfDay == nil)
    #expect(TaglineMoment.return.periodOfDay == nil)
  }

  @Test func aReturnAfterMoreThanThreeDaysShowsAReturnLineThatPeriod() {
    let start = TaglineClock.period(midnight, in: singapore)
    var install = TaglineInstall(seed: 5, firstPeriod: start)
    install.shown(in: start)
    // Every period for ten days (the last one from 18:00 on day 9), then 06:00 on day 12: three days later, not a
    // return.
    for k in 1..<40 { install.shown(in: start + k) }
    install.shown(in: start + 49)
    #expect(install.returnPeriod == nil)
    #expect(install.lastShownPeriod == start + 49)
    #expect(
      rotation.line(.zh, install: install, now: at(12, hour: 7), zone: singapore)?.moment != .return)
    // 00:00 on day 16 is four days after day 12: a return, all that period.
    install.shown(in: start + 64)
    #expect(install.returnPeriod == start + 64)
    for hour in [0, 3, 5] {
      #expect(rotation.line(.zh, install: install, now: at(16, hour: hour), zone: singapore)?.moment == .return)
      #expect(rotation.line(.en, install: install, now: at(16, hour: hour), zone: singapore)?.moment == .return)
    }
    // Shown again in the same period: still the return. From 06:00: the cycle again.
    install.shown(in: start + 64)
    #expect(install.returnPeriod == start + 64)
    install.shown(in: start + 65)
    #expect(install.returnPeriod == start + 64)
    for hour in [6, 9, 11] {
      #expect(rotation.line(.zh, install: install, now: at(16, hour: hour), zone: singapore)?.moment != .return)
    }
    // A clock set back never makes a return or moves the last period back.
    install.shown(in: start + 2)
    #expect(install.lastShownPeriod == start + 65)
    #expect(install.returnPeriod == start + 64)
  }
}

@Suite(.serialized) struct TaglineStoreTests {
  let zone = TimeZone(identifier: "Asia/Singapore")!

  func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "mindloom.taglines.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  @Test func theFirstShowingStartsTheInstallWithTheFirstLine() throws {
    try withDefaults { defaults in
      let store = TaglineStore(defaults: defaults)
      #expect(store.install == nil)
      // 2026-10-06 01:00 in Singapore.
      let now = Date(timeIntervalSince1970: 1_791_216_000 + 3600)
      #expect(store.show(.zh, now: now, zone: zone)?.text == "编织你的史诗。")
      let install = try #require(store.install)
      #expect(install.firstPeriod == TaglineClock.period(now, in: zone))
      #expect(install.lastShownPeriod == install.firstPeriod)
      #expect(install.seed < 1 << 53)
      // The same period again: the same line, the same place.
      #expect(store.show(.zh, now: now.addingTimeInterval(3600), zone: zone)?.text == "编织你的史诗。")
      #expect(
        store.show(.en, now: now.addingTimeInterval(4 * 3600), zone: zone)?.text == "Weave your epic.")
      #expect(store.install == install)
      // From 06:00: position 1 of this install's cycle.
      let morning = now.addingTimeInterval(5 * 3600)
      let expected = TaglineRotation().line(.zh, install: install, now: morning, zone: zone)
      #expect(store.show(.zh, now: morning, zone: zone) == expected)
      #expect(expected != TaglineCatalog.bundled.first(.zh))
      #expect(store.install?.lastShownPeriod == install.firstPeriod + 1)
    }
  }

  @Test func aStoredPlaceIsOneJSONString() throws {
    try withDefaults { defaults in
      defaults.set(#"{"first_period":80000,"seed":9}"#, forKey: TaglineStore.key)
      let store = TaglineStore(defaults: defaults)
      #expect(store.install == TaglineInstall(seed: 9, firstPeriod: 80000))
      // Period 80003 in Singapore (UTC+8), an hour in.
      _ = store.show(.zh, now: Date(timeIntervalSince1970: 80003 * 21_600 - 8 * 3600 + 3600), zone: zone)
      let text = try #require(defaults.string(forKey: TaglineStore.key))
      #expect(text == #"{"first_period":80000,"last_shown_period":80003,"seed":9}"#)
    }
  }

  @Test func anUnreadablePlaceStartsAgain() {
    // Not JSON, and a place stored by the first one-line-a-day build (never shipped).
    for stored in ["not json", #"{"first_day":20000,"last_shown_day":20003,"seed":9}"#] {
      withDefaults { defaults in
        defaults.set(stored, forKey: TaglineStore.key)
        let store = TaglineStore(defaults: defaults)
        #expect(store.install == nil)
        #expect(store.show(.en, zone: zone)?.moment == .first)
        #expect(store.install != nil)
      }
    }
  }
}
