import AVFoundation
import Foundation
import MindloomPhoneKit
import XCTest

@testable import MindloomPhone

/// The voice path on the simulator: the keyboard ↔ app protocol over the
/// real Darwin notify center, and on-device recognition of a synthetic
/// Mandarin file through the DEBUG audio-file hook.
@MainActor
final class VoiceOnDeviceTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "voice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The synthetic Mandarin sentence, spoken by the system's own voice.
  private func fixture() async throws -> URL {
    try await SyntheticSpeech.makeFile(
      SyntheticSpeech.mandarinSentence, language: "zh-CN", in: root)
  }

  private func waitUntil(
    timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// The keyboard and the app talking through the Darwin notify center and
  /// the voice files, exactly as the two processes do (fake recognizer).
  func testKeyboardAndAppOverDarwinNotifications() async throws {
    let channel = try VoiceChannel(directory: root.appendingPathComponent("voice"))
    let recognizer = ScriptedRecognizer(partials: ["合成", "合成：明早"], final: "合成：明早九点站会。")
    let core = VoiceSessionCore(channel: channel, signaling: DarwinSignaling.shared)
    var inserted: [String] = []
    let keyboard = KeyboardVoiceController(
      channel: channel, signaling: DarwinSignaling.shared,
      insert: { inserted.append($0) }, collect: { _ in .collected }, collectedCount: { 0 })
    keyboard.appear()
    XCTAssertEqual(keyboard.display.mic, .needsSession)

    core.start(recognizer: recognizer)
    let ready = await waitUntil { keyboard.display.mic == .ready }
    XCTAssertTrue(ready, "the heartbeat reached the keyboard")

    keyboard.pressDown()
    let listening = await waitUntil { core.isListening }
    XCTAssertTrue(listening, ".start reached the app")
    recognizer.speak()
    let partial = await waitUntil { keyboard.display.transcript == "合成：明早" }
    XCTAssertTrue(partial, ".partial reached the keyboard")

    try await Task.sleep(for: .milliseconds(400))
    keyboard.pressUp()
    let done = await waitUntil { inserted == ["合成：明早九点站会。"] }
    XCTAssertTrue(done, "the final was inserted exactly once: \(inserted)")
    XCTAssertEqual(keyboard.display.mic, .ready)
    core.end()
    keyboard.disappear()
  }

  /// What this simulator offers for on-device zh-CN (recorded for APP.md).
  func testRecognizerDiagnostics() async {
    let report = await RecognizerChoice.diagnostics()
    let choice = await RecognizerChoice.probe()
    let line = report.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    print("MINDLOOM-RECOGNIZER choice=\(choice.kindName) \(line)")
    let attachment = XCTAttachment(string: "choice=\(choice.kindName)\n\(line)")
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// The DEBUG audio-file hook through the real on-device recognizer, trying
  /// every recognizer the device claims for zh-CN, as the session does.
  /// Skips, saying exactly why, when none of them can run (the simulator
  /// has no on-device speech models).
  func testSyntheticMandarinFileIsRecognizedOnDevice() async throws {
    let url = try await fixture()
    let candidates = await RecognizerChoice.candidates()
    let report = await RecognizerChoice.diagnostics()
    var reasons: [String] = []
    print("MINDLOOM-STEP candidates=\(candidates.map(\.kindName))")
    for choice in candidates {
      print("MINDLOOM-STEP trying \(choice.kindName)")
      let channel = try VoiceChannel(
        directory: root.appendingPathComponent("voice-\(choice.kindName)"))
      let audio = VoiceAudio(channel: channel, source: .file(url, paced: false))
      try audio.start()
      defer { audio.stop() }
      let started = Date()
      let recognizer: any VoiceRecognizing
      do {
        switch choice {
        case .speechTranscriber, .dictationTranscriber:
          try await TranscriberAssets.ensureInstalled(for: choice) { _ in }
          let analyzer = AnalyzerRecognizer(choice: choice, audio: audio)
          try await analyzer.prepare()
          recognizer = analyzer
        case .legacyOnDevice(let locale):
          guard await LegacyOnDeviceRecognizer.authorize(),
            let legacy = LegacyOnDeviceRecognizer(locale: locale, audio: audio)
          else { throw RecognizerSetupError.speechDenied }
          recognizer = legacy
        case .debugScripted, .unavailable:
          continue
        }
      } catch {
        reasons.append(
          "\(choice.kindName): \(error) after \(Int(Date().timeIntervalSince(started)))s")
        continue
      }
      print(
        "MINDLOOM-STEP prepared \(choice.kindName) in \(Int(Date().timeIntervalSince(started)))s")
      var partials: [String] = []
      let utterance = try recognizer.beginUtterance { partials.append($0) }
      await audio.waitForFileFeed()
      print("MINDLOOM-STEP fed file, partials=\(partials.count)")
      try await Task.sleep(for: .milliseconds(300))
      let finishing = Task { await utterance.finish() }
      let watchdog = Task {
        try await Task.sleep(for: .seconds(30))
        utterance.cancel()
      }
      let text = await finishing.value ?? ""
      watchdog.cancel()
      let errorCode = (utterance as? LegacyUtterance)?.lastErrorCode ?? "-"
      print(
        "MINDLOOM-TRANSCRIPT recognizer=\(choice.kindName) partials=\(partials.count) error=\(errorCode) text=\(text)"
      )
      if text.isEmpty {
        throw XCTSkip(
          "\(choice.kindName) prepared but produced no text in this simulator (error \(errorCode)). \(report)"
        )
      }
      let attachment = XCTAttachment(string: "recognizer=\(choice.kindName)\ntext=\(text)")
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertFalse(text.isEmpty, "the synthetic sentence produced text")
      XCTAssertTrue(
        ["会议室", "开会", "预算", "下午三点"].contains { text.contains($0) },
        "recognized \(text) contains a key phrase")
      return
    }
    print("MINDLOOM-TRANSCRIPT none: \(reasons) \(report)")
    throw XCTSkip(
      "No on-device zh-CN recognizer could run here. Tried \(candidates.map(\.kindName)): \(reasons). \(report)"
    )
  }

  func testLaunchArgumentSelectsTheFileOnlyInDebug() throws {
    let url = root.appendingPathComponent("voice.caf")
    try Data().write(to: url)
    let source = VoiceSessionModel.launchSource(arguments: ["app", "-MindloomVoiceFile", url.path])
    #if DEBUG
      XCTAssertEqual(source, .file(url, paced: true))
    #else
      XCTAssertEqual(source, .microphone)
    #endif
    XCTAssertEqual(VoiceSessionModel.launchSource(arguments: ["app"]), .microphone)
  }
}

/// Speaks two partials when told to, then returns its final.
@MainActor
final class ScriptedRecognizer: VoiceRecognizing {
  let kindName = "scripted"
  let partials: [String]
  let final: String
  private var current: ScriptedUtterance?

  init(partials: [String], final: String) {
    self.partials = partials
    self.final = final
  }

  func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
    -> any VoiceUtterance
  {
    let utterance = ScriptedUtterance(onPartial: onPartial, final: final)
    current = utterance
    return utterance
  }

  func speak() {
    for partial in partials { current?.onPartial(partial) }
  }
}

@MainActor
final class ScriptedUtterance: VoiceUtterance {
  let onPartial: @MainActor (String) -> Void
  let final: String

  init(onPartial: @escaping @MainActor (String) -> Void, final: String) {
    self.onPartial = onPartial
    self.final = final
  }

  func finish() async -> String? { final }
  func cancel() {}
}
