import AppKit
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRMacAudio
import BestASRMacUI
import BestASRPersistence
import BestASRProcessing
import Combine
import CryptoKit
import XCTest

@testable import bestASR

final class LocalSessionAudioPlayerTests: XCTestCase {
  func testPlaybackKeyboardPolicyMatchesVoiceMemosAndLeavesOtherKeysUnclaimed() {
    XCTAssertEqual(
      HistoryPlaybackKeyboardPolicy.command(
        keyCode: 49,
        modifierRawValue: 0,
        isRepeat: false
      ),
      .togglePlayback
    )
    XCTAssertEqual(
      HistoryPlaybackKeyboardPolicy.command(
        keyCode: 123,
        modifierRawValue: NSEvent.ModifierFlags.command.rawValue,
        isRepeat: false
      ),
      .seekBackward
    )
    XCTAssertEqual(
      HistoryPlaybackKeyboardPolicy.command(
        keyCode: 124,
        modifierRawValue: NSEvent.ModifierFlags.command.rawValue,
        isRepeat: false
      ),
      .seekForward
    )
    XCTAssertNil(
      HistoryPlaybackKeyboardPolicy.command(
        keyCode: 49,
        modifierRawValue: NSEvent.ModifierFlags.command.rawValue,
        isRepeat: false
      ),
      "Command-Space belongs to the system and must not control playback."
    )
    XCTAssertNil(
      HistoryPlaybackKeyboardPolicy.command(
        keyCode: 123,
        modifierRawValue: 0,
        isRepeat: false
      ),
      "Unmodified arrows belong to list and text navigation."
    )
    XCTAssertNil(
      HistoryPlaybackKeyboardPolicy.command(
        keyCode: 49,
        modifierRawValue: 0,
        isRepeat: true
      ),
      "Holding Space must not alternate play and pause repeatedly."
    )
  }

  func testPlaybackDefaultsToThePrimaryRetainedSourceInsteadOfASilentAuxiliaryMic() {
    XCTAssertLessThan(
      DictationAppModel.historyPlaybackTrackPriority(.systemRemote),
      DictationAppModel.historyPlaybackTrackPriority(.microphoneLocal)
    )
    XCTAssertLessThan(
      DictationAppModel.historyPlaybackTrackPriority(.importedSource),
      DictationAppModel.historyPlaybackTrackPriority(.microphoneLocal)
    )
  }

  func testRetainedSourcePlayerLoadsFortyFourPointOneKilohertzMono() async throws {
    try await assertLoadableSource(
      sampleRate: 44_100,
      channelCount: 1,
      encoding: .float32LittleEndian,
      exercisePlayback: true
    )
  }

  func testRetainedSourcePlayerLoadsFortyEightKilohertzInt16Stereo() async throws {
    try await assertLoadableSource(
      sampleRate: 48_000,
      channelCount: 2,
      encoding: .int16LittleEndian,
      exercisePlayback: false
    )
  }

  private func assertLoadableSource(
    sampleRate: UInt32,
    channelCount: UInt16,
    encoding: PCMEncoding,
    exercisePlayback: Bool
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-player-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let relative = "source.pcm"
    let source = root.appendingPathComponent(relative)
    let frameCount = Int(sampleRate / 2)
    let bytesPerSample = encoding == .float32LittleEndian ? 4 : 2
    var data = Data(
      capacity: frameCount * Int(channelCount) * bytesPerSample
    )
    for frame in 0..<frameCount {
      let sample = Float(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate))) * 0.2
      for _ in 0..<channelCount {
        switch encoding {
        case .float32LittleEndian:
          var bits = sample.bitPattern.littleEndian
          withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        case .int16LittleEndian:
          var bits = UInt16(
            bitPattern: Int16(
              max(-32_768, min(32_767, Int((sample * 32_767).rounded())))
            )
          ).littleEndian
          withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
      }
    }
    try data.write(to: source)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let trackID = TrackID()
    let range = AudioRangeInput(
      sourceID: UUID(),
      trackID: trackID.rawValue,
      assetReference: relative,
      contentDigest: digest,
      monotonicStartNanoseconds: 10_000,
      monotonicEndNanoseconds: 500_010_000,
      sampleRateHertz: sampleRate,
      channelCount: channelCount
    )
    let descriptor = CaptureTrackDescriptor(
      id: trackID,
      role: .microphoneLocal,
      deviceUID: "test-device",
      sampleRateHertz: sampleRate,
      channelCount: channelCount,
      encoding: encoding,
      interleaved: true
    )
    let player = LocalSessionAudioPlayer()
    let duration = try await player.load(
      ranges: [range],
      descriptor: descriptor,
      assetRoot: root
    )
    XCTAssertEqual(duration, 0.5, accuracy: 0.000_001)
    let waveform = try await LocalWaveformSampler().sample(
      ranges: [range],
      descriptor: descriptor,
      assetRoot: root,
      binCount: 20
    )
    XCTAssertEqual(waveform.count, 20)
    XCTAssertGreaterThan(waveform.max() ?? 0, 0.9)

    guard exercisePlayback else { return }
    try await player.play()
    try await Task.sleep(for: .milliseconds(60))
    var state = await player.state()
    XCTAssertTrue(state.isPlaying)
    XCTAssertGreaterThan(state.position, 0)

    await player.pause()
    state = await player.state()
    XCTAssertFalse(state.isPlaying)
    let pausedPosition = state.position
    XCTAssertGreaterThan(pausedPosition, 0)
    try await Task.sleep(for: .milliseconds(80))
    state = await player.state()
    XCTAssertEqual(
      state.position,
      pausedPosition,
      accuracy: 0.01,
      "pausing must stop the rendered audio clock instead of advancing a UI-only timer"
    )

    try await player.seek(to: 0.25)
    state = await player.state()
    XCTAssertEqual(state.position, 0.25, accuracy: 0.02)
    try await player.play()
    try await Task.sleep(for: .milliseconds(40))
    state = await player.state()
    XCTAssertTrue(state.isPlaying)
    XCTAssertGreaterThan(state.position, 0.25)

    await player.pause()
    try await player.seek(to: duration)
    try await player.play()
    try await Task.sleep(for: .milliseconds(30))
    state = await player.state()
    XCTAssertTrue(state.isPlaying)
    XCTAssertLessThan(state.position, 0.2, "playing from the end must replay")

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while state.isPlaying, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      state = await player.state()
    }
    XCTAssertFalse(state.isPlaying, "natural completion must stop playback")
    XCTAssertEqual(state.position, duration, accuracy: 0.001)
    try await player.play()
    try await Task.sleep(for: .milliseconds(60))
    state = await player.state()
    XCTAssertTrue(state.isPlaying)
    XCTAssertGreaterThan(state.position, 0)
    XCTAssertLessThan(
      state.position, 0.2,
      "replaying after natural completion must reset the node's rendered audio clock"
    )
    await player.stop()
  }
}

final class TranscriptProvenanceExportTests: XCTestCase {
  private let sessionID = SessionID(UUID())
  private let speakerA = SessionSpeakerID(UUID())
  private let speakerB = SessionSpeakerID(UUID())

  private func occurrence(
    _ speaker: SessionSpeakerID,
    _ start: UInt64,
    _ end: UInt64,
    status: PersonAssociationStatus = .userConfirmed
  ) -> SpeakerOccurrenceSummary {
    SpeakerOccurrenceSummary(
      id: SpeakerOccurrenceID(UUID()), sessionID: sessionID,
      sessionSpeakerID: speaker, stableOrdinal: speaker == speakerA ? 1 : 2,
      monotonicStartNanoseconds: start, monotonicEndNanoseconds: end,
      personID: PersonID(UUID()), personDisplayName: speaker == speakerA ? "甲" : "乙",
      associationStatus: status
    )
  }

  private func segment(_ start: UInt64, _ end: UInt64, text: String = "测试")
    -> DictationTranscriptSegment
  {
    DictationTranscriptSegment(
      id: UUID(), monotonicStartNanoseconds: start,
      monotonicEndNanoseconds: end, text: text, confidence: 0.9
    )
  }

  private func transcript(
    kind: TranscriptRevisionKind,
    parent: TranscriptRevisionID? = nil,
    text: String,
    segments: [DictationTranscriptSegment]
  ) -> DictationPersistedTranscriptRecord {
    DictationPersistedTranscriptRecord(
      id: TranscriptRevisionID(UUID()), sessionID: sessionID,
      inputRevision: kind == .userEdit ? 2 : 1, parentID: parent,
      kind: kind, content: text, modelArtifactID: "fixture-asr", configHash: nil,
      languageHints: ["zh-CN"], audioRanges: [], segments: segments,
      createdAt: Date(timeIntervalSince1970: kind == .userEdit ? 200 : 100)
    )
  }

  func testSpeakerCoverageSurvivesMidpointSilenceAndSumsRepeatedTurns() {
    let phrase = segment(0, 100)
    let separated = [occurrence(speakerA, 0, 40), occurrence(speakerA, 60, 100)]
    XCTAssertEqual(
      TranscriptSpeakerSelection.occurrence(for: phrase, in: separated)?.sessionSpeakerID,
      speakerA
    )
    let repeated = [
      occurrence(speakerA, 0, 20), occurrence(speakerB, 20, 60),
      occurrence(speakerA, 60, 85),
    ]
    XCTAssertEqual(
      TranscriptSpeakerSelection.occurrence(for: phrase, in: repeated)?.sessionSpeakerID,
      speakerA,
      "two turns by the same speaker outweigh a single longer turn by another speaker"
    )
  }

  func testSpeakerCoverageDoesNotDoubleCountOrForceAmbiguousAttribution() {
    let phrase = segment(0, 100)
    XCTAssertEqual(
      TranscriptSpeakerSelection.occurrence(
        for: phrase,
        in: [
          occurrence(speakerA, 0, 30), occurrence(speakerA, 0, 30),
          occurrence(speakerB, 30, 70),
        ]
      )?.sessionSpeakerID,
      speakerB
    )
    XCTAssertNil(
      TranscriptSpeakerSelection.occurrence(
        for: phrase, in: [occurrence(speakerA, 0, 50), occurrence(speakerB, 50, 100)]
      )
    )
    XCTAssertNil(
      TranscriptSpeakerSelection.occurrence(for: phrase, in: [occurrence(speakerA, 120, 150)])
    )
  }

  func testOriginalRecognitionFollowsTheEditParentChain() {
    let source = transcript(kind: .final, text: "识别原文", segments: [])
    let edit = transcript(kind: .userEdit, parent: source.id, text: "第一次校对", segments: [])
    let secondEdit = transcript(kind: .userEdit, parent: edit.id, text: "第二次校对", segments: [])
    let unrelated = transcript(kind: .final, text: "别的识别版本", segments: [])
    XCTAssertEqual(
      TranscriptSelection.recognitionSource(
        for: secondEdit, in: [unrelated, secondEdit, edit, source]
      )?.id,
      source.id
    )
    XCTAssertNil(
      TranscriptSelection.recognitionSource(for: secondEdit, in: [secondEdit, unrelated]),
      "a missing parent must not relabel current corrections as original ASR"
    )
  }

  func testExportsKeepCorrectionsOriginalTextAndSpeakerUncertaintyDistinct() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-export-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = transcript(kind: .final, text: "原来的识别文字", segments: [])
    let edited = transcript(
      kind: .userEdit, parent: source.id, text: "校对甲。校对乙。",
      segments: [
        segment(0, 5_220_000_000, text: "校对甲。"),
        segment(6_420_000_000, 12_140_000_000, text: "校对乙。"),
      ]
    )
    let history = DictationHistoryItem(
      sessionID: sessionID, inputMode: .importedMedia, revision: 2,
      phase: .completed, status: .completed, rawText: edited.content,
      polishedText: nil, failureCode: nil, canRetry: false,
      sourceAudioRetained: true, createdAt: source.createdAt,
      updatedAt: edited.createdAt, recoveredAt: nil
    )
    let occurrences = [
      occurrence(speakerA, 0, 2_495_812_500),
      occurrence(speakerA, 2_971_125_000, 5_076_437_500),
      occurrence(speakerB, 6_536_500_000, 12_003_437_500, status: .candidate),
    ]
    let speakers = [speakerA, speakerB].map { speaker in
      SessionSpeakerSummary(
        id: speaker, stableOrdinal: speaker == speakerA ? 1 : 2,
        personID: nil, displayName: speaker == speakerA ? "甲" : "乙",
        associationStatus: speaker == speakerA ? .userConfirmed : .candidate,
        confidence: nil, speechDurationNanoseconds: 4_000_000_000, occurrenceCount: 2
      )
    }
    let context = LocalHistoryExportContext(
      history: history, transcripts: [source, edited], documents: [],
      speakers: speakers, occurrences: occurrences
    )
    let exporter = LocalHistoryExporter()
    for format in [LocalHistoryExportFormat.plainText, .markdown, .srt, .vtt] {
      let destination = root.appendingPathComponent("transcript.\(format.rawValue)")
      try await exporter.exportText(format: format, context: context, to: destination)
      let exported = try String(contentsOf: destination, encoding: .utf8)
      switch format {
      case .plainText:
        XCTAssertEqual(exported, edited.content + "\n")
      case .markdown:
        XCTAssertTrue(exported.contains("## 校对稿\n\n" + edited.content))
        XCTAssertTrue(exported.contains("## 原始识别\n\n" + source.content))
        XCTAssertTrue(exported.contains("**甲**：校对甲。"))
        XCTAssertTrue(exported.contains("**可能是 乙**：校对乙。"))
      case .srt, .vtt:
        XCTAssertTrue(exported.contains("[甲] 校对甲。"))
        XCTAssertTrue(exported.contains("[可能是 乙] 校对乙。"))
        XCTAssertFalse(exported.contains("原来的识别文字"))
      default:
        XCTFail("unexpected fixture export format")
      }
    }
  }
}

final class ImportPauseIntentTests: XCTestCase {
  func testPauseRequestedDuringPreparationAppliesWhenDecodeBecomesActive() {
    var intent = ImportPauseIntent()

    XCTAssertEqual(intent.action(for: .preparing), .none)
    XCTAssertTrue(intent.toggle())
    XCTAssertEqual(intent.action(for: .preparing), .waitForPreparation)
    XCTAssertEqual(intent.action(for: .recording), .pause)
    XCTAssertEqual(intent.action(for: .paused), .none)

    XCTAssertFalse(intent.toggle())
    XCTAssertEqual(intent.action(for: .paused), .resume)
  }

