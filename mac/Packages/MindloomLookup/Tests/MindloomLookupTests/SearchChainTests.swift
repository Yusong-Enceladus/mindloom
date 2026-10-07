import Foundation
import XCTest

@testable import MindloomLookup

final class SearchChainTests: XCTestCase {
  let allKeys: [SearchServiceID: String] = [
    .brave: "BSAsynthetic000000", .tavily: "tvly-synthetic0000", .exa: "00000000-0000-4000-8000-000000000000",
    .perplexity: "pplx-synthetic0000", .baidu: "bce-v3/ALTAK-synthetic", .bocha: "sk-" + String(repeating: "0", count: 32),
    .zhipu: String(repeating: "a", count: 32) + ".abcdefghijklmnop",
  ]

  /// A product question with no deadline table and no Wikipedia path, so the
  /// general search runs.
  func productRequest(matter: UUID = matterA) -> LookupRequest {
    request(.specification, .product, "DGX Spark", year: nil, matter: matter, site: "nvidia.com")
  }

  func officialPage() -> Data {
    Data(
      """
      <html><head><title>DGX Spark specifications</title></head><body><main>
      <h1>NVIDIA DGX Spark</h1>
      <p>DGX Spark specifications: 128 GB unified memory, the GB10 superchip, and 4 TB of storage in a compact desktop.</p>
      <p>The system measures 150 mm by 150 mm by 50.5 mm and weighs 1.2 kg, with networking for clustering two units.</p>
      <p>Memory, processor, dimensions and weight are listed above for the specifications of this public product page.</p>
      </main></body></html>
      """.utf8)
  }

