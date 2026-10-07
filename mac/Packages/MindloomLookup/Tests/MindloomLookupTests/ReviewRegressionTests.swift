import Foundation
import XCTest

@testable import MindloomLookup

/// Regression tests for the review of 2026-10-06 (v12 web lookup): each test
/// reproduces one finding's failure through the public entry points.
final class ReviewRegressionTests: XCTestCase {
  let braveKey = "BSAsynthetic000000"
  let tavilyKey = "tvly-synthetic0000"

  func officialPage(_ extra: String = "") -> Data {
    Data(
      """
      <html><head><title>DGX Spark specifications</title></head><body><main>
      <h1>NVIDIA DGX Spark</h1>
      <p>DGX Spark specifications: 128 GB unified memory, the GB10 superchip, and 4 TB of storage in a compact desktop.</p>
      <p>The system measures 150 mm by 150 mm by 50.5 mm and weighs 1.2 kg, with networking for clustering two units.</p>
      \(extra)
      </main></body></html>
      """.utf8)
  }

  func braveAnswer(_ url: String = "https://www.nvidia.com/dgx-spark/") -> Data {
    Data(#"{"web":{"results":[{"title":"DGX Spark","url":"\#(url)"}]}}"#.utf8)
  }

  func tavilyAnswer(_ url: String = "https://www.nvidia.com/dgx-spark/") -> Data {
    Data(#"{"results":[{"title":"DGX Spark","url":"\#(url)"}]}"#.utf8)
  }

  func productRequest(matter: UUID = matterA) -> LookupRequest {
    request(.specification, .product, "DGX Spark", year: nil, matter: matter, site: "nvidia.com")
  }

  // MARK: Finding 1: learned names and the owner's words

  func testALearnedNameNeverSendsTheOwnersWords() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, body: braveAnswer())
    let lookup = await makeLookup(transport: transport, keys: [.brave: braveKey])
    let terms = PrivateTerms(dictionaryWords: ["Bluewhale"], matterTitles: ["Kestrel Rollout"])
    let refusedLearning = await lookup.learn(publicName: "Bluewhale", kind: .product, privateTerms: terms)
    XCTAssertFalse(refusedLearning)
    // Learned anyway before the owner added the word (or by a wrong call).
    let first = await lookup.learn(publicName: "Bluewhale", kind: .product, privateTerms: PrivateTerms())
    let second = await lookup.learn(publicName: "Kestrel Rollout", kind: .product, privateTerms: PrivateTerms())
    XCTAssertTrue(first && second)
    let word = await lookup.lookUp(request(.specification, .product, "Bluewhale", year: nil), privateTerms: terms)
    XCTAssertEqual(word, .refused(.privateWord))
    let title = await lookup.lookUp(request(.specification, .product, "Kestrel Rollout", year: nil), privateTerms: terms)
    XCTAssertEqual(title, .refused(.matterTitle))
    XCTAssertTrue(transport.sent.isEmpty)
  }

  // MARK: Findings 2 and 9: health

