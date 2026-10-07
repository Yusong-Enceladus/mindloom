import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRMLXRuntime
import BestASRMemoryUI
import BestASRPersistence
import BestASRProcessing
import BestASRQwenRuntime
import BestASRRecognition
import XCTest

@testable import bestASR

/// The row each dictation adds to the local timing table (收1-2, 收1-5) and
/// the residency rule (ALIGNMENT recommendation 8).
final class DictationTimingTests: XCTestCase {
  func testARowHoldsTheStagesAndExplainsTheRestAsQueue() {
    let released = ContinuousClock.now
    var times = DictationStageClock.Times()
    times.recognition = .milliseconds(320)
    times.cleanup = .milliseconds(2)
    times.delivery = .milliseconds(41)
    times.deliveredAt = released + .milliseconds(450)
    times.footprintBytes = 2_900 * 1_048_576
    times.peakFootprintBytes = 3_100 * 1_048_576
    times.recognizerWasCold = true
    let audio = [
      AudioRangeInput(
        sourceID: UUID(), trackID: UUID(), assetReference: "a",
        contentDigest: String(
          repeating: "a", count: 64), monotonicStartNanoseconds: 1_000_000_000,
        monotonicEndNanoseconds: 3_400_000_000, sampleRateHertz: 16_000, channelCount: 1)
    ]
    let row = DictationAppModel.dictationTiming(
      measured: DictationTimingInputs(
        releasedAt: released, seal: .milliseconds(55), pressToRecording: .milliseconds(210),
        mode: .translate),
      times: times, outcome: .written, audio: audio, now: Date(timeIntervalSince1970: 10))
    XCTAssertEqual(row.mode, .translate)
    XCTAssertEqual(row.audioMilliseconds, 2_400)
    XCTAssertEqual(row.pressToRecordingMilliseconds, 210)
    XCTAssertEqual(row.releaseToTextMilliseconds, 450)
    XCTAssertEqual(row.sealMilliseconds, 55)
    XCTAssertEqual(row.recognitionMilliseconds, 320)
    XCTAssertEqual(row.queueMilliseconds, 450 - 55 - 320 - 2 - 41)
    XCTAssertEqual(row.footprintMegabytes, 2_900)
    XCTAssertEqual(row.peakFootprintMegabytes, 3_100)
    XCTAssertTrue(row.recognizerWasCold)
  }

  func testAFailureHasNoKeyUpToText() {
    var times = DictationStageClock.Times()
    times.deliveredAt = ContinuousClock.now
    let row = DictationAppModel.dictationTiming(
      measured: DictationTimingInputs(
        releasedAt: ContinuousClock.now, seal: .milliseconds(50), pressToRecording: nil,
        mode: .dictate),
      times: times, outcome: .failed, audio: [], now: Date())
    XCTAssertNil(row.releaseToTextMilliseconds)
    XCTAssertNil(row.queueMilliseconds)
    XCTAssertNil(row.audioMilliseconds)
  }

  func testTheRecognizerStaysAnHourAfterTheLastDictation() {
    XCTAssertEqual(LocalDictationRuntime.defaultResidency, .standard)
    XCTAssertEqual(LocalDictationRuntime.defaultResidency.recognizer, .seconds(3_600))
    XCTAssertEqual(LocalDictationRuntime.defaultResidency.secondary, .seconds(600))
  }

  func testNewMacsDoNotDownloadTheUnusedFallbackRecognizers() {
    let required = Set(LocalDictationRuntime.requiredSpeechArtifactIDs)
    XCTAssertFalse(required.contains { $0.contains("paraformer") || $0.contains("parakeet") })
    XCTAssertTrue(required.contains { $0.hasPrefix("qwen3-asr-1.7b-8bit") })
  }