  func testPauseIsUnavailableAfterSourceAudioLeavesTheDecodeStage() {
    var intent = ImportPauseIntent()
    intent.setPaused(true)

    for phase in [
      DictationPhase.finalizing,
      .recognizing,
      .polishing,
      .inserting,
      .completed,
      .failedRecoverable,
    ] {
      XCTAssertEqual(intent.action(for: phase), .unavailable)
    }

    intent.reset()
    XCTAssertFalse(intent.wantsPaused)
  }
}

final class CaptureLifecycleCommandStateTests: XCTestCase {
  func testSameModeIntentIsQueuedAndTheLatestExplicitCommandWins() {
    var state = CaptureLifecycleCommandState()

    XCTAssertTrue(state.begin(.roomRecording, action: .start))
    XCTAssertFalse(state.begin(.systemAudio, action: .start))
    XCTAssertFalse(state.queueIfInFlight(.cancel, for: .systemAudio))
    XCTAssertTrue(state.queueIfInFlight(.pauseOrResume, for: .roomRecording))
    XCTAssertTrue(state.queueIfInFlight(.end, for: .roomRecording))
    XCTAssertEqual(state.finish(.roomRecording), .end)
    XCTAssertNil(state.inFlightMode)
    XCTAssertNil(state.finish(.roomRecording))
  }

  func testAPressWhileSealingStartsTheNextDictationInsteadOfEndingAgain() {
    // While the previous dictation seals, the press starts the next one.
    XCTAssertEqual(DictationAppModel.inFlightDictationAction(inFlight: .end), .start)
    // While a start is still in flight it still means "stop this dictation",
    // which is what a quick press-and-release does.
    XCTAssertEqual(DictationAppModel.inFlightDictationAction(inFlight: .start), .end)
    XCTAssertEqual(DictationAppModel.inFlightDictationAction(inFlight: nil), .end)

    var state = CaptureLifecycleCommandState()
    XCTAssertTrue(state.begin(.dictation, action: .end))
    XCTAssertEqual(state.inFlightAction, .end)
    XCTAssertTrue(state.queueIfInFlight(.start, for: .dictation))
    XCTAssertEqual(state.finish(.dictation), .start)
    XCTAssertNil(state.inFlightAction)
  }

  func testTheNextDictationMayStartWhileTheLastOneIsStillBeingRecognized() {
    let finishing = SessionID()
    // Sealed and handed to the background: the microphone is free again.
    for phase in [DictationPhase.finalizing, .recognizing] {
      XCTAssertTrue(
        DictationAppModel.canStartDictation(
          phase: phase, sessionID: finishing, finalizingInBackground: [finishing]))
      // The same phase without a handoff is still a dictation in progress.
      XCTAssertFalse(
        DictationAppModel.canStartDictation(
          phase: phase, sessionID: finishing, finalizingInBackground: []))
    }
    // Still recording: the key press means "stop", never "start another".
    XCTAssertFalse(
      DictationAppModel.canStartDictation(
        phase: .recording, sessionID: finishing, finalizingInBackground: [finishing]))
    XCTAssertTrue(
      DictationAppModel.canStartDictation(
        phase: .completed, sessionID: finishing, finalizingInBackground: []))
  }

  func testHistoryIsReadBackOnlyWhenSomeoneCanSeeItAndTheBurstIsOver() {
    // Dictating into another application: nothing on screen shows history.
    XCTAssertFalse(
      DictationAppModel.readsHistoryBackNow(historyOnScreen: false, dictationsStillFinishing: 0))
    // Mid-burst: the next dictation is about to replace this reading anyway.
    XCTAssertFalse(
      DictationAppModel.readsHistoryBackNow(historyOnScreen: true, dictationsStillFinishing: 1))
    XCTAssertTrue(
      DictationAppModel.readsHistoryBackNow(historyOnScreen: true, dictationsStillFinishing: 0))
  }

  func testPreparingCaptureSnapshotImmediatelyExposesSafeControls() throws {
    let sessionID = SessionID(
      UUID(uuidString: "D4000000-0000-4000-8000-000000000020")!
    )

    let snapshot = DictationAppModel.preparingCaptureSnapshot(
      sessionID: sessionID,
      now: 42
    )

    XCTAssertEqual(snapshot.sessionID, sessionID)
    XCTAssertEqual(snapshot.phase, .preparing)
    XCTAssertTrue(snapshot.phase.isActive)
    XCTAssertEqual(snapshot.timeline.last?.kind, .started)
    XCTAssertEqual(snapshot.timeline.last?.monotonicNanoseconds, 42)
    try snapshot.validate()
  }
}

@MainActor
final class ImportPresentationWindowTests: XCTestCase {
  func testInactiveWorkspaceRemainsTheChooserParent() {
    let window = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 220, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.title = "bestASR 自动测试（完成即关闭）"
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.orderFront(nil)
    let utility = NSPanel()
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(
      DictationAppModel.importPresentationWindow(
        keyWindow: nil, mainWindow: nil, windows: [utility, window]
      ) === window
    )
    XCTAssertTrue(
      DictationAppModel.importPresentationWindow(
        keyWindow: utility, mainWindow: nil, windows: [window]
      ) === window
    )
  }

  func testClosedWorkspaceIsNotReopenedForAChooser() {
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    XCTAssertNil(
      DictationAppModel.importPresentationWindow(
        keyWindow: nil, mainWindow: nil, windows: [window]
      )
    )
  }
}

@MainActor
final class MemoryDocumentPresentationTests: XCTestCase {
  func testStructuredItemsDoNotRepeatTheirGeneratedBulletBody() {
    XCTAssertNil(
      MemoryDocumentPresentation.distinctBody(
        "• 保留原音。\n• 校对文字。", itemTexts: ["保留原音。", "校对文字。"]
      ))
    XCTAssertNil(
      MemoryDocumentPresentation.distinctBody(
        "1. Keep the source.\n2. Correct the transcript.",
        itemTexts: ["Keep the source.", "Correct the transcript."]
      ))
  }

  func testSeparateNarrativeAndUserEditsAreNeverHidden() {
    let body = "结论：版本 1.2。\n负责人：甲。\n• 保留原音。"
    XCTAssertEqual(
      MemoryDocumentPresentation.distinctBody(body, itemTexts: ["保留原音。"]), body
    )
    XCTAssertEqual(
      MemoryDocumentPresentation.distinctBody("人工补充说明", itemTexts: []), "人工补充说明"
    )
  }
}

@MainActor
final class MemoryOperationFeedbackTests: XCTestCase {
  func testEventCreateRenameMergeAndUndoKeepTheirCompletionFeedback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("memory-feedback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let model = DictationAppModel(preview: true, memoryRepository: store)
    model.events.newEventTitleDraft = "Synthetic event A"
    model.createEventFromSelection()
    try await settle { model.events.eventStatusMessage.hasPrefix("事件已建立") }
    let firstID = try XCTUnwrap(model.events.selectedEventID)
    model.beginNewEvent()
    model.events.newEventTitleDraft = "Synthetic event B"
    model.createEventFromSelection()
    try await settle { model.events.eventStatusMessage.hasPrefix("事件已建立") }
    model.events.titleDraft = "Renamed synthetic event"
    model.saveEventDraft()
    try await settle { model.events.eventStatusMessage == "事件名称和备注已保存在本机" }
    model.events.mergeTargetEventID = firstID
    model.mergeSelectedEvent()
    try await settle { model.events.eventStatusMessage.hasPrefix("事件已合并") }
    XCTAssertEqual(model.events.summaries.count, 1)
    model.undoLastEventEdit()
    try await settle { model.events.eventStatusMessage == "最近一次事件修改已撤销" }
    XCTAssertEqual(model.events.summaries.count, 2)
    try await store.checkpointAndClose()
  }

  func testPersonRenameMergeAndUndoKeepTheirCompletionFeedback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("person-feedback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let firstID = PersonID(UUID())
    let secondID = PersonID(UUID())
    try await store.ensureLocalSelfPerson(personID: firstID)
    try await store.ensureLocalSelfPerson(personID: secondID)
    let people = try await store.personSummaries()
    let model = DictationAppModel(preview: true, memoryRepository: store)
    model.beginEditingPerson(try XCTUnwrap(people.first { $0.id == firstID }))
    model.people.personNameDraft = "Synthetic person A"
    model.savePersonDraft()
    try await settle { model.people.peopleStatusMessage == "人物名称和别名已保存" }
    model.people.mergeTargetPersonID = secondID
    model.mergeSelectedPerson()
    try await settle { model.people.peopleStatusMessage == "人物已合并；可以使用撤销恢复" }
    XCTAssertEqual(model.people.personSummaries.count, 1)
    model.undoLastPersonEdit()
    try await settle { model.people.peopleStatusMessage == "最近一次人物修改已撤销" }
    XCTAssertEqual(model.people.personSummaries.count, 2)
    try await store.checkpointAndClose()
  }

  private func settle(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(predicate(), "Successful writes must not be replaced by ordinary count feedback.")
  }
}