  func testAHealthMatterSendsNothingAtAll() async {
    let transport = FakeTransport()
    transport.on(host: "ccfddl.com", body: Fixture.data("sources/conferences.yml"))
    transport.on(host: "nominatim.openstreetmap.org", body: Fixture.data("sources/nominatim.json"))
    transport.on(host: "api.crossref.org", body: Fixture.data("sources/crossref.json"))
    transport.on(host: SearchServiceID.brave.host, body: braveAnswer())
    let lookup = await makeLookup(transport: transport, keys: [.brave: braveKey])
    let learned = await lookup.learn(publicName: "Planned Parenthood", kind: .place, privateTerms: PrivateTerms())
    XCTAssertTrue(learned)
    let flagged = [
      request(.address, .place, "Planned Parenthood", year: nil, health: true),
      request(.address, .place, "北京协和", year: nil, approval: LookupApproval(terms: "北京协和"), health: true),
      request(.address, .place, "MD Anderson", year: nil, approval: LookupApproval(terms: "MD Anderson"), health: true),
      request(.deadline, .conference, "EXCONF", year: 2026, health: true),
      request(.paperInfo, .paper, nil, year: nil, identifiers: [.doi("10.1038/nature14539")], health: true),
      request(.overview, .organization, "NVIDIA", year: nil, health: true),
    ]
    for probe in flagged {
      let outcome = await lookup.lookUp(probe, privateTerms: PrivateTerms())
      XCTAssertEqual(outcome, .refused(.health), "\(probe.subject?.name ?? "identifier")")
    }
    let link = await lookup.read(
      link: URL(string: "https://www.example.com/about")!, parentItemID: itemA, privateTerms: PrivateTerms(),
      healthRelated: true)
    XCTAssertEqual(link, .refused(.health))
    // Not even the conference table was downloaded.
    XCTAssertTrue(transport.sent.isEmpty, "\(transport.hosts)")
  }