  /// Launch housekeeping removes the retired fallbacks by name (ALIGNMENT
  /// 收1-4, adopted 2026-10-06), and no model the App installs (review
  /// 2026-10-07).
  func testOnlyTheRetiredFallbacksAreRemovedAndNoModelTheAppInstalls() {
    let retired = LocalDictationRuntime.retiredModelArtifactIDs
    XCTAssertEqual(
      retired,
      [FluidParaformerPinnedArtifact.artifactID, FluidParakeetUnifiedPinnedArtifact.artifactID])
    XCTAssertTrue(retired.isDisjoint(with: LocalDictationRuntime.requiredSpeechArtifactIDs))
    XCTAssertFalse(retired.contains(MLXLocalTextArtifact.qwen3Selected.artifactID))
    XCTAssertFalse(retired.contains(FluidSpeakerPinnedArtifact.artifactID))
    XCTAssertFalse(retired.contains(MLXMeaningArtifact.selected.artifactID))
  }

  func testSettingsShowNothingForAnEmptyPeriod() {
    XCTAssertNil(
      DictationAppModel.settingsLatency(
        DictationLatencySummary(count: 0, p50Milliseconds: nil, p95Milliseconds: nil)))
    XCTAssertEqual(
      DictationAppModel.settingsLatency(
        DictationLatencySummary(count: 3, p50Milliseconds: 400, p95Milliseconds: 900)),
      SettingsDictationMetrics.Latency(count: 3, p50Milliseconds: 400, p95Milliseconds: 900))
  }
}

/// Key events anchor the timing table (review 2026-10-06): release to text
/// counts from the key's own event, not from when the main actor got to it.
final class DictationKeyEventTimingTests: XCTestCase {
  func testAKeyEventIsPlacedOnTheContinuousClockByItsAge() throws {
    let now = ContinuousClock.now
    let instant = try XCTUnwrap(
      DictationAppModel.keyEventInstant(1_000.0, now: now, uptime: 1_000.25))
    XCTAssertEqual(now - instant, .milliseconds(250))
    // Unknown, from the future, or stale: not used.
    XCTAssertNil(DictationAppModel.keyEventInstant(nil, now: now, uptime: 1_000))
    XCTAssertNil(DictationAppModel.keyEventInstant(1_000.5, now: now, uptime: 1_000))
    XCTAssertNil(DictationAppModel.keyEventInstant(990, now: now, uptime: 1_000))
  }

  func testATimingStartsAtARecentKeyEventElseNow() {
    let now = ContinuousClock.now
    XCTAssertEqual(
      DictationAppModel.dictationAnchor(now - .milliseconds(80), now: now),
      now - .milliseconds(80))
    XCTAssertEqual(DictationAppModel.dictationAnchor(nil, now: now), now)
    XCTAssertEqual(DictationAppModel.dictationAnchor(now - .seconds(9), now: now), now)
    XCTAssertEqual(DictationAppModel.dictationAnchor(now + .milliseconds(5), now: now), now)
  }
}

/// Counts what the runtime asks of the recognizer.
actor CountingQwenRecognizer: QwenASRSampleTranscribing {
  private let decodeTime: Duration
  private(set) var decodes = 0
  private(set) var releases = 0

  init(decodeTime: Duration = .zero) { self.decodeTime = decodeTime }

  func transcribe(samples: [Float], dictionaryTerms: [String]) async throws
    -> QwenRecognizedText
  {
    decodes += 1
    if decodeTime > .zero { try await Task.sleep(for: decodeTime) }
    return QwenRecognizedText(text: "", language: nil)
  }

  func release() async { releases += 1 }
}

/// Counts what the runtime asks of the aligner.
actor CountingQwenAligner: QwenWordsAligning {
  private(set) var prepares = 0
  private(set) var releases = 0

  func align(samples: [Float], text: String, language: String?) async throws
    -> [TranscriptAlignmentWord]
  { [] }

  func prepare() async throws { prepares += 1 }
  func release() async { releases += 1 }
}

/// What the models were asked to do, in order, across both.
actor ModelEventLog {
  private(set) var events: [String] = []
  func note(_ event: String) { events.append(event) }
}

/// A recognizer that logs its decodes and releases.
actor LoggingQwenRecognizer: QwenASRSampleTranscribing {
  let log: ModelEventLog
  init(log: ModelEventLog) { self.log = log }

  func transcribe(samples: [Float], dictionaryTerms: [String]) async throws
    -> QwenRecognizedText
  {
    await log.note("recognizer-decode")
    return QwenRecognizedText(text: "", language: nil)
  }

  func release() async { await log.note("recognizer-release") }
}

