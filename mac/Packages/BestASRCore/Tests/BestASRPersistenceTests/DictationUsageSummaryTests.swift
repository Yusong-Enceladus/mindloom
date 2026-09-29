import BestASRPersistence
import Foundation
import XCTest

final class DictationUsageSummaryTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }

  private func day(_ offset: Int, hour: Int = 10) -> Date {
    let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: hour))!
    return calendar.date(byAdding: .day, value: offset, to: start)!
  }

  func testWordsCountCJKCharactersAndLatinWords() {
    XCTAssertEqual(DictationUsageSummary.wordCount("今天用 Claude Code 改 bug。"), 7)
    XCTAssertEqual(DictationUsageSummary.wordCount("It's GPT-5, ok?"), 3)
    XCTAssertEqual(DictationUsageSummary.wordCount("，。 ！"), 0)
  }

  func testStreaksSpeedAndSavedTime() {
    let records = [-6, -5, -2, -1, 0].map {
      DictationActivityRecord(
        createdAt: day($0), speechNanoseconds: 20_000_000_000, text: String(repeating: "字", count: 30))
    } + [
      DictationActivityRecord(createdAt: day(0, hour: 20), speechNanoseconds: 0, text: "再说一句")
    ]
    let summary = DictationUsageSummary.make(records, now: day(0, hour: 22), calendar: calendar)
    XCTAssertEqual(summary.wordCount, 154)
    XCTAssertEqual(summary.dictationCount, 6)
    XCTAssertEqual(summary.activeDayCount, 5)
    XCTAssertEqual(summary.currentStreakDays, 3)
    XCTAssertEqual(summary.longestStreakDays, 3)
    XCTAssertEqual(
      summary.wordsPerMinute, 90,
      "The untimed dictation's words may not count against the others' speaking time")
    XCTAssertEqual(summary.savedSeconds, 154 / 45 * 60 - 100, accuracy: 0.001)
    XCTAssertEqual(summary.wordsByDay[calendar.startOfDay(for: day(0))], 34)
  }

  func testStreakSurvivesUntilTheDayEndsWithoutDictation() {
    let records = [-2, -1].map {
      DictationActivityRecord(createdAt: day($0), speechNanoseconds: 1_000_000_000, text: "好")
    }
    let today = DictationUsageSummary.make(records, now: day(0), calendar: calendar)
    XCTAssertEqual(today.currentStreakDays, 2)
    XCTAssertNil(today.wordsPerMinute, "Speed needs enough speech to be meaningful.")
    let later = DictationUsageSummary.make(records, now: day(1), calendar: calendar)
    XCTAssertEqual(later.currentStreakDays, 0)
    XCTAssertEqual(later.longestStreakDays, 2)
  }
}
