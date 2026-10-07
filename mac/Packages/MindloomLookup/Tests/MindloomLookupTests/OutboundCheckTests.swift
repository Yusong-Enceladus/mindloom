import Foundation
import XCTest

@testable import MindloomLookup

final class OutboundCheckTests: XCTestCase {
  let privateTerms = PrivateTerms(
    personNames: ["张伟", "Alice Chen", "Bob", "小周"], dictionaryWords: ["蓝鲸计划", "NeurIPS", "Kestrel"],
    privateLabels: ["组会", "Project Falcon"], matterTitles: ["给王老师的初稿", "EXCONF", "换工作", "装修"])

  var directory: PublicNameDirectory {
    var directory = PublicNameDirectory.bundled
    directory.add("NeurIPS", kind: .conference, officialSite: "neurips.cc", source: .conferenceTable)
    directory.add("EXCONF", kind: .conference, officialSite: "exconf.example.org", source: .conferenceTable)
    directory.add("首台套", kind: .publicNotice, source: .collectedPublicPage)
    directory.add("RTX 5090", kind: .product, source: .collectedPublicPage)
    return directory
  }

  var check: OutboundCheck { OutboundCheck(privateTerms: privateTerms, publicNames: directory) }

  func testPublicSubjectsBecomeFixedWords() {
    XCTAssertEqual(check.terms(for: request(.deadline, .conference, "NeurIPS", year: 2026)), .send("NeurIPS 2026 deadline"))
    XCTAssertEqual(check.terms(for: request(.publicNotice, .publicNotice, "首台套", year: 2026)), .send("首台套 2026 通知"))
    XCTAssertEqual(check.terms(for: request(.specification, .product, "RTX 5090", year: nil)), .send("RTX 5090 specifications"))
    XCTAssertEqual(check.terms(for: request(.overview, .organization, "NVIDIA", year: nil)), .send("NVIDIA"))
    // A matter titled with a public name does not block that name.
    XCTAssertEqual(check.terms(for: request(.eventDates, .conference, "EXCONF", year: 2026)), .send("EXCONF 2026 dates venue"))
  }

  func testUnknownNamesWaitForTheOwner() {
    let unknown = request(.price, .product, "PG-80 样机", year: nil)
    XCTAssertEqual(check.terms(for: unknown), .needsApproval("PG-80 样机 价格"))
    var approved = unknown
    approved.approval = LookupApproval(terms: "PG-80 样机 价格")
    XCTAssertEqual(check.terms(for: approved), .send("PG-80 样机 价格"))
    approved.approval = LookupApproval(terms: "something else")
    XCTAssertEqual(check.terms(for: approved), .needsApproval("PG-80 样机 价格"))
  }

  func testPrivateDataIsRefusedEvenWithApproval() {
    let cases: [(String, OutboundRefusal)] = [
      ("张伟", .personName), ("Alice Chen", .personName), ("bob", .personName), ("小周的", .personName),
      ("给王老师的初稿", .matterTitle), ("组会", .privateWord), ("Project Falcon", .privateWord),
      ("蓝鲸计划", .privateWord), ("kestrel", .privateWord), ("〔手机号·a1b2c3〕", .maskedValue),
      ("医院 预约", .health), ("cancer clinic", .health), ("HIV", .health),
      ("someone@example.com", .contact), ("138 1234 5678", .contact), ("+65 91234567", .contact),
      ("sk-abcdefghijk12345", .secret), ("ghp_abcdefghij1234567890", .secret),
      ("报价 3000元", .money), ("$500 plan", .money), ("200 USD", .money),
      ("10月5日 截止", .date), ("2026-05-11", .date), ("十月五日", .date), ("May 11 meeting", .date),
      ("Room 1203", .number), ("一三八一二三四五六七八", .number), ("2026 07", .number),
      ("1 2 3 4 5 6 7 8 9", .tooLong), ("", .empty),
      // Review 2026-10-06: forms the first rules let through after 「查找」.
      ("October 5th", .date), ("5th October", .date), ("Oct 5th", .date), ("the 5th of October", .date),
      ("沪A12345", .number), ("粤B88888", .number), ("Apt 5B", .number), ("2048 Elm Street", .number),
      ("人民路100号", .number), ("50k offer", .money), ("五万", .money), ("两千块", .money),
      ("换工作", .matterTitle), ("装修", .matterTitle), ("張偉", .personName), ("AliceChen", .personName),
      ("alice_chen", .personName), ("wxid_abc123", .contact), ("alice at example dot com", .contact),
      ("微信 abc_12345", .contact),
      ("chemotherapy", .health), ("HPV疫苗", .health), ("胰岛素", .health), ("MRI 预约", .health),
      ("血压", .health), ("感冒", .health), ("blood pressure", .health),
    ]
    for (name, expected) in cases {
      var unknown = request(.overview, .other, name, year: nil)
      unknown.approval = LookupApproval(terms: name)
      let verdict = check.terms(for: unknown)
      XCTAssertEqual(verdict, .refuse(expected), "\(name)")
    }
  }