/// An aligner whose load takes `loadTime` and cannot be interrupted, then
/// checks for cancellation, as `QwenForcedAlignmentBackend` does.
actor LoadingQwenAligner: QwenWordsAligning {
  let log: ModelEventLog
  let loadTime: Duration
  init(log: ModelEventLog, loadTime: Duration) {
    self.log = log
    self.loadTime = loadTime
  }

  func align(samples: [Float], text: String, language: String?) async throws
    -> [TranscriptAlignmentWord]
  {
    try InferenceCancellation.check()
    try await prepare()
    try InferenceCancellation.check()
    await log.note("aligner-align")
    return []
  }

  func prepare() async throws {
    await log.note("aligner-load-started")
    let seconds =
      Double(loadTime.components.seconds) + Double(loadTime.components.attoseconds) / 1e18
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
    }
    await log.note("aligner-loaded")
  }

  func release() async { await log.note("aligner-release") }
}

private struct NoResidencySamples: SenseVoiceAudioSampleLoading {
  func loadSamples(for input: AudioRangeInput) async throws -> [Float] { [] }
}

private struct NowhereInsertion: DictationInsertionPort {
  func captureTarget() async throws -> DictationTargetSnapshot {
    DictationTargetSnapshot(processIdentifier: 0, bundleIdentifier: "test", isSecure: false)
  }

  func insert(_ request: DictationInsertionRequest) async throws -> DictationInsertionResult {
    DictationInsertionResult(
      idempotencyKey: request.idempotencyKey, method: .directWrite, inserted: true,
      evidence: "test")
  }
}

extension LocalDictationRuntime {
  /// A timing pass already in the aligner when a press comes: what
  /// `startDeferredWordAlignment` runs, on one window, without a library.
  fileprivate func startPassInTheAlignerForTest() {
    guard let runtime = finalASRWarmupRuntime else { return }
    wordAlignmentTask = Task { [weak self] () -> Int in
      _ = try? await runtime.timeDeferredWindow(
        samples: Array(repeating: 0.01, count: 16_000), text: "好", language: nil,
        replacing: DeferredWordAlignment.pendingSegmentID(seed: "test"),
        startNanoseconds: 0, endNanoseconds: 1_000_000_000)
      await self?.finishDeferredWordAlignment()
      return 0
    }
  }

  /// What `process` does around a dictation being written.
  fileprivate func beginInsertionForTest(_ sessionID: SessionID) {
    sessionsAwaitingInsertion.insert(sessionID)
  }

  fileprivate func finishInsertionForTest(_ sessionID: SessionID) {
    endDictationBookkeeping(sessionID: sessionID)
    sessionsAwaitingInsertion.remove(sessionID)
  }
}

/// The runtime's residency timers, memory-pressure release and warm-up, on
/// the real `LocalDictationRuntime` with counting models and short timers
/// (ALIGNMENT recommendation 8; review 2026-10-06).
@MainActor
final class ModelResidencyRuntimeTests: XCTestCase {
  private let recognizer = CountingQwenRecognizer()
  private let aligner = CountingQwenAligner()

  private var root: URL?