final class LocalEventOrganizerTests: XCTestCase {
  func testEventTitleAndGenericAcknowledgmentsCannotOverrideSourceEvidence() async throws {
    let organizer = LocalEventOrganizer()
    let date = Date(timeIntervalSince1970: 9_000)
    let eventID = EventID(UUID())
    let personID = PersonID(UUID())
    let existingID = SessionID(UUID())
    let source = EventOrganizationSession(
      sessionID: existingID, title: "录音检查",
      semanticText: "音频输入设备和逐字稿时间戳正在校验，需要能够回放原始声音。",
      createdAt: date, updatedAt: date, inputMode: "roomMicrophone",
      sourceIdentifier: "same-meeting-app", sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID], currentEventIDs: [eventID], rejectedEventIDs: []
    )
    let event = EventSummary(
      event: MemoryEvent(
        id: eventID, revision: try Revision(1), title: "采购发票预算与报销审批",
        startAt: date, endAt: date, titleIsUserEdited: true,
        createdAt: date, updatedAt: date
      ),
      sessionIDs: [existingID], personIDs: [personID], personDisplayNames: ["甲"],
      inputModes: ["roomMicrophone"], pendingCandidateCount: 0
    )
    for text in ["好的，明白了，就按这个来。", "采购发票预算与报销审批"] {
      let unrelated = EventOrganizationSession(
        sessionID: SessionID(UUID()), title: text, semanticText: text,
        createdAt: date, updatedAt: date, inputMode: "roomMicrophone",
        sourceIdentifier: "same-meeting-app", sourceBundleIdentifier: "com.example.meeting",
        personIDs: [personID], currentEventIDs: [], rejectedEventIDs: []
      )
      let result = await organizer.organize(sessions: [source, unrelated], events: [event])
      XCTAssertTrue(result.automaticLinks.isEmpty)
      XCTAssertTrue(result.candidates.isEmpty)
    }
  }

  func testGenericAcknowledgmentsDoNotCreateAnEventTogether() async throws {
    let organizer = LocalEventOrganizer()
    let date = Date(timeIntervalSince1970: 9_000)
    let sessions = ["好的，谢谢，我们明天继续。", "明白了，好的，谢谢。"].map { text in
      EventOrganizationSession(
        sessionID: SessionID(UUID()), title: "口述", semanticText: text,
        createdAt: date, updatedAt: date, inputMode: "dictation",
        sourceIdentifier: nil, sourceBundleIdentifier: nil,
        personIDs: [], currentEventIDs: [], rejectedEventIDs: []
      )
    }
    let result = await organizer.organize(sessions: sessions, events: [])
    XCTAssertTrue(result.automaticLinks.isEmpty)
    XCTAssertTrue(result.candidates.isEmpty)
  }

  func testHighConfidenceLocalEvidenceAutoLinksWithoutSuggestingAnUnrelatedEvent()
    async throws
  {
    let organizer = LocalEventOrganizer()
    let personID = PersonID(UUID(uuidString: "70000000-0000-4000-8000-000000000001")!)
    let existingSessionID = SessionID(UUID(uuidString: "70000000-0000-4000-8000-000000000002")!)
    let matchingSessionID = SessionID(UUID(uuidString: "70000000-0000-4000-8000-000000000003")!)
    let unrelatedSessionID = SessionID(UUID(uuidString: "70000000-0000-4000-8000-000000000004")!)
    let eventID = EventID(UUID(uuidString: "70000000-0000-4000-8000-000000000005")!)
    let date = Date(timeIntervalSince1970: 10_000)
    let existing = EventOrganizationSession(
      sessionID: existingSessionID,
      title: "Aurora roadmap",
      semanticText: "Aurora roadmap milestones budget and launch plan",
      createdAt: date,
      updatedAt: date,
      inputMode: "roomMicrophone",
      sourceIdentifier: "meeting-aurora",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [eventID],
      rejectedEventIDs: []
    )
    let matching = EventOrganizationSession(
      sessionID: matchingSessionID,
      title: "Aurora roadmap follow-up",
      semanticText: "Aurora roadmap milestones budget and launch plan",
      createdAt: date.addingTimeInterval(600),
      updatedAt: date.addingTimeInterval(600),
      inputMode: "roomMicrophone",
      sourceIdentifier: "meeting-aurora",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [],
      rejectedEventIDs: []
    )
    let unrelated = EventOrganizationSession(
      sessionID: unrelatedSessionID,
      title: "Grocery reminder",
      semanticText: "buy fruit and coffee after work",
      createdAt: date.addingTimeInterval(90 * 24 * 60 * 60),
      updatedAt: date.addingTimeInterval(90 * 24 * 60 * 60),
      inputMode: "dictation",
      sourceIdentifier: nil,
      sourceBundleIdentifier: nil,
      personIDs: [],
      currentEventIDs: [],
      rejectedEventIDs: []
    )
    let event = EventSummary(
      event: MemoryEvent(
        id: eventID,
        revision: try Revision(1),
        title: "Aurora roadmap",
        startAt: date,
        endAt: date,
        titleIsUserEdited: true,
        createdAt: date,
        updatedAt: date
      ),
      sessionIDs: [existingSessionID],
      personIDs: [personID],
      personDisplayNames: ["Alex"],
      inputModes: ["roomMicrophone"],
      pendingCandidateCount: 0
    )

    let result = await organizer.organize(
      sessions: [existing, matching, unrelated],
      events: [event],
      now: date
    )

    XCTAssertEqual(result.automaticLinks.map(\.sessionID), [matchingSessionID])
    XCTAssertEqual(result.automaticLinks.first?.eventID, eventID)
    XCTAssertTrue(result.candidates.isEmpty)
  }

  func testManualEventRejectionPreventsAutomaticRelinking() async throws {
    let organizer = LocalEventOrganizer()
    let personID = PersonID(
      UUID(uuidString: "71000000-0000-4000-8000-000000000001")!
    )
    let existingSessionID = SessionID(
      UUID(uuidString: "71000000-0000-4000-8000-000000000002")!
    )
    let rejectedSessionID = SessionID(
      UUID(uuidString: "71000000-0000-4000-8000-000000000003")!
    )
    let eventID = EventID(
      UUID(uuidString: "71000000-0000-4000-8000-000000000004")!
    )
    let date = Date(timeIntervalSince1970: 20_000)
    let existing = EventOrganizationSession(
      sessionID: existingSessionID,
      title: "Launch review",
      semanticText: "launch review milestones and customer rollout",
      createdAt: date,
      updatedAt: date,
      inputMode: "roomMicrophone",
      sourceIdentifier: "launch-review",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [eventID],
      rejectedEventIDs: []
    )
    let rejected = EventOrganizationSession(
      sessionID: rejectedSessionID,
      title: "Launch review follow-up",
      semanticText: "launch review milestones and customer rollout",
      createdAt: date.addingTimeInterval(60),
      updatedAt: date.addingTimeInterval(60),
      inputMode: "roomMicrophone",
      sourceIdentifier: "launch-review",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [],
      rejectedEventIDs: [eventID]
    )
    let event = EventSummary(
      event: MemoryEvent(
        id: eventID,
        revision: try Revision(1),
        title: "Launch review",
        startAt: date,
        endAt: date,
        titleIsUserEdited: true,
        createdAt: date,
        updatedAt: date
      ),
      sessionIDs: [existingSessionID],
      personIDs: [personID],
      personDisplayNames: ["Alex"],
      inputModes: ["roomMicrophone"],
      pendingCandidateCount: 0
    )

    let result = await organizer.organize(
      sessions: [existing, rejected],
      events: [event],
      now: date
    )

    XCTAssertTrue(result.automaticLinks.isEmpty)
    XCTAssertTrue(result.candidates.isEmpty)
  }

  func testTwoCorroboratedUnassignedRecordingsSuggestOneNewEvent() async throws {
    let organizer = LocalEventOrganizer()
    let personID = PersonID(
      UUID(uuidString: "71500000-0000-4000-8000-000000000001")!
    )
    let firstID = SessionID(
      UUID(uuidString: "71500000-0000-4000-8000-000000000002")!
    )
    let secondID = SessionID(
      UUID(uuidString: "71500000-0000-4000-8000-000000000003")!
    )
    let unrelatedID = SessionID(
      UUID(uuidString: "71500000-0000-4000-8000-000000000004")!
    )
    let date = Date(timeIntervalSince1970: 25_000)
    let first = EventOrganizationSession(
      sessionID: firstID,
      title: "Orion migration review",
      semanticText: "Orion migration rollout blockers owners and customer schedule",
      createdAt: date,
      updatedAt: date,
      inputMode: "roomMicrophone",
      sourceIdentifier: "orion-room",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [],
      rejectedEventIDs: []
    )
    let second = EventOrganizationSession(
      sessionID: secondID,
      title: "Orion migration follow-up",
      semanticText: "Orion migration rollout blockers owners and customer schedule",
      createdAt: date.addingTimeInterval(600),
      updatedAt: date.addingTimeInterval(600),
      inputMode: "systemAudio",
      sourceIdentifier: "orion-room",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [],
      rejectedEventIDs: []
    )
    let unrelated = EventOrganizationSession(
      sessionID: unrelatedID,
      title: "Coffee reminder",
      semanticText: "buy coffee filters tomorrow",
      createdAt: date.addingTimeInterval(900),
      updatedAt: date.addingTimeInterval(900),
      inputMode: "dictation",
      sourceIdentifier: nil,
      sourceBundleIdentifier: nil,
      personIDs: [],
      currentEventIDs: [],
      rejectedEventIDs: []
    )

    let result = await organizer.organize(
      sessions: [first, second, unrelated],
      events: [],
      now: date
    )

    XCTAssertTrue(result.automaticLinks.isEmpty)
    XCTAssertEqual(result.candidates.count, 1)
    let candidate = try XCTUnwrap(result.candidates.first)
    XCTAssertEqual(candidate.sessionID, firstID)
    XCTAssertNil(candidate.candidateEventID)
    XCTAssertEqual(candidate.proposedTitle, "Orion migration review")
    XCTAssertGreaterThanOrEqual(candidate.evidence.semanticScore, 0.58)
  }

  func testConversationalRecordingTitleBecomesScannableEventTopic() {
    let session = EventOrganizationSession(
      sessionID: SessionID(
        UUID(uuidString: "71600000-0000-4000-8000-000000000001")!
      ),
      title: "我想讨论一下全局快捷键与输入框焦点冲突的问题以及录音启动后的交互方案",
      semanticText: "我想讨论一下全局快捷键与输入框焦点冲突的问题，以及录音启动后的交互方案。",
      createdAt: Date(timeIntervalSince1970: 26_000),
      updatedAt: Date(timeIntervalSince1970: 26_000),
      inputMode: "dictation",
      sourceIdentifier: nil,
      sourceBundleIdentifier: nil,
      personIDs: [],
      currentEventIDs: [],
      rejectedEventIDs: []
    )

    let proposed = LocalEventOrganizer.proposedTitle(for: session)

    XCTAssertLessThanOrEqual(proposed.count, 18)
    XCTAssertTrue(proposed.contains("快捷键"))
    XCTAssertTrue(proposed.contains("冲突"))
    XCTAssertFalse(proposed.contains("我想讨论一下"))
    XCTAssertFalse(proposed.contains("。"))
  }

  func testSemanticEvidenceAfterEightThousandCharactersStillFindsEvent()
    async throws
  {
    let organizer = LocalEventOrganizer()
    let personID = PersonID(
      UUID(uuidString: "72000000-0000-4000-8000-000000000001")!
    )
    let existingSessionID = SessionID(
      UUID(uuidString: "72000000-0000-4000-8000-000000000002")!
    )
    let longSessionID = SessionID(
      UUID(uuidString: "72000000-0000-4000-8000-000000000003")!
    )
    let eventID = EventID(
      UUID(uuidString: "72000000-0000-4000-8000-000000000004")!
    )
    let date = Date(timeIntervalSince1970: 30_000)
    let topic = "nebula customer migration launch schedule ownership"
    let existing = EventOrganizationSession(
      sessionID: existingSessionID,
      title: "Nebula launch",
      semanticText: topic,
      createdAt: date,
      updatedAt: date,
      inputMode: "roomMicrophone",
      sourceIdentifier: "nebula-review",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [eventID],
      rejectedEventIDs: []
    )
    let longRecording = EventOrganizationSession(
      sessionID: longSessionID,
      title: "Long meeting",
      semanticText: String(repeating: "noise ", count: 1_600) + topic,
      createdAt: date.addingTimeInterval(120),
      updatedAt: date.addingTimeInterval(120),
      inputMode: "roomMicrophone",
      sourceIdentifier: "nebula-review",
      sourceBundleIdentifier: "com.example.meeting",
      personIDs: [personID],
      currentEventIDs: [],
      rejectedEventIDs: []
    )
    let event = EventSummary(
      event: MemoryEvent(
        id: eventID,
        revision: try Revision(1),
        title: "Nebula launch",
        startAt: date,
        endAt: date,
        titleIsUserEdited: true,
        createdAt: date,
        updatedAt: date
      ),
      sessionIDs: [existingSessionID],
      personIDs: [personID],
      personDisplayNames: ["Alex"],
      inputModes: ["roomMicrophone"],
      pendingCandidateCount: 0
    )

    let result = await organizer.organize(
      sessions: [existing, longRecording],
      events: [event],
      now: date
    )

    let proposed = try XCTUnwrap(
      result.candidates.first(where: { $0.sessionID == longSessionID })
    )
    XCTAssertEqual(proposed.candidateEventID, eventID)
    XCTAssertGreaterThan(proposed.evidence.semanticScore, 0.52)
  }
}

private actor HierarchicalLocalTextFixtureEngine: LocalTextEngine {
  private var receivedRequests: [LocalTextRequest] = []

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(
      artifact: ModelArtifactDescriptor(
        artifactID: "fixture-local-text",
        version: "1",
        sha256: String(repeating: "a", count: 64),
        runtimeID: InferenceRuntimeID("fixture-runtime"),
        capabilities: [.localTextStructured],
        minimumOS: InferenceOSVersion(major: 14, minor: 2),
        supportedArchitectures: ["arm64"],
        minimumUnifiedMemoryBytes: 0,
        licenseIdentifier: "fixture",
        networkRequired: false
      )
    )
  }

  func generate(_ request: LocalTextRequest) async throws -> LocalTextResult {
    receivedRequests.append(request)
    let itemID = UUID(
      uuidString: String(
        format: "73000000-0000-4000-8000-%012llx",
        receivedRequests.count
      )
    )!
    return LocalTextResult(
      modelArtifactID: "fixture-local-text",
      taskID: request.taskID,
      outputText: "本轮完整整理",
      claims: [],
      structuredItems: [
        LocalTextStructuredItem(
          itemID: itemID,
          kind: .summaryPoint,
          text: "本轮覆盖 \(request.sourceSegmentIDs.count) 个证据节点",
          owner: nil,
          sourceSegmentIDs: request.sourceSegmentIDs,
          confidence: 0.99,
          disposition: .supported
        )
      ]
    )
  }

  func requests() -> [LocalTextRequest] {
    receivedRequests
  }
}

final class HierarchicalLocalTextTests: XCTestCase {
  func testEventMetadataStaysSeparateFromCurrentTranscriptEvidence() async throws {
    let engine = HierarchicalLocalTextFixtureEngine()
    let sourceID = UUID()
    _ = try await LocalDictationRuntime.generateHierarchicalLocalText(
      engine: engine,
      taskID: .structuredSummary,
      transcriptRevisionID: UUID(),
      inputRevision: 1,
      namespace: "event-context-regression",
      configHash: String(repeating: "b", count: 64),
      nodes: [
        LocalTextEvidenceNode(
          id: UUID(),
          text: "用户校对后的原话。",
          sourceSegmentIDs: [sourceID],
          context: "来源：文件导入；录制时间：2026-08-29"
        )
      ]
    )
    let requests = await engine.requests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.sourceText, "[S1] 用户校对后的原话。")
    XCTAssertEqual(request.sourceContext, "[S1] 来源：文件导入；录制时间：2026-08-29")
    XCTAssertFalse(request.sourceText.contains("2026-08-29"))
  }

  func testEventDocumentIdentityTracksSourceRevisionsAndSpeakerContext() throws {
    let eventID = EventID()
    let sessionID = SessionID()
    let sourceID = TranscriptRevisionID()
    let segmentID = UUID()
    let firstReference = EventTextSourceReference(
      sessionID: sessionID,
      transcriptRevisionID: sourceID,
      sourceRevision: try Revision(1),
      segmentIDs: [segmentID]
    )
    let correctedReference = EventTextSourceReference(
      sessionID: sessionID,
      transcriptRevisionID: TranscriptRevisionID(),
      sourceRevision: try Revision(2),
      segmentIDs: [segmentID]
    )
    func identity(_ reference: EventTextSourceReference, context: String = "speaker A") throws
      -> UUID
    {
      LocalDictationRuntime.eventTextDocumentID(
        eventID: eventID,
        eventRevision: try Revision(1),
        taskID: .structuredSummary,
        configHash: String(repeating: "b", count: 64),
        references: [reference],
        contexts: [context]
      )
    }
    let initial = try identity(firstReference)
    XCTAssertEqual(initial, try identity(firstReference))
    XCTAssertNotEqual(initial, try identity(correctedReference))
    XCTAssertNotEqual(initial, try identity(firstReference, context: "confirmed speaker B"))
  }

  func testLongSessionProcessesEverySegmentAndRestoresOriginalProvenance()
    async throws
  {
    let engine = HierarchicalLocalTextFixtureEngine()
    let nodes = (0..<220).map { index in
      let sourceID = UUID(
        uuidString: String(
          format: "74000000-0000-4000-8000-%012llx",
          index + 1
        )
      )!
      return LocalTextEvidenceNode(
        id: UUID(
          uuidString: String(
            format: "75000000-0000-4000-8000-%012llx",
            index + 1
          )
        )!,
        text: "第 \(index + 1) 段完整证据，必须参与本地层级整理。",
        sourceSegmentIDs: [sourceID],
        context: "LOCAL_METADATA_\(index + 1) " + String(repeating: "context ", count: 40)
      )
    }

    let result = try await LocalDictationRuntime.generateHierarchicalLocalText(
      engine: engine,
      taskID: .structuredSummary,
      transcriptRevisionID: UUID(
        uuidString: "76000000-0000-4000-8000-000000000001"
      )!,
      inputRevision: 1,
      namespace: "hierarchical-test",
      configHash: String(repeating: "b", count: 64),
      nodes: nodes
    )

    let requests = await engine.requests()
    XCTAssertGreaterThan(requests.count, 1)
    XCTAssertTrue(
      requests.allSatisfy {
        $0.sourceText.utf8.count + ($0.sourceContext?.utf8.count ?? 0) <= 16_384
          && !$0.sourceText.contains("LOCAL_METADATA_")
      })
    XCTAssertGreaterThan(Set(requests.dropLast().flatMap(\.sourceSegmentIDs)).count, 200)
    XCTAssertEqual(
      result.structuredItems.first?.sourceSegmentIDs,
      nodes.flatMap(\.sourceSegmentIDs)
    )
  }
}

@MainActor
final class HotkeyRecorderAccessibilityTests: XCTestCase {
  func testRecorderIsOneNamedInteractiveAccessibilityElement() {
    let view = HotkeyRecorderNSView()
    let binding = DictationHotkeyConfiguration.defaultAlpha.startOrEnd

    view.setBinding(binding)
    view.configureAccessibility(
      identifier: "bestASR.settings.startEndHotkey",
      label: "开始或结束口述快捷键"
    )

    XCTAssertTrue(view.isAccessibilityElement())
    XCTAssertEqual(view.accessibilityRole(), .button)
    XCTAssertEqual(
      view.accessibilityIdentifier(),
      "bestASR.settings.startEndHotkey"
    )
    XCTAssertEqual(view.accessibilityLabel(), "开始或结束口述快捷键")
    XCTAssertEqual(
      view.accessibilityValue() as? String,
      BestASRHotkeyFormatter.title(binding)
    )
  }

