import Foundation
import XCTest

@testable import MindloomLookup

/// The rules a source scan can hold: one network exit, no excluded
/// services, nothing written outside the lookup folder.
final class BoundaryTests: XCTestCase {
  static var sourceFolder: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/MindloomLookup")
  }

  func sources() throws -> [(String, String)] {
    let walker = try XCTUnwrap(FileManager.default.enumerator(at: Self.sourceFolder, includingPropertiesForKeys: nil))
    var files: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
    }
    XCTAssertGreaterThan(files.count, 10)
    return files
  }

  func testOneNetworkExit() throws {
    let networking = ["URLSession(", "URLSession.shared", ".dataTask(", ".data(for", ".bytes(for", "NWConnection", "CFStream", "WKWebView", "WebPage(", "Process("]
    for (name, source) in try sources() where name != "Egress.swift" {
      for token in networking {
        XCTAssertFalse(source.contains(token), "\(name) uses \(token)")
      }
    }
  }

  func testExcludedServicesAreAbsent() throws {
    // WEBSEARCH §4.2: grounding services, the closed Google and Bing APIs and
    // result-page scrapers are not in the chain.
    let excluded = ["googleapis.com/customsearch", "generativelanguage.googleapis.com", "api.bing.microsoft.com", "bing.microsoft.com", "serpapi.com", "google.com/search", "duckduckgo.com"]
    for (name, source) in try sources() {
      for host in excluded {
        XCTAssertFalse(source.contains(host), "\(name) names \(host)")
      }
    }
  }

  func testNoContentIsLogged() throws {
    for (name, source) in try sources() {
      XCTAssertNil(source.range(of: #"(?<![A-Za-z])print\("#, options: .regularExpression), name)
      XCTAssertFalse(source.contains("os_log"), name)
      XCTAssertFalse(source.contains("Logger("), name)
      XCTAssertFalse(source.contains("NSLog"), name)
    }
  }

  func testSettingsDefaultToOff() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let lookupFolder = LookupFolder(dataRoot: folder)
    XCTAssertFalse(lookupFolder.loadSettings().enabled)
    try lookupFolder.save(WebLookupSettings(enabled: true, blockedTerms: ["x"], blockedSites: ["y.example"]))
    XCTAssertEqual(lookupFolder.loadSettings(), WebLookupSettings(enabled: true, blockedTerms: ["x"], blockedSites: ["y.example"]))
    try Data(#"{"enabled": "yes"}"#.utf8).write(to: lookupFolder.settingsURL)
    XCTAssertFalse(lookupFolder.loadSettings().enabled)
    // Nothing but the lookup folder is written in the library.
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertEqual(names, ["lookup"])
  }

  /// Expired answers and crash leftovers are removed once per run, so the
  /// cache folder does not grow without end; a recent stale answer stays
  /// (it backs the deadline table when a new copy cannot be had).
  func testCacheRemovesLongExpiredAnswers() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock()
    let cacheFolder = folder.appendingPathComponent("cache", isDirectory: true)
    let first = LookupCache(folder: cacheFolder, now: { clock.now })
    await first.store(Data("old".utf8), for: "old", keepFor: LookupCache.week)
    await first.store(Data("recent".utf8), for: "recent", keepFor: LookupCache.week)
    let leftover = cacheFolder.appendingPathComponent(".x.json.\(UUID().uuidString).tmp")
    try Data().write(to: leftover)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: leftover.path)

    // Forty days on, "old" expired 33 days ago; "recent" is stored again
    // first so it is fresh, then a new run prunes.
    clock.advance(40 * 86_400)
    await first.store(Data("recent".utf8), for: "recent", keepFor: LookupCache.week)
    let second = LookupCache(folder: cacheFolder, now: { clock.now })
    await second.store(Data("new".utf8), for: "new", keepFor: LookupCache.week)
    let stale = await second.body("old", stale: true)
    XCTAssertNil(stale)
    let recent = await second.body("recent")
    XCTAssertEqual(recent, Data("recent".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)
    XCTAssertEqual(names.count, 2)
  }

  /// Writes and removes a key in the real Keychain under a test service;
  /// runs only with MINDLOOM_LOOKUP_KEYCHAIN_TEST=1 (it touches the login
  /// keychain of the Mac running the tests).
  func testKeychainStore() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["MINDLOOM_LOOKUP_KEYCHAIN_TEST"] == "1")
    let store = KeychainSearchKeyStore(
      keychainService: "app.mindloom.lookup.tests.\(UUID().uuidString)", synchronizable: false)
    defer { try? store.remove(.brave) }
    XCTAssertNil(store.key(for: .brave))
    try store.save("  BSAtest-key-0000000  ", for: .brave)
    XCTAssertEqual(store.key(for: .brave), "BSAtest-key-0000000")
    print("keychain store: synchronizable=\(store.syncsAcrossDevices(.brave))")
    try store.save("BSAtest-key-1111111", for: .brave)
    XCTAssertEqual(store.key(for: .brave), "BSAtest-key-1111111")
    try store.remove(.brave)
    XCTAssertNil(store.key(for: .brave))
    XCTAssertThrowsError(try store.save("bad key\nline", for: .brave))
  }
}

