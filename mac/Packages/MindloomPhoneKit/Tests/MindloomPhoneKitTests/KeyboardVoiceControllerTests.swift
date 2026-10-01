import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// The keyboard ↔ app voice protocol end to end in one process: the app's
/// `VoiceSessionCore` with a fake recognizer and the keyboard's
/// `KeyboardVoiceController`, talking only through the voice files and the
/// signals, exactly as the two processes do.
@MainActor
final class KeyboardVoiceControllerTests: XCTestCase {
  private var root: URL!
  private var channel: VoiceChannel!
  private var signaling: LocalSignaling!
  private var clock: TestClock!
  private var recognizer: FakeRecognizer!
  private var core: VoiceSessionCore!
  private var keyboard: KeyboardVoiceController!
  private var inserted: [String] = []
  private var collected: [String] = []
  private var collectResult: CollectResult = .collected
  private var haptics: [KeyboardVoiceController.Haptic] = []

  override func setUp() async throws {
    root = try makeTemporaryDirectory()
    channel = try VoiceChannel(directory: root.appendingPathComponent("voice"))
    signaling = LocalSignaling()
    clock = TestClock()
    recognizer = FakeRecognizer()
    core = VoiceSessionCore(channel: channel, signaling: signaling, clock: clock.function)
    inserted = []
    collected = []
    collectResult = .collected
    haptics = []
    keyboard = makeKeyboard(channel: channel)
  }