  func testAutomaticFirstResponderDoesNotStartHotkeyCapture() {
    let view = HotkeyRecorderNSView()
    let binding = DictationHotkeyConfiguration.defaultAlpha.startOrEnd
    view.setBinding(binding)

    XCTAssertTrue(view.becomeFirstResponder())

    XCTAssertFalse(view.isCapturingHotkey)
    XCTAssertEqual(view.displayedTitle, BestASRHotkeyFormatter.title(binding))
    XCTAssertEqual(
      view.accessibilityValue() as? String,
      BestASRHotkeyFormatter.title(binding)
    )
  }

  func testExplicitAccessibilityPressStartsHotkeyCapture() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let view = HotkeyRecorderNSView()
    window.contentView = view

    XCTAssertTrue(view.accessibilityPerformPress())
    XCTAssertTrue(view.isCapturingHotkey)
    XCTAssertEqual(view.displayedTitle, "请按新的全局快捷键…")
    XCTAssertEqual(view.accessibilityValue() as? String, "等待输入新快捷键")
  }
}

final class AppTestHostEnvironmentTests: XCTestCase {
  func testXCTestHostDetectionDoesNotAffectNormalLaunches() {
    XCTAssertFalse(
      BestASRProcessEnvironment.isXCTestHost(
        environment: [:],
        xctestClassAvailable: false
      )
    )
    XCTAssertTrue(
      BestASRProcessEnvironment.isXCTestHost(
        environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
        xctestClassAvailable: false
      )
    )
    XCTAssertTrue(
      BestASRProcessEnvironment.isXCTestHost(
        environment: [:],
        xctestClassAvailable: true
      )
    )
  }
}

@MainActor
final class DictationModelReadinessTests: XCTestCase {
  func testStoppingRoomLevelPreviewRestoresActionableIdleStatus() {
    let model = DictationAppModel(preview: true)

    model.toggleRoomLevelPreview()
    XCTAssertTrue(model.capture.roomLevelPreviewActive)
    XCTAssertEqual(
      model.capture.roomStatusMessage,
      "正在本机预览输入音量；不会保存预览音频"
    )

    model.toggleRoomLevelPreview()
    XCTAssertFalse(model.capture.roomLevelPreviewActive)
    XCTAssertEqual(model.capture.roomInputLevel, 0)
    XCTAssertEqual(model.capture.roomStatusMessage, "已停止音量预览；可以开始线下录音")
  }

  func testSystemAudioPickerHidesBackgroundServicesButKeepsRealSources() {
    let daemon = SystemAudioSource(
      id: "bundle:com.apple.corespeechd",
      displayName: "corespeechd",
      bundleID: "com.apple.corespeechd",
      isRunningOutput: false
    )
    let application = SystemAudioSource(
      id: "bundle:com.google.Chrome",
      displayName: "Google Chrome",
      bundleID: "com.google.Chrome",
      isRunningOutput: false
    )
    let commandLinePlayer = SystemAudioSource(
      id: "name:afplay",
      displayName: "afplay",
      bundleID: nil,
      isRunningOutput: true
    )

    XCTAssertFalse(
      DictationAppModel.shouldShowSystemAudioSource(
        daemon,
        isUserFacingApplication: false
      )
    )
    XCTAssertTrue(
      DictationAppModel.shouldShowSystemAudioSource(
        application,
        isUserFacingApplication: true
      )
    )
    XCTAssertTrue(
      DictationAppModel.shouldShowSystemAudioSource(
        commandLinePlayer,
        isUserFacingApplication: false
      )
    )

    let staleRecentDaemon = SystemAudioSource(
      id: "bundle:com.apple.systemstats",
      displayName: "systemstats",
      bundleID: "com.apple.systemstats",
      isRunningOutput: false
    )
    XCTAssertFalse(
      DictationAppModel.shouldShowSystemAudioSource(
        staleRecentDaemon,
        isUserFacingApplication: false
      ),
      "Persisting a background service as recent must never make it selectable"
    )

    XCTAssertFalse(
      DictationAppModel.applicationAudioSourceIsUserFacing(
        bundleID: "com.apple.controlcenter",
        activationPolicy: .accessory,
        resolvesToApplication: true
      )
    )
    XCTAssertFalse(
      DictationAppModel.applicationAudioSourceIsUserFacing(
        bundleID: "com.apple.CoreSimulator.SimAudioProcessorServices.SimAudioProcessorService",
        activationPolicy: .prohibited,
        resolvesToApplication: true
      )
    )
    XCTAssertFalse(
      DictationAppModel.applicationAudioSourceIsUserFacing(
        bundleID: "com.bestasr.app",
        activationPolicy: .regular,
        resolvesToApplication: true
      )
    )
    XCTAssertTrue(
      DictationAppModel.applicationAudioSourceIsUserFacing(
        bundleID: "com.example.menu-bar-player",
        activationPolicy: .accessory,
        resolvesToApplication: true
      )
    )
  }

  func testHistoryRefreshGenerationRejectsAnOlderResultThatFinishesLast() {
    var gate = HistoryRefreshGenerationGate()

    let olderRequest = gate.begin()
    let latestRequest = gate.begin()

    XCTAssertFalse(gate.accepts(olderRequest))
    XCTAssertTrue(gate.accepts(latestRequest))
  }

  func testDurationFiltersDoNotTreatUnknownAudioAsShortAndKeepExactBoundaries() {
    func item(_ duration: UInt64?) -> DictationHistoryItem {
      DictationHistoryItem(
        sessionID: SessionID(), revision: 1, phase: .completed, status: .completed,
        rawText: nil, polishedText: nil, failureCode: nil, canRetry: false,
        sourceAudioRetained: true, createdAt: .distantPast, updatedAt: .distantPast,
        recoveredAt: nil, durationNanoseconds: duration
      )
    }
    let unknown = item(nil)
    XCTAssertTrue(DictationAppModel.historyItemMatchesDurationFilter(unknown, filter: "all"))
    for filter in ["short", "medium", "long"] {
      XCTAssertFalse(DictationAppModel.historyItemMatchesDurationFilter(unknown, filter: filter))
    }
    let underFive = item(299_999_999_999)
    let fiveMinutes = item(300_000_000_000)
    let thirtyMinutes = item(1_800_000_000_000)
    XCTAssertTrue(DictationAppModel.historyItemMatchesDurationFilter(underFive, filter: "short"))
    XCTAssertFalse(DictationAppModel.historyItemMatchesDurationFilter(fiveMinutes, filter: "short"))
    XCTAssertTrue(DictationAppModel.historyItemMatchesDurationFilter(fiveMinutes, filter: "medium"))
    XCTAssertFalse(
      DictationAppModel.historyItemMatchesDurationFilter(thirtyMinutes, filter: "medium"))
    XCTAssertTrue(DictationAppModel.historyItemMatchesDurationFilter(thirtyMinutes, filter: "long"))
  }

  func testMemoryNavigationRevealsLinkedHistoryAndRetainsOneClickReturn() {
    let model = DictationAppModel(preview: true)
    let item = model.history.historyItems[1]
    model.history.searchQuery = "a filter that hides the linked recording"
    model.history.modeFilter = "systemAudio"
    model.history.personFilterID = PersonID(UUID())
    let origin = HistoryNavigationOrigin(kind: .person, title: "陈老师")

    model.openHistoryItem(item, returningTo: origin)

    XCTAssertEqual(model.requestedNavigationSectionID, "history")
    XCTAssertEqual(model.history.selectedHistorySessionID, item.sessionID)
    XCTAssertEqual(model.history.navigationOrigin, origin)
    XCTAssertEqual(origin.returnTitle, "返回人物：陈老师")
    XCTAssertEqual(model.history.searchQuery, "")
    XCTAssertEqual(model.history.modeFilter, "all")
    XCTAssertNil(model.history.personFilterID)

    model.openHistoryItem(model.history.historyItems[0])
    XCTAssertNil(
      model.history.navigationOrigin,
      "Opening an unrelated Library row must not retain a misleading memory return."
    )
  }

  func testHistoryNavigationClearsActionFeedbackAndRejectsAnotherRecordsCompletion() {
    let model = DictationAppModel(preview: true)
    let first = model.history.historyItems[0]
    let second = model.history.historyItems[1]
    model.openHistoryItem(first)
    model.setHistoryDetailFeedback("First record is paused", for: first.sessionID)
    XCTAssertEqual(model.history.detailStatusMessage, "First record is paused")

    model.openHistoryItem(second)
    XCTAssertEqual(model.history.detailStatusMessage, "")
    model.setHistoryDetailFeedback("Late completion from first", for: first.sessionID)
    XCTAssertEqual(model.history.detailStatusMessage, "")
    model.setHistoryDetailFeedback("Second record completed", for: second.sessionID)
    XCTAssertEqual(model.history.detailStatusMessage, "Second record completed")

    model.toggleHistoryDetails(second)
    XCTAssertNil(model.history.selectedHistorySessionID)
    XCTAssertEqual(model.history.detailStatusMessage, "")
    model.setHistoryDetailFeedback("Late completion after closing", for: second.sessionID)
    XCTAssertEqual(model.history.detailStatusMessage, "")
  }

  func testRerecognitionFeedbackDistinguishesCompletedQueuedFailedAndHumanPreserved() {
    XCTAssertTrue(HistorySpeakerRefreshOutcome.completed.detailMessage.contains("文字与说话人已重新识别"))
    XCTAssertTrue(HistorySpeakerRefreshOutcome.queued.detailMessage.contains("人物处理已排队"))
    XCTAssertTrue(HistorySpeakerRefreshOutcome.failed.detailMessage.contains("人物处理未完成"))
    XCTAssertTrue(
      HistorySpeakerRefreshOutcome.preservedHumanDecisions.detailMessage.contains("未自动重新划分"))
    XCTAssertEqual(
      Set([
        HistorySpeakerRefreshOutcome.completed.detailMessage,
        HistorySpeakerRefreshOutcome.queued.detailMessage,
        HistorySpeakerRefreshOutcome.failed.detailMessage,
        HistorySpeakerRefreshOutcome.preservedHumanDecisions.detailMessage,
      ]).count, 4)
  }

  func testUnifiedMemorySearchFindsAndOpensTheUnderlyingRecording() {
    let model = DictationAppModel(preview: true)
    model.memorySearch.searchQuery = "Fixture raw"

    model.searchMemory()

    XCTAssertEqual(model.memorySearch.searchHistoryItems.count, 1)
    XCTAssertEqual(model.memorySearch.searchStatusMessage, "找到 1 项本机记忆")
    model.openFirstMemorySearchResult()
    XCTAssertEqual(model.requestedNavigationSectionID, "history")
    XCTAssertEqual(
      model.history.selectedHistorySessionID,
      model.memorySearch.searchHistoryItems.first?.sessionID
    )

    model.memorySearch.searchQuery = ""
    model.searchMemory()
    XCTAssertTrue(model.memorySearch.searchHistoryItems.isEmpty)
    XCTAssertEqual(
      model.memorySearch.searchStatusMessage,
      "搜索逐字稿、整理、人物、事件和来源"
    )
  }

  func testMemorySearchDoesNotTreatPersonStorageIDsAsUserMemory() throws {
    let person = Person(
      id: PersonID(
        UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
      ),
      revision: try Revision(1),
      displayName: nil,
      aliases: [],
      createdAt: .distantPast,
      updatedAt: .distantPast
    )
    let anonymousVoice = PersonSummary(
      person: person,
      occurrenceCount: 1,
      embeddingCount: 1,
      sessionCount: 1
    )
    let emptyAnonymousProfile = PersonSummary(
      person: person,
      occurrenceCount: 0,
      embeddingCount: 0,
      sessionCount: 0
    )

    XCTAssertFalse(
      DictationAppModel.personSummary(anonymousVoice, matches: "1"),
      "A query must never match an internal UUID."
    )
    XCTAssertTrue(
      DictationAppModel.personSummary(anonymousVoice, matches: "待命名")
    )
    XCTAssertFalse(
      DictationAppModel.personSummary(emptyAnonymousProfile, matches: "待命名"),
      "An empty anonymous profile is not a searchable audio memory."
    )
    XCTAssertEqual(
      DictationAppModel.browsablePersonSummaries([
        emptyAnonymousProfile,
        anonymousVoice,
      ]),
      [anonymousVoice],
      "An unnamed identity without a recording, occurrence, or voiceprint must not appear as a real person."
    )
  }

