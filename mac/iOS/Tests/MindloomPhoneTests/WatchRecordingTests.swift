@preconcurrency import AVFoundation
import Foundation
import MindloomLink
import MindloomPhoneKit
import MindloomWatchHandoff
import XCTest

@testable import MindloomPhone

/// A recording in the watch's format (mono AAC, ADTS, 24 kHz) on this iPhone (WATCH-004,
/// WATCH-005): it is stored byte for byte and transcribed by the same on-device recognizers as
/// the speak bar. Synthetic speech only (the system's own voice, made at test time).
@MainActor
final class WatchRecordingTests: XCTestCase {
  private var root: URL!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The synthetic sentence re-encoded exactly as the watch records (24 kHz mono AAC in ADTS).
  private func watchFormatFixture() async throws -> URL {
    let source = try await SyntheticSpeech.makeFile(
      SyntheticSpeech.mandarinSentence, language: "zh-CN", in: root)
    let target = root.appendingPathComponent("\(WatchRecordingID.make()).aac")
    let input = try AVAudioFile(forReading: source)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000.0, AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 48_000,
    ]
    let output = try AVAudioFile(
      forWriting: target, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let converter = try XCTUnwrap(
      AVAudioConverter(from: input.processingFormat, to: output.processingFormat))
    while input.framePosition < input.length {
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096))
      try input.read(into: buffer, frameCount: 4096)
      if buffer.frameLength == 0 { break }
      let converted = try XCTUnwrap(
        AVAudioPCMBuffer(
          pcmFormat: output.processingFormat,
          frameCapacity: AVAudioFrameCount(
            Double(buffer.frameLength) * 24_000 / input.processingFormat.sampleRate) + 64))
      let given = Given()
      var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        if given.value {
          status.pointee = .noDataNow
          return nil
        }
        given.value = true
        status.pointee = .haveData
        return buffer
      }
      if let error { throw error }
      if converted.frameLength > 0 { try output.write(from: converted) }
    }
    return target
  }

  private final class Given: @unchecked Sendable {
    var value = false
  }

  func testWatchRecordingIsStoredAndTranscribedOnDevice() async throws {
    let file = try await watchFormatFixture()
    let digest = try WatchFileDigest.of(file)
    let seconds = try XCTUnwrap(
      { () -> Double? in
        let read = try? AVAudioFile(forReading: file)
        return read.map { Double($0.length) / $0.fileFormat.sampleRate }
      }())
    XCTAssertGreaterThan(seconds, 2)
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: Date().addingTimeInterval(-60), duration: seconds,
      bytes: digest.bytes, sha256: digest.sha256)
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: root))
    XCTAssertEqual(
      try inbox.accept(file: file, metadata: recording.transferMetadata), .stored(recording))
    XCTAssertEqual(
      try Data(contentsOf: inbox.audioURL(id: recording.id)), try Data(contentsOf: file))

    let started = Date()
    let outcome = await WatchTranscriber.transcribe(
      inbox.audioURL(id: recording.id), seconds: seconds)
    let elapsed = Date().timeIntervalSince(started)
    guard case .text(let text) = outcome else {
      let candidates = await RecognizerChoice.candidates().map(\.kindName)
      let report = await RecognizerChoice.diagnostics()
      print("MINDLOOM-WATCH not transcribed candidates=\(candidates) \(report)")
      throw XCTSkip(
        "No on-device zh-CN recognizer could run here (\(outcome)); candidates \(candidates), \(report)"
      )
    }
    print("MINDLOOM-WATCH transcribed seconds=\(seconds) took=\(elapsed) characters=\(text.count)")
    let attachment = XCTAttachment(
      string: "audio_seconds=\(seconds) transcribe_seconds=\(elapsed) characters=\(text.count)")
    attachment.lifetime = .keepAlways
    add(attachment)
    // Synthetic sentence: these words must come through.
    for word in ["三点", "会议室", "预算"] {
      XCTAssertTrue(text.contains(word), "\(word) missing")
    }
  }

  /// Regression (review, 10-06): the time a recognizer may take came from the watch's figure,
  /// which is 0 when the system had already stopped the recorder; a long file then got 62 s and
  /// was cut off on every try. The limit follows the file's own length.
  func testTheTimeLimitFollowsTheFileNotTheWatchsFigure() async throws {
    let file = try await watchFormatFixture()
    let length = try XCTUnwrap(WatchTranscriber.length(of: file))
    XCTAssertGreaterThan(length, 2)
    XCTAssertEqual(
      try XCTUnwrap(WatchTranscriber.timeLimit(for: file, seconds: 0)), 2 * length + 60,
      accuracy: 0.01)
    XCTAssertEqual(
      try XCTUnwrap(WatchTranscriber.timeLimit(for: file, seconds: 600)), 2 * 600 + 60)
    let cut = root.appendingPathComponent("cut.aac")
    try Data(try Data(contentsOf: file).prefix(5)).write(to: cut)
    XCTAssertNil(WatchTranscriber.timeLimit(for: cut, seconds: 30), "no frame: not audio")
    let outcome = await WatchTranscriber.transcribe(cut, seconds: 30)
    XCTAssertEqual(outcome, .unreadable)
  }

  /// Regression (review, 10-06): one original that could never be transcribed stopped every
  /// later one, for good, with 「正在转写…」 on all of them. An unreadable original is marked
  /// failed (「无法转写音频」) and the newer one behind it gets its text (the DEBUG scripted
  /// recognizer stands in, set for this process only).
  func testAnUnreadableOriginalDoesNotHoldUpANewerOne() async throws {
    let good = try await watchFormatFixture()
    let bad = root.appendingPathComponent("bad.aac")
    try Data(try Data(contentsOf: good).prefix(5)).write(to: bad)
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: root))
    var ids: [String] = []
    for (index, file) in [bad, good].enumerated() {
      let digest = try WatchFileDigest.of(file)
      let recording = WatchRecording(
        id: WatchRecordingID.make(), startedAt: Date().addingTimeInterval(Double(index - 10) * 60),
        duration: 0, bytes: digest.bytes, sha256: digest.sha256)
      _ = try inbox.accept(file: file, metadata: recording.transferMetadata)
      ids.append(recording.id)
    }
    let collector = PhoneItemCollector(
      items: try PhoneItemStore(root: root.appendingPathComponent("items")),
      outbox: try OutboxStore(root: root.appendingPathComponent("outbox")),
      pairing: PairingRecordStore(file: root.appendingPathComponent("pairing.json")),
      signaling: nil)
    let suite = "app.mindloom.phone.tests.\(UUID().uuidString)"
    let keychain = PhoneKeyKeychain(service: suite)
    defer {
      keychain.delete()
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let delivery = DeliveryService(
      collector: collector,
      pairing: PairingModel(
        recordStore: PairingRecordStore(file: root.appendingPathComponent("pairing.json")),
        keychain: keychain),
      settings: PhoneSettings(
        defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), isShared: false))
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(
      arguments.merging(["MindloomWatchScriptedText": "合成：周五前交预算表。"]) { $1 },
      forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

    let recordings = WatchRecordings(inbox: inbox, delivery: delivery)
    await recordings.finish()

    XCTAssertEqual(inbox.record(id: ids[0])?.transcription, .failed)
    XCTAssertEqual(inbox.record(id: ids[1])?.transcription, .done)
    let failed = try XCTUnwrap(collector.items.item(id: ids[0]))
    XCTAssertNil(failed.awaitingTranscription, "no longer 「正在转写…」")
    XCTAssertNil(failed.text)
    XCTAssertEqual(collector.items.item(id: ids[1])?.text, "合成：周五前交预算表。")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: inbox.root.path).filter {
        $0.hasSuffix(".aac")
      }.count, 2, "both originals are kept")

    // 「重新转写」 starts the failed one over; it fails again at once (still not audio).
    recordings.retry(id: ids[0])
    await recordings.finish()
    XCTAssertEqual(inbox.record(id: ids[0])?.transcription, .failed)
    // 「删除录音…」 removes the original and its item; the other stays.
    XCTAssertTrue(recordings.delete(id: ids[0]))
    XCTAssertNil(collector.items.item(id: ids[0]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.audioURL(id: ids[0]).path))
    XCTAssertNotNil(collector.items.item(id: ids[1]))
  }

  /// Regression (review, 10-06, WATCH-009): a restore from a backup brings back the originals and
  /// their records, not the Home items (the App Group is not in backups), and a transcribed or
  /// failed original then had no item: it could not be seen, retried or deleted. Every kept
  /// original gets its item again: a transcribed one with its text and nothing sent again, a
  /// failed one with 「无法转写音频」 (「重新转写」 and 「删除录音…」 work), and one an earlier
  /// build transcribed without keeping the text is transcribed again. A deleted one stays deleted.
  func testARestoreBringsTheHomeItemsBack() async throws {
    let good = try await watchFormatFixture()
    let notAudio = root.appendingPathComponent("not-audio.aac")
    try Data([0xFF, 0xF1, 0x50, 0x80, 0x01]).write(to: notAudio)
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: root))
    func keep(_ file: URL, minutesAgo: Double) throws -> String {
      let digest = try WatchFileDigest.of(file)
      let recording = WatchRecording(
        id: WatchRecordingID.make(), startedAt: Date().addingTimeInterval(-minutesAgo * 60),
        duration: 7, bytes: digest.bytes, sha256: digest.sha256)
      _ = try inbox.accept(file: file, metadata: recording.transferMetadata)
      return recording.id
    }
    let transcribed = try keep(good, minutesAgo: 40)
    try inbox.noteTranscribed(text: "合成：恢复前转好的一句。", id: transcribed)
    let failed = try keep(notAudio, minutesAgo: 30)
    try inbox.setTranscription(.failed, id: failed)
    let earlierBuild = try keep(good, minutesAgo: 20)
    try inbox.setTranscription(.done, id: earlierBuild)
    let deleted = try keep(notAudio, minutesAgo: 10)
    XCTAssertTrue(try inbox.delete(id: deleted))

    // The restored iPhone: its App Group (items, outbox) did not come back.
    let collector = PhoneItemCollector(
      items: try PhoneItemStore(root: root.appendingPathComponent("items")),
      outbox: try OutboxStore(root: root.appendingPathComponent("outbox")),
      pairing: PairingRecordStore(file: root.appendingPathComponent("pairing.json")),
      signaling: nil)
    XCTAssertEqual(collector.items.all(), [])
    let suite = "app.mindloom.phone.tests.\(UUID().uuidString)"
    let keychain = PhoneKeyKeychain(service: suite)
    defer {
      keychain.delete()
      UserDefaults().removePersistentDomain(forName: suite)
    }
    let delivery = DeliveryService(
      collector: collector,
      pairing: PairingModel(
        recordStore: PairingRecordStore(file: root.appendingPathComponent("pairing.json")),
        keychain: keychain),
      settings: PhoneSettings(
        defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), isShared: false))
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(
      arguments.merging(["MindloomWatchScriptedText": "合成：重新转出的一句。"]) { $1 },
      forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }

    let recordings = WatchRecordings(inbox: inbox, delivery: delivery)
    await recordings.finish()

    let restored = try XCTUnwrap(collector.items.item(id: transcribed))
    XCTAssertEqual(restored.source, .watch)
    XCTAssertEqual(restored.recordingID, transcribed)
    XCTAssertEqual(restored.text, "合成：恢复前转好的一句。")
    XCTAssertEqual(restored.entryIDs, [], "not sent again")
    XCTAssertFalse(restored.awaitingPairing, "not sent again")
    let failedItem = try XCTUnwrap(collector.items.item(id: failed))
    XCTAssertNil(failedItem.text)
    XCTAssertNil(failedItem.awaitingTranscription, "「无法转写音频」")
    let again = try XCTUnwrap(collector.items.item(id: earlierBuild))
    XCTAssertEqual(again.text, "合成：重新转出的一句。")
    XCTAssertTrue(again.awaitingPairing, "sent as usual (no Mac is paired here)")
    XCTAssertEqual(inbox.record(id: earlierBuild)?.text, "合成：重新转出的一句。")
    XCTAssertNil(collector.items.item(id: deleted), "deleted stays deleted")
    XCTAssertEqual(collector.items.all().count, 3)

    recordings.retry(id: failed)
    await recordings.finish()
    XCTAssertEqual(inbox.record(id: failed)?.transcription, .failed, "still not audio")
    XCTAssertTrue(recordings.delete(id: failed))
    XCTAssertNil(collector.items.item(id: failed))
    XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.audioURL(id: failed).path))
  }

  private func excludedFromBackup(_ url: URL) -> Bool {
    var url = URL(fileURLWithPath: url.path)
    url.removeAllCachedResourceValues()
    return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
      ?? false
  }

  /// WATCH-009: on the iPhone the originals are in the device's backups (iCloud or a computer)
  /// until device sync exists. The app's own inbox, opened at launch, is included and so is the
  /// Application Support it lives in; staging is not. An inbox an earlier build excluded is
  /// included again when opened, its originals untouched.
  func testOriginalsAreInTheIPhonesBackups() throws {
    let inbox = try XCTUnwrap(WatchRecordings.makeInbox())
    XCTAssertFalse(excludedFromBackup(inbox.root), "the app's originals are backed up")
    XCTAssertFalse(excludedFromBackup(inbox.root.deletingLastPathComponent()))
    XCTAssertTrue(excludedFromBackup(inbox.root.appendingPathComponent("tmp", isDirectory: true)))

    let earlier = WatchRecordingInbox.directory(in: root)
    try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
    let audio = earlier.appendingPathComponent("\(WatchRecordingID.make()).aac")
    try Data([0xFF, 0xF1, 0x50, 0x80]).write(to: audio)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mark = earlier
    try mark.setResourceValues(excluded)
    var markAudio = audio
    try markAudio.setResourceValues(excluded)
    XCTAssertTrue(excludedFromBackup(earlier))

    let reopened = try WatchRecordingInbox(root: earlier)
    XCTAssertFalse(excludedFromBackup(reopened.root))
    XCTAssertFalse(excludedFromBackup(audio))
    XCTAssertEqual(try Data(contentsOf: audio), Data([0xFF, 0xF1, 0x50, 0x80]))
  }
}
