import BestASRPersistence
import Foundation
import GRDB
import XCTest

final class DictationMetricsStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("metrics-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testRecordsNumbersOnlyAndReadsThemBack() async throws {
    let url = DictationMetricsStore.databaseURL(dataRoot: root)
    XCTAssertEqual(url.lastPathComponent, "dictation-timings.sqlite")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "metrics")
    let store = try DictationMetricsStore(databaseURL: url)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let timing = DictationTiming(
      recordedAt: now, mode: .translate, outcome: .written, recognizerWasCold: true,
      audioMilliseconds: 2_400, pressToRecordingMilliseconds: 120,
      releaseToTextMilliseconds: 480, sealMilliseconds: 55, recognitionMilliseconds: 300,
      cleanupMilliseconds: 2, transformMilliseconds: 40, deliveryMilliseconds: 42,
      queueMilliseconds: 41, footprintMegabytes: 2_900, peakFootprintMegabytes: 3_100)
    try await store.record(timing, now: now)
    let read = try await store.timings(since: now.addingTimeInterval(-1))
    XCTAssertEqual(read, [timing])

    // Every column is a number: nothing else can be stored.
    let queue = try DatabaseQueue(path: url.path)
    let columns = try await queue.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(dictation_timings)").map {
        ($0["name"] as String, $0["type"] as String)
      }
    }
    XCTAssertFalse(columns.isEmpty)
    for (name, type) in columns {
      XCTAssertTrue(["INTEGER", "REAL"].contains(type), "\(name) is \(type)")
    }
  }

  func testKeepsNinetyDays() async throws {
    let store = try DictationMetricsStore(
      databaseURL: DictationMetricsStore.databaseURL(dataRoot: root))
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400
    for age in [100.0, 91, 89, 1] {
      try await store.record(
        DictationTiming(
          recordedAt: now.addingTimeInterval(-age * day), outcome: .written,
          releaseToTextMilliseconds: Int(age)),
        now: now.addingTimeInterval(-age * day))
    }
    // The last write prunes: 100 and 91 days are gone, 89 and 1 stay.
    try await store.record(
      DictationTiming(recordedAt: now, outcome: .written, releaseToTextMilliseconds: 0),
      now: now)
    let kept = try await store.timings(since: .distantPast)
      .compactMap(\.releaseToTextMilliseconds)
    XCTAssertEqual(kept, [89, 1, 0])
  }

  func testSummariesCountWrittenAndKeptDictationsInTheirPeriod() async throws {
    let store = try DictationMetricsStore(
      databaseURL: DictationMetricsStore.databaseURL(dataRoot: root))
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400
    // 20 in the last week (100…2000 ms), 10 more three weeks ago (5000 ms),
    // and a failure and a silent take that must not count.
    for index in 1...20 {
      try await store.record(
        DictationTiming(
          recordedAt: now.addingTimeInterval(-Double(index) * 3_600),
          outcome: index.isMultiple(of: 5) ? .kept : .written,
          releaseToTextMilliseconds: index * 100),
        now: now)
    }
    for index in 1...10 {
      try await store.record(
        DictationTiming(
          recordedAt: now.addingTimeInterval(-21 * day - Double(index)), outcome: .written,
          releaseToTextMilliseconds: 5_000),
        now: now)
    }
    try await store.record(
      DictationTiming(recordedAt: now, outcome: .failed, releaseToTextMilliseconds: 9_000),
      now: now)
    try await store.record(
      DictationTiming(recordedAt: now, outcome: .noSpeech, releaseToTextMilliseconds: 9_000),
      now: now)

    let week = try await store.releaseToTextSummary(lastDays: 7, now: now)
    XCTAssertEqual(
      week, DictationLatencySummary(count: 20, p50Milliseconds: 1_000, p95Milliseconds: 1_900))
    let month = try await store.releaseToTextSummary(lastDays: 30, now: now)
    XCTAssertEqual(month.count, 30)
    XCTAssertEqual(month.p50Milliseconds, 1_500)
    XCTAssertEqual(month.p95Milliseconds, 5_000)
    let empty = try await store.releaseToTextSummary(
      lastDays: 7, now: now.addingTimeInterval(365 * day))
    XCTAssertEqual(
      empty, DictationLatencySummary(count: 0, p50Milliseconds: nil, p95Milliseconds: nil))
  }

  /// Regression (review 2026-10-06): 翻译 and 指令 also wait for a text
  /// model, so they were pooled into the dictation figure Settings shows.
  func testTheDictationSummaryLeavesOutTranslationsAndInstructions() async throws {
    let store = try DictationMetricsStore(
      databaseURL: DictationMetricsStore.databaseURL(dataRoot: root))
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    for (index, mode) in [DictationTiming.Mode.dictate, .dictate, .translate, .command]
      .enumerated()
    {
      try await store.record(
        DictationTiming(
          recordedAt: now.addingTimeInterval(-Double(index) * 60), mode: mode,
          outcome: .written, releaseToTextMilliseconds: mode == .dictate ? 400 : 3_000),
        now: now)
    }
    let dictation = try await store.releaseToTextSummary(lastDays: 7, now: now)
    XCTAssertEqual(
      dictation, DictationLatencySummary(count: 2, p50Milliseconds: 400, p95Milliseconds: 400))
    let translations = try await store.releaseToTextSummary(
      lastDays: 7, mode: .translate, now: now)
    XCTAssertEqual(translations.count, 1)
    let instructions = try await store.releaseToTextSummary(lastDays: 7, mode: .command, now: now)
    XCTAssertEqual(instructions.count, 1)
  }

  func testPercentileIsNearestRank() {
    XCTAssertNil(DictationLatencySummary.percentile([], 0.5))
    XCTAssertEqual(DictationLatencySummary.percentile([7], 0.95), 7)
    XCTAssertEqual(DictationLatencySummary.percentile([1, 2, 3, 4], 0.5), 2)
    XCTAssertEqual(DictationLatencySummary.percentile(Array(1...100), 0.95), 95)
    XCTAssertEqual(DictationLatencySummary.percentile([5, 1, 3], 0.5), 3)
  }

  func testQueueIsWhatTheNamedStagesDoNotExplain() {
    XCTAssertEqual(
      DictationTiming.queue(
        releaseToText: 600, seal: 55, recognition: 330, cleanup: 100, transform: nil,
        delivery: 43), 72)
    XCTAssertEqual(
      DictationTiming.queue(
        releaseToText: 100, seal: 55, recognition: 330, cleanup: nil, transform: nil,
        delivery: nil), 0)
    XCTAssertNil(
      DictationTiming.queue(
        releaseToText: nil, seal: 1, recognition: 1, cleanup: 1, transform: 1, delivery: 1))
  }

  func testFootprintIsReadable() throws {
    let footprint = try XCTUnwrap(ProcessFootprint.current())
    XCTAssertGreaterThan(footprint.bytes, 0)
    XCTAssertGreaterThanOrEqual(footprint.peakBytes, footprint.bytes)
  }
}