  func testHealthWordsAreRefusedEvenAfterApproval() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, body: braveAnswer())
    let lookup = await makeLookup(transport: transport, keys: [.brave: braveKey])
    for name in ["chemotherapy", "HPV疫苗", "胰岛素", "MRI 预约", "血压", "感冒"] {
      var probe = request(.specification, .product, name, year: nil, matter: UUID())
      if case .needsApproval(let words) = await lookup.lookUp(probe, privateTerms: PrivateTerms()) {
        probe.approval = LookupApproval(terms: words)
      }
      let outcome = await lookup.lookUp(probe, privateTerms: PrivateTerms())
      XCTAssertEqual(outcome, .refused(.health), name)
    }
    XCTAssertTrue(transport.sent.isEmpty)
  }

  // MARK: Finding 3: collected links

  func testCollectedLinksNeverCarryPrivateWordsTrackersOrSignedCredentials() async throws {
    let transport = FakeTransport()
    let article = Fixture.data("pages/article.html")
    transport.on(host: "docs.example.com", headers: ["Content-Type": "text/html"], body: article)
    transport.on(host: "click.example-mail.com", status: 302, headers: ["Location": "https://docs.example.com/landing?uid=alice.chen"], body: Data())
    transport.on(host: "bucket.s3.amazonaws.com", body: Data("%PDF-1.4".utf8))
    transport.on(host: "www.example.com", headers: ["Content-Type": "text/html"], body: article)
    transport.on(host: "short.example.org", status: 302, headers: ["Location": "https://www.other-site.com/page"], body: Data())
    transport.on(host: "www.other-site.com", headers: ["Content-Type": "text/html"], body: article)
    transport.on(host: "a.example.net", status: 301, headers: ["Location": "https://www.example.net/new"], body: Data())
    transport.on(host: "www.example.net", headers: ["Content-Type": "text/html"], body: article)
    let lookup = await makeLookup(transport: transport)
    try await lookup.update(WebLookupSettings(enabled: true, blockedTerms: ["蓝鲸计划"]))
    let terms = PrivateTerms(personNames: ["张伟", "Alice Chen"])
    func read(_ address: String, approval: String? = nil) async -> LookupOutcome {
      await lookup.read(
        link: URL(string: address)!, parentItemID: itemA, privateTerms: terms, healthRelated: false,
        approval: approval.map { LookupApproval(terms: $0) })
    }
    let path = "蓝鲸计划".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    let owner = "张伟".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    let blocked = await read("https://docs.example.com/\(path)/plan")
    XCTAssertEqual(blocked, .refused(.blockedByOwner))
    let named = await read("https://docs.example.com/plan?owner=\(owner)", approval: "https://docs.example.com/plan?owner=\(owner)")
    XCTAssertEqual(named, .refused(.personName))
    let tracker = await read("https://click.example-mail.com/track?u=8f3a9c2e&e=YWxpY2VAZXhhbXBsZS5jb20=")
    XCTAssertEqual(tracker, .refused(.identifierInAddress))
    let signed = await read("https://bucket.s3.amazonaws.com/f.pdf?X-Amz-Credential=AKIA%2F1&X-Amz-Signature=abc0123")
    XCTAssertEqual(signed, .refused(.identifierInAddress))
    XCTAssertTrue(transport.sent.isEmpty, "\(transport.hosts)")

    // A query waits for the owner, then reads.
    let address = "https://www.example.com/article?id=42"
    let held = await read(address)
    XCTAssertEqual(held, .needsApproval(terms: address))
    XCTAssertTrue(transport.sent.isEmpty)
    guard case .found = await read(address, approval: address) else { return XCTFail("approved link not read") }

    // A redirect to another site is not followed: the owner sees it first.
    let away = await read("https://short.example.org/x")
    XCTAssertEqual(away, .needsApproval(terms: "https://www.other-site.com/page"))
    XCTAssertFalse(transport.hosts.contains("www.other-site.com"))
    // On its own site it is followed.
    guard case .found(let items) = await read("https://a.example.net/old") else { return XCTFail("same-site redirect") }
    XCTAssertEqual(items.first?.finalURL.host, "www.example.net")
    XCTAssertFalse(transport.hosts.contains("click.example-mail.com"))
    XCTAssertFalse(transport.hosts.contains("bucket.s3.amazonaws.com"))
  }

  // MARK: Finding 5: the dry run resolves no name

  func testTheDryRunResolvesNoName() async {
    let transport = FakeTransport()
    let resolver = FakeResolver()
    let lookup = await makeLookup(transport: transport, resolver: resolver, keys: [.brave: braveKey], dryRun: true)
    let link = await lookup.read(
      link: URL(string: "https://wiki.acme-internal-project.com/page")!, parentItemID: itemA,
      privateTerms: PrivateTerms(), healthRelated: false)
    XCTAssertEqual(link, .planned([PlannedRequest(kind: .page, service: "page", host: "wiki.acme-internal-project.com")]))
    guard case .planned = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms()) else {
      return XCTFail("search not planned")
    }
    XCTAssertEqual(resolver.queries, [])
    XCTAssertTrue(transport.sent.isEmpty)
  }

  // MARK: Finding 7: Brave's invalid-key answer

  func testBravesInvalidKeyAnswerIsABadKey() async {
    let recorded = Fixture.data("search/brave-invalid-key.json")
    XCTAssertEqual(SearchAdapter.interpret(.brave, status: 422, headers: [:], body: recorded), .failure(.badKey))
    XCTAssertEqual(SearchAdapter.interpret(.brave, status: 422, headers: [:], body: Data("{}".utf8)), .failure(.server))
    XCTAssertEqual(
      SearchAdapter.interpret(.exa, status: 400, headers: [:], body: Data(#"{"error":{"code":"INVALID_API_KEY"}}"#.utf8)),
      .failure(.badKey))

    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, status: 422, body: recorded)
    transport.on(host: SearchServiceID.tavily.host, status: 503, body: Data())
    let keys = InMemorySearchKeyStore()
    let lookup = WebLookup(dataRoot: nil, keys: keys, device: "Mac", transport: transport, resolver: FakeResolver())
    try? await lookup.setEnabled(true)
    let refused = await lookup.addKey("BSAwrong-key-00000", for: .brave)
    XCTAssertEqual(refused, .badKey)
    XCTAssertNil(keys.key(for: .brave))
    // A key the service could not check is kept, but not shown as 「可用」.
    let unchecked = await lookup.addKey("tvly-unchecked-0000", for: .tavily)
    XCTAssertEqual(unchecked, .failing)
    XCTAssertNotNil(keys.key(for: .tavily))
    let statuses = await lookup.statuses()
    XCTAssertEqual(statuses.first(where: { $0.service == .tavily })?.condition, .failing)
    XCTAssertEqual(statuses.first(where: { $0.service == .brave })?.condition, .notAdded)
    // With the switch off a key is neither checked nor kept.
    try? await lookup.setEnabled(false)
    let off = await lookup.addKey("BSAanother-key-0000", for: .brave)
    XCTAssertEqual(off, .notAdded)
    XCTAssertEqual(transport.sent.count, 2)
  }

  // MARK: Finding 8: hostile pages

  func time(_ label: String, _ body: () -> Void) -> TimeInterval {
    let start = Date()
    body()
    let seconds = Date().timeIntervalSince(start)
    print("reader probe \(label): \(String(format: "%.2f", seconds)) s (debug build)")
    return seconds
  }

  func testHostilePagesAreReadInLinearTime() {
    let paragraph = "<p>Visible text that a person reads, long enough to count as content, with commas, too.</p>"
    // 40,000 dropped siblings (a 200 KB page): 110 s before the fix.
    let siblings = "<html><body><div>" + String(repeating: "<img src=x>", count: 40_000) + paragraph + "</div></body></html>"
    var page: ExtractedPage?
    XCTAssertLessThan(time("40k dropped siblings") { page = PageReader.read(Data(siblings.utf8), contentType: "text/html") }, 10)
    XCTAssertTrue(page?.text.contains("Visible text") == true)

    // 4,000 hiding rules and 20,000 elements: 16.6 s before the fix.
    let rules = (0..<4_000).map { ".h\($0) { display: none }" }.joined(separator: "\n")
    let elements = String(repeating: "<span class=\"c\">x</span>", count: 20_000)
    let styled = "<html><head><style>\(rules)</style></head><body><div>\(elements)</div>\(paragraph)</body></html>"
    XCTAssertLessThan(time("4k rules x 20k elements") { page = PageReader.read(Data(styled.utf8), contentType: "text/html") }, 10)
    XCTAssertTrue(page?.text.contains("Visible text") == true)

    // An unclosed comment in a large style sheet.
    let comment = "<html><head><style>/*" + String(repeating: "a/b*c ", count: 40_000) + "</style></head><body>\(paragraph)</body></html>"
    XCTAssertLessThan(time("unclosed comment") { page = PageReader.read(Data(comment.utf8), contentType: "text/html") }, 10)
    XCTAssertTrue(page?.text.contains("Visible text") == true)

    // 250 nested blockquotes over 400 KB: 22.5 s before the fix.
    let nested = "<html><body>" + String(repeating: "<blockquote>" + String(repeating: "Quoted words, with commas. ", count: 60), count: 250)
      + String(repeating: "</blockquote>", count: 250) + "</body></html>"
    XCTAssertLessThan(time("250 nested blockquotes") { page = PageReader.read(Data(nested.utf8), contentType: "text/html") }, 10)
    XCTAssertNotNil(page)

    // A spent budget gives up instead of running on.
    XCTAssertNil(PageReader.read(Data(siblings.utf8), contentType: "text/html", seconds: 0))
  }

  // MARK: Finding 9: turning the switch off during a lookup

  func testTurningTheSwitchOffMidLookupStopsEveryLaterRequest() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let transport = FakeTransport()
    let answer = braveAnswer()
    transport.on(host: SearchServiceID.brave.host) { _ in
      // The owner turns the switch off while the answer arrives.
      try? LookupFolder(dataRoot: folder).save(WebLookupSettings(enabled: false))
      return .success(TransportReply(status: 200, body: answer))
    }
    transport.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html"], body: officialPage())
    transport.on(host: "r.jina.ai", body: Data("text".utf8))
    let lookup = await makeLookup(transport: transport, keys: [.brave: braveKey], dataRoot: folder)
    let outcome = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(outcome, .off)
    XCTAssertEqual(transport.hosts, [SearchServiceID.brave.host])
  }

  func testTurningTheSwitchOffCancelsTheRequestInFlight() async throws {
    let base = FakeTransport()
    base.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html"], body: officialPage())
    base.on(host: SearchServiceID.tavily.host, body: tavilyAnswer())
    let transport = SuspendingTransport(base: base, holding: [SearchServiceID.brave.host])
    let lookup = WebLookup(
      dataRoot: nil, keys: InMemorySearchKeyStore([.brave: braveKey, .tavily: tavilyKey]), device: "Mac",
      transport: transport, resolver: FakeResolver())
    try await lookup.setEnabled(true)
    let probe = productRequest()
    let running = Task { await lookup.lookUp(probe, privateTerms: PrivateTerms()) }
    try await transport.waitForHold()
    let started = Date()
    try await lookup.setEnabled(false)
    // Settings answers at once, even while a request is in flight.
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    let outcome = await running.value
    XCTAssertEqual(outcome, .off)
    XCTAssertTrue(base.sent.isEmpty, "\(base.hosts)")
  }

  // MARK: Finding 10: failed sends do not close a gap for good

  func testFailedSendsCloseAGapForADayOnly() async {
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, status: 503, body: Data())
    transport.on(host: SearchServiceID.tavily.host, status: 503, body: Data())
    let clock = TestClock()
    let lookup = await makeLookup(transport: transport, keys: [.brave: braveKey, .tavily: tavilyKey], clock: clock)
    let first = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(first, .noSource)
    XCTAssertEqual(transport.sent.count, 2)
    clock.advance(600)
    let soon = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(soon, .limited(.gapLimit))
    XCTAssertEqual(transport.sent.count, 2)
    // The services recover; a day later the gap may be asked again.
    transport.on(host: SearchServiceID.brave.host, body: braveAnswer())
    transport.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html"], body: officialPage())
    clock.advance(86_400)
    guard case .found = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms()) else {
      return XCTFail("the gap stayed closed")
    }
  }

  func testChangingAKeyReopensTheGapItsFailuresClosed() async {
    let transport = FakeTransport()
    let recorded = Fixture.data("search/brave-invalid-key.json")
    let answer = braveAnswer()
    transport.on(host: SearchServiceID.brave.host) { request in
      request.value(forHTTPHeaderField: "X-Subscription-Token") == "BSAwrong-key-00000"
        ? .success(TransportReply(status: 422, body: recorded)) : .success(TransportReply(status: 200, body: answer))
    }
    transport.on(host: SearchServiceID.tavily.host, status: 503, body: Data())
    transport.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html"], body: officialPage())
    let keys = InMemorySearchKeyStore([.brave: "BSAwrong-key-00000", .tavily: tavilyKey])
    let clock = TestClock()
    let lookup = WebLookup(
      dataRoot: nil, keys: keys, device: "Mac", transport: transport, resolver: FakeResolver(), now: { clock.now },
      sleep: { clock.sleep($0) })
    try? await lookup.setEnabled(true)
    let first = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    XCTAssertEqual(first, .noSource)
    let statuses = await lookup.statuses()
    XCTAssertEqual(statuses.first(where: { $0.service == .brave })?.condition, .badKey)
    // The owner pastes the right key; Brave's failure no longer holds the gap.
    let added = await lookup.addKey("BSAright-key-00000", for: .brave)
    XCTAssertEqual(added, .ready)
    clock.advance(600)
    guard case .found = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms()) else {
      return XCTFail("the gap stayed closed after the key changed")
    }
  }

  // MARK: Finding 11: cancelling blames no service

  func testCancellingALookupBlamesNoServiceAndCountsNothing() async throws {
    let base = FakeTransport()
    base.on(host: SearchServiceID.brave.host, body: braveAnswer())
    base.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html"], body: officialPage())
    let transport = SuspendingTransport(base: base, holding: [SearchServiceID.brave.host])
    let keys: [SearchServiceID: String] = [.brave: braveKey, .tavily: tavilyKey, .exa: "00000000-0000-4000-8000-000000000000"]
    let lookup = WebLookup(
      dataRoot: nil, keys: InMemorySearchKeyStore(keys), device: "Mac", transport: transport, resolver: FakeResolver())
    try await lookup.setEnabled(true)
    let probe = productRequest()
    let running = Task { await lookup.lookUp(probe, privateTerms: PrivateTerms()) }
    try await transport.waitForHold()
    running.cancel()
    let outcome = await running.value
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(transport.holdCount, 1)
    XCTAssertTrue(base.sent.isEmpty)
    let statuses = await lookup.statuses()
    for service in [SearchServiceID.brave, .tavily, .exa] {
      XCTAssertEqual(statuses.first(where: { $0.service == service })?.condition, .ready, "\(service)")
    }
    // Nothing was counted: the same gap goes out again, to Brave.
    transport.release()
    guard case .found = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms()) else {
      return XCTFail("the cancelled lookup was counted")
    }
  }

  // MARK: Finding 12: cached answers keep their fetch time

  func testACachedAnswerKeepsTheTimeItWasFetched() async throws {
    let transport = FakeTransport()
    transport.on(host: "en.wikipedia.org", body: Fixture.data("sources/wikipedia.json"))
    let clock = TestClock()
    let lookup = await makeLookup(transport: transport, clock: clock)
    await lookup.learn(publicName: "Swift (programming language)", kind: .other, privateTerms: PrivateTerms())
    let probe = request(.overview, .other, "Swift (programming language)", year: nil)
    guard case .found(let first) = await lookup.lookUp(probe, privateTerms: PrivateTerms()) else { return XCTFail() }
    clock.advance(6 * 86_400)
    var later = probe
    later.matterID = UUID()
    guard case .found(let second) = await lookup.lookUp(later, privateTerms: PrivateTerms()) else { return XCTFail() }
    XCTAssertEqual(transport.sent.count, 1)
    XCTAssertEqual(second[0].retrievedAt, first[0].retrievedAt)
  }

  // MARK: Finding 13: a hidden heading

  func testAHiddenHeadingIsNeitherTheTitleNorEvidence() throws {
    let html = """
      <html><body><h1 style="display:none">EXCONF 2026 HIDDEN-H1</h1><main>
      <p>Our workshop on unrelated topics opens registration soon, with details to follow for every attendee.</p>
      <p>The abstract submission deadline is May 11, and full papers are due one week later for all tracks.</p>
      </main></body></html>
      """
    let page = try XCTUnwrap(PageReader.read(Data(html.utf8), contentType: "text/html"))
    XCTAssertFalse(page.title.contains("HIDDEN-H1"), page.title)
    XCTAssertFalse(page.text.contains("HIDDEN-H1"))
    let item = WebSourceItem(
      parentItemID: itemA, matterID: matterA, gap: .deadline, title: "EXCONF 2026", requestedURL: URL(string: "https://a.example/")!,
      finalURL: URL(string: "https://a.example/")!, retrievedAt: Date(), retrievedUptimeNanoseconds: 1, origin: .collectedLink,
      reader: .onDevice(extractor: PageReader.htmlExtractor), authority: .other, contentType: "text/html", text: page.text,
      excerpt: page.text, raw: Data(html.utf8))
    // The title alone does not make an unrelated page evidence.
    XCTAssertNil(Excerpts.verify(quote: "The abstract submission deadline is May 11", in: item, subject: "EXCONF", year: 2026))
    // A visible heading is still the title when nothing else is.
    let visible = try XCTUnwrap(PageReader.read(Data("<html><body><h1>Visible Title</h1><p>Text.</p></body></html>".utf8), contentType: "text/html"))
    XCTAssertEqual(visible.title, "Visible Title")
  }

  // MARK: Finding 14: more ways of hiding text

  func testMoreWaysOfHidingTextAreRemoved() throws {
    let html = """
      <html><head><style>
      @media all { .media-hidden { display: none } }
      @media screen and (max-width: 600px) { .narrow-only { display: none } }
      main .ai { display: none }
      .box > .tip { visibility: hidden }
      </style></head><body><main>
      <p>Visible paragraph one, long enough to be read as the content of this page by any reader.</p>
      <p style="color: rgba(0, 0, 0, 0)">HIDDEN-RGBA instructions</p>
      <p style="color: hsla(0, 0%, 0%, 0)">HIDDEN-HSLA instructions</p>
      <p style="color: #0000">HIDDEN-HEX instructions</p>
      <p class="media-hidden">HIDDEN-MEDIA instructions</p>
      <p class="ai">HIDDEN-DESCENDANT instructions</p>
      <div class="box"><p class="tip">HIDDEN-CHILD instructions</p></div>
      <p style="transform: translateX(-10000px)">HIDDEN-TRANSLATE instructions</p>
      <p style="font-size: 1px">HIDDEN-ONEPIXEL instructions</p>
      <p style="position: absolute; left: -100vw">HIDDEN-VIEWPORT instructions</p>
      <p class="narrow-only">Visible on a wide screen, a second paragraph that a person reads here.</p>
      </main></body></html>
      """
    let page = try XCTUnwrap(PageReader.read(Data(html.utf8), contentType: "text/html"))
    XCTAssertTrue(page.text.contains("Visible paragraph one"))
    XCTAssertTrue(page.text.contains("Visible on a wide screen"), page.text)
    XCTAssertFalse(page.text.contains("HIDDEN-"), page.text)
  }

  // MARK: Finding 15: long pages

  func testALongPagesExcerptIsInTheStoredText() async throws {
    let filler = String(repeating: "<p>Plain words about something else entirely, repeated to make the page long.</p>\n", count: 3_200)
    let page = officialPage(filler + "<p>DGX Spark specifications, final table: 128 GB memory, GB10 processor.</p>")
    let transport = FakeTransport()
    transport.on(host: SearchServiceID.brave.host, body: braveAnswer())
    transport.on(host: "www.nvidia.com", headers: ["Content-Type": "text/html"], body: page)
    let lookup = await makeLookup(transport: transport, keys: [.brave: braveKey], readerService: false)
    guard case .found(let items) = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms()) else {
      return XCTFail("not found")
    }
    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(item.text.count, WebSourceItem.maximumTextCharacters)
    XCTAssertFalse(item.excerpt.isEmpty)
    for passage in item.excerpt.components(separatedBy: "\n…\n") {
      XCTAssertNotNil(Excerpts.locate(passage, in: item.text), passage)
    }
  }

  // MARK: Finding 16: a connection lost mid-request

  func testAConnectionLostMidRequestCountsAsSent() async {
    XCTAssertEqual(ResponseCollector.failure(for: .networkConnectionLost), .other)
    XCTAssertEqual(ResponseCollector.failure(for: .cannotFindHost), .cannotConnect)
    XCTAssertEqual(ResponseCollector.failure(for: .cannotConnectToHost), .cannotConnect)
    XCTAssertEqual(ResponseCollector.failure(for: .secureConnectionFailed), .cannotConnect)
    XCTAssertEqual(ResponseCollector.failure(for: .timedOut), .timedOut)
    XCTAssertEqual(ResponseCollector.failure(for: .cancelled), .cancelled)

    let transport = FakeTransport()
    for service in [SearchServiceID.brave, .tavily, .exa] {
      transport.on(host: service.host, failure: .other)
    }
    let lookup = await makeLookup(
      transport: transport, keys: [.brave: braveKey, .tavily: tavilyKey, .exa: "00000000-0000-4000-8000-000000000000"])
    _ = await lookup.lookUp(productRequest(), privateTerms: PrivateTerms())
    // Two services at most saw the words, and the record says bytes left.
    XCTAssertEqual(transport.hosts, [SearchServiceID.brave.host, SearchServiceID.tavily.host])
    let entries = await lookup.activity.entries()
    XCTAssertEqual(entries.count, 2)
    XCTAssertTrue(entries.allSatisfy { $0.bytesSent > 0 })
  }
}
