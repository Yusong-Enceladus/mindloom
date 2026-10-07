import Foundation
import XCTest

@testable import MindloomLookup

final class PublicSourceTests: XCTestCase {
  func testArXiv() throws {
    let record = try XCTUnwrap(ArXivSource.parse(Fixture.data("sources/arxiv.xml"), id: "1706.03762"))
    XCTAssertEqual(record.title, "Attention Is All You Need")
    XCTAssertEqual(record.authors, ["Ashish Vaswani", "Noam Shazeer"])
    XCTAssertEqual(record.published, "2017-06-12")
    XCTAssertEqual(record.note, "15 pages, 5 figures")
    XCTAssertEqual(record.pageURL.absoluteString, "https://arxiv.org/abs/1706.03762")
    XCTAssertTrue(record.text.contains("arXiv：1706.03762"))
    XCTAssertNil(ArXivSource.parse(Fixture.data("sources/arxiv-error.xml"), id: "9999.99999"))
    XCTAssertEqual(ArXivSource.request(id: "1706.03762").url.absoluteString, "https://export.arxiv.org/api/query?id_list=1706.03762&max_results=1")
  }

  func testCrossref() throws {
    let record = try XCTUnwrap(CrossrefSource.parse(Fixture.data("sources/crossref.json"), doi: "10.1038/nature14539"))
    XCTAssertEqual(record.title, "Deep learning")
    XCTAssertEqual(record.venue, "Nature")
    XCTAssertEqual(record.published, "2015-05-27")
    XCTAssertEqual(record.authors.count, 3)
    XCTAssertEqual(record.summary, "Deep learning allows computational models to learn .")
    XCTAssertEqual(CrossrefSource.request(doi: "10.1038/nature14539").url.absoluteString, "https://api.crossref.org/works/10.1038/nature14539")
  }

  func testWikipediaAndOpenStreetMap() throws {
    let summary = try XCTUnwrap(WikipediaSource.parse(Fixture.data("sources/wikipedia.json")))
    XCTAssertEqual(summary.pageURL.absoluteString, "https://en.wikipedia.org/wiki/Swift_(programming_language)")
    XCTAssertNil(WikipediaSource.parse(Fixture.data("sources/wikipedia-disambiguation.json")))
    XCTAssertEqual(
      WikipediaSource.request(name: "Swift (programming language)", chinese: false).url.absoluteString,
      "https://en.wikipedia.org/api/rest_v1/page/summary/Swift_(programming_language)")
    let place = try XCTUnwrap(OpenStreetMapSource.parse(Fixture.data("sources/nominatim.json")))
    XCTAssertEqual(place.name, "Example Public Library")
    XCTAssertEqual(place.openingHours, "Mo-Su 10:00-21:00")
    XCTAssertEqual(place.pageURL.absoluteString, "https://www.openstreetmap.org/node/123456")
    XCTAssertFalse(place.text.contains("+65"), "a phone number is not kept")
  }