  func testDictionaryWordsOnAPublicListStayUsable() {
    // 「NeurIPS」 is in the owner's dictionary for recognition and is public.
    XCTAssertEqual(check.terms(for: request(.deadline, .conference, "NeurIPS", year: 2027)), .send("NeurIPS 2027 deadline"))
  }

  /// Public names that the new rules must still let through.
  func testPublicWordsAreNotMistakenForPrivateData() {
    var names = directory
    for name in ["iPhone 16", "Llama 3.1", "Telegram", "VxWorks", "百度千帆", "万达", "5th Avenue", "Hospitality Expo"] {
      names.add(name, kind: .product, source: .bundled)
    }
    let check = OutboundCheck(privateTerms: privateTerms, publicNames: names)
    XCTAssertEqual(check.terms(for: request(.specification, .product, "iPhone 16", year: nil)), .send("iPhone 16 specifications"))
    XCTAssertEqual(check.terms(for: request(.specification, .product, "Llama 3.1", year: nil)), .send("Llama 3.1 specifications"))
    XCTAssertEqual(check.terms(for: request(.specification, .product, "Telegram", year: nil)), .send("Telegram specifications"))
    XCTAssertEqual(check.terms(for: request(.overview, .product, "VxWorks", year: nil)), .send("VxWorks"))
    XCTAssertEqual(check.terms(for: request(.overview, .organization, "万达", year: nil)), .send("万达"))
    XCTAssertEqual(check.terms(for: request(.address, .place, "5th Avenue", year: nil)), .send("5th Avenue address"))
    XCTAssertEqual(check.terms(for: request(.eventDates, .other, "Hospitality Expo", year: 2026)), .send("Hospitality Expo 2026 dates venue"))
    // A matter titled with a fixed phrase does not block the phrase.
    let titled = OutboundCheck(privateTerms: PrivateTerms(matterTitles: ["论文", "通知"]), publicNames: directory)
    XCTAssertEqual(titled.terms(for: request(.publicNotice, .publicNotice, "首台套", year: 2026)), .send("首台套 2026 通知"))
    XCTAssertEqual(titled.terms(for: request(.paperInfo, .paper, "首台套", year: nil)), .send("首台套 论文"))
  }

  /// Review 2026-10-06: a name learned from a page (or a public record) is
  /// public enough to go out without 「查找」, but never overrides the
  /// owner's dictionary words or matter titles; only the bundled list and
  /// the conference table do.
  func testLearnedNamesNeverOverrideTheOwnersWords() {
    var names = PublicNameDirectory.bundled
    names.add("Bluewhale", kind: .product, source: .collectedPublicPage)
    names.add("Kestrel Rollout", kind: .product, source: .collectedPublicPage)
    names.add("Ocean Notes", kind: .journal, source: .publicRecord)
    let terms = PrivateTerms(dictionaryWords: ["Bluewhale", "Ocean Notes"], matterTitles: ["Kestrel Rollout"])
    let check = OutboundCheck(privateTerms: terms, publicNames: names)
    XCTAssertEqual(check.terms(for: request(.specification, .product, "Bluewhale", year: nil)), .refuse(.privateWord))
    XCTAssertEqual(check.terms(for: request(.specification, .product, "Kestrel Rollout", year: nil)), .refuse(.matterTitle))
    XCTAssertEqual(check.terms(for: request(.overview, .journal, "Ocean Notes", year: nil)), .refuse(.privateWord))
    // A learned entry never replaces a trusted one either.
    names.add("NeurIPS", kind: .conference, officialSite: "neurips.cc", source: .conferenceTable)
    names.add("NeurIPS", kind: .conference, officialSite: "fake.example", source: .collectedPublicPage)
    XCTAssertTrue(names.isTrusted("NeurIPS"))
    XCTAssertEqual(names.entry(for: "NeurIPS")?.officialSite, "neurips.cc")
    // What learn() refuses outright.
    let learner = OutboundCheck(privateTerms: terms, publicNames: .bundled, blockedTerms: ["蓝鲸计划"])
    for name in ["Bluewhale", "蓝鲸计划 内部版", "Call 13812345678", "3号楼502", "Room 1203 Lab", "Account 12345678"] {
      XCTAssertNotNil(learner.learnedNameRefusal(name), name)
    }
    XCTAssertNil(learner.learnedNameRefusal("RTX 5090"))
    XCTAssertNil(learner.learnedNameRefusal("Marina Bay Sands"))
  }