  func testAnonymousPeopleHaveHumanDistinguishableTitles() throws {
    func summary(id: String, date: TimeInterval) throws -> PersonSummary {
      PersonSummary(
        person: Person(
          id: PersonID(UUID(uuidString: id)!),
          revision: try Revision(1),
          displayName: nil,
          aliases: [],
          createdAt: Date(timeIntervalSince1970: date),
          updatedAt: Date(timeIntervalSince1970: date)
        ),
        occurrenceCount: 1,
        embeddingCount: 1,
        sessionCount: 1,
        latestOccurrenceAt: Date(timeIntervalSince1970: date)
      )
    }

    let first = try summary(
      id: "A2000000-0000-4000-8000-000000000001",
      date: 1_700_000_000
    )
    let second = try summary(
      id: "A2000000-0000-4000-8000-000000000002",
      date: 1_700_090_000
    )
    let firstTitle = ContentView.personTitle(first)
    let secondTitle = ContentView.personTitle(second)

    XCTAssertTrue(firstTitle.hasPrefix("待命名 · "))
    XCTAssertNotEqual(firstTitle, secondTitle)
    XCTAssertFalse(firstTitle.contains("A2000000"))
    XCTAssertEqual(
      ContentView.speakerDisplayTitle(
        displayName: nil,
        personID: first.person.id,
        associationStatus: .anonymousIdentity,
        stableOrdinal: 2
      ),
      "说话人 B"
    )
    let seenAgain = PersonSummary(
      person: first.person, occurrenceCount: 2, embeddingCount: 2, sessionCount: 2,
      latestOccurrenceAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    XCTAssertEqual(
      ContentView.personTitle(seenAgain), firstTitle,
      "An unnamed person's title must not change when seen in another recording.")
    XCTAssertEqual(TranscriptSpeakerSelection.speakerLabel(ordinal: 26), "Z")
    XCTAssertEqual(TranscriptSpeakerSelection.speakerLabel(ordinal: 27), "AA")
    XCTAssertEqual(
      ContentView.speakerDisplayTitle(
        displayName: nil, personID: first.person.id,
        associationStatus: .candidate, stableOrdinal: 2),
      "说话人 B · 待确认"
    )
  }

  func testHistorySearchLocatesDirectAndProvenanceBackedSegments() throws {
    let directSegment = DictationTranscriptSegment(
      id: UUID(),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 200,
      text: "The launch decision belongs here.",
      confidence: 0.95
    )
    let provenanceSegment = DictationTranscriptSegment(
      id: UUID(),
      monotonicStartNanoseconds: 300,
      monotonicEndNanoseconds: 400,
      text: "The source wording is intentionally different.",
      confidence: 0.91
    )
    let document = LocalTextDocumentRecord(
      id: UUID(),
      sessionID: SessionID(UUID()),
      sourceTranscriptID: TranscriptRevisionID(UUID()),
      sourceRevision: try Revision(1),
      taskID: .structuredSummary,
      modelArtifactID: "fixture-local-text",
      configHash: try SHA256Digest(String(repeating: "a", count: 64)),
      result: LocalTextResult(
        modelArtifactID: "fixture-local-text",
        taskID: .structuredSummary,
        outputText: "Synthetic summary",
        claims: [
          LocalTextClaim(
            claimID: UUID(),
            text: "Follow up with the design team.",
            sourceSegmentIDs: [provenanceSegment.id]
          )
        ]
      ),
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let segments = [directSegment, provenanceSegment]

    XCTAssertEqual(
      DictationAppModel.historySearchSegmentID(
        query: "launch decision",
        segments: segments,
        documents: [document]
      ),
      directSegment.id
    )
    XCTAssertEqual(
      DictationAppModel.historySearchSegmentID(
        query: "design team",
        segments: segments,
        documents: [document]
      ),
      provenanceSegment.id
    )
    XCTAssertNil(
      DictationAppModel.historySearchSegmentID(
        query: "record title only",
        segments: segments,
        documents: [document]
      ),
      "Metadata-only matches must not invent an audio timestamp."
    )
  }

  func testEventCandidateEvidenceChoosesTheMostRelevantAudioSegment() {
    let first = DictationTranscriptSegment(
      id: UUID(),
      monotonicStartNanoseconds: 0,
      monotonicEndNanoseconds: 10,
      text: "先讨论预算与采购安排。",
      confidence: 0.9
    )
    let second = DictationTranscriptSegment(
      id: UUID(),
      monotonicStartNanoseconds: 10,
      monotonicEndNanoseconds: 20,
      text: "随后复盘播放进度和交互问题。",
      confidence: 0.9
    )

    XCTAssertEqual(
      DictationAppModel.eventCandidateEvidenceSegment(
        proposedTitle: "播放进度与交互复盘",
        segments: [first, second]
      )?.id,
      second.id
    )
    XCTAssertEqual(
      DictationAppModel.eventCandidateEvidenceSegment(
        proposedTitle: "完全没有共同词语",
        segments: [first, second]
      )?.id,
      first.id,
      "A candidate without timestamp-level semantic evidence must fall back to the start rather than inventing a match."
    )
  }

  func testHistorySearchSnippetShowsTheMatchingContextInsteadOfTheBeginning() {
    let text =
      "开头是与搜索无关的说明，后面还有一段较长的背景内容。真正需要找回的是设计评审结论和对应的下一步行动，最后再补充一些收尾内容。"

    let snippet = DictationAppModel.historySearchSnippet(
      text: text,
      query: "设计评审结论",
      contextBefore: 8,
      contextAfter: 12
    )

    XCTAssertEqual(snippet, "…真正需要找回的是设计评审结论和对应的下一步行动，最后…")
    XCTAssertNil(
      DictationAppModel.historySearchSnippet(
        text: text,
        query: "不存在的内容"
      )
    )
    XCTAssertNil(
      DictationAppModel.historySearchSnippet(
        text: text,
        query: "   "
      )
    )
  }

  func testCompletedFinalWinsOverHigherNumberedLiveDrafts() throws {
    let sessionID = SessionID(UUID())
    let segment = DictationTranscriptSegment(
      id: UUID(),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 200,
      text: "完整最终稿",
      confidence: 0.9
    )
    let live = DictationPersistedTranscriptRecord(
      id: TranscriptRevisionID(UUID()),
      sessionID: sessionID,
      inputRevision: 45,
      parentID: nil,
      kind: .sentence,
      content: "最后一句实时稿",
      modelArtifactID: "fixture-live",
      configHash: nil,
      languageHints: ["zh-CN"],
      audioRanges: [],
      segments: [
        DictationTranscriptSegment(
          id: UUID(),
          monotonicStartNanoseconds: 300,
          monotonicEndNanoseconds: 400,
          text: "最后一句实时稿",
          confidence: 0.8
        )
      ],
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let final = DictationPersistedTranscriptRecord(
      id: TranscriptRevisionID(UUID()),
      sessionID: sessionID,
      inputRevision: 6,
      parentID: live.id,
      kind: .final,
      content: "完整最终稿",
      modelArtifactID: "fixture-final",
      configHash: nil,
      languageHints: ["zh-CN"],
      audioRanges: [],
      segments: [segment],
      createdAt: Date(timeIntervalSince1970: 200)
    )

    XCTAssertEqual(TranscriptSelection.current(in: [final, live])?.id, final.id)
    XCTAssertEqual(
      TranscriptSelection.timestamped(in: [final, live])?.segments,
      [segment]
    )
    XCTAssertEqual(
      try LocalDictationRuntime.finalProcessingInputRevision(
        snapshotRevision: 6,
        persistedInputRevision: nil,
        persistedTranscripts: [final, live]
      ),
      46
    )
    XCTAssertEqual(
      try LocalDictationRuntime.finalProcessingInputRevision(
        snapshotRevision: 50,
        persistedInputRevision: 6,
        persistedTranscripts: [final, live]
      ),
      6,
      "Recovery must reuse the already-persisted final revision."
    )
  }

  @MainActor
  func testSelectingTranscriptTextLocatesWithoutInventingPlayback() {
    let model = DictationAppModel(preview: true)
    let segment = DictationTranscriptSegment(
      id: UUID(),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 200,
      text: "Synthetic transcript segment",
      confidence: 0.9
    )

    model.locateHistoryTranscriptSegment(segment)

    XCTAssertEqual(model.history.locatedSegmentID, segment.id)
    XCTAssertFalse(model.playback.playbackIsPlaying)
    XCTAssertEqual(
      model.history.detailStatusMessage,
      "已选中这段逐字稿；当前原音没有可定位的时间范围"
    )
  }

  func testStartupFailureDescriptionDoesNotExposePathsOrPrivateContent() {
    let error = NSError(
      domain: "bestASR.test.database",
      code: 19,
      userInfo: [
        NSLocalizedDescriptionKey:
          "failed at /private/user/history.sqlite with transcript secret"
      ]
    )

    let description = DictationAppModel.startupFailureDescription(error)

    XCTAssertTrue(description.contains("bestASR.test.database#19"))
    XCTAssertFalse(description.contains("/private/user"))
    XCTAssertFalse(description.contains("transcript secret"))
  }

  func testExternalRuntimeCacheFailsClosedOnMissingOrInternalTarget() throws {
    let localBase = FileManager.default.temporaryDirectory
    let missing = localBase.appendingPathComponent(UUID().uuidString)

    XCTAssertFalse(
      DictationAppModel.externalCacheTargetIsAvailable(
        missing,
        localBase: localBase
      )
    )
    XCTAssertFalse(
      DictationAppModel.externalCacheTargetIsAvailable(
        localBase,
        localBase: localBase
      )
    )
    XCTAssertTrue(
      DictationAppModel.startupFailureDescription(
        BestASRAppStorageError.externalCacheUnavailable
      ).contains("外置缓存盘未挂载")
    )
  }

  func testUnmountedCacheLinkFallsBackToLocalCacheWithoutTouchingLink() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let link = base.appendingPathComponent("com.bestasr.app")
    let missingVolume = "/Volumes/bestASR-missing-\(UUID().uuidString)/cache"
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: missingVolume)

    let resolved = try DictationAppModel.resolveApplicationCacheRoot(base: base)

    XCTAssertEqual(resolved.lastPathComponent, "com.bestasr.app.local")
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path), missingVolume)
  }

  func testUninsertedDictationCopiesFinalTextOrAFailedDraftOnly() throws {
    let sessionID = SessionID()
    let transcript = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(), segmentIDs: [], text: "最终文字",
      modelArtifactID: "fixture")
    let retained = DictationSessionSnapshot(
      sessionID: sessionID, revision: 3, phase: .completed, transcript: transcript,
      insertion: DictationInsertionResult(
        idempotencyKey: try DictationIdempotencyKey("copy-retained"),
        method: .retainedForCopy, inserted: false,
        failureReason: .nowhere))
    XCTAssertEqual(
      DictationAppModel.uninsertedClipboardText(retained, draft: "草稿")?.value, "最终文字")

    let inserted = DictationSessionSnapshot(
      sessionID: sessionID, revision: 3, phase: .completed, transcript: transcript,
      insertion: DictationInsertionResult(
        idempotencyKey: try DictationIdempotencyKey("copy-inserted"),
        method: .clipboardPaste, inserted: true))
    XCTAssertNil(DictationAppModel.uninsertedClipboardText(inserted, draft: "草稿"))

    let failed = DictationSessionSnapshot(
      sessionID: sessionID, revision: 3, phase: .failedRecoverable)
    let failedCopy = DictationAppModel.uninsertedClipboardText(failed, draft: " 实时草稿 ")
    XCTAssertEqual(failedCopy?.value, "实时草稿")
    XCTAssertEqual(failedCopy?.isDraft, true)
    XCTAssertNil(DictationAppModel.uninsertedClipboardText(failed, draft: "  "))
  }

  func testOnlyDoNothingGlobeSettingAvoidsTheFnConflict() {
    XCTAssertFalse(DictationAppModel.globeKeyTriggersSystemAction(usageType: 0))
    XCTAssertTrue(DictationAppModel.globeKeyTriggersSystemAction(usageType: nil))
    XCTAssertTrue(DictationAppModel.globeKeyTriggersSystemAction(usageType: 1))
    XCTAssertTrue(DictationAppModel.globeKeyTriggersSystemAction(usageType: 2))
  }

  func testFunctionKeyTapStaysHandsFreeWhileAHoldEndsOnRelease() {
    XCTAssertFalse(
      DictationAppModel.functionReleaseEndsDictation(heldFor: .milliseconds(150)))
    XCTAssertTrue(
      DictationAppModel.functionReleaseEndsDictation(heldFor: .milliseconds(600)))
  }

  func testUsableCacheLinkIsKept() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = base.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let link = base.appendingPathComponent("com.bestasr.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let resolved = try DictationAppModel.resolveApplicationCacheRoot(base: base)

    XCTAssertEqual(resolved.lastPathComponent, "com.bestasr.app")
  }

  func testMenuBarSceneDoesNotRepublishAnUnchangedInsertionState() {
    let model = DictationAppModel(preview: true)
    var republishedValues: [Bool] = []
    let observation = model.$menuBarEnabled
      .dropFirst()
      .sink { republishedValues.append($0) }

    model.updateMenuBarInsertion(model.menuBarEnabled)

    XCTAssertTrue(republishedValues.isEmpty)
    observation.cancel()
  }

  func testRecoverableFailureAllowsStartingANewDictation() {
    XCTAssertTrue(
      DictationAppModel.canStartNewDictation(from: .failedRecoverable)
    )
    XCTAssertFalse(
      DictationAppModel.canStartNewDictation(from: .recognizing)
    )
  }

  func testOwnAppIsATargetOnlyWhileThePracticeFieldIsUp() {
    let target = DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.bestasr.app", isSecure: false)
    XCTAssertNil(
      DictationAppModel.externalInsertionTarget(target, ownBundleIdentifier: "com.bestasr.app"))
    XCTAssertEqual(
      DictationAppModel.externalInsertionTarget(
        target, ownBundleIdentifier: "com.bestasr.app", ownApplicationAllowed: true),
      target)
    XCTAssertEqual(
      DictationAppModel.externalInsertionTarget(target, ownBundleIdentifier: "com.example.other"),
      target)
  }

  func testOuterProcessingFailurePreservesSafeInferenceDiagnostic() throws {
    let error = InferenceEngineError(
      category: .corruptInput,
      code: "dictation-asr-source-range-mapping-invalid",
      retryable: false
    )

    let code = LocalDictationRuntime.processingDiagnosticCode(for: error)
    let failure = try LocalDictationRuntime.outerProcessingFailure(
      for: error,
      code: code,
      recoveryPhase: .recognizing
    )

    XCTAssertEqual(code, "dictation-asr-source-range-mapping-invalid")
    XCTAssertEqual(failure.stage, .recognition)
    XCTAssertEqual(failure.category, .corruptInput)
    XCTAssertFalse(failure.retryable)
    XCTAssertEqual(failure.recoveryPhase, .recognizing)
  }

  func testOuterProcessingFailureMakesPersistenceErrorsRetryable() throws {
    let error = DictationProcessingError.persistenceUnavailable(
      code: "recognition-commit-failed"
    )

    let code = LocalDictationRuntime.processingDiagnosticCode(for: error)
    let failure = try LocalDictationRuntime.outerProcessingFailure(
      for: error,
      code: code,
      recoveryPhase: .polishing
    )

    XCTAssertEqual(code, "recognition-commit-failed")
    XCTAssertEqual(failure.stage, .persistence)
    XCTAssertEqual(failure.category, .transientRuntime)
    XCTAssertTrue(failure.retryable)
    XCTAssertEqual(failure.recoveryPhase, .polishing)
  }

  func testProcessingDiagnosticNeverIncludesNSErrorDescription() {
    let error = NSError(
      domain: "bestASR.private/user",
      code: 19,
      userInfo: [
        NSLocalizedDescriptionKey:
          "failed at /private/user/history.sqlite with transcript secret"
      ]
    )

    let code = LocalDictationRuntime.processingDiagnosticCode(for: error)

    XCTAssertEqual(code, "ns-bestasr.private-user-19")
    XCTAssertFalse(code.contains("/private/user"))
    XCTAssertFalse(code.contains("transcript secret"))
  }

  func testOrphanedActiveHistoryItemCanRetryOnlyWhenStartupScanFoundIt() {
    let sessionID = SessionID(
      UUID(uuidString: "D4000000-0000-4000-8000-000000000001")!
    )
    let item = DictationHistoryItem(
      sessionID: sessionID,
      revision: 4,
      phase: .recording,
      status: .processing,
      rawText: nil,
      polishedText: nil,
      failureCode: nil,
      canRetry: false,
      sourceAudioRetained: true,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      recoveredAt: nil
    )

    XCTAssertFalse(
      DictationAppModel.canRetryHistoryItem(
        item,
        startupRecoverySessionIDs: []
      ),
      "a live in-process capture must not expose a competing recovery action"
    )
    XCTAssertTrue(
      DictationAppModel.canRetryHistoryItem(
        item,
        startupRecoverySessionIDs: [sessionID]
      ),
      "an orphaned active snapshot found at startup must be recoverable"
    )
    XCTAssertFalse(
      DictationAppModel.canDeleteHistoryItem(
        item,
        startupRecoverySessionIDs: []
      ),
      "a live in-process capture must not expose deletion"
    )
    XCTAssertTrue(
      DictationAppModel.canDeleteHistoryItem(
        item,
        startupRecoverySessionIDs: [sessionID]
      ),
      "an orphaned active snapshot may be explicitly deleted after confirmation"
    )
    XCTAssertEqual(
      DictationAppModel.historyStatusTitle(item, startupRecoverySessionIDs: [sessionID]),
      "可恢复",
      "an interrupted recording is waiting for the user, not still processing"
    )
    XCTAssertEqual(DictationAppModel.historyStatusTitle(item), "处理中")
    XCTAssertTrue(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "recoverable", startupRecoverySessionIDs: [sessionID]
      )
    )
    XCTAssertFalse(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "processing", startupRecoverySessionIDs: [sessionID]
      )
    )
    XCTAssertFalse(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "recoverable", startupRecoverySessionIDs: []
      ),
      "a currently recording session must not appear as interrupted"
    )
    XCTAssertTrue(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "processing", startupRecoverySessionIDs: []
      )
    )
    XCTAssertEqual(
      DictationAppModel.historyStatusTitle(
        item, startupRecoverySessionIDs: [sessionID], retryingSessionID: sessionID
      ),
      "正在恢复"
    )
    XCTAssertTrue(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "processing", startupRecoverySessionIDs: [sessionID],
        retryingSessionID: sessionID
      )
    )
    XCTAssertFalse(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "recoverable", startupRecoverySessionIDs: [sessionID],
        retryingSessionID: sessionID
      )
    )
    XCTAssertFalse(
      DictationAppModel.canDeleteHistoryItem(
        item, startupRecoverySessionIDs: [sessionID], retryingSessionID: sessionID
      ),
      "recovery must retain exclusive access to its source audio"
    )
  }

  func testRecoveryCompletionKeepsTheOpenResultVisibleWithoutChangingOtherBrowsing() {
    let sessionID = SessionID(UUID())
    for filter in ["recoverable", "failed", "processing"] {
      XCTAssertEqual(
        DictationAppModel.historyFilterAfterRecovery(
          filter, recoveredSessionID: sessionID, selectedSessionID: sessionID
        ), "all"
      )
      XCTAssertEqual(
        DictationAppModel.historyFilterAfterRecovery(
          filter, recoveredSessionID: sessionID, selectedSessionID: SessionID(UUID())
        ), filter
      )
    }
    XCTAssertEqual(
      DictationAppModel.historyFilterAfterRecovery(
        "recovered", recoveredSessionID: sessionID, selectedSessionID: sessionID
      ), "recovered"
    )
  }

  func testStoppingRetainedImportImmediatelyMarksItRecoverable() {
    let existing = SessionID(
      UUID(uuidString: "D4000000-0000-4000-8000-000000000010")!
    )
    let activeImport = SessionID(
      UUID(uuidString: "D4000000-0000-4000-8000-000000000011")!
    )

    XCTAssertEqual(
      DictationAppModel.recoverySessionIDsAfterStoppingImport(
        [existing],
        sessionID: activeImport,
        canDiscard: false
      ),
      [existing, activeImport],
      "a post-seal stop must enable recovery and deletion without an App restart"
    )
    XCTAssertEqual(
      DictationAppModel.recoverySessionIDsAfterStoppingImport(
        [existing],
        sessionID: activeImport,
        canDiscard: true
      ),
      [existing],
      "a pre-seal cancellation still removes its ephemeral record"
    )
  }

  func testSilentDictationStaysRetryableButIsNotCountedAsUnfinished() throws {
    let sessionID = SessionID(
      UUID(uuidString: "D4000000-0000-4000-8000-000000000031")!
    )
    let failure = try DictationFailure(
      stage: .recognition,
      category: .corruptInput,
      code: "dictation-asr-no-speech-detected",
      retryable: true,
      recoveryPhase: .recognizing
    )
    let candidate = DictationRecoveryCandidate(
      snapshot: DictationSessionSnapshot(
        sessionID: sessionID, revision: 3, phase: .failedRecoverable, failure: failure),
      journal: nil,
      disposition: .readyToFinalize
    )
    let item = DictationHistoryItem(
      sessionID: sessionID,
      revision: 3,
      phase: .failedRecoverable,
      status: .failed,
      rawText: nil,
      polishedText: nil,
      failureCode: failure.code,
      canRetry: true,
      sourceAudioRetained: true,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      recoveredAt: nil
    )

    XCTAssertTrue(DictationAppModel.startupRecoverySessionIDs(from: [candidate]).isEmpty)
    XCTAssertTrue(
      DictationAppModel.canRetryHistoryItem(item, startupRecoverySessionIDs: []))
    XCTAssertEqual(DictationAppModel.historyEmptyText(item), "没有听到说话。")
  }

  func testNonretryableFailureIsNotReofferedAfterRestart() throws {
    let sessionID = SessionID(
      UUID(uuidString: "D4000000-0000-4000-8000-000000000002")!
    )
    let failure = try DictationFailure(
      stage: .journal,
      category: .corruptInput,
      code: "journal-no-committed-audio",
      retryable: false,
      recoveryPhase: .finalizing
    )
    let snapshot = DictationSessionSnapshot(
      sessionID: sessionID,
      revision: 2,
      phase: .failedRecoverable,
      failure: failure
    )
    let candidate = DictationRecoveryCandidate(
      snapshot: snapshot,
      journal: nil,
      disposition: .requiresRepair
    )
    let item = DictationHistoryItem(
      sessionID: sessionID,
      revision: 2,
      phase: .failedRecoverable,
      status: .failed,
      rawText: nil,
      polishedText: nil,
      failureCode: failure.code,
      canRetry: false,
      sourceAudioRetained: false,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      recoveredAt: nil
    )

    let startupIDs = DictationAppModel.startupRecoverySessionIDs(
      from: [candidate]
    )

    XCTAssertTrue(startupIDs.isEmpty)
    XCTAssertFalse(
      DictationAppModel.canRetryHistoryItem(
        item,
        startupRecoverySessionIDs: [sessionID]
      ),
      "a persisted nonretryable failure must not be revived by a stale startup ID"
    )
  }

  func testHistoryFailureAndEmptyAudioMessagesDoNotClaimRecoveryThatIsImpossible() {
    let item = DictationHistoryItem(
      sessionID: SessionID(
        UUID(uuidString: "D4000000-0000-4000-8000-000000000003")!
      ),
      revision: 2,
      phase: .failedRecoverable,
      status: .failed,
      rawText: nil,
      polishedText: nil,
      failureCode: "journal-no-committed-audio",
      canRetry: false,
      sourceAudioRetained: true,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      recoveredAt: nil
    )

    XCTAssertEqual(DictationAppModel.historyStatusTitle(item), "失败")
    XCTAssertFalse(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "recoverable", startupRecoverySessionIDs: [item.sessionID]
      ),
      "an impossible repair must not reappear in the recoverable filter"
    )
    XCTAssertTrue(
      DictationAppModel.historyItemMatchesStatusFilter(
        item, filter: "failed", startupRecoverySessionIDs: []
      )
    )
    XCTAssertEqual(
      DictationAppModel.historyEmptyText(item),
      "没有可恢复的已提交音频；可在确认后删除这条记录。"
    )
  }

  func testRecoveredEmptyTranscriptStatesThatNoSpeechWasDetected() {
    let item = DictationHistoryItem(
      sessionID: SessionID(
        UUID(uuidString: "D4000000-0000-4000-8000-000000000004")!
      ),
      revision: 7,
      phase: .completed,
      status: .recovered,
      rawText: "",
      polishedText: "",
      failureCode: nil,
      canRetry: false,
      sourceAudioRetained: true,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      recoveredAt: Date(timeIntervalSince1970: 1_700_000_002)
    )

    XCTAssertEqual(
      DictationAppModel.historyEmptyText(item),
      "没有检测到可识别的语音；原始音频仍保留在本机。"
    )
  }

  func testRecordingReadinessDoesNotRequireAccessibilityFocusOrPermission() {
    XCTAssertTrue(
      DictationAppModel.canRecord(
        microphonePermission: .granted
      )
    )
    XCTAssertFalse(
      DictationAppModel.canRecord(
        microphonePermission: .denied
      )
    )
  }

  func testStartupVerificationIsNotReportedAsMissingSetup() {
    XCTAssertEqual(
      DictationAppModel.modelReadinessHeadline(
        ready: false,
        message: "正在检查已验证的本地语音模型…"
      ),
      "正在校验"
    )
    XCTAssertEqual(
      DictationAppModel.modelReadinessHeadline(
        ready: false,
        message: "尚未安装 SenseVoice"
      ),
      "需要准备"
    )
  }

  func testCompatibleFixtureBypassesSetupOffline() {
    let model = DictationAppModel(preview: true)

    XCTAssertTrue(model.models.modelRuntimeReady)
    XCTAssertTrue(model.polishRuntimeReady)
    XCTAssertTrue(model.people.speakerRuntimeReady)
    XCTAssertEqual(model.capture.systemAudioPermission, .granted)
    XCTAssertFalse(model.models.recommendedModelInstallInProgress)
  }

  func testRecommendedSetupTransitionsFromConsentToOfflineReady() {
    let model = DictationAppModel(preview: true, modelSetupFixture: true)
    XCTAssertFalse(model.models.modelRuntimeReady)
    XCTAssertFalse(model.polishRuntimeReady)
    XCTAssertFalse(model.people.speakerRuntimeReady)

    model.models.modelLicenseAccepted = true
    model.models.polishModelLicenseAccepted = true
    model.models.speakerModelLicenseAccepted = true
    model.downloadRecommendedModels()

    XCTAssertTrue(model.models.modelRuntimeReady)
    XCTAssertTrue(model.polishRuntimeReady)
    XCTAssertTrue(model.people.speakerRuntimeReady)
    XCTAssertEqual(model.models.recommendedModelProgress, 1)
    XCTAssertEqual(
      model.models.recommendedModelProgressMessage,
      "三个本地组件均已校验并可离线使用"
    )
  }
}