  private func makeRuntime(
    recognizer recognizerResidency: Duration = .seconds(60),
    secondary: Duration = .seconds(60),
    pressureGrace: Duration = .seconds(60),
    adoptModels: Bool = true
  ) async throws -> LocalDictationRuntime {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("residency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    self.root = root
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets", isDirectory: true))
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let runtime = try LocalDictationRuntime(
      applicationRoot: root, cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
      journal: journal, repository: store, insertion: NowhereInsertion(),
      localSelfPersonID: PersonID())
    await runtime.useResidency(
      ModelResidencyPolicy(
        recognizer: recognizerResidency, secondary: secondary,
        recognizerPressureGrace: pressureGrace))
    if adoptModels {
      await runtime.adoptFinalASRWarmupRuntime(
        QwenASRRuntime(audioLoader: NoResidencySamples(), backend: recognizer, aligner: aligner))
      // The launch warm-up: one throwaway decode.
      let warmed = await eventually { await runtime.recognizerResident }
      XCTAssertTrue(warmed)
    }
    return runtime
  }

  /// The aligner releases so far, once the launch warm-up's own release
  /// (a press lets the aligner go) has landed.
  private func settledAlignerReleases() async -> Int {
    try? await Task.sleep(for: .milliseconds(100))
    return await aligner.releases
  }

  private func eventually(
    within timeout: Duration = .seconds(3), _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
  }

  func testALaunchNobodyDictatedIntoLetsEveryModelGoAfterTheShortTimer() async throws {
    let runtime = try await makeRuntime(secondary: .milliseconds(150))
    // What the launch prewarm does once the models are in memory.
    await runtime.scheduleIdleModelRelease()
    let released = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(released)
    let alignerReleases = await aligner.releases
    XCTAssertGreaterThanOrEqual(alignerReleases, 1)
  }

  func testAfterADictationTheOthersGoFirstAndTheRecognizerLater() async throws {
    let runtime = try await makeRuntime(
      recognizer: .milliseconds(900), secondary: .milliseconds(100))
    await runtime.endDictationBookkeeping(sessionID: SessionID())
    let alignerReleased = await eventually { await self.aligner.releases >= 1 }
    XCTAssertTrue(alignerReleased)
    let recognizerReleasesEarly = await recognizer.releases
    XCTAssertEqual(recognizerReleasesEarly, 0, "the recognizer stays longer")
    let recognizerReleased = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(recognizerReleased)
  }

  /// Regression: after a take cancelled with Esc the speculation slot stayed
  /// taken, so memory pressure was put off until the next dictation.
  func testMemoryPressureDuringATakeCancelledWithEscStillReleasesEveryModel() async throws {
    let runtime = try await makeRuntime()
    let sessionID = SessionID()
    await runtime.warmFinalASRIfIdle()
    await runtime.beginFinalSpeculation(sessionID: sessionID)
    await runtime.releaseForMemoryPressure()
    try await Task.sleep(for: .milliseconds(100))
    let whileRecording = await recognizer.releases
    XCTAssertEqual(whileRecording, 0, "a take that is recording finishes first")
    // What `cancel()` gives the runtime for Esc and the fn chord.
    await runtime.endUnprocessedDictation(sessionID: sessionID)
    let released = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(released)
  }

  /// Regression: the press cancelled the idle timer and only `process`
  /// re-armed it, so after one Esc the models stayed resident indefinitely.
  func testATakeCancelledWithEscReArmsTheIdleRelease() async throws {
    let runtime = try await makeRuntime(
      recognizer: .milliseconds(300), secondary: .milliseconds(100))
    let sessionID = SessionID()
    await runtime.warmFinalASRIfIdle()
    await runtime.beginFinalSpeculation(sessionID: sessionID)
    await runtime.endUnprocessedDictation(sessionID: sessionID)
    let released = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(released)
  }

  func testMemoryPressureDuringAnInsertionIsAppliedWhenItEnds() async throws {
    let runtime = try await makeRuntime()
    let sessionID = SessionID()
    await runtime.beginInsertionForTest(sessionID)
    await runtime.releaseForMemoryPressure()
    try await Task.sleep(for: .milliseconds(100))
    let whileWriting = await recognizer.releases
    XCTAssertEqual(whileWriting, 0)
    await runtime.finishInsertionForTest(sessionID)
    let released = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(released)
  }

  /// Regression: the press skipped the warm-up whenever the last activity
  /// was under 90 s old, even if the recognizer had been released since
  /// (memory pressure moments after a dictation), so the reload landed on
  /// the release path.
  func testAPressAfterTheRecognizerWasReleasedWarmsItAgain() async throws {
    let runtime = try await makeRuntime()
    await runtime.endDictationBookkeeping(sessionID: SessionID())
    // In memory and used moments ago: no warm-up.
    await runtime.warmFinalASRIfIdle()
    try await Task.sleep(for: .milliseconds(150))
    let decodesWhileResident = await recognizer.decodes
    XCTAssertEqual(decodesWhileResident, 1, "only the launch warm-up")
    await runtime.releaseIdleModels([.recognizer])
    await runtime.warmFinalASRIfIdle()
    let warmedAgain = await eventually { await self.recognizer.decodes == 2 }
    XCTAssertTrue(warmedAgain)
  }

  /// A release that lands while the press's warm-up is still loading must
  /// leave the recognizer marked out of memory, or the next press would
  /// skip the warm-up again.
  func testAReleaseDuringTheWarmUpLeavesTheRecognizerOutOfMemory() async throws {
    let slow = CountingQwenRecognizer(decodeTime: .milliseconds(300))
    let runtime = try await makeRuntime(adoptModels: false)
    await runtime.adoptFinalASRWarmupRuntime(
      QwenASRRuntime(audioLoader: NoResidencySamples(), backend: slow, aligner: aligner))
    let decoding = await eventually { await slow.decodes == 1 }
    XCTAssertTrue(decoding)
    await runtime.releaseIdleModels([.recognizer])
    let finished = await eventually { await runtime.finalASRWarmupTask == nil }
    XCTAssertTrue(finished)
    let resident = await runtime.recognizerResident
    XCTAssertFalse(resident)
    await runtime.warmFinalASRIfIdle()
    let warmedAgain = await eventually { await slow.decodes == 2 }
    XCTAssertTrue(warmedAgain)
  }

  /// Recommendation 1 (2026-10-06): dictation's word timings come later, so
  /// a press warms the recognizer and never loads the aligner.
  func testAPressNeverLoadsTheAligner() async throws {
    let runtime = try await makeRuntime()
    await runtime.releaseIdleModels([.recognizer])
    await runtime.warmFinalASRIfIdle()
    let warmed = await eventually { await self.recognizer.decodes == 2 }
    XCTAssertTrue(warmed)
    try await Task.sleep(for: .milliseconds(100))
    let prepares = await aligner.prepares
    XCTAssertEqual(prepares, 0)
  }

  /// Recommendation 5 (2026-10-06): a warning releases the others at once
  /// and keeps the recognizer, so a warning its own load raised does not
  /// make every dictation cold.
  func testAMemoryPressureWarningReleasesTheOthersAndKeepsTheRecognizer() async throws {
    let runtime = try await makeRuntime()
    let before = await settledAlignerReleases()
    await runtime.handleMemoryPressure(.warning)
    let othersReleased = await eventually { await self.aligner.releases > before }
    XCTAssertTrue(othersReleased)
    try await Task.sleep(for: .milliseconds(200))
    let recognizerReleases = await recognizer.releases
    XCTAssertEqual(recognizerReleases, 0)
    let resident = await runtime.recognizerResident
    XCTAssertTrue(resident)
  }

  func testAWarningThatLastsReleasesTheRecognizerToo() async throws {
    let runtime = try await makeRuntime(pressureGrace: .milliseconds(200))
    await runtime.handleMemoryPressure(.warning)
    let early = await recognizer.releases
    XCTAssertEqual(early, 0)
    let released = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(released)
  }

  func testAWarningThatEndsInTimeKeepsTheRecognizer() async throws {
    let runtime = try await makeRuntime(pressureGrace: .milliseconds(300))
    await runtime.handleMemoryPressure(.warning)
    await runtime.handleMemoryPressure(.normal)
    try await Task.sleep(for: .milliseconds(600))
    let releases = await recognizer.releases
    XCTAssertEqual(releases, 0)
  }

  func testCriticalMemoryPressureReleasesEveryModelAtOnce() async throws {
    let runtime = try await makeRuntime()
    await runtime.handleMemoryPressure(.critical)
    let recognizerReleases = await recognizer.releases
    let alignerReleases = await aligner.releases
    XCTAssertEqual(recognizerReleases, 1)
    XCTAssertGreaterThanOrEqual(alignerReleases, 1)
  }

  /// A warning that lasts while a take is recording releases the
  /// recognizer when the take ends, not during it.
  func testALastingWarningDuringATakeWaitsForItsEnd() async throws {
    let runtime = try await makeRuntime(pressureGrace: .milliseconds(100))
    let sessionID = SessionID()
    await runtime.warmFinalASRIfIdle()
    await runtime.beginFinalSpeculation(sessionID: sessionID)
    await runtime.handleMemoryPressure(.warning)
    try await Task.sleep(for: .milliseconds(400))
    let whileRecording = await recognizer.releases
    XCTAssertEqual(whileRecording, 0)
    await runtime.endUnprocessedDictation(sessionID: sessionID)
    let released = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(released)
  }

  /// Sentences are timed with the aligner alone: never next to the
  /// resident recognizer or a take, never under memory pressure.
  func testSentencesAreNotTimedNextToATakeOrUnderMemoryPressure() async throws {
    let runtime = try await makeRuntime()
    let resident = await eventually { await runtime.recognizerResident }
    XCTAssertTrue(resident)
    let nextToTheRecognizer = await runtime.startDeferredWordAlignment()
    XCTAssertNil(nextToTheRecognizer)
    await runtime.releaseIdleModels([.recognizer])
    let sessionID = SessionID()
    await runtime.beginFinalSpeculation(sessionID: sessionID)
    let duringTake = await runtime.startDeferredWordAlignment()
    XCTAssertNil(duringTake)
    await runtime.endUnprocessedDictation(sessionID: sessionID)
    await runtime.handleMemoryPressure(.warning)
    let underPressure = await runtime.startDeferredWordAlignment()
    XCTAssertNil(underPressure)
    await runtime.handleMemoryPressure(.normal)
    let idle = await runtime.startDeferredWordAlignment()
    XCTAssertNotNil(idle)
    _ = await idle?.value
  }

  /// When the hour's timer releases the recognizer, a pass times what is
  /// pending and the aligner leaves when it is done.
  func testReleasingTheRecognizerTimesSentencesThenLetsTheAlignerGo() async throws {
    let runtime = try await makeRuntime(
      recognizer: .milliseconds(300), secondary: .milliseconds(100))
    let before = await settledAlignerReleases()
    await runtime.endDictationBookkeeping(sessionID: SessionID())
    let recognizerReleased = await eventually { await self.recognizer.releases == 1 }
    XCTAssertTrue(recognizerReleased)
    // Once at the ten-minute step, once when the pass ends.
    let alignerReleased = await eventually { await self.aligner.releases >= before + 2 }
    XCTAssertTrue(alignerReleased)
    let passEnded = await eventually { await runtime.wordAlignmentTask == nil }
    XCTAssertTrue(passEnded)
  }

  /// Launch housekeeping removes a model the App no longer uses from the
  /// store before discovery (ALIGNMENT 收1-4, adopted 2026-10-06).
  func testLaunchHousekeepingRemovesTheRetiredFallbackRecognizers() async throws {
    let runtime = try await makeRuntime(adoptModels: false)
    let models = try XCTUnwrap(root).appendingPathComponent("models", isDirectory: true)
    let retired = FluidParaformerPinnedArtifact.artifactID
    let kept = QwenASRPinnedArtifact.artifactID
    // Installed by another feature into the same store (v12 search's meaning
    // model, merged with this one), and it stays (review 2026-10-07).
    let other = MLXMeaningArtifact.selected.artifactID
    XCTAssertEqual(other, "qwen3-embedding-0.6b-mlx-4bit-6c3ae708")
    for id in [retired, kept, other] {
      let version = models.appendingPathComponent("versions/\(id)/v1", isDirectory: true)
      try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
      try Data("weights".utf8).write(to: version.appendingPathComponent("weights.bin"))
      try FileManager.default.createDirectory(
        at: models.appendingPathComponent("active"), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: models.appendingPathComponent("active/\(id).json"))
    }
    await runtime.startModelHousekeeping()
    func exists(_ path: String) -> Bool {
      FileManager.default.fileExists(atPath: models.appendingPathComponent(path).path)
    }
    XCTAssertFalse(exists("versions/\(retired)"))
    XCTAssertFalse(exists("active/\(retired).json"))
    XCTAssertTrue(exists("versions/\(kept)/v1/weights.bin"))
    XCTAssertTrue(exists("active/\(kept).json"))
    XCTAssertTrue(exists("versions/\(other)/v1/weights.bin"))
    XCTAssertTrue(exists("active/\(other).json"))
    let installs = await runtime.recommendedModelArtifacts().map(\.artifactID)
    XCTAssertFalse(installs.isEmpty)
    XCTAssertTrue(LocalDictationRuntime.retiredModelArtifactIDs.isDisjoint(with: installs))
  }

  /// Review 2026-10-07: opening a dictation in History right after it
  /// loaded the aligner next to the resident recognizer (about 5.1 GB). A
  /// pass waits for the recognizer to leave; an export releases it first.
  func testHistoryWaitsForTheRecognizerAndAnExportReleasesItFirst() async throws {
    let runtime = try await makeRuntime()
    let resident = await eventually { await runtime.recognizerResident }
    XCTAssertTrue(resident)
    let fromHistory = await runtime.startDeferredWordAlignment(sessionID: SessionID())
    XCTAssertNil(fromHistory)
    let early = await recognizer.releases
    XCTAssertEqual(early, 0)
    let fromExport = await runtime.startDeferredWordAlignment(
      sessionID: SessionID(), releasingRecognizer: true)
    XCTAssertNotNil(fromExport)
    _ = await fromExport?.value
    let releases = await recognizer.releases
    XCTAssertEqual(releases, 1)
    let stillResident = await runtime.recognizerResident
    XCTAssertFalse(stillResident)
  }

  /// Review 2026-10-07: a press during a pass only cancelled it; the
  /// aligner finished loading and aligned a whole window while the
  /// recognizer loaded next to it. Now the aligner is released after its
  /// load, before the recognizer is warmed.
  func testAPressDuringAPassReleasesTheAlignerBeforeTheRecognizerLoads() async throws {
    let log = ModelEventLog()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("residency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets", isDirectory: true))
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let runtime = try LocalDictationRuntime(
      applicationRoot: root, cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
      journal: journal, repository: store, insertion: NowhereInsertion(),
      localSelfPersonID: PersonID())
    await runtime.adoptFinalASRWarmupRuntime(
      QwenASRRuntime(
        audioLoader: NoResidencySamples(), backend: LoggingQwenRecognizer(log: log),
        aligner: LoadingQwenAligner(log: log, loadTime: .milliseconds(400))))
    let warmed = await eventually { await runtime.recognizerResident }
    XCTAssertTrue(warmed)
    await runtime.releaseIdleModels([.recognizer])
    await runtime.startPassInTheAlignerForTest()
    let loading = await eventually { await log.events.contains("aligner-load-started") }
    XCTAssertTrue(loading)
    let pressedAt = await log.events.count
    await runtime.warmFinalASRIfIdle()
    let rewarmed = await eventually { await runtime.recognizerResident }
    XCTAssertTrue(rewarmed)
    let afterPress = Array(await log.events.dropFirst(pressedAt))
    XCTAssertFalse(afterPress.contains("aligner-align"), "\(afterPress)")
    let alignerReleased = afterPress.firstIndex(of: "aligner-release")
    let recognizerDecoded = afterPress.firstIndex(of: "recognizer-decode")
    XCTAssertNotNil(alignerReleased, "\(afterPress)")
    XCTAssertNotNil(recognizerDecoded, "\(afterPress)")
    XCTAssertLessThan(alignerReleased ?? .max, recognizerDecoded ?? .min, "\(afterPress)")
    let passEnded = await runtime.wordAlignmentTask == nil
    XCTAssertTrue(passEnded)
  }