  func testOwnerBlockedWords() {
    let blocking = OutboundCheck(privateTerms: PrivateTerms(), publicNames: directory, blockedTerms: ["neurips"])
    XCTAssertEqual(blocking.terms(for: request(.deadline, .conference, "NeurIPS", year: 2026)), .refuse(.blockedByOwner))
  }

  func testYearOutOfRangeIsANumber() {
    XCTAssertEqual(check.terms(for: request(.deadline, .conference, "NeurIPS", year: 12)), .refuse(.number))
  }

  func testIdentifiers() {
    XCTAssertEqual(check.check(identifier: .arXiv("arXiv:2401.01234v2")), .success("2401.01234v2"))
    XCTAssertEqual(check.check(identifier: .arXiv("https://arxiv.org/abs/1706.03762")), .success("1706.03762"))
    XCTAssertEqual(check.check(identifier: .arXiv("cs/0112017")), .success("cs/0112017"))
    XCTAssertEqual(check.check(identifier: .arXiv("13812345678")), .failure(.number))
    XCTAssertEqual(check.check(identifier: .doi("https://doi.org/10.1038/nature14539")), .success("10.1038/nature14539"))
    XCTAssertEqual(check.check(identifier: .doi("10.1038 nature")), .failure(.number))
    // Real DOI shapes stay usable.
    for doi in ["10.1145/3292500.3330701", "10.1038/s41586-020-2649-2", "10.1007/978-3-319-46448-0_2", "10.1016/j.patcog.2020.107281", "10.48550/arXiv.1706.03762", "10.1109/CVPR.2016.90"] {
      XCTAssertEqual(check.check(identifier: .doi(doi)), .success(doi), doi)
    }
    // Review 2026-10-06: a DOI goes out without 「查找」, so its suffix may
    // not carry a phone number, a token or a long number.
    XCTAssertEqual(check.check(identifier: .doi("10.1234/13812345678")), .failure(.contact))
    XCTAssertEqual(check.check(identifier: .doi("10.1234/sk-abcdefghij1234567890")), .failure(.secret))
    XCTAssertEqual(check.check(identifier: .doi("10.1234/eyJhbGciOiJIUzI1NiJ9")), .failure(.secret))
    XCTAssertEqual(check.check(identifier: .doi("10.1234/310101199001011234")), .failure(.number))
    XCTAssertEqual(check.check(identifier: .doi("10.1234/zhangwei")), .success("10.1234/zhangwei"))
    XCTAssertEqual(check.check(identifier: .doi("10.1234/张伟")), .failure(.number))
    XCTAssertEqual(check.check(identifier: .doi("10.1234/Kestrel.2026")), .failure(.privateWord))
  }