@MainActor
final class DictationSetupViewModelTests: XCTestCase {
  func testOneClickRecommendedSetupRequiresAllThreeLicenseReceipts() {
    let model = DictationAppModel(preview: true, modelSetupFixture: true)

    model.downloadRecommendedModels()
    XCTAssertFalse(model.models.modelRuntimeReady)
    XCTAssertTrue(model.models.recommendedModelProgressMessage.contains("三个本地组件许可"))

    model.models.modelLicenseAccepted = true
    XCTAssertFalse(model.canInstallRecommendedModels)
    model.models.polishModelLicenseAccepted = true
    XCTAssertFalse(model.canInstallRecommendedModels)
    model.models.speakerModelLicenseAccepted = true
    XCTAssertTrue(model.canInstallRecommendedModels)
    model.downloadRecommendedModels()
    XCTAssertTrue(model.models.modelRuntimeReady)
    XCTAssertTrue(model.polishRuntimeReady)
    XCTAssertTrue(model.people.speakerRuntimeReady)
  }
}

final class AppUpdateCheckResultTests: XCTestCase {
  func testChecksArePublicRepositoryOnlyAndOptIn() {
    XCTAssertEqual(AppUpdateChecker.repositorySlug, "Yusong-Enceladus/mindloom")
    XCTAssertEqual(
      AppUpdateChecker.latestReleaseEndpoint.absoluteString,
      "https://api.github.com/repos/Yusong-Enceladus/mindloom/releases/latest"
    )
    // Nothing is contacted at launch until the user turns checks on.
    XCTAssertFalse(AppUpdateChecker.automaticChecksEnabledByDefault)
    XCTAssertTrue(
      AppUpdateChecker.isOfficialReleasePage(
        URL(string: "https://github.com/Yusong-Enceladus/mindloom/releases/tag/v1.0")!
      )
    )
    for page in [
      "http://github.com/Yusong-Enceladus/mindloom/releases/tag/v1.0",
      "https://github.com/someone-else/mindloom/releases/tag/v1.0",
      "https://example.com/Yusong-Enceladus/mindloom/releases/tag/v1.0",
      "https://github.com/Yusong-Enceladus/mindloom-fork/releases/tag/v1.0",
    ] {
      XCTAssertFalse(AppUpdateChecker.isOfficialReleasePage(URL(string: page)!), page)
    }
  }

  func testSemanticVersionComparisonHandlesPrefixesAndDifferentDepths() {
    let releaseURL = URL(
      string: "https://github.com/\(AppUpdateChecker.repositorySlug)/releases/tag/v1.2.1"
    )!
    XCTAssertTrue(
      AppUpdateCheckResult(
        currentVersion: "1.2",
        latestVersion: "v1.2.1",
        releasePageURL: releaseURL
      ).updateAvailable
    )
    XCTAssertFalse(
      AppUpdateCheckResult(
        currentVersion: "1.2.1",
        latestVersion: "v1.2.1",
        releasePageURL: releaseURL
      ).updateAvailable
    )
    XCTAssertFalse(
      AppUpdateCheckResult(
        currentVersion: "2.0",
        latestVersion: "v1.9.9",
        releasePageURL: releaseURL
      ).updateAvailable
    )
  }
}

final class RemoteOrganizerHostPreferenceTests: XCTestCase {
  /// There is no built-in organizer host: an unset or blank preference means
  /// the link is not configured, never someone's default machine.
  func testOnlyAUserWrittenHostConfiguresTheLink() {
    XCTAssertNil(DictationAppModel.remoteOrganizerHost(preference: nil))
    XCTAssertNil(DictationAppModel.remoteOrganizerHost(preference: ""))
    XCTAssertNil(DictationAppModel.remoteOrganizerHost(preference: "  \n"))
    XCTAssertEqual(
      DictationAppModel.remoteOrganizerHost(preference: " spark-xxxx\n"), "spark-xxxx"
    )
  }
}