  /// No pass starts while a press is warming the recognizer, before its
  /// dictation has taken the speculation slot (review 2026-10-07).
  func testNoPassStartsWhileAPressWarmsTheRecognizer() async throws {
    let slow = CountingQwenRecognizer(decodeTime: .milliseconds(400))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("residency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let journal = try ProductionAudioJournal(
      assetRootURL: root.appendingPathComponent("assets", isDirectory: true))
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let runtime = try LocalDictationRuntime(
      applicationRoot: root, cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
      journal: journal, repository: store, insertion: NowhereInsertion(),
      localSelfPersonID: PersonID())
    await runtime.adoptFinalASRWarmupRuntime(
      QwenASRRuntime(audioLoader: NoResidencySamples(), backend: slow, aligner: aligner))
    let warmed = await eventually { await runtime.recognizerResident }
    XCTAssertTrue(warmed)
    await runtime.releaseIdleModels([.recognizer])
    await runtime.warmFinalASRIfIdle()
    let duringWarmUp = await runtime.startDeferredWordAlignment()
    XCTAssertNil(duringWarmUp)
  }

  /// Review 2026-10-07: a warning that outlasted its grace during a take
  /// put the recognizer's release off to the take's end, and a normal
  /// report before then did not call it off.
  func testNormalBeforeTheTakeEndsCallsOffAPostponedRelease() async throws {
    let runtime = try await makeRuntime(pressureGrace: .milliseconds(100))
    let sessionID = SessionID()
    await runtime.warmFinalASRIfIdle()
    await runtime.beginFinalSpeculation(sessionID: sessionID)
    await runtime.handleMemoryPressure(.warning)
    let postponed = await eventually {
      await runtime.pendingMemoryPressureRelease.contains(.recognizer)
    }
    XCTAssertTrue(postponed)
    await runtime.handleMemoryPressure(.normal)
    await runtime.endUnprocessedDictation(sessionID: sessionID)
    try await Task.sleep(for: .milliseconds(300))
    let releases = await recognizer.releases
    XCTAssertEqual(releases, 0)
  }

