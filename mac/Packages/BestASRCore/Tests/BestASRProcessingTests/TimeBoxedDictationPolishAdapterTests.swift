import BestASRDictation
import BestASRDomain
import BestASRProcessing
import Foundation
import XCTest

final class TimeBoxedDictationPolishAdapterTests: XCTestCase {
  func testResultWithinBudgetIsReturnedAndNotReportedLate() async throws {
    let late = LatePolishRecorder()
    let adapter = TimeBoxedDictationPolishAdapter(
      base: DelayedPolish(delay: .zero),
      budget: .seconds(2),
      onLateResult: { _, result in await late.record(result) }
    )

    let result = try await adapter.polish(timeBoxedRequest())

    XCTAssertEqual(result.text, "Polished.")
    try await Task.sleep(for: .milliseconds(50))
    let lateCount = await late.results().count
    XCTAssertEqual(lateCount, 0)
  }

  func testExpiredBudgetFailsFastAndStillDeliversModelResult() async throws {
    let late = LatePolishRecorder()
    let adapter = TimeBoxedDictationPolishAdapter(
      base: DelayedPolish(delay: .milliseconds(400)),
      budget: .milliseconds(40),
      onLateResult: { _, result in await late.record(result) }
    )
    let started = ContinuousClock.now

    do {
      _ = try await adapter.polish(timeBoxedRequest())
      XCTFail("Expected the insertion deadline to win")
    } catch is DictationPolishDeadlineExceeded {}

    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(300))
    let deadline = ContinuousClock.now + .seconds(3)
    while await late.results().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let delivered = await late.results()
    XCTAssertEqual(delivered.map(\.text), ["Polished."])
  }

  func testZeroBudgetNeverWaitsAndDeliversEveryModelResultLate() async throws {
    let late = LatePolishRecorder()
    let adapter = TimeBoxedDictationPolishAdapter(
      base: DelayedPolish(delay: .zero),
      budget: .zero,
      onLateResult: { _, result in await late.record(result) }
    )

    do {
      _ = try await adapter.polish(timeBoxedRequest())
      XCTFail("A zero budget must insert the fallback without waiting")
    } catch is DictationPolishDeadlineExceeded {}

    let deadline = ContinuousClock.now + .seconds(3)
    while await late.results().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let delivered = await late.results()
    XCTAssertEqual(delivered.map(\.text), ["Polished."])
  }

  func testModelFailureWithinBudgetIsRethrown() async throws {
    let adapter = TimeBoxedDictationPolishAdapter(
      base: FailingPolish(),
      budget: .seconds(2),
      onLateResult: { _, _ in XCTFail("A failure is never a late result") }
    )

    do {
      _ = try await adapter.polish(timeBoxedRequest())
      XCTFail("Expected the model failure")
    } catch is FailingPolish.Failure {}
  }
}

private struct DelayedPolish: DictationPolishPort {
  let delay: Duration

  func polish(_ request: DictationPolishRequest) async throws -> DictationPolishResult {
    try await Task.sleep(for: delay)
    return DictationPolishResult(
      sourceRevisionID: request.transcript.revisionID,
      text: "Polished.",
      disposition: .model,
      modelArtifactID: "fixture-text"
    )
  }
}

private struct FailingPolish: DictationPolishPort {
  struct Failure: Error {}

  func polish(_ request: DictationPolishRequest) async throws -> DictationPolishResult {
    throw Failure()
  }
}

private actor LatePolishRecorder {
  private var recorded: [DictationPolishResult] = []

  func record(_ result: DictationPolishResult) { recorded.append(result) }
  func results() -> [DictationPolishResult] { recorded }
}

private func timeBoxedRequest() -> DictationPolishRequest {
  DictationPolishRequest(
    sessionID: SessionID(),
    transcript: DictationTranscriptResult(
      revisionID: TranscriptRevisionID(),
      segmentIDs: [],
      text: "polished",
      modelArtifactID: "fixture-asr"
    ),
    dictionaryTerms: [],
    targetBundleIdentifier: nil
  )
}
