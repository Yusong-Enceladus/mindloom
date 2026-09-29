import BestASRAudioJournal
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import Foundation
import XCTest

final class ProductionAudioJournalTests: XCTestCase {
  func testExplicitDeletionAllowsSessionWhoseCaptureNeverCreatedAssets()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try ProductionAudioJournal(assetRootURL: root)

    let staged = try await journal.stageExplicitDeletion(
      sessionID: SessionID(journalUUID(99))
    )

    XCTAssertNil(staged)
  }

  func testExplicitDeletionStillStagesAndCommitsExistingAssets() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(98))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    let sessionRoot = await journal.journalRootURL(sessionID: sessionID)
      .deletingLastPathComponent()

    let stagedDeletion = try await journal.stageExplicitDeletion(
      sessionID: sessionID
    )
    let staged = try XCTUnwrap(stagedDeletion)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))

    try await journal.commitExplicitDeletion(staged)

    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
  }

  func testDiskPolicyHasDeterministicSoftAndHardBoundaries() throws {
    let policy = try CaptureDiskSpacePolicy(
      warningThresholdBytes: 1_000,
      hardStopThresholdBytes: 100
    )

    XCTAssertEqual(policy.evaluate(availableBytes: 1_001).state, .available)
    XCTAssertEqual(policy.evaluate(availableBytes: 1_000).state, .warning)
    XCTAssertEqual(policy.evaluate(availableBytes: 101).state, .warning)
    XCTAssertEqual(policy.evaluate(availableBytes: 100).state, .hardStop)
    XCTAssertEqual(policy.evaluate(availableBytes: 0).state, .hardStop)
    XCTAssertThrowsError(
      try CaptureDiskSpacePolicy(
        warningThresholdBytes: 100,
        hardStopThresholdBytes: 100
      )
    )
  }

  func testDiskPressureStopPreservesCommittedSourceAndDoesNotClaimSealed() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(0))
    let source = floatPCM([0.125, -0.125, 0.5, -0.5])
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(sequence: 0, start: 10, bytes: source)
    )

    try await journal.stopForDiskPressure(sessionID: sessionID)

    let restarted = try ProductionAudioJournal(assetRootURL: root)
    let report = try await restarted.recover(sessionID: sessionID)
    XCTAssertEqual(report.state, .stoppedForDiskPressure)
    XCTAssertEqual(report.readableCommittedChunkCount, 1)
    XCTAssertEqual(report.issueCount, 0)
    XCTAssertEqual(report.ranges.count, 1)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(report.ranges[0].assetReference)),
      source
    )
    let status = try await restarted.recoveryStatus(sessionID: sessionID)
    XCTAssertFalse(status.sealed)
  }

  func testManifestPrecedesChunksAndSealPreservesSourceBytes() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(1))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    let journalRoot = await journal.journalRootURL(sessionID: sessionID)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: journalRoot.appendingPathComponent("manifest.json").path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: journalRoot.appendingPathComponent("production-metadata.json").path
      )
    )

    let firstBytes = floatPCM([0, 0.25, -0.25, 0.5])
    let secondBytes = floatPCM([0.75, -0.75, 0.1, -0.1])
    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(sequence: 0, start: 10, bytes: firstBytes)
    )
    try await journal.append(
      sessionID: sessionID,
      marker: DictationTimelineMarker(kind: .paused, monotonicNanoseconds: 20)
    )
    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(sequence: 1, start: 30, bytes: secondBytes)
    )
    let ranges = try await journal.seal(sessionID: sessionID)

    XCTAssertEqual(ranges.count, 2)
    XCTAssertEqual(ranges.map(\.monotonicStartNanoseconds), [10, 30])
    XCTAssertTrue(ranges.allSatisfy { !$0.assetReference.hasPrefix("/") })
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(ranges[0].assetReference)),
      firstBytes
    )
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(ranges[1].assetReference)),
      secondBytes
    )
    let metadata = try await journal.metadata(sessionID: sessionID)
    XCTAssertEqual(metadata.state, .sealed)
    XCTAssertEqual(metadata.timeline.map(\.kind), [.paused])
  }

  func testCommittedSnapshotAndInferenceMaterializationWorkBeforeSeal() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(2))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(
        sequence: 0,
        start: 1_000_000_000,
        bytes: floatPCM([Float](repeating: 0.1, count: 4_800))
      )
    )

    let firstSnapshot = try await journal.committedAudioSnapshot(
      sessionID: sessionID
    )
    XCTAssertEqual(firstSnapshot.count, 1)
    let journalRoot = await journal.journalRootURL(sessionID: sessionID)
    let manifestBeforeLiveInference = try Data(
      contentsOf: journalRoot.appendingPathComponent("manifest.json")
    )
    let prepared = try await journal.prepareInferenceAudio(
      sessionID: sessionID,
      sourceAudio: firstSnapshot
    )
    XCTAssertFalse(prepared.isEmpty)
    XCTAssertTrue(prepared.allSatisfy { $0.sampleRateHertz == 16_000 })
    let liveMetadata = try await journal.metadata(sessionID: sessionID)
    XCTAssertEqual(
      liveMetadata.state,
      .recording,
      "live inference must not seal or mutate source capture state"
    )
    XCTAssertEqual(
      try Data(contentsOf: journalRoot.appendingPathComponent("manifest.json")),
      manifestBeforeLiveInference,
      "live inference must not rewrite the growing crash-recovery manifest"
    )

    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(
        sequence: 1,
        start: 1_100_000_000,
        bytes: floatPCM([Float](repeating: 0.2, count: 4_800))
      )
    )
    let secondSnapshot = try await journal.committedAudioSnapshot(
      sessionID: sessionID
    )
    XCTAssertEqual(secondSnapshot.count, 2)
    XCTAssertEqual(Array(secondSnapshot.prefix(1)), firstSnapshot)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(firstSnapshot[0].assetReference)),
      floatPCM([Float](repeating: 0.1, count: 4_800))
    )
  }

  func testInferenceScratchUsesLeasesAndStaleScratchIsPurgedOnRelaunch()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(21))
    let sourceBytes = floatPCM([Float](repeating: 0.2, count: 4_800))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(sequence: 0, start: 1_000, bytes: sourceBytes)
    )
    let source = try await journal.committedAudioSnapshot(sessionID: sessionID)
    async let firstTask = journal.prepareInferenceAudio(
      sessionID: sessionID,
      sourceAudio: source
    )
    async let secondTask = journal.prepareInferenceAudio(
      sessionID: sessionID,
      sourceAudio: source
    )
    let (first, second) = try await (firstTask, secondTask)
    let derivationDirectory =
      root
      .appendingPathComponent(first[0].assetReference)
      .deletingLastPathComponent()

    XCTAssertEqual(first, second)
    XCTAssertTrue(FileManager.default.fileExists(atPath: derivationDirectory.path))

    await journal.discardInferenceAudio(
      sessionID: sessionID,
      preparedAudio: first
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: derivationDirectory.path),
      "one active consumer lease must keep the shared derivative readable"
    )
    await journal.discardInferenceAudio(
      sessionID: sessionID,
      preparedAudio: second
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: derivationDirectory.path))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(source[0].assetReference)),
      sourceBytes,
      "scratch cleanup must never remove retained source audio"
    )

    let staleDirectory =
      root
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(
        sessionID.rawValue.uuidString.lowercased(),
        isDirectory: true
      )
      .appendingPathComponent("inference", isDirectory: true)
      .appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
    try FileManager.default.createDirectory(
      at: staleDirectory,
      withIntermediateDirectories: true
    )
    try Data([1, 2, 3]).write(
      to: staleDirectory.appendingPathComponent("window-00000.f32le")
    )

    _ = try ProductionAudioJournal(assetRootURL: root)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          staleDirectory
          .deletingLastPathComponent()
          .path
      ),
      "a relaunched process must purge reproducible unleased scratch"
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(source[0].assetReference).path
      )
    )
  }

  func testInferenceMaterializationNormalizesFractionalHostTimeOverlap() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(22))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    let descriptor = MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "builtin-44khz-fixture",
      sampleRateHertz: 44_100,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
    try await journal.create(sessionID: sessionID, descriptor: descriptor)
    let samples = [Float](repeating: 0.1, count: 4_410)
    let bytes = samples.withUnsafeBytes { Data($0) }
    for sequence in 0..<12 {
      // Mirrors the low-microsecond overlap observed from the built-in mic's
      // host clock even though each callback contains exactly 100 ms of audio.
      // The sequence is intentionally long enough for the cumulative drift to
      // exceed the per-callback tolerance that used to reject real recordings.
      let nominalStart = 1_000_000_000 + UInt64(sequence) * 100_000_000
      let jitteredStart = sequence == 0 ? nominalStart : nominalStart - 7_584
      try await journal.append(
        sessionID: sessionID,
        chunk: CapturedPCMChunk(
          sequence: UInt64(sequence),
          monotonicStartNanoseconds: jitteredStart,
          frameCount: UInt64(samples.count),
          sampleRateHertz: 44_100,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: bytes
        )
      )
    }

    let ranges = try await journal.seal(sessionID: sessionID)
    XCTAssertEqual(
      ranges.map(\.monotonicStartNanoseconds),
      (0..<12).map { 1_000_000_000 + UInt64($0) * 100_000_000 }
    )
    let prepared = try await journal.prepareInferenceAudio(
      sessionID: sessionID,
      sourceAudio: ranges
    )
    XCTAssertFalse(prepared.isEmpty)
    XCTAssertTrue(prepared.allSatisfy { $0.sampleRateHertz == 16_000 })
  }

  func testCommittedInferenceAudioMatchesFinalMaterializationSampleForSample() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(24))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "builtin-44khz-fixture", sampleRateHertz: 44_100,
        channelCount: 1, encoding: .float32LittleEndian, interleaved: true))
    let live = try CommittedInferenceAudio(windowLimit: 480_000)
    // Uneven chunk sizes, like a pause flush in the middle of a recording.
    let frameCounts = [4_410, 4_410, 1_637, 4_410, 2_773, 4_410, 4_410, 4_410, 900, 4_410]
    var start: UInt64 = 1_000_000_000
    var offset = 0
    var prefixAtPause: [Float] = []
    for (sequence, frames) in frameCounts.enumerated() {
      let samples = (0..<frames).map { Float(sin(Double(offset + $0) * 0.031)) * 0.3 }
      let captured = CapturedPCMChunk(
        sequence: UInt64(sequence), monotonicStartNanoseconds: start,
        frameCount: UInt64(frames), sampleRateHertz: 44_100, channelCount: 1,
        encoding: .float32LittleEndian, interleaved: true,
        bytes: samples.withUnsafeBytes { Data($0) })
      try await journal.append(sessionID: sessionID, chunk: captured)
      await live.append(captured)
      if sequence == 4 { prefixAtPause = await live.samples }
      offset += frames
      start += UInt64(frames) * 1_000_000_000 / 44_100
    }

    let ranges = try await journal.seal(sessionID: sessionID)
    let prepared = try await journal.prepareInferenceAudio(sessionID: sessionID, sourceAudio: ranges)
    XCTAssertEqual(prepared.count, 1)
    let final = try Data(contentsOf: root.appendingPathComponent(prepared[0].assetReference))
      .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let whole = await live.samples
    XCTAssertFalse(prefixAtPause.isEmpty)
    XCTAssertEqual(Array(final.prefix(prefixAtPause.count)), prefixAtPause)
    XCTAssertEqual(Array(final.prefix(whole.count)), whole)
    XCTAssertLessThanOrEqual(final.count - whole.count, 4)
  }

  func testCommittedInferenceAudioCutsTheSameWindowsAsFinalMaterialization() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(25))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "builtin-48khz-fixture", sampleRateHertz: 48_000,
        channelCount: 1, encoding: .float32LittleEndian, interleaved: true))
    let live = try CommittedInferenceAudio(windowLimit: 480_000)
    // 70 s of speech with pauses at 23 s and 51 s, in 500 ms chunks plus a
    // short flush-sized chunk now and then.
    var windows: [[Float]] = []
    var start: UInt64 = 1_000_000_000
    var offset = 0
    var sequence: UInt64 = 0
    while offset < 70 * 48_000 {
      let frames = sequence % 7 == 3 ? 7_391 : 24_000
      let samples = (0..<frames).map { index -> Float in
        let second = Double(offset + index) / 48_000
        let pause = (23.0..<23.6).contains(second) || (51.0..<51.5).contains(second)
        return pause ? 0 : Float(sin(Double(offset + index) * 0.021)) * 0.25
      }
      let captured = CapturedPCMChunk(
        sequence: sequence, monotonicStartNanoseconds: start, frameCount: UInt64(frames),
        sampleRateHertz: 48_000, channelCount: 1, encoding: .float32LittleEndian,
        interleaved: true, bytes: samples.withUnsafeBytes { Data($0) })
      try await journal.append(sessionID: sessionID, chunk: captured)
      await live.append(captured)
      windows += await live.takeCompletedWindows()
      offset += frames
      start += UInt64(frames) * 1_000_000_000 / 48_000
      sequence += 1
    }

    let ranges = try await journal.seal(sessionID: sessionID)
    let prepared = try await journal.prepareInferenceAudio(sessionID: sessionID, sourceAudio: ranges)
    let final = try prepared.map {
      try Data(contentsOf: root.appendingPathComponent($0.assetReference))
        .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    XCTAssertEqual(final.count, 3)
    XCTAssertEqual(windows.count, 2, "Two windows are final before release")
    XCTAssertEqual(Array(final.prefix(2)), windows, "Completed windows match sample for sample")
    let rest = await live.samples
    XCTAssertEqual(Array(final[2].prefix(rest.count)), rest)
  }

  func testInferenceMaterializationBuildsIndependentWindowsForInterleavedTracks()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(23))
    let remoteTrack = TrackID(journalUUID(230))
    let microphoneTrack = TrackID(journalUUID(231))
    let remoteDescriptor = CaptureTrackDescriptor(
      id: remoteTrack,
      role: .systemRemote,
      deviceUID: "process-tap-fixture",
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
    let microphoneDescriptor = CaptureTrackDescriptor(
      id: microphoneTrack,
      role: .microphoneLocal,
      deviceUID: "builtin-44khz-fixture",
      sampleRateHertz: 44_100,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
    let journal = try ProductionAudioJournal(
      assetRootURL: root,
      inferenceWindowNanoseconds: 1_000_000_000
    )
    try await journal.create(
      sessionID: sessionID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: sessionID,
        deviceUID: remoteDescriptor.deviceUID,
        sampleRateHertz: remoteDescriptor.sampleRateHertz,
        channelCount: remoteDescriptor.channelCount,
        encoding: remoteDescriptor.encoding,
        interleaved: remoteDescriptor.interleaved,
        tracks: [remoteDescriptor, microphoneDescriptor]
      )
    )
    let start: UInt64 = 5_000_000_000
    let remoteBytes = floatPCM([Float](repeating: 0.1, count: 12_000))
    let microphoneBytes = floatPCM([Float](repeating: 0.2, count: 11_025))
    for sequence in 0..<4 {
      let chunkStart = start + UInt64(sequence) * 250_000_000
      try await journal.append(
        sessionID: sessionID,
        chunk: CapturedPCMChunk(
          trackID: remoteTrack,
          sequence: UInt64(sequence),
          monotonicStartNanoseconds: chunkStart,
          frameCount: 12_000,
          sampleRateHertz: 48_000,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: remoteBytes
        )
      )
      try await journal.append(
        sessionID: sessionID,
        chunk: CapturedPCMChunk(
          trackID: microphoneTrack,
          sequence: UInt64(sequence),
          monotonicStartNanoseconds: chunkStart,
          frameCount: 11_025,
          sampleRateHertz: 44_100,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: microphoneBytes
        )
      )
    }

    let source = try await journal.seal(sessionID: sessionID)
    let prepared = try await journal.prepareInferenceAudio(
      sessionID: sessionID,
      sourceAudio: source
    )

    XCTAssertEqual(source.count, 8)
    XCTAssertEqual(prepared.count, 2)
    XCTAssertEqual(
      Set(prepared.map(\.trackID)),
      Set([remoteTrack.rawValue, microphoneTrack.rawValue])
    )
    XCTAssertTrue(prepared.allSatisfy { $0.sampleRateHertz == 16_000 })
    XCTAssertTrue(prepared.allSatisfy { $0.channelCount == 1 })
    XCTAssertEqual(prepared.map(\.monotonicStartNanoseconds), [start, start])
    XCTAssertTrue(
      prepared.allSatisfy {
        $0.monotonicEndNanoseconds >= start + 999_000_000
          && $0.monotonicEndNanoseconds <= start + 1_001_000_000
      }
    )
  }

  func testCommittedChunkReopensAfterInjectedKill() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(10))
    let firstProcess = try ProductionAudioJournal(assetRootURL: root)
    try await firstProcess.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    do {
      try await firstProcess.append(
        sessionID: sessionID,
        chunk: chunk(sequence: 0, start: 0, bytes: floatPCM([0.2, 0.4])),
        faultPoint: .afterManifestCommit
      )
      XCTFail("Expected injected crash")
    } catch let error as AudioJournalError {
      XCTAssertEqual(error, .injectedCrash(.afterManifestCommit))
    }

    let restarted = try ProductionAudioJournal(assetRootURL: root)
    let report = try await restarted.recover(sessionID: sessionID)
    XCTAssertEqual(report.readableCommittedChunkCount, 1)
    XCTAssertEqual(report.issueCount, 0)
    XCTAssertEqual(report.ranges.count, 1)
    let sealed = try await restarted.seal(sessionID: sessionID)
    XCTAssertEqual(sealed, report.ranges)
  }

  func testPartialStagingWriteIsQuarantinedAndNeverPublished() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(20))
    let firstProcess = try ProductionAudioJournal(assetRootURL: root)
    try await firstProcess.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    do {
      try await firstProcess.append(
        sessionID: sessionID,
        chunk: chunk(
          sequence: 0,
          start: 0,
          bytes: floatPCM([0.1, 0.2, 0.3, 0.4])
        ),
        faultPoint: .afterPartialStagingWrite
      )
      XCTFail("Expected injected crash")
    } catch let error as AudioJournalError {
      XCTAssertEqual(error, .injectedCrash(.afterPartialStagingWrite))
    }

    let restarted = try ProductionAudioJournal(assetRootURL: root)
    let report = try await restarted.recover(sessionID: sessionID)
    XCTAssertEqual(report.readableCommittedChunkCount, 0)
    XCTAssertEqual(report.ranges, [])
    XCTAssertGreaterThan(report.quarantinedByteCount, 0)
    XCTAssertGreaterThan(report.issueCount, 0)
  }

  func testSequenceFormatAndCommittedDeletionFailClosed() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(journalUUID(30))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: descriptor(sessionID: sessionID)
    )
    await assertThrowsJournalError(.invalidSequence(expected: 0, actual: 1)) {
      try await journal.append(
        sessionID: sessionID,
        chunk: chunk(sequence: 1, start: 0, bytes: floatPCM([0.1]))
      )
    }
    var wrongFormat = chunk(sequence: 0, start: 0, bytes: Data([0, 0]))
    wrongFormat = CapturedPCMChunk(
      sequence: wrongFormat.sequence,
      monotonicStartNanoseconds: wrongFormat.monotonicStartNanoseconds,
      frameCount: 1,
      sampleRateHertz: wrongFormat.sampleRateHertz,
      channelCount: wrongFormat.channelCount,
      encoding: .int16LittleEndian,
      interleaved: true,
      bytes: wrongFormat.bytes
    )
    await assertThrowsJournalError(.formatChanged) {
      try await journal.append(sessionID: sessionID, chunk: wrongFormat)
    }
    try await journal.append(
      sessionID: sessionID,
      chunk: chunk(sequence: 0, start: 0, bytes: floatPCM([0.1]))
    )
    _ = try await journal.seal(sessionID: sessionID)
    await assertThrowsJournalError(.committedSourceCannotBeCancelled) {
      try await journal.cancelEphemeral(sessionID: sessionID)
    }
  }

  func testCancelRemovesOnlyNamedEphemeralSession() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstID = SessionID(journalUUID(40))
    let secondID = SessionID(journalUUID(41))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(sessionID: firstID, descriptor: descriptor(sessionID: firstID))
    try await journal.create(sessionID: secondID, descriptor: descriptor(sessionID: secondID))
    let firstRoot = await journal.journalRootURL(sessionID: firstID)
    let secondRoot = await journal.journalRootURL(sessionID: secondID)

    try await journal.cancelEphemeral(sessionID: firstID)

    XCTAssertFalse(FileManager.default.fileExists(atPath: firstRoot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondRoot.path))
    let secondMetadata = try await journal.metadata(sessionID: secondID)
    XCTAssertEqual(secondMetadata.sessionID, secondID)
  }

  private func descriptor(sessionID: SessionID) -> MicrophoneCaptureDescriptor {
    MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "builtin-fixture",
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
  }

  private func chunk(
    sequence: UInt64,
    start: UInt64,
    bytes: Data
  ) -> CapturedPCMChunk {
    CapturedPCMChunk(
      sequence: sequence,
      monotonicStartNanoseconds: start,
      frameCount: UInt64(bytes.count / MemoryLayout<Float>.size),
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true,
      bytes: bytes
    )
  }

  private func floatPCM(_ samples: [Float]) -> Data {
    samples.withUnsafeBytes { Data($0) }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private func journalUUID(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(format: "00000000-0000-4000-8000-%012llx", value)
  )!
}

private func assertThrowsJournalError(
  _ expected: ProductionAudioJournalError,
  operation: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as ProductionAudioJournalError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