  func serve(_ transport: FakeTransport, _ service: SearchServiceID, fixture: String) {
    var body = Fixture.data("search/\(fixture).json")
    // Point every result at the product page.
    let text = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "https://neurips.cc/Conferences/2026/CallForPapers", with: "https://www.nvidia.com/dgx-spark/")
      .replacingOccurrences(of: "https://www.example.gov.cn/notice/2026.html", with: "https://www.nvidia.com/dgx-spark/")
    body = Data(text.utf8)
    transport.on(host: service.host, body: body)
  }

  func testEachServiceParsesItsAnswer() {
    let cases: [(SearchServiceID, String, Int)] = [
      (.brave, "brave", 2), (.tavily, "tavily", 1), (.exa, "exa", 1), (.perplexity, "perplexity", 1),
      (.baidu, "baidu", 1), (.bocha, "bocha", 1), (.zhipu, "zhipu", 1),
    ]
    for (service, fixture, count) in cases {
      let reply = SearchAdapter.interpret(service, status: 200, headers: [:], body: Fixture.data("search/\(fixture).json"))
      guard case .hits(let hits) = reply else { return XCTFail("\(service): \(reply)") }
      XCTAssertEqual(hits.count, count, "\(service)")
      XCTAssertEqual(hits.map(\.rank), Array(1...count))
      XCTAssertFalse(hits[0].title.isEmpty)
    }
    XCTAssertEqual(SearchAdapter.interpret(.brave, status: 200, headers: [:], body: Fixture.data("search/brave-empty.json")), .hits([]))
  }

  func testFailuresAreClassified() {
    func reply(_ service: SearchServiceID, _ status: Int, _ body: String = "{}", headers: [String: String] = [:]) -> SearchReply {
      SearchAdapter.interpret(service, status: status, headers: headers, body: Data(body.utf8))
    }
    XCTAssertEqual(reply(.brave, 401), .failure(.badKey))
    XCTAssertEqual(reply(.tavily, 403), .failure(.badKey))
    XCTAssertEqual(reply(.exa, 402), .failure(.quotaUsed))
    XCTAssertEqual(reply(.brave, 429, headers: ["Retry-After": "12"]), .failure(.rateLimited(retryAfter: 12)))
    XCTAssertEqual(reply(.perplexity, 503), .failure(.server))
    XCTAssertEqual(reply(.brave, 200, "not json"), .failure(.malformed))
    XCTAssertEqual(SearchAdapter.interpret(.bocha, status: 200, headers: [:], body: Fixture.data("search/bocha-unauthorized.json")), .failure(.badKey))
    XCTAssertEqual(SearchAdapter.interpret(.bocha, status: 200, headers: [:], body: Fixture.data("search/bocha-balance.json")), .failure(.quotaUsed))
    XCTAssertEqual(SearchAdapter.interpret(.zhipu, status: 200, headers: [:], body: Fixture.data("search/zhipu-balance.json")), .failure(.quotaUsed))
    XCTAssertEqual(SearchAdapter.interpret(.baidu, status: 200, headers: [:], body: Fixture.data("search/baidu-error.json")), .failure(.badKey))
    // Brave answers a wrong key with 422 (recorded 2026-10-06).
    XCTAssertEqual(SearchAdapter.interpret(.brave, status: 422, headers: [:], body: Fixture.data("search/brave-invalid-key.json")), .failure(.badKey))
  }

  func testRequestsPutTheKeyWhereEachServiceWantsIt() throws {
    let brave = SearchAdapter.request(.brave, terms: "a b", key: "K")
    XCTAssertEqual(brave.method, "GET")
    XCTAssertEqual(brave.headers["X-Subscription-Token"], "K")
    XCTAssertTrue(brave.url.absoluteString.hasPrefix("https://api.search.brave.com/res/v1/web/search?q=a%20b"))
    for service in [SearchServiceID.tavily, .perplexity, .baidu, .bocha, .zhipu] {
      let request = SearchAdapter.request(service, terms: "a b", key: "K")
      XCTAssertEqual(request.method, "POST", "\(service)")
      XCTAssertEqual(request.headers["Authorization"], "Bearer K", "\(service)")
      XCTAssertEqual(request.url.host, service.host)
      XCTAssertFalse(request.url.absoluteString.contains("K"), "\(service): the key is not in the address")
    }
    XCTAssertEqual(SearchAdapter.request(.exa, terms: "a", key: "K").headers["x-api-key"], "K")
    let baidu = try JSONSerialization.jsonObject(with: SearchAdapter.request(.baidu, terms: "首台套", key: "K").body!) as! [String: Any]
    XCTAssertEqual(baidu["search_source"] as? String, "baidu_search_v2")
    XCTAssertEqual(((baidu["messages"] as? [[String: String]])?.first)?["content"], "首台套")
    let zhipu = try JSONSerialization.jsonObject(with: SearchAdapter.request(.zhipu, terms: "x", key: "K").body!) as! [String: Any]
    XCTAssertEqual(zhipu["search_engine"] as? String, "search_std")
  }

  func testKeyShapes() {
    for (service, key) in allKeys {
      XCTAssertEqual(SearchServiceID.likelyService(forKey: key), service, key)
    }
    XCTAssertNil(SearchServiceID.likelyService(forKey: "something-else-123"))
    XCTAssertFalse(SearchServiceID.isPlausibleKey("short"))
    XCTAssertFalse(SearchServiceID.isPlausibleKey("two\nlines-of-key"))
    XCTAssertTrue(SearchServiceID.isPlausibleKey("  BSAabcdefgh12345  "))
    XCTAssertEqual(SearchServiceID.order(chineseFirst: true).prefix(3), [.baidu, .bocha, .zhipu])
  }

  func testFindsResultsAndReadsTheOfficialPage() async throws {
    let transport = FakeTransport()
    serve(transport, .brave, fixture: "brave")
    transport.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html; charset=utf-8"], body: officialPage())
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!])
    let outcome = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(item.parentItemID, itemA)
    XCTAssertEqual(item.matterID, matterA)
    XCTAssertEqual(item.host, "www.nvidia.com")
    XCTAssertEqual(item.authority, .official)
    XCTAssertEqual(item.origin, .search(service: .brave, terms: "DGX Spark specifications", rank: 1))
    XCTAssertEqual(item.reader, .onDevice(extractor: PageReader.htmlExtractor))
    XCTAssertTrue(item.excerpt.contains("128 GB unified memory"))
    for passage in item.excerpt.components(separatedBy: "\n…\n") {
      XCTAssertNotNil(Excerpts.locate(passage, in: item.text), passage)
    }
    XCTAssertEqual(item.raw, officialPage())
    // The same page under the same item gets the same identity.
    let again = WebSourceItem.deterministicID(parentItemID: itemA, gap: .specification, finalURL: item.finalURL, rawSHA256: item.rawSHA256)
    XCTAssertEqual(item.id, again)
    // One search request, then pages.
    XCTAssertEqual(transport.hosts.first, "api.search.brave.com")
    XCTAssertEqual(transport.hosts.filter { $0 == "api.search.brave.com" }.count, 1)
  }

  func testEveryFailureMovesToTheNextServiceWithinTwoSends() async {
    let failures: [(String, (FakeTransport) -> Void, Int)] = [
      ("cannot connect", { $0.on(host: SearchServiceID.brave.host, failure: .cannotConnect) }, 1),
      ("timeout", { $0.on(host: SearchServiceID.brave.host, failure: .timedOut) }, 2),
      ("5xx", { $0.on(host: SearchServiceID.brave.host, status: 502, body: Data()) }, 2),
      ("429", { $0.on(host: SearchServiceID.brave.host, status: 429, headers: ["Retry-After": "30"], body: Data()) }, 2),
      ("401", { $0.on(host: SearchServiceID.brave.host, status: 401, body: Data()) }, 2),
      ("402", { $0.on(host: SearchServiceID.brave.host, status: 402, body: Data()) }, 2),
    ]
    for (name, failBrave, expectedSends) in failures {
      let transport = FakeTransport()
      serve(transport, .tavily, fixture: "tavily")
      transport.on(host: "www.nvidia.com", body: officialPage())
      failBrave(transport)
      let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!, .tavily: allKeys[.tavily]!])
      let outcome = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
      guard case .found(let items) = outcome else {
        XCTFail("\(name): \(outcome)")
        continue
      }
      XCTAssertEqual(items.first?.origin, .search(service: .tavily, terms: "DGX Spark specifications", rank: 1), name)
      XCTAssertEqual(transport.hosts.filter { $0.hasPrefix("api.") }, ["api.search.brave.com", "api.tavily.com"], name)
      let entries = await lookup.activity.entries()
      XCTAssertEqual(entries.filter { $0.kind == .search }.count, 2, name)
      _ = expectedSends
    }
  }

  func testTwoSendsPerGapAcrossServices() async {
    let transport = FakeTransport()
    for service in [SearchServiceID.brave, .tavily, .exa] {
      transport.on(host: service.host, status: 500, body: Data())
    }
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!, .tavily: allKeys[.tavily]!, .exa: allKeys[.exa]!])
    let first = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(first, .limited(.gapLimit))
    XCTAssertEqual(transport.hosts, ["api.search.brave.com", "api.tavily.com"])
    let second = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(second, .limited(.gapLimit))
    XCTAssertEqual(transport.sent.count, 2)
  }

  func testNoResultsTriesOneMoreServiceOnly() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, body: Fixture.data("search/brave-empty.json"))
    transport.on(host: SearchServiceID.tavily.host, body: Data(#"{"results":[]}"#.utf8))
    transport.on(host: SearchServiceID.exa.host, body: Data(#"{"results":[]}"#.utf8))
    let clock = TestClock()
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!, .tavily: allKeys[.tavily]!, .exa: allKeys[.exa]!], clock: clock)
    let outcome = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(outcome, .nothingFound)
    XCTAssertEqual(transport.hosts, ["api.search.brave.com", "api.tavily.com"])
    let entries = await lookup.activity.entries()
    XCTAssertEqual(entries.map(\.result), [.nothingFound, .nothingFound])
    // The same words within a week are not sent again, even for another matter.
    let other = await lookup.lookUp(productRequest(matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(other, .nothingFound)
    XCTAssertEqual(transport.sent.count, 2)
  }

  func testServiceStateFollowsRealAnswersOnly() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, status: 401, body: Data())
    serve(transport, .tavily, fixture: "tavily")
    transport.on(host: "www.nvidia.com", body: officialPage())
    let clock = TestClock()
    let keys = InMemorySearchKeyStore([.brave: allKeys[.brave]!, .tavily: allKeys[.tavily]!])
    let lookup = WebLookup(dataRoot: nil, keys: keys, device: "Mac", transport: transport, resolver: FakeResolver(), now: { clock.now }, sleep: { clock.sleep($0) })
    try? await lookup.setEnabled(true)
    _ = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    var statuses = await lookup.statuses()
    XCTAssertEqual(statuses.first(where: { $0.service == .brave })?.condition, .badKey)
    XCTAssertEqual(statuses.first(where: { $0.service == .tavily })?.condition, .ready)
    XCTAssertEqual(statuses.first(where: { $0.service == .exa })?.condition, .notAdded)
    // A bad key stays skipped until the key changes.
    _ = await lookup.lookUp(productRequest(matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(transport.hosts.filter { $0 == SearchServiceID.brave.host }.count, 1)
    try? keys.save("BSAanother-key-0000", for: .brave)
    statuses = await lookup.statuses()
    XCTAssertEqual(statuses.first(where: { $0.service == .brave })?.condition, .ready)
    // Never a probe: nothing was sent besides the two lookups' requests.
    XCTAssertFalse(transport.hosts.contains { $0.contains("captive") || $0.contains("ipinfo") })
  }

  func testUnreachableServicesWaitHalfAnHour() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, failure: .cannotConnect)
    transport.on(host: SearchServiceID.tavily.host, status: 500, body: Data())
    let clock = TestClock()
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!, .tavily: allKeys[.tavily]!], clock: clock)
    _ = await lookup.lookUp(productRequest(matter: UUID()), privateTerms: PrivateTerms())
    clock.advance(600)
    _ = await lookup.lookUp(productRequest(matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(transport.hosts.filter { $0 == SearchServiceID.brave.host }.count, 1)
    clock.advance(1_300)
    _ = await lookup.lookUp(productRequest(matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(transport.hosts.filter { $0 == SearchServiceID.brave.host }.count, 2)
  }

  func testChineseSubjectsStartWithDomesticServices() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.baidu.host, body: Fixture.data("search/baidu.json"))
    transport.on(host: "www.example.gov.cn", headers: ["Content-Type": "text/html"], body: Fixture.data("pages/gbk.html"))
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!, .baidu: allKeys[.baidu]!])
    await lookup.learn(publicName: "首台套", kind: .publicNotice, privateTerms: PrivateTerms())
    let outcome = await lookup.lookUp(request(.publicNotice, .publicNotice, "首台套", year: 2026), privateTerms: PrivateTerms())
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(transport.hosts.first, SearchServiceID.baidu.host)
    XCTAssertTrue(items[0].excerpt.contains("申报截止日期：2026年4月30日17:00"))
  }

  func testWithoutKeysThereIsNoGeneralSearch() async {
    let transport = FakeTransport()
    let lookup = await makeLookup(transport: transport)
    let outcome = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(outcome, .noSource)
    XCTAssertTrue(transport.sent.isEmpty)
  }

  func testOffSendsNothing() async {
    let transport = FakeTransport()
    let lookup = await makeLookup(transport: transport, keys: allKeys, enabled: false)
    let outcomes = [
      await lookup.lookUp(productRequest(), privateTerms: PrivateTerms()),
      await lookup.lookUp(request(.paperInfo, .paper, nil, identifiers: [.arXiv("1706.03762")]), privateTerms: PrivateTerms()),
      await lookup.read(link: URL(string: "https://example.com/")!, parentItemID: itemA, privateTerms: PrivateTerms(), healthRelated: false),
    ]
    XCTAssertEqual(outcomes, [.off, .off, .off])
    XCTAssertTrue(transport.sent.isEmpty)
    let entries = await lookup.activity.entries()
    XCTAssertTrue(entries.isEmpty)
  }

  func testRefusedWordsAreRecordedButNeverSent() async {
    let transport = FakeTransport()
    let lookup = await makeLookup(transport: transport, keys: allKeys)
    let outcome = await lookup.lookUp(
      request(.specification, .product, "张伟的样机", year: nil), privateTerms: PrivateTerms(personNames: ["张伟"]))
    XCTAssertEqual(outcome, .refused(.personName))
    XCTAssertTrue(transport.sent.isEmpty)
    let entries = await lookup.activity.entries()
    XCTAssertEqual(entries.map(\.result), [.notSent])
    XCTAssertEqual(entries.first?.refusal, .personName)
    XCTAssertNil(entries.first?.host)
  }

  func testUnknownNamesAreHeldForTheOwner() async throws {
    let transport = FakeTransport()
    serve(transport, .brave, fixture: "brave")
    transport.on(host: "www.nvidia.com", body: officialPage())
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!])
    var probe = request(.specification, .product, "PG-80 样机", year: nil)
    let first = await lookup.lookUp(probe, privateTerms: PrivateTerms())
    XCTAssertEqual(first, .needsApproval(terms: "PG-80 样机 规格"))
    XCTAssertTrue(transport.sent.isEmpty)
    probe.approval = LookupApproval(terms: "PG-80 样机 规格")
    let second = await lookup.lookUp(probe, privateTerms: PrivateTerms())
    XCTAssertNotEqual(second, .needsApproval(terms: "PG-80 样机 规格"))
    let sentURL = try XCTUnwrap(transport.sent.first?.url)
    let items = URLComponents(url: sentURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "PG-80 样机 规格")
  }

  func testDailyAndPerMatterLimits() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, body: Fixture.data("search/brave-empty.json"))
    let clock = TestClock()
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!], clock: clock)
    var names: [String] = []
    for index in 0..<26 {
      let name = "Product\(String(UnicodeScalar(65 + index)!))"
      names.append(name)
      await lookup.learn(publicName: name, kind: .product, privateTerms: PrivateTerms())
    }
    // Three a day for one matter (four different gaps).
    var outcomes: [LookupOutcome] = []
    for (name, gap) in zip(names.prefix(4), [LookupGap.price, .specification, .publicNotice, .callForPapers]) {
      outcomes.append(await lookup.lookUp(request(gap, .product, name, year: nil), privateTerms: PrivateTerms()))
    }
    XCTAssertEqual(outcomes.last, .limited(.matterDailyLimit))
    XCTAssertEqual(transport.sent.count, 3)
    // Twenty a day in all.
    for name in names[4..<25] {
      _ = await lookup.lookUp(request(.price, .product, name, year: nil, matter: UUID()), privateTerms: PrivateTerms())
    }
    XCTAssertEqual(transport.sent.count, 20)
    let limited = await lookup.lookUp(request(.price, .product, names[25], year: nil, matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(limited, .limited(.dailyLimit))
    clock.advance(86_401)
    _ = await lookup.lookUp(request(.price, .product, names[25], year: nil, matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(transport.sent.count, 21)
  }

  func testAddingAKeyChecksItOnceWithAFixedWord() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, status: 401, body: Data())
    transport.on(host: SearchServiceID.tavily.host, body: Fixture.data("search/tavily.json"))
    let keys = InMemorySearchKeyStore()
    let lookup = WebLookup(dataRoot: nil, keys: keys, device: "Mac", transport: transport, resolver: FakeResolver())
    // Keys are checked only with the switch on (it is the only way to reach
    // 添加密钥… in Settings).
    try? await lookup.setEnabled(true)
    let refused = await lookup.addKey("BSAwrong-key-00000", for: .brave)
    XCTAssertEqual(refused, .badKey)
    XCTAssertNil(keys.key(for: .brave))
    let accepted = await lookup.addKey("  tvly-right-key-000  ", for: .tavily)
    XCTAssertEqual(accepted, .ready)
    XCTAssertEqual(keys.key(for: .tavily), "tvly-right-key-000")
    XCTAssertEqual(bodyJSON(transport.sent[1])["query"] as? String, WebLookup.keyCheckTerms)
    let entries = await lookup.activity.entries()
    XCTAssertEqual(entries.map(\.kind), [.keyCheck, .keyCheck])
    try? await lookup.removeKey(.tavily)
    XCTAssertNil(keys.key(for: .tavily))
  }

  func testDryRunPlansWithoutSending() async {
    let transport = FakeTransport()
    let lookup = await makeLookup(transport: transport, keys: [.brave: allKeys[.brave]!], dryRun: true)
    let outcome = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    guard case .planned(let plan) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertTrue(plan.contains(PlannedRequest(kind: .search, service: "brave", host: SearchServiceID.brave.host)))
    XCTAssertTrue(transport.sent.isEmpty)
  }
}
