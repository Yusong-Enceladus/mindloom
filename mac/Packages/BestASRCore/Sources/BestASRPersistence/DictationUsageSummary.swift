import Foundation

/// One finished dictation as the Home statistics see it: when it started, how
/// much speech it held, and its current text.
public struct DictationActivityRecord: Equatable, Sendable {
  public let createdAt: Date
  public let speechNanoseconds: UInt64
  public let text: String

  public init(createdAt: Date, speechNanoseconds: UInt64, text: String) {
    self.createdAt = createdAt
    self.speechNanoseconds = speechNanoseconds
    self.text = text
  }
}

/// Home statistics for dictation: words, speaking time, speed, estimated time
/// saved against typing, streaks, and a per-day activity map.
public struct DictationUsageSummary: Equatable, Sendable {
  /// Typing speed the time-saved estimate compares against, in words (a CJK
  /// character or a Latin word) per minute.
  public static let typingWordsPerMinute = 45.0

  public let wordCount: Int
  /// Words from the dictations whose speaking time is known. A dictation
  /// imported from another App arrives with its text but not its audio, and
  /// counting those words against only the other dictations' speaking time
  /// reports a speed nobody ever spoke at.
  public let timedWordCount: Int
  public let speechSeconds: Double
  public let dictationCount: Int
  public let currentStreakDays: Int
  public let longestStreakDays: Int
  public let activeDayCount: Int
  /// Words dictated per local calendar day, keyed by the day's start.
  public let wordsByDay: [Date: Int]

  public init(
    wordCount: Int = 0,
    timedWordCount: Int = 0,
    speechSeconds: Double = 0,
    dictationCount: Int = 0,
    currentStreakDays: Int = 0,
    longestStreakDays: Int = 0,
    activeDayCount: Int = 0,
    wordsByDay: [Date: Int] = [:]
  ) {
    self.wordCount = wordCount
    self.timedWordCount = timedWordCount
    self.speechSeconds = speechSeconds
    self.dictationCount = dictationCount
    self.currentStreakDays = currentStreakDays
    self.longestStreakDays = longestStreakDays
    self.activeDayCount = activeDayCount
    self.wordsByDay = wordsByDay
  }

  /// Words per minute of speech; nil until there is at least ten seconds.
  public var wordsPerMinute: Int? {
    guard speechSeconds >= 10 else { return nil }
    return Int((Double(timedWordCount) / (speechSeconds / 60)).rounded())
  }

  /// Typing time for the same words minus the time spent speaking them.
  public var savedSeconds: Double {
    max(0, Double(wordCount) / Self.typingWordsPerMinute * 60 - speechSeconds)
  }

  public static func make(
    _ records: [DictationActivityRecord],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Self {
    var wordsByDay: [Date: Int] = [:]
    var words = 0
    var timedWords = 0
    var seconds = 0.0
    for record in records {
      let count = wordCount(record.text)
      words += count
      if record.speechNanoseconds > 0 {
        timedWords += count
        seconds += Double(record.speechNanoseconds) / 1_000_000_000
      }
      wordsByDay[calendar.startOfDay(for: record.createdAt), default: 0] += count
    }
    let days = Set(records.map { calendar.startOfDay(for: $0.createdAt) })
    var longest = 0
    var run = 0
    var previous: Date?
    for day in days.sorted() {
      let continues = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day
      run = continues ? run + 1 : 1
      longest = max(longest, run)
      previous = day
    }
    // A streak still counts today before the first dictation of the day.
    let today = calendar.startOfDay(for: now)
    var cursor =
      days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    var current = 0
    while days.contains(cursor) {
      current += 1
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
    }
    return Self(
      wordCount: words,
      timedWordCount: timedWords,
      speechSeconds: seconds,
      dictationCount: records.count,
      currentStreakDays: current,
      longestStreakDays: longest,
      activeDayCount: days.count,
      wordsByDay: wordsByDay
    )
  }

  /// Counts each CJK character (Han, kana, Hangul) as one word and each run of
  /// Latin letters or digits as one word; punctuation and spaces count as none.
  public static func wordCount(_ text: String) -> Int {
    var count = 0
    var inWord = false
    for scalar in text.unicodeScalars {
      if isCJK(scalar) {
        count += 1
        inWord = false
      } else if CharacterSet.alphanumerics.contains(scalar) {
        if !inWord { count += 1 }
        inWord = true
      } else if !(inWord && (scalar == "'" || scalar == "’" || scalar == "-")) {
        inWord = false
      }
    }
    return count
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
      0xF900...0xFAFF, 0x20000...0x2FA1F:
      true
    default:
      false
    }
  }
}
