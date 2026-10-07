import Foundation
import XCTest

@testable import MindloomPhoneKit

/// The app's storage when the App Group entitlement is missing (a device
/// build signed by a free Personal Team): it falls back to its own
/// Application Support instead of failing.
final class PhoneStorageRootTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = try makeTemporaryDirectory()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private struct Unwritable: Error {}

  func testUsesTheAppGroupWhenItExists() throws {
    let group = root.appendingPathComponent("group", isDirectory: true)
    var askedForFallback = false
    let storage = try PhoneAppGroup.storageRoot(
      sharedContainer: group,
      applicationSupport: {
        askedForFallback = true
        return self.root.appendingPathComponent("support")
      })
    XCTAssertEqual(storage, PhoneAppGroup.StorageRoot(url: group, isShared: true))
    XCTAssertFalse(askedForFallback, "Application Support is not touched when the group exists")
  }

  func testFallsBackToApplicationSupportWithoutTheEntitlement() throws {
    let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    let storage = try PhoneAppGroup.storageRoot(
      sharedContainer: nil, applicationSupport: { support })
    XCTAssertEqual(storage.url, support)
    XCTAssertFalse(storage.isShared, "the extensions cannot reach the fallback")

    // The app's whole layout works under the fallback, even before
    // Application Support exists.
    let outbox = try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: storage.url))
    XCTAssertEqual(try outbox.queued(), [])
    let channel = try VoiceChannel(directory: PhoneAppGroup.voiceDirectory(in: storage.url))
    try channel.writeState(VoiceState(sessionAliveUntil: 1, seq: 3, heartbeatAt: 1))
    XCTAssertEqual(channel.highestSeq(), 3)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: support.appendingPathComponent("voice/state.json").path))
    XCTAssertEqual(
      PhoneAppGroup.pairingRecordFile(in: storage.url).deletingLastPathComponent()
        .standardizedFileURL, support.standardizedFileURL)
  }

  func testReportsAnUnusableFallbackInsteadOfGuessing() {
    XCTAssertThrowsError(
      try PhoneAppGroup.storageRoot(
        sharedContainer: nil, applicationSupport: { throw Unwritable() })
    ) { error in
      XCTAssertTrue(error is Unwritable)
    }
  }
}
