import BestASRMemory
import Foundation
import XCTest

/// v12 search review fixes: the busy gauge and pause that keep the meaning
/// index out of dictation's way, and a query's vector that never holds the
/// character results up for long. Synthetic text, stand-in models.
final class MeaningUpkeepTests: XCTestCase {
  final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.withLock { count += 1 } }
    var hits: Int { lock.withLock { count } }
  }

  func testGaugeCountsOverlappingWork() {
    let gauge = BusyGauge()
    XCTAssertFalse(gauge.isBusy)
    gauge.begin()  // an import's recognition
    gauge.begin()  // speaker matching of another record
    gauge.end()
    XCTAssertTrue(gauge.isBusy, "one piece of work is still running")
    gauge.end()
    XCTAssertFalse(gauge.isBusy)
    gauge.end()  // an extra end never goes below idle
    gauge.begin()
    XCTAssertTrue(gauge.isBusy)
  }

  /// The pause holds while the gauge is busy, calls `whenBusy` once (the
  /// App drops the model then), and returns once the work is done.
  func testPauseHoldsWhileBusyAndReleasesTheModelOnce() async throws {
    let gauge = BusyGauge()
    gauge.begin()
    let released = Flag()
    let passed = Flag()
    let waiting = Task {
      try await MeaningPause.wait(
        poll: .milliseconds(5), isBusy: { gauge.isBusy }, whenBusy: { released.hit() })
      passed.hit()
    }
    for _ in 0..<500 where released.hits == 0 { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(passed.hits, 0, "held while busy")
    XCTAssertEqual(released.hits, 1, "the model is released once, when the wait begins")
    gauge.end()
    try await waiting.value
    XCTAssertEqual(passed.hits, 1)
    XCTAssertEqual(released.hits, 1)
    // Not busy: no wait, nothing released.
    try await MeaningPause.wait(
      poll: .milliseconds(5), isBusy: { gauge.isBusy }, whenBusy: { released.hit() })
    XCTAssertEqual(released.hits, 1)
  }

  func testPauseStopsWhenCancelled() async throws {
    let gauge = BusyGauge()
    gauge.begin()
    let waiting = Task {
      try await MeaningPause.wait(poll: .milliseconds(5), isBusy: { gauge.isBusy })
    }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    do {
      try await waiting.value
      XCTFail("a cancelled pause throws")
    } catch is CancellationError {}
  }

  /// The model is busy (a step of the index): the character results do not
  /// wait for the query's vector; it is kept when it comes, and the search
  /// is shown again with it.
  func testALateQueryVectorShowsTheSearchAgain() async throws {
    let vectors = MeaningQueryVectors { text in
      try? await Task.sleep(for: .milliseconds(500))
      return [Float(text.count), 1]
    }
    let again = Flag()
    let started = ContinuousClock.now
    let first = await vectors.vector(
      for: "房东", within: .milliseconds(20), whenLate: { again.hit() })
    XCTAssertNil(first)
    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(400), "not held up")
    for _ in 0..<500 where again.hits == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(again.hits, 1, "the search is shown again once the vector came")
    let second = await vectors.vector(for: "房东", within: .milliseconds(20))
    XCTAssertEqual(second, [2, 1])
    let embedded = await vectors.embedded
    XCTAssertEqual(embedded, 1, "the late vector was kept, not made again")
  }

  func testAQuickVectorIsUsedAndOneTextIsEmbeddedOnce() async {
    let calls = Flag()
    let vectors = MeaningQueryVectors { _ in
      calls.hit()
      try? await Task.sleep(for: .milliseconds(10))
      return [1, 0]
    }
    async let a = vectors.vector(for: "续租", within: .seconds(2))
    async let b = vectors.vector(for: "续租", within: .seconds(2))
    let (first, second) = await (a, b)
    XCTAssertEqual(first, [1, 0])
    XCTAssertEqual(second, [1, 0])
    XCTAssertEqual(calls.hits, 1)
    // Forgotten (the model was released): made again.
    await vectors.forget()
    _ = await vectors.vector(for: "续租", within: .seconds(2))
    XCTAssertEqual(calls.hits, 2)
  }
}
