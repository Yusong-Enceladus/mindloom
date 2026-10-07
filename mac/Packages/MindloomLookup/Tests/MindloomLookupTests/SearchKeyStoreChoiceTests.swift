import Foundation
import MindloomIdentity
import XCTest

@testable import MindloomLookup

/// Verification builds never reach the owner's Keychain item
/// (`app.mindloom.lookup`): a synthetic root keeps keys in a 0600 file inside
/// it, and a check or Preview identity keeps them in memory.
final class SearchKeyStoreChoiceTests: XCTestCase {
  private let key = "BSAsynthetic-key-0000000"

  private func makeRoot(marked: Bool) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("lookup-keys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if marked {
      FileManager.default.createFile(
        atPath: root.appendingPathComponent("SYNTHETIC_DATA_ROOT").path, contents: Data())
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testASyntheticRootUsesAFileInsideItAndNotTheKeychain() throws {
    let root = try makeRoot(marked: true)
    let store = SearchKeyStores.make(
      dataRoot: root, isOwnersLibrary: false, bundleIdentifier: "com.bestasr.mindloom.check")
    XCTAssertTrue(store is SyntheticSearchKeyStore)
    try store.save(key, for: .brave)
    XCTAssertEqual(store.key(for: .brave), key)
    XCTAssertFalse(store.syncsAcrossDevices(.brave))
    let file = root.appendingPathComponent("lookup/search-keys.test")
    var status = stat()
    XCTAssertEqual(lstat(file.path, &status), 0)
    XCTAssertEqual(status.st_mode & 0o777, 0o600)
    try store.remove(.brave)
    XCTAssertNil(store.key(for: .brave))
  }

  func testAnUnmarkedRootIsRefusedByTheFileStore() throws {
    let root = try makeRoot(marked: false)
    XCTAssertNil(SyntheticSearchKeyStore(dataRoot: root))
  }

  func testACheckOrPreviewIdentityNeverGetsTheKeychain() throws {
    let root = try makeRoot(marked: false)
    for identifier in [
      MindloomIdentity.checkBundleIDPrefix, MindloomIdentity.checkBundleIDPrefix + ".x",
      "com.bestasr.mindloom.preview",
    ] {
      let store = SearchKeyStores.make(dataRoot: root, isOwnersLibrary: true, bundleIdentifier: identifier)
      XCTAssertTrue(store is InMemorySearchKeyStore, identifier)
    }
    // A root that is not the owner's library never reaches it either.
    XCTAssertTrue(
      SearchKeyStores.make(dataRoot: root, isOwnersLibrary: false, bundleIdentifier: "app.mindloom")
        is InMemorySearchKeyStore)
  }

  func testTheOwnersLibraryInTheShippedIdentityUsesTheKeychainStore() throws {
    let root = try makeRoot(marked: true)
    for identifier in ["app.mindloom", "app.mindloom.debug", nil] {
      let store = SearchKeyStores.make(dataRoot: root, isOwnersLibrary: true, bundleIdentifier: identifier)
      XCTAssertTrue(store is KeychainSearchKeyStore, identifier ?? "nil")
    }
  }
}