  func testConferenceTable() throws {
    let conferences = ConferenceTableSource.parse(Fixture.data("sources/conferences.yml"))
    XCTAssertEqual(conferences.map(\.title), ["EXCONF", "SAMPLE"])
    let exconf = conferences[0]
    XCTAssertEqual(exconf.description, "Example Conference on Learning Systems")
    XCTAssertEqual(exconf.editions.map(\.year), [2025, 2026])
    let edition = exconf.editions[1]
    XCTAssertEqual(edition.timeline.count, 2)
    XCTAssertEqual(edition.timeline[0].comment, "Main track; supplementary material deadline: May 25, 2026, 23:59 AoE")
    XCTAssertEqual(edition.timeline[1].deadline, "TBD")
    XCTAssertEqual(edition.place, "Example City, Exampleland")

    // Matched by short name, full name or DBLP key, never by a part.
    let now = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
    XCTAssertEqual(ConferenceTableSource.match(conferences, name: "exconf", year: 2025, now: now)?.1.year, 2025)
    XCTAssertEqual(ConferenceTableSource.match(conferences, name: "Example Conference on Learning Systems", year: nil, now: now)?.1.year, 2026)
    XCTAssertEqual(ConferenceTableSource.match(conferences, name: "sample", year: nil, now: now)?.1.year, 2027)
    XCTAssertNil(ConferenceTableSource.match(conferences, name: "EXCON", year: nil, now: now))
    XCTAssertNil(ConferenceTableSource.match(conferences, name: "EXCONF", year: 2030, now: now))

    let deadlines = ConferenceTableSource.deadlines(of: edition)
    XCTAssertEqual(deadlines.map(\.kind), [.abstract, .paper, .paper])
    // 23:59:59 AoE is 11:59:59 UTC the next day.
    let utc = ISO8601DateFormatter()
    XCTAssertEqual(deadlines[0].moment.map(utc.string(from:)), "2026-05-12T11:59:59Z")
    XCTAssertNil(deadlines[2].moment)
    let sample = ConferenceTableSource.deadlines(of: conferences[1].editions[0])
    XCTAssertEqual(sample[0].moment.map(utc.string(from:)), "2026-09-16T07:59:59Z")

    let text = ConferenceTableSource.text(exconf, edition)
    XCTAssertTrue(text.contains("摘要截止：2026-05-11 23:59:59 AoE"))
    XCTAssertTrue(text.contains("网站：https://exconf.example.org/2026/"))
    let names = ConferenceTableSource.names(conferences)
    XCTAssertEqual(names.entry(for: "EXCONF")?.officialSite, "exconf.example.org")
    XCTAssertTrue(names.contains("Symposium on Sample Data"))
  }

  func conferenceLookup(_ transport: FakeTransport, clock: TestClock = TestClock()) async -> WebLookup {
    transport.on(host: "ccfddl.com", body: Fixture.data("sources/conferences.yml"))
    transport.on(host: "exconf.example.org", headers: ["Content-Type": "text/html; charset=utf-8"], body: Fixture.data("pages/conference.html"))
    return await makeLookup(transport: transport, clock: clock)
  }

  func testAConferenceDeadlineComesFromTheTableAndTheOfficialPage() async throws {
    let transport = FakeTransport()
    let lookup = await conferenceLookup(transport)
    let outcome = await lookup.lookUp(request(.deadline, .conference, "EXCONF", year: 2026), privateTerms: PrivateTerms())
    guard case .found(let items) = outcome, items.count == 2 else { return XCTFail("\(outcome)") }
    let table = items[0]
    XCTAssertEqual(table.origin, .publicSource(.conferenceTable, query: "EXCONF"))
    XCTAssertEqual(table.authority, .reference)
    XCTAssertTrue(table.text.contains("论文截止：2026-05-18 23:59:59 AoE"))
    let official = items[1]
    XCTAssertEqual(official.origin, .linkedFrom(.conferenceTable))
    XCTAssertEqual(official.authority, .official)
    XCTAssertEqual(official.host, "exconf.example.org")
    XCTAssertTrue(official.excerpt.contains("May 11, 2026 (AoE)"), official.excerpt)
    XCTAssertFalse(official.text.contains("IGNORE-PREVIOUS"), official.text)
    XCTAssertFalse(official.excerpt.contains("June 30"))
    // A model's quote is checked against the stored text.
    XCTAssertNotNil(Excerpts.verify(quote: "Abstract submission deadline May 11, 2026 (AoE)", in: official, subject: "EXCONF", year: 2026))
    XCTAssertNil(Excerpts.verify(quote: "deadline moved to June 30", in: official, subject: "EXCONF", year: 2026))
    XCTAssertNil(Excerpts.verify(quote: "Abstract submission deadline", in: official, subject: "OTHERCONF", year: nil))
    // Nothing about the conference left the device: the whole table, then
    // the official page; no search.
    XCTAssertEqual(transport.hosts, ["ccfddl.com", "exconf.example.org"])
    let entries = await lookup.activity.entries()
    XCTAssertEqual(entries.map(\.kind), [.page, .conferenceTable])

    // The table is kept for a day.
    _ = await lookup.lookUp(request(.eventDates, .conference, "EXCONF", year: 2026, matter: UUID()), privateTerms: PrivateTerms())
    XCTAssertEqual(transport.hosts.filter { $0 == "ccfddl.com" }.count, 1)
  }

