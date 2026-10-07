import Foundation
import XCTest

@testable import MindloomLookup

final class EgressTests: XCTestCase {
  func makeEgress(_ transport: FakeTransport, _ resolver: FakeResolver = FakeResolver(), clock: TestClock = TestClock(), dryRun: Bool = false, log: NetworkActivityLog? = nil)
    -> (LookupEgress, NetworkActivityLog)
  {
    let activity = log ?? NetworkActivityLog(fileURL: nil, now: { clock.now })
    let egress = LookupEgress(
      transport: transport, resolver: resolver, activity: activity, device: "Mac", dryRun: dryRun,
      now: { clock.now }, sleep: { clock.sleep($0) })
    return (egress, activity)
  }

  func testEveryRequestIsRecordedWithoutContent() async throws {
    let transport = FakeTransport()
    transport.on(host: "api.search.brave.com", body: Fixture.data("search/brave.json"))
    let (egress, activity) = makeEgress(transport)
    let request = SearchAdapter.request(.brave, terms: "EXCONF 2026 deadline", key: "BSAsynthetic-key-000")
    let result = await egress.fetch(request)
    guard case .success(let response) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(response.status, 200)
    let entries = await activity.entries()
    XCTAssertEqual(entries.count, 1)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entry.kind, .search)
    XCTAssertEqual(entry.service, "brave")
    XCTAssertEqual(entry.host, "api.search.brave.com")
    XCTAssertEqual(entry.device, "Mac")
    XCTAssertEqual(entry.result, .found)
    XCTAssertGreaterThan(entry.bytesSent, 0)
    XCTAssertEqual(entry.bytesReceived, Fixture.data("search/brave.json").count)
    let line = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
    for content in ["EXCONF", "deadline", "2026", "BSAsynthetic", "/res/v1"] {
      XCTAssertFalse(line.contains(content), content)
    }
    // The User-Agent names the program and nothing else.
    XCTAssertEqual(transport.sent.first?.headers["User-Agent"], LookupEgress.defaultUserAgent)
    XCTAssertNil(transport.sent.first?.headers["Cookie"])
  }

  func testANamePointingAtAPrivateAddressIsRefused() async {
    let transport = FakeTransport()
    transport.on(host: "rebind.example.com", body: Data("x".utf8))
    let resolver = FakeResolver()
    resolver.answer("rebind.example.com", ["10.0.0.7"])
    let (egress, activity) = makeEgress(transport, resolver)
    let result = await egress.fetch(EgressRequest(url: URL(string: "https://rebind.example.com/")!, kind: .page, service: "page"))
    XCTAssertEqual(result.failure, .refused(.privateAddress))
    XCTAssertTrue(transport.sent.isEmpty)
    let entries = await activity.entries()
    XCTAssertEqual(entries.first?.result, .notSent)
    XCTAssertEqual(entries.first?.refusal, .privateAddress)
  }

  func testFakeIPProxiesStillWork() async {
    let transport = FakeTransport()
    transport.on(host: "exconf.example.org", body: Data("<html><body><p>ok</p></body></html>".utf8))
    let resolver = FakeResolver()
    resolver.answer("exconf.example.org", ["198.18.0.42"])
    let (egress, _) = makeEgress(transport, resolver)
    let result = await egress.fetch(EgressRequest(url: URL(string: "https://exconf.example.org/")!, kind: .page, service: "page"))
    XCTAssertNotNil(result.success)
  }

  func testRedirectsAreCheckedAgainAndLimited() async {
    let transport = FakeTransport()
    transport.on(host: "a.example.com", status: 302, headers: ["Location": "https://b.example.com/next"], body: Data())
    transport.on(host: "b.example.com", status: 301, headers: ["Location": "/final"], body: Data())
    transport.on(host: "b.example.com", path: "/final", body: Data("done".utf8))
    let check = OutboundCheck(privateTerms: PrivateTerms())
    let (egress, activity) = makeEgress(transport)
    let page = EgressRequest(url: URL(string: "https://a.example.com/start")!, kind: .page, service: "page", followRedirects: true)
    let result = await egress.fetch(page, addressCheck: check)
    XCTAssertEqual(result.success?.finalURL.absoluteString, "https://b.example.com/final")
    XCTAssertEqual(result.success?.body, Data("done".utf8))
    let hops = await activity.entries()
    XCTAssertEqual(hops.count, 3)

    // A redirect to a private address stops there.
    transport.on(host: "c.example.com", status: 302, headers: ["Location": "https://192.168.1.1/admin"], body: Data())
    let private_ = await egress.fetch(
      EgressRequest(url: URL(string: "https://c.example.com/")!, kind: .page, service: "page", followRedirects: true),
      addressCheck: check)
    XCTAssertEqual(private_.failure, .refused(.privateAddress))
    XCTAssertFalse(transport.hosts.contains("192.168.1.1"))

    // A loop ends after three redirects.
    transport.on(host: "loop.example.com", status: 302, headers: ["Location": "https://loop.example.com/again"], body: Data())
    let loop = await egress.fetch(
      EgressRequest(url: URL(string: "https://loop.example.com/")!, kind: .page, service: "page", followRedirects: true),
      addressCheck: check)
    XCTAssertEqual(loop.failure, .tooManyRedirects)
    XCTAssertEqual(transport.hosts.filter { $0 == "loop.example.com" }.count, 4)

    // Service calls follow no redirect.
    let api = await egress.fetch(EgressRequest(url: URL(string: "https://a.example.com/api")!, kind: .search, service: "brave"))
    XCTAssertEqual(api.success?.status, 302)
  }

  func testHTTPAndPlainHostsAreNeverContacted() async {
    let transport = FakeTransport()
    let (egress, _) = makeEgress(transport)
    let plain = await egress.fetch(EgressRequest(url: URL(string: "http://example.com/")!, kind: .page, service: "page"))
    XCTAssertEqual(plain.failure, .refused(.unsupportedAddress))
    let local = await egress.fetch(EgressRequest(url: URL(string: "https://router.local/")!, kind: .page, service: "page"))
    XCTAssertEqual(local.failure, .refused(.privateAddress))
    XCTAssertTrue(transport.sent.isEmpty)
  }

  func testEachHostIsPacedByItsOwnRule() async {
    let transport = FakeTransport()
    transport.on(host: "export.arxiv.org", body: Fixture.data("sources/arxiv.xml"))
    let clock = TestClock()
    let (egress, _) = makeEgress(transport, clock: clock)
    _ = await egress.fetch(ArXivSource.request(id: "1706.03762"))
    _ = await egress.fetch(ArXivSource.request(id: "1706.03762"))
    XCTAssertEqual(clock.slept.count, 1)
    XCTAssertEqual(clock.slept.first ?? 0, 3.1, accuracy: 0.01)
  }

  func testDryRunSendsNothing() async {
    let transport = FakeTransport()
    let (egress, activity) = makeEgress(transport, dryRun: true)
    let result = await egress.fetch(SearchAdapter.request(.brave, terms: "EXCONF 2026 deadline", key: "BSAkey-00000"))
    XCTAssertEqual(result.failure, .dryRun)
    XCTAssertTrue(transport.sent.isEmpty)
    let planned = await egress.takePlanned()
    XCTAssertEqual(planned, [PlannedRequest(kind: .search, service: "brave", host: "api.search.brave.com")])
    let entries = await activity.entries()
    XCTAssertTrue(entries.isEmpty)
  }

  func testAFailedConnectionCountsNoBytes() async {
    let transport = FakeTransport()
    transport.on(host: "api.tavily.com", failure: .cannotConnect)
    transport.on(host: "api.exa.ai", failure: .timedOut)
    let (egress, activity) = makeEgress(transport)
    let first = await egress.fetch(SearchAdapter.request(.tavily, terms: "x", key: "tvly-000000000"))
    XCTAssertEqual(first.failure, .cannotConnect)
    let second = await egress.fetch(SearchAdapter.request(.exa, terms: "x", key: "00000000-0000-0000-0000-000000000000"))
    XCTAssertEqual(second.failure, .timedOut)
    let entries = await activity.entries()
    XCTAssertEqual(entries.map(\.result), [.failed, .failed])
    XCTAssertEqual(entries.last?.bytesSent, 0)
    XCTAssertGreaterThan(entries.first?.bytesSent ?? 0, 0)
  }

  func testTheRecordPersistsPrivatelyAndAmends() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let lookupFolder = LookupFolder(dataRoot: folder)
    let clock = TestClock()
    let log = NetworkActivityLog(folder: lookupFolder, now: { clock.now })
    let entry = NetworkActivityEntry(time: clock.now, device: "Mac", kind: .search, service: "brave", host: "api.search.brave.com", result: .found)
    await log.append(entry)
    await log.amend(entry.id, result: .nothingFound)
    let reopened = NetworkActivityLog(folder: lookupFolder, now: { clock.now })
    let entries = await reopened.entries()
    XCTAssertEqual(entries.map(\.result), [.nothingFound])
    let folderMode = try FileManager.default.attributesOfItem(atPath: lookupFolder.url.path)[.posixPermissions] as? Int
    let fileMode = try FileManager.default.attributesOfItem(atPath: lookupFolder.activityURL.path)[.posixPermissions] as? Int
    XCTAssertEqual(folderMode, 0o700)
    XCTAssertEqual(fileMode, 0o600)
    // Lines older than 90 days fall away.
    clock.advance(91 * 86_400)
    let later = NetworkActivityLog(folder: lookupFolder, now: { clock.now })
    let kept = await later.entries()
    XCTAssertTrue(kept.isEmpty)
    await later.removeAll()
  }
}

extension Result {
  var success: Success? {
    if case .success(let value) = self { return value }
    return nil
  }

  var failure: Failure? {
    if case .failure(let value) = self { return value }
    return nil
  }
}