final class PlatformSpeakerNameEvidenceTests: XCTestCase {
  func testOnlyReliableUnambiguousCurrentSpeakerIntervalsCreateNameEvidence()
    throws
  {
    let sessionID = SessionID(
      UUID(uuidString: "51000000-0000-4000-8000-000000000001")!
    )
    let speakerID = SessionSpeakerID(
      UUID(uuidString: "51000000-0000-4000-8000-000000000002")!
    )
    let trackID = TrackID(
      UUID(uuidString: "51000000-0000-4000-8000-000000000003")!
    )
    let occurrenceID = SpeakerOccurrenceID(
      UUID(uuidString: "51000000-0000-4000-8000-000000000004")!
    )
    let revision = try Revision(1)
    let track = SourceTrack(
      id: trackID,
      sessionID: sessionID,
      revision: revision,
      role: .systemRemote,
      assetReference: try PortableAssetReference(
        relativePath: "sessions/fixture/journal/manifest.json"
      ),
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let occurrence = SpeakerOccurrence(
      id: occurrenceID,
      sessionID: sessionID,
      sessionSpeakerID: speakerID,
      revision: revision,
      trackIDs: [trackID],
      monotonicStartNanoseconds: 1_000_000_000,
      monotonicEndNanoseconds: 2_200_000_000,
      overlapsAnotherSpeaker: false,
      association: try PersonAssociation(
        status: .unknown,
        personID: nil,
        confidence: nil,
        evidenceRevision: revision
      )
    )
    func context(
      _ id: String,
      at timestamp: UInt64,
      activeSpeaker: String?,
      reliability: SourceContextReliability = .reliable
    ) -> SourceContextSnapshot {
      SourceContextSnapshot(
        id: UUID(uuidString: id)!,
        sessionID: sessionID,
        revision: revision,
        adapterID: "fixture",
        sourceBundleID: "com.example.meeting",
        meetingTitle: "Fixture",
        windowTitle: nil,
        participantDisplayNames: ["Alice", "Bob"],
        activeSpeakerDisplayName: activeSpeaker,
        monotonicNanoseconds: timestamp,
        reliability: reliability
      )
    }

    let participantListOnly = LocalDictationRuntime.platformSpeakerNameEvidence(
      sessionID: sessionID,
      revision: revision,
      tracks: [track],
      occurrences: [occurrence],
      contexts: [
        context(
          "51000000-0000-4000-8000-000000000005",
          at: 1_000_000_000,
          activeSpeaker: nil
        )
      ]
    )
    XCTAssertTrue(participantListOnly.isEmpty)

    let reliable = LocalDictationRuntime.platformSpeakerNameEvidence(
      sessionID: sessionID,
      revision: revision,
      tracks: [track],
      occurrences: [occurrence],
      contexts: [
        context(
          "51000000-0000-4000-8000-000000000006",
          at: 1_000_000_000,
          activeSpeaker: "Alice"
        )
      ]
    )
    XCTAssertEqual(reliable.count, 1)
    XCTAssertEqual(reliable.first?.displayName, "Alice")
    XCTAssertEqual(reliable.first?.occurrenceIDs, [occurrenceID])

    let conflicting = LocalDictationRuntime.platformSpeakerNameEvidence(
      sessionID: sessionID,
      revision: revision,
      tracks: [track],
      occurrences: [occurrence],
      contexts: [
        context(
          "51000000-0000-4000-8000-000000000007",
          at: 1_000_000_000,
          activeSpeaker: "Alice"
        ),
        context(
          "51000000-0000-4000-8000-000000000008",
          at: 1_600_000_000,
          activeSpeaker: "Bob"
        ),
      ]
    )
    XCTAssertTrue(conflicting.isEmpty)
  }
}

@MainActor
final class DictationCopyResponsivenessTests: XCTestCase {
  func testTitleSaveReportsProgressAndCompletesAfterPersistence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID(UUID())
    try await store.create(
      DictationSessionSnapshot(sessionID: sessionID, revision: 1, phase: .preparing))
    let records = try await store.loadHistory()
    let model = DictationAppModel(preview: true, memoryRepository: store)
    model.openHistoryItem(try XCTUnwrap(records.first))
    model.history.titleDraft = "  人工标题，保留逗号  "
    var result: Bool?
    model.saveHistoryTitle { result = $0 }
    XCTAssertTrue(model.history.titleSaveInProgress)
    XCTAssertEqual(model.history.detailStatusMessage, "正在保存标题…")
    let deadline = Date().addingTimeInterval(3)
    while result == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(result, true)
    XCTAssertFalse(model.history.titleSaveInProgress)
    let saved = try await store.loadHistory()
    XCTAssertEqual(saved.first?.title, "人工标题，保留逗号")
    XCTAssertEqual(model.history.titleDraft, "人工标题，保留逗号")
    XCTAssertEqual(model.history.detailStatusMessage, "标题已保存在本机")
    try await store.checkpointAndClose()
  }

  func testFailedTitleSaveKeepsTheDraftAndDoesNotCompleteTheEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let sessionID = SessionID(UUID())
    try await store.create(
      DictationSessionSnapshot(sessionID: sessionID, revision: 1, phase: .preparing))
    let records = try await store.loadHistory()
    let model = DictationAppModel(preview: true, memoryRepository: store)
    model.openHistoryItem(try XCTUnwrap(records.first))
    try await store.deleteSessionRecordsExplicitly(sessionID: sessionID)
    model.history.titleDraft = "尚未保存的标题"
    var result: Bool?
    model.saveHistoryTitle { result = $0 }
    let deadline = Date().addingTimeInterval(3)
    while result == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(result, false)
    XCTAssertFalse(model.history.titleSaveInProgress)
    XCTAssertEqual(model.history.titleDraft, "尚未保存的标题")
    XCTAssertTrue(model.history.detailStatusMessage.contains("草稿和原记录仍保留"))
    try await store.checkpointAndClose()
  }

  func testHistoryTitleRefreshFollowsNewResultsButPreservesUnsavedEdits() {
    XCTAssertEqual(
      DictationAppModel.refreshedHistoryTitleDraft(
        "旧的自动标题", previousTitle: "旧的自动标题", currentTitle: "重新识别后的标题"
      ),
      "重新识别后的标题"
    )
    XCTAssertEqual(
      DictationAppModel.refreshedHistoryTitleDraft(
        "尚未保存的自定义标题", previousTitle: "旧的自动标题", currentTitle: "重新识别后的标题"
      ),
      "尚未保存的自定义标题"
    )
    XCTAssertEqual(
      DictationAppModel.refreshedHistoryTitleDraft(
        "当前草稿", previousTitle: nil, currentTitle: nil
      ),
      "当前草稿"
    )
  }

  func testHistoryCopyReturnsImmediatelyAndCompletesAsynchronously() async throws {
    let model = DictationAppModel(preview: true)
    let item = try XCTUnwrap(
      model.history.historyItems.first(where: {
        $0.preferredText?.isEmpty == false
      }))

    model.copyHistoryItem(item)
    XCTAssertEqual(model.history.historyStatusMessage, "正在复制…")

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline, model.history.historyStatusMessage == "正在复制…" {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.history.historyStatusMessage, "已复制所选本地口述")
  }
}

final class FirstLaunchPracticeValidationTests: XCTestCase {
  func testPermissionActionsMatchTheActualSystemState() {
    XCTAssertEqual(
      ContentView.permissionActionTitle(
        title: "麦克风",
        state: .notDetermined
      ),
      "允许麦克风"
    )
    XCTAssertEqual(
      ContentView.permissionActionTitle(title: "麦克风", state: .denied),
      "打开麦克风设置"
    )
    XCTAssertEqual(
      ContentView.permissionActionTitle(title: "辅助功能", state: .revoked),
      "打开辅助功能设置"
    )
    XCTAssertEqual(
      ContentView.permissionActionTitle(title: "麦克风", state: .granted),
      "麦克风已允许"
    )
    XCTAssertEqual(
      ContentView.permissionActionTitle(
        title: "系统音频",
        state: .restartRequired
      ),
      "重新打开后生效"
    )
  }

  func testPracticeRequiresBothInsertionEvidenceAndVisibleEditorChange() {
    XCTAssertFalse(
      ContentView.practiceCompletionIsVisible(
        insertionReported: true,
        textBefore: "",
        textAfter: ""
      ),
      "An internal success flag must not complete onboarding when the practice editor did not change."
    )
    XCTAssertFalse(
      ContentView.practiceCompletionIsVisible(
        insertionReported: false,
        textBefore: "",
        textAfter: "visible text"
      ),
      "Manual typing must not be mistaken for a successful dictation insertion."
    )
    XCTAssertFalse(
      ContentView.practiceCompletionIsVisible(
        insertionReported: true,
        textBefore: "existing",
        textAfter: "existing"
      )
    )
    XCTAssertTrue(
      ContentView.practiceCompletionIsVisible(
        insertionReported: true,
        textBefore: "existing ",
        textAfter: "existing visible dictation"
      )
    )
  }
}

@MainActor
final class DictationDegradedRuntimeIntegrationTests: XCTestCase {
  func testImmediateSecondToggleQueuesOneEndAndRetainsTheSession() async throws {
    let model = DictationAppModel(preview: true)
    let previousSessionIDs = Set(model.history.historyItems.map(\.sessionID))

    model.startOrEnd()
    model.startOrEnd()

    // These are two explicit toggles, not a repeated key-down event. The second
    // request must survive microphone preparation instead of being swallowed.
    try await waitForPhase("completed", model: model)
    try await waitForHandoff(model: model)
    let sessionID = try XCTUnwrap(model.snapshot.sessionID)
    XCTAssertEqual(
      Set(model.history.historyItems.map(\.sessionID)).subtracting(previousSessionIDs),
      [sessionID]
    )
    XCTAssertEqual(model.history.historyItems.filter { $0.sessionID == sessionID }.count, 1)
    XCTAssertEqual(model.capture.captureWorkspaceHandoff?.sessionID, sessionID)
    XCTAssertEqual(model.snapshot.timeline.filter { $0.kind == .endRequested }.count, 1)
    XCTAssertNil(model.snapshot.target)
  }

  func testCaptureRemainsAvailableBeforeModelSetupAndFinishesRecoverably() async throws {
    let model = DictationAppModel(preview: true, modelSetupFixture: true)

    model.startOrEnd()
    try await waitForPhase("recording", model: model)
    XCTAssertTrue(model.liveTranscriptStatus.contains("正在保存音频"))

    model.startOrEnd()
    try await waitForPhase("recognizing", model: model)
    try await waitForHandoff(model: model)
    XCTAssertFalse(model.models.modelRuntimeReady)
    XCTAssertEqual(model.capture.captureWorkspaceHandoff?.state, .processing)
    XCTAssertEqual(
      model.capture.captureWorkspaceHandoff?.sessionID,
      model.snapshot.sessionID
    )
    XCTAssertNil(
      model.requestedNavigationSectionID,
      "Safely closing capture must not force the user away from the current workspace."
    )
  }

  func testCompletedFixturePublishesAnExactDismissibleLibraryHandoff()
    async throws
  {
    let model = DictationAppModel(preview: true)

    model.startOrEnd()
    try await waitForPhase("recording", model: model)
    model.startOrEnd()
    try await waitForPhase("completed", model: model)
    try await waitForHandoff(model: model)

    let sessionID = try XCTUnwrap(model.snapshot.sessionID)
    XCTAssertEqual(model.capture.captureWorkspaceHandoff?.state, .completed)
    XCTAssertEqual(model.capture.captureWorkspaceHandoff?.sessionID, sessionID)
    XCTAssertEqual(model.menuBarStatusMessage, "口述已完成")
    XCTAssertEqual(model.menuBarSymbol, "checkmark.circle.fill")
    XCTAssertTrue(model.history.historyItems.contains { $0.sessionID == sessionID })
    XCTAssertNil(model.requestedNavigationSectionID)

    model.openCaptureWorkspaceHandoff()
    XCTAssertNil(model.capture.captureWorkspaceHandoff)
    XCTAssertEqual(model.requestedNavigationSectionID, "history")
    XCTAssertEqual(model.history.selectedHistorySessionID, sessionID)
  }

  func testDeletingCompletedCaptureClearsOnlyItsMatchingHomeHandoff()
    async throws
  {
    let model = DictationAppModel(preview: true)

    model.startOrEnd()
    try await waitForPhase("recording", model: model)
    model.startOrEnd()
    try await waitForPhase("completed", model: model)
    try await waitForHandoff(model: model)

    let sessionID = try XCTUnwrap(model.snapshot.sessionID)
    let unrelatedSessionID = SessionID(
      UUID(uuidString: "03FF5731-975F-41C9-86FA-889013BF19B6")!
    )

    model.clearCaptureWorkspaceHandoff(afterDeleting: unrelatedSessionID)
    XCTAssertEqual(model.capture.captureWorkspaceHandoff?.sessionID, sessionID)

    model.clearCaptureWorkspaceHandoff(afterDeleting: sessionID)

    XCTAssertNil(model.capture.captureWorkspaceHandoff)
  }

  private func waitForPhase(
    _ phase: String,
    model: DictationAppModel
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if model.snapshot.phase.rawValue == phase { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for \(phase)")
  }

  private func waitForHandoff(
    model: DictationAppModel
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if model.capture.captureWorkspaceHandoff != nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the capture handoff")
  }
}

@MainActor
final class ProgressiveModelDiscoveryTests: XCTestCase {
  func testASRReadinessPublishesBeforePolishDiscoveryBegins() async {
    let trace = ModelDiscoveryTrace()

    await DictationAppModel.discoverModelsProgressively(
      discoverASR: {
        await trace.append("discover-asr")
        return true
      },
      publishASR: { ready in
        trace.append("publish-asr-\(ready)")
      },
      discoverSpeaker: {
        await trace.append("discover-speaker")
        return true
      },
      publishSpeaker: { ready in
        trace.append("publish-speaker-\(ready)")
      },
      discoverPolish: {
        await trace.append("discover-polish")
        return true
      },
      publishPolish: { ready in
        trace.append("publish-polish-\(ready)")
      }
    )

    XCTAssertEqual(
      trace.events,
      [
        "discover-asr",
        "publish-asr-true",
        "discover-speaker",
        "publish-speaker-true",
        "discover-polish",
        "publish-polish-true",
      ]
    )
  }
}

@MainActor
private final class ModelDiscoveryTrace: Sendable {
  private(set) var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }
}