  func testTheTableIsKeptOnDiskAndUsedWhenOffline() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock()
    let first = FakeTransport()
    first.on(host: "ccfddl.com", body: Fixture.data("sources/conferences.yml"))
    let lookup = await makeLookup(transport: first, clock: clock, dataRoot: folder)
    _ = await lookup.lookUp(request(.deadline, .conference, "EXCONF", year: 2026), privateTerms: PrivateTerms())
    // Two days later, offline: the older copy answers.
    clock.advance(2 * 86_400)
    let offline = FakeTransport()
    offline.on(host: "ccfddl.com", failure: .cannotConnect)
    let later = await makeLookup(transport: offline, clock: clock, dataRoot: folder)
    let outcome = await later.lookUp(request(.deadline, .conference, "EXCONF", year: 2026), privateTerms: PrivateTerms())
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertTrue(items[0].text.contains("2026-05-11"))
    // The library's lookup folder has no key and no words in the record.
    let record = try String(contentsOf: LookupFolder(dataRoot: folder).activityURL, encoding: .utf8)
    XCTAssertFalse(record.contains("EXCONF"))
  }

  func testIdentifiersGoToTheirRegistries() async throws {
    let transport = FakeTransport()
    transport.on(host: "export.arxiv.org", body: Fixture.data("sources/arxiv.xml"))
    transport.on(host: "api.crossref.org", body: Fixture.data("sources/crossref.json"))
    let lookup = await makeLookup(transport: transport)
    let probe = request(.paperInfo, .paper, nil, year: nil, identifiers: [.arXiv("arXiv:1706.03762"), .doi("doi:10.1038/nature14539")])
    let outcome = await lookup.lookUp(probe, privateTerms: PrivateTerms())
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(items.map(\.title), ["Attention Is All You Need", "Deep learning"])
    XCTAssertEqual(items.map(\.authority), [.official, .official])
    XCTAssertEqual(items[1].finalURL.absoluteString, "https://doi.org/10.1038/nature14539")
    // Cached for 30 days: asking again sends nothing.
    _ = await lookup.lookUp(request(.paperInfo, .paper, nil, year: nil, matter: UUID(), identifiers: [.arXiv("1706.03762")]), privateTerms: PrivateTerms())
    XCTAssertEqual(transport.sent.count, 2)
    // The venue becomes a public name.
    let names = await lookup.publicNames()
    XCTAssertTrue(names.contains("Nature"))
  }

  func testPlacesAndOverviews() async throws {
    let transport = FakeTransport()
    transport.on(host: "nominatim.openstreetmap.org", body: Fixture.data("sources/nominatim.json"))
    transport.on(host: "en.wikipedia.org", body: Fixture.data("sources/wikipedia.json"))
    let lookup = await makeLookup(transport: transport)
    await lookup.learn(publicName: "Example Public Library", kind: .place, privateTerms: PrivateTerms())
    await lookup.learn(publicName: "Swift (programming language)", kind: .other, privateTerms: PrivateTerms())
    let place = await lookup.lookUp(request(.openingHours, .place, "Example Public Library", year: nil), privateTerms: PrivateTerms())
    guard case .found(let placeItems) = place else { return XCTFail("\(place)") }
    XCTAssertTrue(placeItems[0].text.contains("营业时间：Mo-Su 10:00-21:00"))
    XCTAssertEqual(transport.sent.first?.url.query?.contains("q=Example%20Public%20Library"), true)
    let overview = await lookup.lookUp(request(.overview, .other, "Swift (programming language)", year: nil), privateTerms: PrivateTerms())
    guard case .found(let overviewItems) = overview else { return XCTFail("\(overview)") }
    XCTAssertEqual(overviewItems[0].authority, .reference)
    XCTAssertEqual(overviewItems[0].finalURL.host, "en.wikipedia.org")
  }

  func testCollectedLinksAreReadHereOnly() async throws {
    let transport = FakeTransport()
    transport.on(host: "spa.example.com", headers: ["Content-Type": "text/html"], body: Fixture.data("pages/spa.html"))
    transport.on(host: "r.jina.ai", headers: ["Content-Type": "text/plain"], body: Fixture.data("pages/jina.txt"))
    transport.on(host: "article.example.com", headers: ["Content-Type": "text/html"], body: Fixture.data("pages/article.html"))
    let lookup = await makeLookup(transport: transport)
    // A script-only page the owner collected is not handed to a reader service.
    let spa = await lookup.read(link: URL(string: "https://spa.example.com/doc")!, parentItemID: itemA, privateTerms: PrivateTerms(), healthRelated: false)
    XCTAssertEqual(spa, .nothingFound)
    XCTAssertFalse(transport.hosts.contains("r.jina.ai"))
    let article = await lookup.read(link: URL(string: "http://article.example.com/post")!, parentItemID: itemA, privateTerms: PrivateTerms(), healthRelated: false)
    guard case .found(let items) = article else { return XCTFail("\(article)") }
    XCTAssertEqual(items[0].origin, .collectedLink)
    XCTAssertEqual(items[0].title, "A Long Public Article")
    XCTAssertEqual(items[0].finalURL.scheme, "https")
    XCTAssertFalse(items[0].text.contains("Related link"))
    XCTAssertFalse(items[0].text.contains("Comment:"))
    let private_ = await lookup.read(link: URL(string: "https://192.168.1.20/notes")!, parentItemID: itemA, privateTerms: PrivateTerms(), healthRelated: false)
    XCTAssertEqual(private_, .refused(.privateAddress))
  }

  func testAScriptOnlySearchResultIsReadByTheReaderService() async throws {
    let transport = FakeTransport()
    transport.on(host: "ccfddl.com", body: Data("- title: OTHER\n  description: Other\n  confs: []\n".utf8))
    transport.on(host: SearchServiceID.brave.host, body: Data(#"{"web":{"results":[{"title":"EXCONF 2026","url":"https://spa.example.com/exconf"}]}}"#.utf8))
    transport.on(host: "spa.example.com", headers: ["Content-Type": "text/html"], body: Fixture.data("pages/spa.html"))
    transport.on(host: "r.jina.ai", headers: ["Content-Type": "text/plain"], body: Fixture.data("pages/jina.txt"))
    let lookup = await makeLookup(transport: transport, keys: [.brave: "BSAsynthetic000000"])
    await lookup.learn(publicName: "EXCONF", kind: .conference, privateTerms: PrivateTerms())
    let outcome = await lookup.lookUp(request(.deadline, .conference, "EXCONF", year: 2026), privateTerms: PrivateTerms())
    guard case .found(let items) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(items[0].reader, .readerService(host: "r.jina.ai"))
    XCTAssertEqual(items[0].host, "spa.example.com")
    let jina = try XCTUnwrap(transport.sent.first(where: { $0.url.host == "r.jina.ai" }))
    XCTAssertEqual(jina.headers["DNT"], "1")
    XCTAssertEqual(jina.url.absoluteString, "https://r.jina.ai/https://spa.example.com/exconf")
    XCTAssertTrue(items[0].excerpt.contains("Abstract submission deadline: May 11, 2026 (AoE)"))
  }
}
