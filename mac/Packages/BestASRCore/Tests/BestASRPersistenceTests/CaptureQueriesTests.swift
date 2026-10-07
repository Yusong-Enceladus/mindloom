import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation
import XCTest

/// v11 capture queries: a file taken in twice is found by its bytes'
/// SHA-256 (never by its name), and what waits for the DGX Spark is counted.
/// Every value is synthetic.
final class CaptureQueriesTests: XCTestCase {
  private let capturedAt = Date(timeIntervalSince1970: 2_000)

  private func makeStore() throws -> GRDBDictationStore {
    let root = try persistenceTemporaryDirectory()
    return try GRDBDictationStore(databaseURL: root.appendingPathComponent("capture.sqlite"))
  }

  private func fileDraft(_ id: SessionID, digest: Character, name: String) throws -> UserItemDraft {
    UserItemDraft(
      id: id, kind: .image, capturedAt: capturedAt, source: nil, sourceOrigin: .finder, text: "",
      extractor: "imageio-normalize-v1", pixelWidth: 3_000, pixelHeight: 2_000,
      originalFilename: name,
      attachments: [
        UserItemAttachment(
          role: .original,
          relativePath: "sessions/\(id.rawValue.uuidString.lowercased())/source/original.png",
          originalFilename: name, mediaType: "image/png", digest: try persistenceDigest(digest),
          sizeBytes: 100),
        UserItemAttachment(
          role: .normalizedImage,
          relativePath: "sessions/\(id.rawValue.uuidString.lowercased())/source/normalized.jpg",
          originalFilename: "normalized.jpg", mediaType: "image/jpeg",
          digest: try persistenceDigest("f"), sizeBytes: 50),
      ])
  }

  func testTheSameBytesAreFoundWhateverTheName() async throws {
    let store = try makeStore()
    let first = SessionID()
    try await store.createUserItem(try fileDraft(first, digest: "a", name: "截屏 1.png"))
    let digest = try persistenceDigest("a").value
    let found = try await store.existingCapture(withOriginalDigest: digest)
    XCTAssertEqual(found, first)
    // Upper-case digests match too.
    let upper = try await store.existingCapture(withOriginalDigest: digest.uppercased())
    XCTAssertEqual(upper, first)
    // Other bytes (even under the same name) are new.
    let other = try await store.existingCapture(
      withOriginalDigest: try persistenceDigest("b").value)
    XCTAssertNil(other)
    // Not a digest at all.
    let junk = try await store.existingCapture(withOriginalDigest: "截屏 1.png")
    XCTAssertNil(junk)
  }

  func testPastedItemsHaveNoAudioToDelete() async throws {
    let store = try makeStore()
    try await store.createUserItem(try fileDraft(SessionID(), digest: "c", name: "a.png"))
    let retained = try await store.sessionsRetainingSourceAudio()
    XCTAssertEqual(retained.finished, [])
    XCTAssertEqual(retained.unfinished, 0)
  }

  /// fix-mac: 删除原始录音 never takes the audio of a recording that is
  /// not transcribed yet (its transcript could not be made or retried).
  func testAnUnfinishedRecordingKeepsItsAudio() async throws {
    let store = try makeStore()
    let session = SessionID()
    try await store.create(preparingSnapshot(sessionID: session), inputMode: .dictation)
    let retained = try await store.sessionsRetainingSourceAudio()
    XCTAssertEqual(retained.finished, [])
    XCTAssertEqual(retained.unfinished, 1)
  }

  func testNothingWaitsWhileTheLinkIsOff() async throws {
    let store = try makeStore()
    try await store.createUserItem(try fileDraft(SessionID(), digest: "d", name: "b.png"))
    let waiting = try await store.undeliveredRemoteItemCount()
    XCTAssertEqual(waiting, 0)
  }

  func testAnItemTakenWithTheLinkOnWaits() async throws {
    let store = try makeStore()
    try await store.enableRemoteLink(at: Date(timeIntervalSince1970: 1))
    try await store.createUserItem(
      UserItemDraft(
        id: SessionID(), kind: .text, capturedAt: capturedAt, source: nil,
        sourceOrigin: .previousFrontmost, text: "虚构的一句话", extractor: "pasteboard-text-v1"))
    let waiting = try await store.undeliveredRemoteItemCount()
    XCTAssertEqual(waiting, 1)
  }
}