  override func tearDown() async throws {
    keyboard = nil
    core = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func makeKeyboard(channel: VoiceChannel?) -> KeyboardVoiceController {
    KeyboardVoiceController(
      channel: channel, signaling: signaling, clock: clock.function,
      insert: { [weak self] in self?.inserted.append($0) },
      collect: { [weak self] text in
        guard let self else { return .failed }
        if self.collectResult == .collected { self.collected.append(text) }
        return self.collectResult
      },
      collectedCount: { [weak self] in
        guard let self, self.collectResult != .notPaired else { return nil }
        return self.collected.count
      },
      haptic: { [weak self] in self?.haptics.append($0) })
  }

  /// Starts the app's session and shows the keyboard.
  private func openSessionAndKeyboard() {
    core.start(recognizer: recognizer)
    keyboard.appear()
    signaling.deliverPending()
  }

  /// Delivers signals and lets the app's finishing tasks run (without
  /// waiting for utterances the test is holding back).
  private func pump() async {
    for _ in 0..<5 {
      signaling.deliverPending()
      await settle()
    }
  }

  private func hold(_ seconds: TimeInterval, saying partial: String? = nil) async {
    keyboard.pressDown()
    await pump()
    if let partial { recognizer.utterances.last?.say(partial) }
    await pump()
    clock.advance(seconds)
    keyboard.pressUp()
    await pump()
  }

  func testWithoutFullAccessTheKeyAsksForIt() {
    let locked = makeKeyboard(channel: nil)
    locked.appear()
    XCTAssertEqual(locked.display.mic, .needsFullAccess)
    locked.pressDown()
    XCTAssertTrue(signaling.posted.isEmpty, "nothing is sent without full access")
  }

  func testWithoutASessionTheKeyOpensTheApp() {
    keyboard.appear()
    XCTAssertEqual(keyboard.display.mic, .needsSession)
    keyboard.pressDown()
    XCTAssertFalse(signaling.posted.contains(PhoneSignal.voiceStart))
    // A session whose app stopped writing heartbeats counts as gone.
    core.start(recognizer: recognizer)
    signaling.deliverPending()
    XCTAssertEqual(keyboard.display.mic, .ready)
    clock.advance(VoiceState.heartbeatGrace + 1)
    keyboard.tick()
    XCTAssertEqual(keyboard.display.mic, .needsSession)
  }

  func testHoldToTalkInsertsTheFinalOnceAndCollectsIt() async {
    openSessionAndKeyboard()
    XCTAssertEqual(keyboard.display.mic, .ready)
    keyboard.pressDown()
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: false))
    await pump()
    XCTAssertEqual(core.phase, .listening(seq: 1))
    recognizer.utterances[0].say("合成：明早")
    await pump()
    XCTAssertEqual(keyboard.display.transcript, "合成：明早")
    XCTAssertTrue(keyboard.display.transcriptIsLive)
    clock.advance(1.2)
    keyboard.pressUp()
    XCTAssertEqual(keyboard.display.mic, .finishing)
    await pump()
    XCTAssertEqual(inserted, ["合成：明早九点站会"])
    XCTAssertEqual(collected, ["合成：明早九点站会"])
    XCTAssertEqual(keyboard.display.mic, .ready)
    XCTAssertEqual(keyboard.display.transcript, "合成：明早九点站会")
    XCTAssertFalse(keyboard.display.transcriptIsLive)
    XCTAssertEqual(keyboard.display.collected, 1)
    XCTAssertEqual(haptics, [.start, .stop, .inserted])
    // Another final notification changes nothing.
    signaling.post(PhoneSignal.voiceFinal)
    await pump()
    XCTAssertEqual(inserted.count, 1)
  }

  func testShortTapTogglesListeningUntilTheNextTap() async {
    openSessionAndKeyboard()
    keyboard.pressDown()
    clock.advance(0.2)
    keyboard.pressUp()
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: true))
    await pump()
    XCTAssertEqual(core.phase, .listening(seq: 1), "still listening after the finger lifts")
    clock.advance(4)
    keyboard.pressDown()
    XCTAssertEqual(keyboard.display.mic, .finishing)
    keyboard.pressUp()
    await pump()
    XCTAssertEqual(inserted, ["合成：明早九点站会"])
    XCTAssertEqual(keyboard.display.mic, .ready)
  }

  func testFinalsOnDiskBeforeTheKeyboardAppearedAreNeverInserted() async throws {
    core.start(recognizer: recognizer)
    core.handleStart()
    core.handleStop()
    await core.waitForFinals()
    XCTAssertEqual(channel.readFinals()?.text, "合成：明早九点站会")
    keyboard.appear()
    signaling.post(PhoneSignal.voiceFinal)
    await pump()
    XCTAssertEqual(inserted, [])
  }

  func testAFinalThisKeyboardDidNotAskForIsNotInserted() async {
    openSessionAndKeyboard()
    // Another keyboard instance (or a stray command) drives the app.
    core.handleStart()
    core.handleStop()
    await pump()
    XCTAssertEqual(inserted, [])
    XCTAssertEqual(keyboard.display.mic, .ready)
  }

  func testCoalescedFinalsAreAllInsertedInOrder() async {
    openSessionAndKeyboard()
    recognizer.holdFinishes = true
    recognizer.nextFinalText = "第一句。"
    await hold(1)
    recognizer.nextFinalText = "第二句。"
    await hold(1)
    XCTAssertEqual(keyboard.display.mic, .finishing)
    recognizer.utterances[1].release()
    recognizer.utterances[0].release()
    // Both finals land before the keyboard hears a single `.final`.
    await core.waitForFinals()
    await settle()
    await pump()
    XCTAssertEqual(inserted, ["第一句。", "第二句。"])
    XCTAssertEqual(collected, ["第一句。", "第二句。"])
    XCTAssertEqual(keyboard.display.mic, .ready)
  }

  func testSpeakingAgainWhileTheLastUtteranceFinishes() async {
    openSessionAndKeyboard()
    recognizer.holdFinishes = true
    recognizer.nextFinalText = "前一句"
    await hold(1)
    recognizer.nextFinalText = "后一句"
    keyboard.pressDown()
    await pump()
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: false))
    recognizer.utterances[0].release()
    await pump()
    XCTAssertEqual(inserted, ["前一句"])
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: false), "still holding the key")
    clock.advance(1)
    keyboard.pressUp()
    await pump()
    recognizer.utterances[1].release()
    await pump()
    XCTAssertEqual(inserted, ["前一句", "后一句"])
  }

  func testNothingHeardIsSaidPlainly() async {
    openSessionAndKeyboard()
    recognizer.nextFinalText = ""
    await hold(1)
    XCTAssertEqual(inserted, [])
    XCTAssertEqual(collected, [])
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.heardNothing)
    recognizer.nextFinalText = nil
    await hold(1)
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.recognitionFailed)
    XCTAssertEqual(keyboard.display.mic, .ready)
  }

  func testUnpairedPhoneStillTypesButDoesNotCollect() async {
    collectResult = .notPaired
    openSessionAndKeyboard()
    XCTAssertNil(keyboard.display.collected)
    await hold(1)
    XCTAssertEqual(inserted, ["合成：明早九点站会"])
    XCTAssertEqual(collected, [])
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.notPaired)
    XCTAssertNil(keyboard.display.collected)
  }

  func testAppThatNeverAnswersIsReported() async {
    openSessionAndKeyboard()
    core.end()  // the state file is still "alive" for the keyboard below
    try? channel.writeState(
      VoiceState(
        sessionAliveUntil: clock.now.timeIntervalSince1970 + 600, seq: 0,
        heartbeatAt: clock.now.timeIntervalSince1970))
    keyboard.refreshState()
    XCTAssertEqual(keyboard.display.mic, .ready)
    keyboard.pressDown()
    await pump()
    clock.advance(KeyboardVoiceController.startAcknowledgeTimeout)
    keyboard.tick()
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.appNotResponding)
    XCTAssertEqual(signaling.posted.last, PhoneSignal.voiceStop)
    XCTAssertNotEqual(keyboard.display.mic, .listening(toggle: false))
  }

  func testMissingFinalTimesOut() async {
    openSessionAndKeyboard()
    recognizer.holdFinishes = true
    await hold(1)
    XCTAssertEqual(keyboard.display.mic, .finishing)
    clock.advance(KeyboardVoiceController.finalTimeout)
    core.tick()  // the app's heartbeat keeps the session alive meanwhile
    keyboard.tick()
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.noFinal)
    XCTAssertEqual(keyboard.display.mic, .ready)
    // A final arriving after the timeout is not inserted into a later field.
    recognizer.utterances[0].release()
    await pump()
    XCTAssertEqual(inserted, [])
  }

  func testLeavingTheKeyboardStopsListening() async {
    openSessionAndKeyboard()
    keyboard.pressDown()
    clock.advance(0.1)
    keyboard.pressUp()
    await pump()
    XCTAssertTrue(core.isListening)
    keyboard.disappear()
    await pump()
    XCTAssertFalse(core.isListening)
  }

  func testAppProblemIsShownOnTheKey() async {
    openSessionAndKeyboard()
    core.report(problem: .preparingModel)
    signaling.deliverPending()
    XCTAssertEqual(keyboard.display.mic, .unavailable(.preparingModel))
    keyboard.pressDown()
    XCTAssertFalse(signaling.posted.contains(PhoneSignal.voiceStart))
  }

  func testAppEndingTheUtteranceWhileTheKeyIsHeld() async {
    openSessionAndKeyboard()
    recognizer.failNextBegin = true
    keyboard.pressDown()
    await pump()
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.recognitionFailed)
    XCTAssertEqual(keyboard.display.mic, .ready)
    clock.advance(1)
    keyboard.pressUp()
    await pump()
    XCTAssertEqual(inserted, [])
  }

  // MARK: - Collecting through the real outbox

  func testKeyboardFinalBecomesOneSealedOutboxItem() throws {
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let pairing = PairingRecordStore(file: root.appendingPathComponent("pairing.json"))
    let collector = InboxCollector(
      outbox: try OutboxStore(root: root.appendingPathComponent("outbox")), pairing: pairing,
      signaling: signaling)
    XCTAssertEqual(collector.collectKeyboardText("合成：周五交报告", now: baseDate), .notPaired)
    XCTAssertEqual(try collector.outbox.queued(), [])

    try pairing.write(try syntheticPairing(macKey: macKey).record)
    XCTAssertEqual(collector.collectKeyboardText("合成：周五交报告", now: baseDate), .collected)
    XCTAssertEqual(signaling.posted.last, PhoneSignal.outboxChanged)
    let entry = try XCTUnwrap(try collector.outbox.queued().first)
    XCTAssertEqual(entry.kind, .text)
    XCTAssertEqual(entry.source, .keyboard)
    XCTAssertEqual(entry.preview, "合成：周五交报告")
    let wire = try XCTUnwrap(entry.wire)
    XCTAssertTrue(wire.hasPrefix("mlseal1."))
    XCTAssertFalse(wire.contains("周五"))
    let opened = try InboxItemPayload.decode(
      MindloomSeal.open(wire, entryID: entry.entryID, with: macKey))
    XCTAssertEqual(opened.text, "合成：周五交报告")
    XCTAssertEqual(opened.source.rawValue, "iPhone 键盘")
    XCTAssertEqual(opened.createdDate, baseDate)
    XCTAssertEqual(collector.collectedCount(now: baseDate), 1)
    // The outbox file holds the sealed wire and the short preview only.
    let files = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("outbox/queued"), includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 1)
  }
}

func syntheticPairing(macKey: Curve25519.KeyAgreement.PrivateKey) throws -> PairingPayload {
  let hostKey = Curve25519.Signing.PrivateKey().publicKey
  let hostLine = PairingPayload.openSSHPublicKey(hostKey)
  return try PairingPayload(
    label: "合成的 Mac",
    spark: PairingEndpoint(
      host: "spark.example", port: 22, user: "mindloom",
      hostKey: try XCTUnwrap(SSHHostKey(openSSH: hostLine))),
    relay: nil,
    phoneKey: Curve25519.Signing.PrivateKey().rawRepresentation,
    phoneKeyID: "phone-test",
    macSealPublicKey: macKey.publicKey.rawRepresentation)
}