  func testAddresses() {
    let check = OutboundCheck(privateTerms: PrivateTerms(), blockedSites: ["blocked.example"])
    func verdict(_ address: String) -> Result<URL, OutboundRefusal> { check.check(address: URL(string: address)!) }
    XCTAssertEqual(verdict("http://example.com/a#frag"), .success(URL(string: "https://example.com/a")!))
    XCTAssertEqual(verdict("https://198.18.0.5/page"), .success(URL(string: "https://198.18.0.5/page")!))
    let refused: [(String, OutboundRefusal)] = [
      ("ftp://example.com/", .unsupportedAddress), ("https://example.com:8443/", .unsupportedAddress),
      ("https://user:pass@example.com/", .credentialsInAddress), ("https://127.0.0.1/", .privateAddress),
      ("https://10.1.2.3/", .privateAddress), ("https://192.168.1.1/", .privateAddress),
      ("https://172.20.0.1/", .privateAddress), ("https://100.100.1.1/", .privateAddress),
      ("https://169.254.169.254/latest/meta-data", .privateAddress), ("https://[::1]/", .privateAddress),
      ("https://[fe80::1]/", .privateAddress), ("https://[fd00::1]/", .privateAddress),
      ("https://[::ffff:10.0.0.1]/", .privateAddress), ("https://printer.local/", .privateAddress),
      ("https://intranet/", .privateAddress), ("https://2130706433/", .privateAddress),
      ("https://0x7f.1/", .privateAddress), ("https://localhost/", .privateAddress),
      ("https://example.com/reset?token=abc", .identifierInAddress),
      ("https://example.com/u/someone@example.com", .identifierInAddress),
      ("https://example.com/call/13812345678", .identifierInAddress),
      ("https://news.blocked.example/a", .blockedSite),
    ]
    for (address, expected) in refused {
      XCTAssertEqual(verdict(address), .failure(expected), address)
    }
  }

  /// Review 2026-10-06: a collected link's address carries no private word,
  /// no tracker or signed-link parameter; a query or an opaque identifier
  /// waits for the owner to see the whole address.
  func testCollectedLinks() {
    let check = OutboundCheck(
      privateTerms: PrivateTerms(personNames: ["张伟", "Alice Chen"], dictionaryWords: ["Kestrel"]),
      blockedTerms: ["蓝鲸计划"])
    func verdict(_ address: String, approved: String? = nil) -> CollectedLinkVerdict {
      check.check(collectedLink: URL(string: address)!, approval: approved.map { LookupApproval(terms: $0) })
    }
    let encoded = "https://docs.example.com/" + "蓝鲸计划".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    let refused: [(String, OutboundRefusal)] = [
      (encoded + "/plan", .blockedByOwner),
      (encoded + "/plan?owner=x&t=abc123def456", .identifierInAddress),
      ("https://docs.example.com/plan?owner=" + "张伟".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!, .personName),
      ("https://example.com/people/alice-chen/notes", .personName),
      ("https://example.com/kestrel/roadmap", .privateWord),
      ("https://click.example-mail.com/track?u=8f3a9c2e&e=YWxpY2VAZXhhbXBsZS5jb20=", .identifierInAddress),
      ("https://bucket.s3.amazonaws.com/f.pdf?X-Amz-Credential=AKIA%2F20261006&X-Amz-Signature=abcdef0123", .identifierInAddress),
      ("https://example.com/join?invite=abc", .identifierInAddress),
      ("https://example.com/a?auth_token=abc", .identifierInAddress),
      ("https://example.com/clinic/booking", .health),
    ]
    for (address, expected) in refused {
      XCTAssertEqual(verdict(address), .refuse(expected), address)
      XCTAssertEqual(verdict(address, approved: address), .refuse(expected), "approval never overrides: \(address)")
    }
    XCTAssertEqual(verdict("http://www.swift.org/about/"), .read(URL(string: "https://www.swift.org/about/")!))
    XCTAssertEqual(verdict("https://www.example.com/how-to-read-a-paper-2026"), .read(URL(string: "https://www.example.com/how-to-read-a-paper-2026")!))
    for address in ["https://www.example.com/article?id=42", "https://medium.example.com/my-post-8f3a9c2e1b4d", "https://x.example.com/u/status/1790000000000000000"] {
      XCTAssertEqual(verdict(address), .needsApproval(address), address)
      XCTAssertEqual(verdict(address, approved: address), .read(URL(string: address)!), address)
      XCTAssertEqual(verdict(address, approved: address + "x"), .needsApproval(address), address)
    }
    XCTAssertEqual(OutboundCheck.site(of: "docs.example.com"), "example.com")
    XCTAssertEqual(OutboundCheck.site(of: "www.example.co.uk"), "example.co.uk")
    XCTAssertEqual(OutboundCheck.site(of: "news.example.com.cn"), "example.com.cn")
  }

