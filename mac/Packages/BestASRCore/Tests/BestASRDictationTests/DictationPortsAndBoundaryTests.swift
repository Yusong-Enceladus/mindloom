import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import XCTest

final class DictationPortsAndBoundaryTests: XCTestCase {
  func testDeterministicFakesConformToEveryPort() async throws {
    let capture: any MicrophoneCapturePort = FakeCapturePort()
    let descriptor = try await capture.prepare(sessionID: SessionID(testUUID(70)))
    XCTAssertEqual(descriptor.sampleRateHertz, 48_000)
    try await capture.start()
    try await capture.pause()
    try await capture.resume()
    try await capture.stop()
    await capture.cancel()

    let clock: any DictationClock = FixedDictationClock(value: 9)
    XCTAssertEqual(clock.monotonicNanoseconds(), 9)
    let permissions: any DictationPermissionPort = FakePermissionPort()
    let microphonePermission = await permissions.state(for: .microphone)
    XCTAssertEqual(microphonePermission, .granted)

    let repository: any DictationRepositoryPort = FakeRepositoryPort()
    let journal: any DictationJournalPort = FakeJournalPort()
    let asr: any DictationASRPort = FakeASRPort()
    let polish: any DictationPolishPort = FakePolishPort()
    let insertion: any DictationInsertionPort = FakeInsertionPort()
    let speaker: any DictationSpeakerSchedulingPort = FakeSpeakerPort()
    _ = (repository, journal, asr, polish, insertion, speaker)
  }

  func testProductionContractHasNoUIStorageOrModelSDKImports() throws {
    let sourceRoot =
      repositoryRoot
      .appendingPathComponent("Packages/BestASRCore/Sources/BestASRDictation")
    let files = try FileManager.default.contentsOfDirectory(
      at: sourceRoot,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    let forbiddenImports = [
      "import AppKit",
      "import AVFoundation",
      "import FluidAudio",
      "import GRDB",
      "import MLX",
      "import SwiftUI",
    ]

    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for forbidden in forbiddenImports {
        XCTAssertFalse(source.contains(forbidden), "\(file.lastPathComponent): \(forbidden)")
      }
    }
  }

  private var repositoryRoot: URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("PRODUCT_REQUIREMENTS.md").path
      ) {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root")
  }
}

private struct FakeCapturePort: MicrophoneCapturePort {
  func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
    MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "fixture-device",
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
  }
  func start() async throws {}
  func chunks() async -> AsyncStream<CapturedPCMChunk> {
    AsyncStream { $0.finish() }
  }
  func pause() async throws {}
  func resume() async throws {}
  func stop() async throws {}
  func cancel() async {}
  func terminalFailure() async -> DictationFailure? { nil }
}

private struct FakePermissionPort: DictationPermissionPort {
  func state(for permission: DictationPermissionKind) async -> DictationPermissionState {
    .granted
  }
  func request(_ permission: DictationPermissionKind) async -> DictationPermissionState {
    .granted
  }
  func openRecoverySettings(for permission: DictationPermissionKind) async {}
}

private struct FakeRepositoryPort: DictationRepositoryPort {
  func create(_ snapshot: DictationSessionSnapshot) async throws {}
  func save(_ snapshot: DictationSessionSnapshot) async throws {}
  func load(sessionID: SessionID) async throws -> DictationSessionSnapshot? { nil }
  func loadRecoverable() async throws -> [DictationSessionSnapshot] { [] }
  func reserveInsertion(
    sessionID: SessionID,
    key: DictationIdempotencyKey
  ) async throws -> InsertionReservation { .acquired }
  func completeInsertion(
    sessionID: SessionID,
    result: DictationInsertionResult
  ) async throws {}
  func insertionResult(sessionID: SessionID) async throws
    -> DictationInsertionResult?
  { nil }
  func cancelEphemeral(sessionID: SessionID) async throws {}
}

private struct FakeJournalPort: DictationJournalPort {
  func create(
    sessionID: SessionID,
    descriptor: MicrophoneCaptureDescriptor
  ) async throws {}
  func append(sessionID: SessionID, chunk: CapturedPCMChunk) async throws {}
  func append(
    sessionID: SessionID,
    marker: DictationTimelineMarker
  ) async throws {}
  func seal(sessionID: SessionID) async throws -> [AudioRangeInput] { [] }
  func cancelEphemeral(sessionID: SessionID) async throws {}
  func recoveryStatus(sessionID: SessionID) async throws
    -> DictationJournalRecoveryStatus
  {
    DictationJournalRecoveryStatus(
      committedChunkCount: 0,
      issueCount: 0,
      sealed: false
    )
  }
}

private struct FakeASRPort: DictationASRPort {
  func recognize(_ request: DictationASRRequest) async throws
    -> DictationTranscriptResult
  {
    DictationTranscriptResult(
      revisionID: TranscriptRevisionID(testUUID(71)),
      segmentIDs: [testUUID(72)],
      text: "fixture",
      modelArtifactID: "fixture-asr"
    )
  }
}

private struct FakePolishPort: DictationPolishPort {
  func polish(_ request: DictationPolishRequest) async throws
    -> DictationPolishResult
  {
    DictationPolishResult(
      sourceRevisionID: request.transcript.revisionID,
      text: request.transcript.text,
      disposition: .rawTranscriptFallback,
      modelArtifactID: nil
    )
  }
}

private struct FakeInsertionPort: DictationInsertionPort {
  func captureTarget() async throws -> DictationTargetSnapshot { try testTarget() }
  func insert(_ request: DictationInsertionRequest) async throws
    -> DictationInsertionResult
  {
    DictationInsertionResult(
      idempotencyKey: request.idempotencyKey,
      method: .retainedForCopy,
      inserted: false
    )
  }
}

private struct FakeSpeakerPort: DictationSpeakerSchedulingPort {
  func scheduleFinalSpeakerWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64
  ) async throws {}
}
