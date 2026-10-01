import Foundation
import XCTest

@testable import MindloomPhoneKit

@MainActor
final class VoiceSessionCoreTests: XCTestCase {
  private var root: URL!
  private var channel: VoiceChannel!
  private var signaling: LocalSignaling!
  private var clock: TestClock!
  private var recognizer: FakeRecognizer!
  private var core: VoiceSessionCore!

  override func setUp() async throws {
    root = try makeTemporaryDirectory()
    channel = try VoiceChannel(directory: root.appendingPathComponent("voice"))
    signaling = LocalSignaling()
    clock = TestClock()
    recognizer = FakeRecognizer()
    core = VoiceSessionCore(channel: channel, signaling: signaling, clock: clock.function)
  }

  override func tearDown() async throws {
    core = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func startSession() {
    core.start(recognizer: recognizer)
    signaling.deliverPending()
    signaling.clearLog()
  }

  func testStartWritesAnAliveStateAndHeartbeat() throws {
    core.start(recognizer: recognizer)
    let state = try XCTUnwrap(channel.readState())
    XCTAssertEqual(state.sessionAliveUntil, baseDate.timeIntervalSince1970 + 600)
    XCTAssertFalse(state.recording)
    XCTAssertEqual(state.seq, 0)
    XCTAssertEqual(state.recognizer, "fake")
    XCTAssertTrue(state.isAlive(at: baseDate))
    XCTAssertEqual(signaling.posted, [PhoneSignal.voiceHeartbeat])
    XCTAssertEqual(core.phase, .ready)
  }

  func testHoldProducesPartialsThenOneFinal() async throws {
    startSession()
    signaling.post(PhoneSignal.voiceStart)
    signaling.deliverPending()
    XCTAssertEqual(core.phase, .listening(seq: 1))
    XCTAssertEqual(channel.readState()?.recording, true)
    let utterance = try XCTUnwrap(recognizer.utterances.first)
    utterance.say("合成")
    XCTAssertEqual(
      channel.readPartial(), VoiceText(seq: 1, text: "合成", at: baseDate.timeIntervalSince1970))

    signaling.post(PhoneSignal.voiceStop)
    signaling.deliverPending()
    XCTAssertEqual(core.phase, .ready)
    XCTAssertEqual(channel.readState()?.recording, false)
    await core.waitForFinals()

    let finals = try XCTUnwrap(channel.readFinals())
    XCTAssertEqual(finals.seq, 1)
    XCTAssertEqual(finals.text, "合成：明早九点站会")
    XCTAssertEqual(finals.outcome, .text)
    XCTAssertNil(channel.readPartial(), "the partial is removed once the final lands")
    XCTAssertEqual(
      signaling.posted.filter { $0 != PhoneSignal.voiceHeartbeat },
      [
        PhoneSignal.voiceStart, PhoneSignal.voicePartial, PhoneSignal.voiceStop,
        PhoneSignal.voiceFinal,
      ])
  }

  func testEmptyAndFailedUtterancesStillEndWithAFinal() async throws {
    startSession()
    recognizer.nextFinalText = "   "
    core.handleStart()
    core.handleStop()
    await core.waitForFinals()
    XCTAssertEqual(channel.readFinals()?.outcome, .empty)
    XCTAssertEqual(channel.readFinals()?.text, "")

    recognizer.nextFinalText = nil
    core.handleStart()
    core.handleStop()
    await core.waitForFinals()
    XCTAssertEqual(channel.readFinals()?.seq, 2)
    XCTAssertEqual(channel.readFinals()?.outcome, .failed)

    recognizer.failNextBegin = true
    core.handleStart()
    XCTAssertEqual(core.phase, .ready, "a recognizer that cannot start leaves the session ready")
    XCTAssertEqual(channel.readFinals()?.seq, 3)
    XCTAssertEqual(channel.readFinals()?.outcome, .failed)
  }

  func testFinalsArePublishedInSpokenOrder() async throws {
    startSession()
    recognizer.holdFinishes = true
    recognizer.nextFinalText = "第一句"
    core.handleStart()
    core.handleStop()
    recognizer.nextFinalText = "第二句"
    core.handleStart()
    core.handleStop()
    XCTAssertEqual(core.finishingCount, 2)
    await settle()
    // The second utterance finishes first, but its final waits for the first.
    recognizer.utterances[1].release()
    await settle()
    XCTAssertNil(channel.readFinals())
    recognizer.utterances[0].release()
    await core.waitForFinals()
    let finals = try XCTUnwrap(channel.readFinals())
    XCTAssertEqual(finals.entries.map(\.text), ["第一句", "第二句"])
    XCTAssertEqual(finals.seq, 2)
    XCTAssertEqual(core.finishingCount, 0)
  }

  func testCommandsOutsideTheirPhaseAreIgnored() {
    core.handleStart()
    XCTAssertEqual(core.phase, .off, "no session, no utterance")
    startSession()
    core.handleStop()
    XCTAssertEqual(core.phase, .ready)
    core.handleStart()
    core.handleStart()
    XCTAssertEqual(
      recognizer.utterances.count, 1, "a repeated start does not open a second utterance")
    XCTAssertEqual(core.seq, 1)
  }

  func testSessionEndsTenMinutesAfterLastUse() async throws {
    startSession()
    clock.advance(300)
    core.handleStart()
    clock.advance(5)
    core.handleStop()
    await core.waitForFinals()
    clock.advance(599)
    core.tick()
    XCTAssertTrue(core.isAlive, "idle time counts from the last use")
    clock.advance(1)
    core.tick()
    XCTAssertFalse(core.isAlive)
    XCTAssertEqual(core.lastEndReason, .idle)
    let state = try XCTUnwrap(channel.readState())
    XCTAssertEqual(state.sessionAliveUntil, 0)
    XCTAssertFalse(state.isAlive(at: clock.now))
    XCTAssertEqual(channel.readFinals()?.text, "", "transcripts are cleared when the session ends")
    XCTAssertEqual(channel.readFinals()?.recent, [])
    XCTAssertEqual(channel.readFinals()?.seq, 1, "the number stays so old finals stay old")
  }

  func testUtteranceLeftOpenStopsByItself() async throws {
    startSession()
    core.handleStart()
    clock.advance(VoiceSessionCore.defaultMaximumUtterance)
    core.tick()
    XCTAssertEqual(core.phase, .ready)
    await core.waitForFinals()
    XCTAssertEqual(channel.readFinals()?.seq, 1)
  }

  func testEndingMidUtteranceDropsIt() async throws {
    startSession()
    recognizer.holdFinishes = true
    core.handleStart()
    core.handleStop()
    core.handleStart()
    core.end(reason: .user)
    XCTAssertTrue(recognizer.utterances[1].cancelled)
    recognizer.utterances[0].release()
    await settle()
    XCTAssertNil(
      channel.readFinals()?.recent.first, "no final is published after the session ended")
    XCTAssertEqual(channel.readState()?.recording, false)
    XCTAssertNil(channel.readPartial())
  }

  func testNumberingContinuesAcrossAppLaunches() async throws {
    startSession()
    core.handleStart()
    core.handleStop()
    await core.waitForFinals()
    core.end()
    let relaunched = VoiceSessionCore(channel: channel, signaling: signaling, clock: clock.function)
    XCTAssertEqual(relaunched.seq, 1)
    relaunched.start(recognizer: recognizer)
    relaunched.handleStart()
    XCTAssertEqual(relaunched.phase, .listening(seq: 2))
  }

  func testOldFinalsAreBlanked() async throws {
    startSession()
    core.handleStart()
    core.handleStop()
    await core.waitForFinals()
    XCTAssertEqual(channel.readFinals()?.text, "合成：明早九点站会")
    clock.advance(59)
    core.tick()
    XCTAssertEqual(channel.readFinals()?.text, "合成：明早九点站会")
    clock.advance(2)
    core.tick()
    XCTAssertEqual(channel.readFinals()?.text, "")
    XCTAssertEqual(channel.readFinals()?.seq, 1)
  }

  func testTranscriptsLeftByAnEndedRunAreBlankedAtLaunch() async throws {
    startSession()
    core.handleStart()
    recognizer.utterances[0].say("合成：半句")
    core.handleStop()
    await core.waitForFinals()
    try channel.writePartial(VoiceText(seq: 9, text: "合成：残留", at: baseDate.timeIntervalSince1970))
    // The process is killed here; the next launch runs a new core.
    clock.advance(VoiceSessionCore.defaultFinalRetention + 1)
    let relaunched = VoiceSessionCore(channel: channel, signaling: signaling, clock: clock.function)
    relaunched.scrubExpiredFinals()
    XCTAssertEqual(channel.readFinals()?.text, "")
    XCTAssertEqual(channel.readFinals()?.recent, [])
    XCTAssertNil(channel.readPartial())
  }

  func testHeartbeatKeepsTheStateFresh() throws {
    startSession()
    clock.advance(VoiceState.heartbeatGrace + 1)
    XCTAssertFalse(try XCTUnwrap(channel.readState()).isAlive(at: clock.now))
    core.tick()
    XCTAssertTrue(try XCTUnwrap(channel.readState()).isAlive(at: clock.now))
    XCTAssertEqual(signaling.posted.last, PhoneSignal.voiceHeartbeat)
  }

  func testProblemIsReported() throws {
    startSession()
    core.report(problem: .preparingModel)
    XCTAssertEqual(channel.readState()?.problem, .preparingModel)
    core.report(problem: nil)
    XCTAssertNil(channel.readState()?.problem)
  }

  func testLevelFileRoundTrip() {
    XCTAssertEqual(channel.readLevel(), 0)
    channel.writeLevel(0.42)
    XCTAssertEqual(channel.readLevel(), 0.42, accuracy: 0.0001)
    channel.writeLevel(7)
    XCTAssertEqual(channel.readLevel(), 1)
  }
}