  /// MATTER-MINIMUM §11: synthetic material with names, code names,
  /// numbers, money, house numbers and health words planted; none of them
  /// may appear in anything that is sent.
  func testPlantedPrivateDataNeverLeaves() {
    let names = ["张伟", "李娜", "王芳", "Alice Chen", "David Kim", "小周"]
    let codes = ["Project Falcon", "蓝鲸计划", "Kestrel"]
    let numbers = ["13812345678", "021-12345678", "310101199001011234", "6222021234567890123", "Room 1203", "3号楼502"]
    let money = ["3000元", "¥2,000", "$450", "12万元"]
    let health = ["协和医院", "糖尿病复诊", "therapy session", "孕检"]
    let terms = PrivateTerms(personNames: names, dictionaryWords: ["Kestrel"], privateLabels: ["Project Falcon", "蓝鲸计划"])
    let check = OutboundCheck(privateTerms: terms, publicNames: directory)
    let planted = names + codes + numbers + money + health
    var sent: [String] = []
    var asked = 0
    var refused = 0
    for subject in planted {
      for public_ in ["", "NeurIPS ", "EXCONF "] {
        for gap in LookupGap.allCases {
          for approved in [false, true] {
            let name = public_ + subject
            var probe = request(gap, .other, name, year: 2026)
            if approved, case .needsApproval(let words) = check.terms(for: probe) {
              probe.approval = LookupApproval(terms: words)
            }
            switch check.terms(for: probe) {
            case .send(let words): sent.append(words)
            case .needsApproval: asked += 1
            case .refuse: refused += 1
            }
          }
        }
      }
    }
    let leaked = sent.filter { words in
      planted.contains { words.localizedCaseInsensitiveContains($0) }
    }
    XCTAssertEqual(leaked, [])
    XCTAssertEqual(sent, [])
    print("planted-leak probe: \(planted.count) planted values, \(refused) refused, \(asked) held for the owner, \(sent.count) sent")
  }

  func testRoutingAsksTheOwnerForEveryDeadline() {
    XCTAssertEqual(LookupRouting.route(for: request(.deadline, .conference, "NeurIPS")), .askPersonAndLookUp)
    XCTAssertEqual(LookupRouting.route(for: request(.deadline, .other, "改简历")), .askPerson)
    XCTAssertEqual(LookupRouting.route(for: request(.deadline, .conference, nil)), .askPerson)
    XCTAssertEqual(LookupRouting.route(for: request(.paperInfo, .paper, nil, identifiers: [.doi("10.1/x")])), .lookUp)
    XCTAssertEqual(LookupRouting.route(for: request(.paperInfo, .paper, nil)), .neither)
    XCTAssertEqual(LookupRouting.route(for: request(.openingHours, .place, "Example Public Library")), .lookUp)
    XCTAssertEqual(LookupRouting.route(for: request(.openingHours, .place, "Example"), healthRelated: true), .neither)
    XCTAssertEqual(LookupRouting.route(for: request(.deadline, .conference, "NeurIPS"), healthRelated: true), .askPerson)
  }

  /// A stored request without the health flag reads as health-related, so
  /// nothing is sent until the organizer decides again.
  func testOldRequestsReadAsHealthRelated() throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request(.deadline))) as? [String: Any])
    XCTAssertEqual(object["healthRelated"] as? Bool, false)
    object["healthRelated"] = nil
    let decoded = try JSONDecoder().decode(LookupRequest.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertTrue(decoded.healthRelated)
    XCTAssertEqual(decoded.subject, request(.deadline).subject)
  }

  func testHostClassification() {
    XCTAssertFalse(IPAddress("93.184.216.34")!.isPrivate)
    XCTAssertFalse(IPAddress("198.18.0.1")!.isPrivate)
    XCTAssertFalse(IPAddress("198.19.255.1")!.isPrivate)
    XCTAssertFalse(IPAddress("2606:4700::1111")!.isPrivate)
    for address in ["0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.31.0.1", "192.168.0.1", "224.0.0.1", "255.255.255.255", "::", "::1", "fe80::1", "fc00::1", "ff02::1", "::ffff:192.168.1.1", "64:ff9b::a00:1", "2001:db8::1"] {
      XCTAssertTrue(IPAddress(address)!.isPrivate, address)
    }
  }
}
