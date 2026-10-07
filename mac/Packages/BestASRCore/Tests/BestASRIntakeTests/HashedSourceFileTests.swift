import CryptoKit
import Foundation
import XCTest

@testable import BestASRIntake

/// The drop path's digest of a recording is reused by the import's copy only
/// while it still describes the file (finish-mac: the media is not hashed
/// twice). Synthetic bytes only.
final class HashedSourceFileTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("hashed-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  func testDigestIsTheSHA256OfTheBytesReadInChunks() throws {
    let url = folder.appendingPathComponent("a.m4a")
    let bytes = Data((0..<10_000).map { UInt8($0 % 251) })
    try bytes.write(to: url)
    let hashed = try XCTUnwrap(HashedSourceFile.hash(url, chunk: 1_000))
    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(hashed.digest, expected)
    XCTAssertEqual(hashed.fingerprint.size, 10_000)
    XCTAssertTrue(hashed.stillDescribes(url))
  }

  func testAChangedOrOtherFileIsNotDescribed() throws {
    let url = folder.appendingPathComponent("a.wav")
    try Data(repeating: 1, count: 4096).write(to: url)
    let hashed = try XCTUnwrap(HashedSourceFile.hash(url))

    // Another file with the same bytes is another file.
    let other = folder.appendingPathComponent("b.wav")
    try Data(repeating: 1, count: 4096).write(to: other)
    XCTAssertFalse(hashed.stillDescribes(other))

    // The same file, rewritten.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([2]))
    try handle.close()
    XCTAssertFalse(hashed.stillDescribes(url))

    // Gone.
    try FileManager.default.removeItem(at: url)
    XCTAssertFalse(hashed.stillDescribes(url))
    XCTAssertNil(HashedSourceFile.hash(url))
  }

  /// review finish-ship: a read that fails part way gives no digest, so the
  /// import hashes its own copy instead of recording part of the file.
  func testAReadErrorPartWayGivesNoDigest() throws {
    let url = folder.appendingPathComponent("c.m4a")
    try Data(repeating: 7, count: 10_000).write(to: url)
    struct Flaky: Error {}
    var reads = 0
    let hashed = HashedSourceFile.hash(url, chunk: 1_000) { handle, count in
      reads += 1
      if reads == 4 { throw Flaky() }
      return try handle.read(upToCount: count)
    }
    XCTAssertNil(hashed)
    XCTAssertEqual(reads, 4)
  }

  /// A reader that stops early (no error, fewer bytes than the size).
  func testAShortReadGivesNoDigest() throws {
    let url = folder.appendingPathComponent("d.m4a")
    try Data(repeating: 9, count: 5_000).write(to: url)
    var reads = 0
    let hashed = HashedSourceFile.hash(url, chunk: 1_000) { handle, count in
      reads += 1
      return reads > 2 ? nil : try handle.read(upToCount: count)
    }
    XCTAssertNil(hashed)
  }

  /// A dropped symbolic link is hashed and described as the file it names.
  func testASymbolicLinkIsFollowed() throws {
    let target = folder.appendingPathComponent("e.wav")
    let bytes = Data((0..<3_000).map { UInt8($0 % 7) })
    try bytes.write(to: target)
    let link = folder.appendingPathComponent("e-link.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let hashed = try XCTUnwrap(HashedSourceFile.hash(link))
    XCTAssertEqual(
      hashed.digest, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(hashed.fingerprint.size, 3_000)
    XCTAssertTrue(hashed.stillDescribes(link))
  }
}