final class AutomaticLanguageRoutedASRAdapterTests: XCTestCase {
  func testAlignedMultilingualFinalOverridesUnreliableLiveLanguageEvidence() async throws {
    let fallback = RoutingASRPort(text: "wrong live draft", model: "mixed")
    let mandarin = RoutingASRPort(text: "wrong route", model: "zh")
    let preferred = RoutingASRPort(text: "今天 use Codex 写代码。", model: "qwen-aligned")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin, englishFinal: nil, multilingualFinal: preferred,
      languageEvidenceText: "wrong live draft", languageEvidenceHints: ["zh-CN"],
      permitsEmptyResult: false)
    let result = try await router.recognize(makeRoutingRequest())
    XCTAssertEqual(result.modelArtifactID, "qwen-aligned")
    XCTAssertEqual(result.text, "今天 use Codex 写代码。")
    let fallbackCalls = await fallback.callCount()
    let mandarinCalls = await mandarin.callCount()
    XCTAssertEqual(fallbackCalls, 0)
    XCTAssertEqual(mandarinCalls, 0)
  }

  func testAlignmentFailureUsesExistingFinalRouteWithItsOwnProvenance() async throws {
    let fallback = RoutingASRPort(text: "unused", model: "mixed")
    let mandarin = RoutingASRPort(text: "今天开会。", model: "zh")
    let preferred = RoutingASRPort(
      text: "partial must not appear", model: "qwen-aligned",
      failure: InferenceEngineError(
        category: .transientRuntime, code: "qwen-final-alignment-invalid", retryable: true))
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin, englishFinal: nil, multilingualFinal: preferred,
      languageEvidenceText: "今天开会", permitsEmptyResult: false)
    let result = try await router.recognize(makeRoutingRequest())
    XCTAssertEqual(result.modelArtifactID, "zh")
    XCTAssertEqual(result.text, "今天开会。")
  }

  func testMultilingualCancellationNeverStartsFallbackInference() async throws {
    let fallback = RoutingASRPort(text: "must not appear", model: "mixed")
    let preferred = RoutingASRPort(text: "", model: "qwen-aligned", failure: .cancelled)
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: nil, englishFinal: nil, multilingualFinal: preferred, permitsEmptyResult: true)
    do {
      _ = try await router.recognize(makeRoutingRequest())
      XCTFail("cancellation must propagate")
    } catch let error as InferenceEngineError { XCTAssertEqual(error.category, .cancelled) }
    let calls = await fallback.callCount()
    XCTAssertEqual(calls, 0)
  }

  func testEmptyAuthoritativeFinalDoesNotAskFallbackToInventSpeech() async throws {
    for permitsEmpty in [true, false] {
      let fallback = RoutingASRPort(text: "hallucinated speech", model: "mixed")
      let preferred = RoutingASRPort(text: "", model: "qwen-aligned")
      let router = AutomaticLanguageRoutedASRAdapter(
        mixedLanguageFallback: fallback,
        mandarinFinal: nil, englishFinal: nil, multilingualFinal: preferred,
        permitsEmptyResult: permitsEmpty)
      do {
        let result = try await router.recognize(makeRoutingRequest())
        XCTAssertTrue(permitsEmpty)
        XCTAssertTrue(result.text.isEmpty)
      } catch let error as InferenceEngineError {
        XCTAssertFalse(permitsEmpty)
        XCTAssertEqual(error.code, "dictation-asr-no-speech-detected")
      }
      let calls = await fallback.callCount()
      XCTAssertEqual(calls, 0)
    }
  }

  func testStreamingStillUsesLowLatencyModel() async throws {
    let fallback = RoutingASRPort(text: "live draft", model: "mixed")
    let preferred = RoutingASRPort(text: "unused final", model: "qwen-aligned")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: nil, englishFinal: nil, multilingualFinal: preferred, permitsEmptyResult: false
    )
    let result = try await router.recognize(
      VersionedDictationASRRequest(
        request: makeRoutingRequest(),
        mode: .streaming, languageHints: ["zh-CN", "en-US"], supersedesRevisionID: nil))
    XCTAssertEqual(result.modelArtifactID, "mixed")
    let calls = await preferred.callCount()
    XCTAssertEqual(calls, 0)
  }

  func testClassifierKeepsSentenceLevelCodeSwitchingOnMixedModel() {
    XCTAssertEqual(
      AutomaticASRLanguageClassifier.profile(for: "今天 use Codex 写代码"),
      .mixed
    )
    XCTAssertEqual(
      AutomaticASRLanguageClassifier.profile(for: "今天下午继续开会"),
      .mandarin
    )
    XCTAssertEqual(
      AutomaticASRLanguageClassifier.profile(for: "Please send the notes"),
      .english
    )
  }

  func testClearlyMandarinFinalUsesSpecializedResult() async throws {
    let fallback = RoutingASRPort(text: "今天下午开会", model: "mixed")
    let mandarin = RoutingASRPort(text: "今天下午开会。", model: "zh")
    let english = RoutingASRPort(text: "today meeting", model: "en")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin,
      englishFinal: english,
      permitsEmptyResult: false
    )

    let result = try await router.recognize(makeRoutingRequest())
    let fallbackCalls = await fallback.callCount()
    let mandarinCalls = await mandarin.callCount()
    let englishCalls = await english.callCount()

    XCTAssertEqual(result.modelArtifactID, "zh")
    XCTAssertEqual(fallbackCalls, 1)
    XCTAssertEqual(mandarinCalls, 1)
    XCTAssertEqual(englishCalls, 0)
  }

  func testMixedSentenceDoesNotGetForcedThroughMonolingualModels() async throws {
    let fallback = RoutingASRPort(
      text: "今天 use Codex 写代码",
      model: "mixed",
      languageHints: ["zh-CN"]
    )
    let mandarin = RoutingASRPort(text: "今天写代码", model: "zh")
    let english = RoutingASRPort(text: "use Codex", model: "en")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin,
      englishFinal: english,
      permitsEmptyResult: false
    )

    let result = try await router.recognize(makeRoutingRequest())
    let mandarinCalls = await mandarin.callCount()
    let englishCalls = await english.callCount()

    XCTAssertEqual(result.modelArtifactID, "mixed")
    XCTAssertEqual(mandarinCalls, 0)
    XCTAssertEqual(englishCalls, 0)
  }

  func testMixedLiveEvidenceIsNotOverriddenByDominantLanguageTag() async throws {
    let fallback = RoutingASRPort(
      text: "今天 use Codex 写代码",
      model: "mixed",
      languageHints: ["zh-CN"]
    )
    let mandarin = RoutingASRPort(text: "今天写代码", model: "zh")
    let english = RoutingASRPort(text: "use Codex", model: "en")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin,
      englishFinal: english,
      languageEvidenceText: "今天 use Codex 写代码",
      languageEvidenceHints: ["zh-CN"],
      permitsEmptyResult: false
    )

    let result = try await router.recognize(makeRoutingRequest())
    let mandarinCalls = await mandarin.callCount()
    let englishCalls = await english.callCount()

    XCTAssertEqual(result.modelArtifactID, "mixed")
    XCTAssertEqual(mandarinCalls, 0)
    XCTAssertEqual(englishCalls, 0)
  }

  func testLiveEvidenceRoutesAnEmptyEnglishBaseline() async throws {
    let fallback = RoutingASRPort(text: "", model: "mixed")
    let mandarin = RoutingASRPort(text: "", model: "zh")
    let english = RoutingASRPort(text: "Please send the notes.", model: "en")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin,
      englishFinal: english,
      languageEvidenceText: "please send notes",
      permitsEmptyResult: false
    )

    let result = try await router.recognize(makeRoutingRequest())
    let englishCalls = await english.callCount()
    let mandarinCalls = await mandarin.callCount()

    XCTAssertEqual(result.modelArtifactID, "en")
    XCTAssertEqual(englishCalls, 1)
    XCTAssertEqual(mandarinCalls, 0)
  }

  func testDetectedMandarinTagOverridesEnglishShapedBaseline() async throws {
    let fallback = RoutingASRPort(
      text: "Just the way so harden any kind of kind way.",
      model: "mixed",
      languageHints: ["zh-CN"]
    )
    let mandarin = RoutingASRPort(
      text: "这是导入音频功能的第一位说话人。",
      model: "zh"
    )
    let english = RoutingASRPort(
      text: "Just the way so harden any kind of kind way.",
      model: "en"
    )
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin,
      englishFinal: english,
      permitsEmptyResult: false
    )

    let result = try await router.recognize(makeRoutingRequest())
    let mandarinCalls = await mandarin.callCount()
    let englishCalls = await english.callCount()

    XCTAssertEqual(result.modelArtifactID, "zh")
    XCTAssertEqual(mandarinCalls, 1)
    XCTAssertEqual(englishCalls, 0)
  }

  func testDetectedMandarinLiveEvidenceOverridesEnglishShapedText() async throws {
    let fallback = RoutingASRPort(text: "unused", model: "mixed")
    let mandarin = RoutingASRPort(
      text: "这是中文实时识别结果。",
      model: "zh"
    )
    let english = RoutingASRPort(text: "wrong route", model: "en")
    let router = AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: fallback,
      mandarinFinal: mandarin,
      englishFinal: english,
      languageEvidenceText: "Just the way so harden any kind of kind way.",
      languageEvidenceHints: ["zh-CN"],
      permitsEmptyResult: false
    )

    let result = try await router.recognize(makeRoutingRequest())
    let fallbackCalls = await fallback.callCount()
    let mandarinCalls = await mandarin.callCount()
    let englishCalls = await english.callCount()

    XCTAssertEqual(result.modelArtifactID, "zh")
    XCTAssertEqual(fallbackCalls, 0)
    XCTAssertEqual(mandarinCalls, 1)
    XCTAssertEqual(englishCalls, 0)
  }

  private func makeRoutingRequest() -> DictationASRRequest {
    DictationASRRequest(
      sessionID: SessionID(UUID()),
      inputRevision: 1,
      audio: [],
      dictionaryTerms: []
    )
  }
}

final class LazyManagedASREngineTests: XCTestCase {
  func testConcurrentPrewarmBuildsOneRuntimeAndReusesIt() async throws {
    let artifact = ModelArtifactDescriptor(
      artifactID: "fixture-prewarmed-asr",
      version: "1",
      sha256: String(repeating: "a", count: 64),
      runtimeID: InferenceRuntimeID("fixture-prewarmed-runtime"),
      capabilities: [.asrBatch],
      minimumOS: InferenceOSVersion(major: 14, minor: 2),
      supportedArchitectures: ["arm64"],
      minimumUnifiedMemoryBytes: 0,
      licenseIdentifier: "fixture",
      networkRequired: false
    )
    let factory = PrewarmedASRFactory(artifact: artifact)
    let engine = LazyManagedASREngine(
      artifact: artifact,
      factory: { try await factory.make() }
    )

    async let first: Void = engine.prepare()
    async let second: Void = engine.prepare()
    _ = try await (first, second)
    try await engine.prepare()

    let makeCount = await factory.makeCount()
    XCTAssertEqual(makeCount, 1)
  }
}

private actor PrewarmedASRFactory {
  private let artifact: ModelArtifactDescriptor
  private var count = 0

  init(artifact: ModelArtifactDescriptor) {
    self.artifact = artifact
  }

  func make() async throws -> any ASREngine {
    count += 1
    try await Task.sleep(nanoseconds: 30_000_000)
    return PrewarmedASREngine(artifact: artifact)
  }

  func makeCount() -> Int { count }
}

private struct PrewarmedASREngine: ASREngine {
  let artifact: ModelArtifactDescriptor

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    throw CancellationError()
  }
}

private actor RoutingASRPort: VersionedDictationASRPort {
  private let result: DictationTranscriptResult
  private let failure: InferenceEngineError?
  private var count = 0

  init(
    text: String, model: String, languageHints: [String] = [], failure: InferenceEngineError? = nil
  ) {
    self.failure = failure
    result = DictationTranscriptResult(
      revisionID: TranscriptRevisionID(UUID()),
      segmentIDs: [],
      text: text,
      modelArtifactID: model,
      provenance: languageHints.isEmpty
        ? nil
        : DictationTranscriptProvenance(
          parentRevisionID: nil,
          kind: .final,
          languageHints: languageHints,
          audioRanges: [],
          segments: []
        )
    )
  }

  func recognize(
    _ request: DictationASRRequest
  ) throws -> DictationTranscriptResult {
    count += 1
    if let failure { throw failure }
    return result
  }

  func recognize(
    _ request: VersionedDictationASRRequest
  ) throws -> DictationTranscriptResult {
    count += 1
    if let failure { throw failure }
    return result
  }

  func callCount() -> Int { count }
}

final class LocalDictionaryTransferCodecTests: XCTestCase {
  func testExportedCSVWithCRLFRowsImportsAgain() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let entries = try [
      DictionaryEntry(
        revision: Revision(1), canonicalForm: "bestASR", spokenForms: ["百思特"], enabled: true,
        createdAt: now, updatedAt: now),
      DictionaryEntry(
        revision: Revision(1), canonicalForm: "Claude Code", spokenForms: [], enabled: false,
        createdAt: now, updatedAt: now),
    ]
    let data = try LocalDictionaryTransferCodec.encode(entries: entries, format: .csv)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\r\n"))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dictionary-\(UUID().uuidString).csv")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try LocalDictionaryTransferCodec.decode(url: url)

    XCTAssertEqual(decoded.map(\.canonicalForm), ["bestASR", "Claude Code"])
    XCTAssertEqual(decoded.map(\.spokenForms), [["百思特"], []])
    XCTAssertEqual(decoded.map(\.enabled), [true, false])
  }
}

final class DefaultPolishMigrationTests: XCTestCase {
  func testModelPolishIsSwitchedOffOnceThenFollowsTheUser() throws {
    let suite = "bestasr-polish-migration-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "preferences.default-polish-enabled")

    XCTAssertFalse(DictationAppModel.initialDefaultPolishEnabled(defaults: defaults))
    defaults.set(true, forKey: "preferences.default-polish-enabled")
    XCTAssertTrue(
      DictationAppModel.initialDefaultPolishEnabled(defaults: defaults),
      "After the one-time migration the user's own choice wins")
  }
}
