import BestASRAudioJournal
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import XCTest

final class CommittedAudioSnapshotTests: XCTestCase {
  func testSnapshotPreservesDiscontinuityAndExcludesPartialStagingBlock() async throws {
    let root = try snapshotTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(snapshotUUID(1))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: snapshotDescriptor(sessionID: sessionID)
    )
    try await journal.append(
      sessionID: sessionID,
      chunk: snapshotChunk(sequence: 0, start: 10)
    )
    do {
      try await journal.append(
        sessionID: sessionID,
        chunk: snapshotChunk(sequence: 1, start: 2_000_000_000),
        faultPoint: .afterPartialStagingWrite
      )
      XCTFail("Expected injected partial write")
    } catch let error as AudioJournalError {
      XCTAssertEqual(error, .injectedCrash(.afterPartialStagingWrite))
    }

    let reopened = try ProductionAudioJournal(assetRootURL: root)
    let snapshot = try await reopened.committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(snapshot.count, 1)
    XCTAssertEqual(snapshot[0].monotonicStartNanoseconds, 10)
    XCTAssertLessThan(snapshot[0].monotonicEndNanoseconds, 2_000_000_000)
  }
}

final class ProductionAudioJournalLiveSnapshotTests: XCTestCase {
  func testConcurrentAppendAndSnapshotPublishOnlyStableOrderedPrefixes() async throws {
    let root = try snapshotTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = SessionID(snapshotUUID(2))
    let journal = try ProductionAudioJournal(assetRootURL: root)
    try await journal.create(
      sessionID: sessionID,
      descriptor: snapshotDescriptor(sessionID: sessionID)
    )

    async let append: Void = {
      for sequence in 0..<10 {
        try await journal.append(
          sessionID: sessionID,
          chunk: snapshotChunk(
            sequence: UInt64(sequence),
            start: UInt64(sequence) * 100_000_000
          )
        )
        await Task.yield()
      }
    }()
    async let observe: [[AudioRangeInput]] = {
      var snapshots: [[AudioRangeInput]] = []
      for _ in 0..<20 {
        snapshots.append(
          try await journal.committedAudioSnapshot(sessionID: sessionID)
        )
        await Task.yield()
      }
      return snapshots
    }()

    _ = try await append
    let observed = try await observe
    let final = try await journal.committedAudioSnapshot(sessionID: sessionID)
    XCTAssertEqual(final.count, 10)
    for snapshot in observed {
      XCTAssertEqual(snapshot, Array(final.prefix(snapshot.count)))
      XCTAssertEqual(
        snapshot.map(\.monotonicStartNanoseconds),
        snapshot.map(\.monotonicStartNanoseconds).sorted()
      )
    }
    let metadata = try await journal.metadata(sessionID: sessionID)
    XCTAssertEqual(metadata.state, .recording)
  }
}

private func snapshotDescriptor(sessionID: SessionID) -> MicrophoneCaptureDescriptor {
  MicrophoneCaptureDescriptor(
    sessionID: sessionID,
    deviceUID: "builtin-fixture",
    sampleRateHertz: 48_000,
    channelCount: 1,
    encoding: .float32LittleEndian,
    interleaved: true
  )
}

private func snapshotChunk(sequence: UInt64, start: UInt64) -> CapturedPCMChunk {
  let samples = [Float](repeating: Float(sequence + 1) / 10, count: 4_800)
  return CapturedPCMChunk(
    sequence: sequence,
    monotonicStartNanoseconds: start,
    frameCount: UInt64(samples.count),
    sampleRateHertz: 48_000,
    channelCount: 1,
    encoding: .float32LittleEndian,
    interleaved: true,
    bytes: samples.withUnsafeBytes { Data($0) }
  )
}

private func snapshotTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bestasr-live-snapshot-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func snapshotUUID(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(format: "41000000-0000-4000-8000-%012llx", value)
  )!
}
