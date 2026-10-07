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
  /// The host field: committed text plus the marked (underlined) text after it.
  private var field = ""
  private var marked = ""
  private var marks: [String] = []
  private var inserted: [String] = []
  private var outcomes: [KeyboardVoiceController.Outcome] = []
  private var delays: [TimeInterval] = []
  private var haptics: [KeyboardVoiceController.Haptic] = []
  private var keptForMac: [String] = []
  private var withdrawnSeqs: [Int] = []

  override func setUp() async throws {
    root = try makeTemporaryDirectory()
    channel = try VoiceChannel(directory: root.appendingPathComponent("voice"))
    signaling = LocalSignaling()
    clock = TestClock()
    recognizer = FakeRecognizer()
    core = VoiceSessionCore(channel: channel, signaling: signaling, clock: clock.function)
    core.onKeyboardInserted = { [weak self] final, _ in self?.keptForMac.append(final.text) }
    core.onKeyboardWithdrawn = { [weak self] seq in self?.withdrawnSeqs.append(seq) }
    field = ""
    marked = ""
    marks = []
    inserted = []
    outcomes = []
    delays = []
    haptics = []
    keptForMac = []
    withdrawnSeqs = []
    keyboard = makeKeyboard(channel: channel)
  }

  override func tearDown() async throws {
    keyboard = nil
    core = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func makeKeyboard(channel: VoiceChannel?) -> KeyboardVoiceController {
    let host = KeyboardTextHost(
      mark: { [weak self] in
        self?.marked = $0
        self?.marks.append($0)
      },
      insert: { [weak self] text in
        guard let self else { return }
        self.marked = ""
        self.field += text
        self.inserted.append(text)
      },
      clearMarked: { [weak self] in self?.marked = "" },
      textBeforeCursor: { [weak self] in self?.field },
      deleteBackward: { [weak self] count in
        guard let self else { return }
        self.field = String(self.field.dropLast(count))
      })
    let controller = KeyboardVoiceController(
      channel: channel, signaling: signaling, clock: clock.function, host: host,
      after: { [weak self] delay, body in
        self?.delays.append(delay)
        body()
      },
      haptic: { [weak self] in self?.haptics.append($0) })
    controller.onOutcome = { [weak self] in self?.outcomes.append($0) }
    return controller
  }

  /// Starts the app's session and shows the keyboard.
  private func openSessionAndKeyboard() {
    core.start(recognizer: recognizer)
    keyboard.appear()
    signaling.deliverPending()
  }

  /// Delivers signals and lets the app's finishing tasks run (without waiting for utterances the
  /// test is holding back).
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
    keyboard.pressUp(moved: 20)
    await pump()
  }

  func testWithoutFullAccessTheKeyAsksForIt() {
    let locked = makeKeyboard(channel: nil)
    locked.appear()
    XCTAssertEqual(locked.display.mic, .needsFullAccess)
    XCTAssertFalse(locked.pressDown())
    XCTAssertTrue(signaling.posted.isEmpty, "nothing is sent without full access")
  }

  func testWithoutASessionTheKeyOpensTheApp() {
    keyboard.appear()
    XCTAssertEqual(keyboard.display.mic, .needsSession)
    XCTAssertFalse(keyboard.pressDown())
    XCTAssertFalse(signaling.posted.contains(PhoneSignal.voiceStart))
    // A session whose app stopped writing heartbeats counts as gone.
    core.start(recognizer: recognizer)
    signaling.deliverPending()
    XCTAssertEqual(keyboard.display.mic, .ready)
    clock.advance(VoiceState.heartbeatGrace + 1)
    keyboard.tick()
    XCTAssertEqual(keyboard.display.mic, .needsSession)
  }

  func testMicrophoneOffIsShownEvenWithoutASession() {
    keyboard.appear()
    core.setMicrophoneDenied(true)
    signaling.deliverPending()
    XCTAssertEqual(keyboard.display.mic, .microphoneDenied)
    XCTAssertFalse(keyboard.pressDown())
    core.setMicrophoneDenied(false)
    signaling.deliverPending()
    XCTAssertEqual(keyboard.display.mic, .needsSession)
  }

  func testPartialsAreMarkedTextAndTheFinalReplacesThem() async {
    openSessionAndKeyboard()
    XCTAssertEqual(keyboard.display.mic, .ready)
    XCTAssertTrue(keyboard.pressDown())
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: false))
    await pump()
    XCTAssertEqual(core.phase, .listening(seq: 1))
    recognizer.utterances[0].say("合成：明早")
    await pump()
    XCTAssertEqual(marked, "合成：明早", "live words are marked text in the field")
    XCTAssertEqual(field, "", "nothing is committed while speaking")
    clock.advance(1.2)
    XCTAssertFalse(keyboard.pressUp(moved: 30))
    XCTAssertEqual(keyboard.display.mic, .finishing)
    await pump()
    XCTAssertEqual(inserted, ["合成：明早九点站会。"], "「。」 is added")
    XCTAssertEqual(field, "合成：明早九点站会。")
    XCTAssertEqual(marked, "")
    XCTAssertEqual(outcomes, [.inserted("合成：明早九点站会。")])
    XCTAssertEqual(delays.count, 1)
    XCTAssertEqual(
      delays[0], KeyboardVoiceController.commitDelay, accuracy: 0.001,
      "committed no earlier than release + 0.35 s")
    XCTAssertEqual(keyboard.display.mic, .ready)
    XCTAssertEqual(haptics, [.start, .stop, .inserted])
    // The app keeps the inserted final for the Mac (once).
    XCTAssertEqual(keptForMac, ["合成：明早九点站会"])
    signaling.post(PhoneSignal.voiceFinal)
    signaling.post(PhoneSignal.voiceAck)
    await pump()
    XCTAssertEqual(inserted.count, 1)
    XCTAssertEqual(keptForMac.count, 1)
  }

  func testShortTapLatchesUntilTheNextTapOrDone() async {
    openSessionAndKeyboard()
    keyboard.pressDown()
    clock.advance(0.2)
    XCTAssertTrue(keyboard.pressUp(moved: 3))
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: true))
    await pump()
    XCTAssertEqual(core.phase, .listening(seq: 1), "still listening after the finger lifts")
    clock.advance(4)
    keyboard.pressDown()
    XCTAssertEqual(keyboard.display.mic, .finishing)
    keyboard.pressUp()
    await pump()
    XCTAssertEqual(inserted, ["合成：明早九点站会。"])
    XCTAssertEqual(keyboard.display.mic, .ready)
    // ✓ finishes a latched press too.
    keyboard.pressDown()
    clock.advance(0.1)
    keyboard.pressUp()
    await pump()
    keyboard.done()
    await pump()
    XCTAssertEqual(inserted.count, 2)
  }

  func testAShortPressThatMovedIsNotATap() async {
    openSessionAndKeyboard()
    keyboard.pressDown()
    clock.advance(0.2)
    XCTAssertFalse(keyboard.pressUp(moved: 15))
    XCTAssertEqual(keyboard.display.mic, .finishing)
  }

  func testCancelInsertsNothingAndTheAppDropsTheUtterance() async {
    openSessionAndKeyboard()
    keyboard.pressDown()
    await pump()
    recognizer.utterances[0].say("合成：算了")
    await pump()
    XCTAssertEqual(marked, "合成：算了")
    keyboard.cancel()
    XCTAssertEqual(marked, "", "the marked text is removed")
    XCTAssertEqual(signaling.posted.last, PhoneSignal.voiceCancel)
    await pump()
    XCTAssertTrue(recognizer.utterances[0].cancelled)
    XCTAssertEqual(core.phase, .ready)
    XCTAssertEqual(inserted, [])
    XCTAssertEqual(outcomes, [.cancelled])
    XCTAssertEqual(keptForMac, [])
    // The next utterance works and is numbered after the cancelled one.
    await hold(1)
    XCTAssertEqual(inserted, ["合成：明早九点站会。"])
    XCTAssertEqual(core.seq, 2)
  }

  func testUndoRemovesTheTextAndTheAppWithdrawsTheItem() async {
    openSessionAndKeyboard()
    field = "好的，"
    await hold(1)
    XCTAssertEqual(field, "好的，合成：明早九点站会。")
    XCTAssertTrue(keyboard.canUndo)
    clock.advance(2)
    XCTAssertTrue(keyboard.undo())
    XCTAssertEqual(field, "好的，", "only the inserted words are deleted")
    await pump()
    XCTAssertEqual(withdrawnSeqs, [1])
    XCTAssertFalse(keyboard.undo(), "once")
  }

  func testUndoLeavesTheFieldAloneWhenTheUserTypedAfter() async {
    openSessionAndKeyboard()
    await hold(1)
    field += "？"
    XCTAssertTrue(keyboard.undo())
    XCTAssertEqual(field, "合成：明早九点站会。？")
    await pump()
    XCTAssertEqual(withdrawnSeqs, [1], "the item is still taken back")
  }

  func testUndoWindowCloses() async {
    openSessionAndKeyboard()
    await hold(1)
    clock.advance(KeyboardVoiceController.undoWindow + 1)
    XCTAssertFalse(keyboard.undo())
    await hold(1)
    keyboard.settle()
    XCTAssertFalse(keyboard.undo())
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
    XCTAssertEqual(keptForMac, [], "nothing the keyboard did not insert is kept")
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
    XCTAssertEqual(keptForMac, ["第一句。", "第二句。"])
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
    XCTAssertEqual(inserted, ["前一句。"])
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: false), "still holding the key")
    clock.advance(1)
    keyboard.pressUp()
    await pump()
    recognizer.utterances[1].release()
    await pump()
    XCTAssertEqual(inserted, ["前一句。", "后一句。"])
  }

  /// Regression (fix-ios review): an older utterance that comes back empty while the next press is
  /// held must not clear that press's live words, end it, or leave the app listening on.
  func testAnEmptyOlderFinalDoesNotEndTheHeldPress() async {
    openSessionAndKeyboard()
    recognizer.holdFinishes = true
    recognizer.nextFinalText = ""
    await hold(1)
    recognizer.nextFinalText = "后一句"
    keyboard.pressDown()
    await pump()
    recognizer.utterances.last?.say("后一")
    await pump()
    XCTAssertEqual(marked, "后一")
    recognizer.utterances[0].release()
    await pump()
    XCTAssertEqual(marked, "后一", "the held press keeps its live words")
    XCTAssertEqual(keyboard.display.mic, .listening(toggle: false), "still holding the key")
    XCTAssertEqual(outcomes, [], "no outcome for the older, empty utterance")
    clock.advance(1)
    keyboard.pressUp()
    await pump()
    recognizer.utterances[1].release()
    await pump()
    XCTAssertEqual(inserted, ["后一句。"])
    XCTAssertEqual(keptForMac, ["后一句"], "the app keeps the raw final (it finalizes it itself)")
  }

  /// Regression: switching away while the final is still coming leaves no partial behind as marked
  /// text.
  func testLeavingWhileFinishingClearsTheMarkedPartial() async {
    openSessionAndKeyboard()
    recognizer.holdFinishes = true
    keyboard.pressDown()
    await pump()
    recognizer.utterances.last?.say("还没说完")
    await pump()
    clock.advance(1)
    keyboard.pressUp(moved: 20)
    await pump()
    XCTAssertEqual(keyboard.display.mic, .finishing)
    keyboard.disappear()
    XCTAssertEqual(marked, "")
  }

  func testNothingHeardEndsWithoutSaving() async {
    openSessionAndKeyboard()
    recognizer.nextFinalText = ""
    await hold(1)
    XCTAssertEqual(inserted, [])
    XCTAssertEqual(outcomes, [.nothing])
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.heardNothing)
    recognizer.nextFinalText = nil
    await hold(1)
    XCTAssertEqual(keyboard.display.notice, KeyboardCopy.recognitionFailed)
    XCTAssertEqual(outcomes, [.nothing, .nothing])
    XCTAssertEqual(keyboard.display.mic, .ready)
    XCTAssertEqual(keptForMac, [])
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
    XCTAssertEqual(outcomes, [.nothing])
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

  func testSessionEndingUnderTheFingerGoesBackToOff() async {
    openSessionAndKeyboard()
    keyboard.pressDown()
    await pump()
    core.end(reason: .user)
    await pump()
    XCTAssertEqual(keyboard.display.mic, .needsSession)
    XCTAssertEqual(outcomes, [.nothing])
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
    XCTAssertEqual(inserted, [])
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