  /// A grace timer from an earlier warning that has already passed its
  /// cancellation check does nothing to a later warning (review
  /// 2026-10-07).
  func testAStaleGraceTimerDoesNotReleaseTheRecognizer() async throws {
    let runtime = try await makeRuntime()
    await runtime.handleMemoryPressure(.warning)
    let first = await runtime.memoryPressureGeneration
    await runtime.handleMemoryPressure(.normal)
    await runtime.handleMemoryPressure(.warning)
    let timerOfTheSecondWarning = await runtime.recognizerPressureTask
    XCTAssertNotNil(timerOfTheSecondWarning)
    await runtime.memoryPressureWarningLasted(.seconds(60), generation: first)
    let releases = await recognizer.releases
    XCTAssertEqual(releases, 0)
    let timerKept = await runtime.recognizerPressureTask
    XCTAssertNotNil(timerKept)
    timerKept?.cancel()
  }

  /// The system's reports are handled in the order it sent them (review
  /// 2026-10-07: a task per report could apply a warning after the normal
  /// that followed it).
  func testMemoryPressureReportsAreHandledInOrder() async throws {
    let runtime = try await makeRuntime()
    await runtime.startMemoryPressureWatch()
    for _ in 0..<20 {
      await runtime.reportMemoryPressure(.warning)
      await runtime.reportMemoryPressure(.normal)
    }
    let settled = await eventually {
      let pressure = await runtime.memoryPressure
      let timer = await runtime.recognizerPressureTask
      return pressure == .normal && timer == nil
    }
    XCTAssertTrue(settled)
    try await Task.sleep(for: .milliseconds(200))
    let pressure = await runtime.memoryPressure
    XCTAssertEqual(pressure, .normal)
  }

  /// When memory pressure ends with the recognizer out of memory, the
  /// sentences its release left untimed are timed (review 2026-10-07: no
  /// pass followed a release under pressure until the next dictation's
  /// hour or a relaunch).
  func testNormalAfterAReleaseUnderPressureStartsAPass() async throws {
    let runtime = try await makeRuntime()
    await runtime.handleMemoryPressure(.critical)
    let released = await recognizer.releases
    XCTAssertEqual(released, 1)
    let before = await settledAlignerReleases()
    await runtime.handleMemoryPressure(.normal)
    // The pass ends by releasing the aligner.
    let passRan = await eventually { await self.aligner.releases > before }
    XCTAssertTrue(passRan)
  }

  /// Regression: the memory-pressure watch was started only from a
  /// discovery entry the App never calls.
  func testTheAppsModelDiscoveryStartsTheMemoryPressureWatch() async throws {
    let runtime = try await makeRuntime(adoptModels: false)
    let before = await runtime.watchesMemoryPressure
    XCTAssertFalse(before)
    let model = DictationAppModel(preview: true)
    await model.discoverInstalledModels(on: runtime)
    let after = await runtime.watchesMemoryPressure
    XCTAssertTrue(after)
  }
}