/// Live requests with fixed public words only; run with
/// MINDLOOM_LOOKUP_LIVE=1. They use the real transport and resolver.
final class LiveLookupTests: XCTestCase {
  func liveLookup(keys: [SearchServiceID: String] = [:]) async throws -> WebLookup {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["MINDLOOM_LOOKUP_LIVE"] == "1")
    let lookup = WebLookup(dataRoot: nil, keys: InMemorySearchKeyStore(keys), device: "Mac")
    try await lookup.setEnabled(true)
    return lookup
  }

  func report(_ lookup: WebLookup, _ label: String) async {
    let entries = await lookup.activity.entries()
    let summary = entries.reversed().map { "\($0.kind.rawValue)/\($0.host ?? "-")/\($0.result.rawValue)/\($0.status.map(String.init) ?? "-")/\($0.bytesReceived)B/\($0.durationMilliseconds)ms" }
    print("live \(label): \(summary.joined(separator: " | "))")
  }

  func testPublicIdentifiers() async throws {
    let lookup = try await liveLookup()
    let outcome = await lookup.lookUp(
      request(.paperInfo, .paper, nil, year: nil, identifiers: [.arXiv("1706.03762"), .doi("10.1038/nature14539")]),
      privateTerms: PrivateTerms())
    await report(lookup, "identifiers")
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items[0].title.contains("Attention"))
    XCTAssertTrue(items[1].title.contains("Deep learning"))
  }

  func testConferenceTableAndOfficialPage() async throws {
    let lookup = try await liveLookup()
    let outcome = await lookup.lookUp(request(.deadline, .conference, "NeurIPS", year: nil), privateTerms: PrivateTerms())
    await report(lookup, "conference")
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertTrue(items[0].text.contains("NeurIPS"))
    print("live conference: \(items.count) items, table text \(items[0].text.count) chars, official page \(items.count > 1 ? "\(items[1].text.count) chars, excerpt \(items[1].excerpt.count) chars" : "not read")")
    let names = await lookup.publicNames()
    print("live conference: public names \(names.count)")
  }

  func testNamesAndPlaces() async throws {
    let lookup = try await liveLookup()
    await lookup.learn(publicName: "Swift (programming language)", kind: .other, privateTerms: PrivateTerms())
    await lookup.learn(publicName: "Marina Bay Sands", kind: .place, privateTerms: PrivateTerms())
    let overview = await lookup.lookUp(request(.overview, .other, "Swift (programming language)", year: nil), privateTerms: PrivateTerms())
    let place = await lookup.lookUp(request(.address, .place, "Marina Bay Sands", year: nil, matter: UUID()), privateTerms: PrivateTerms())
    await report(lookup, "names")
    if case .found(let items) = overview { print("live overview: \(items[0].host), \(items[0].text.count) chars") } else { print("live overview: \(overview)") }
    if case .found(let items) = place { print("live place: \(items[0].host), \(items[0].text.count) chars") } else { print("live place: \(place)") }
    guard case .found = place else { return XCTFail("\(place)") }
  }

  func testCollectedLink() async throws {
    let lookup = try await liveLookup()
    let outcome = await lookup.read(link: URL(string: "https://www.swift.org/about/")!, parentItemID: itemA, privateTerms: PrivateTerms(), healthRelated: false)
    await report(lookup, "link")
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    print("live link: \(items[0].title) · \(items[0].text.count) chars · \(items[0].reader)")
    XCTAssertTrue(items[0].text.contains("Swift"))
  }
}
