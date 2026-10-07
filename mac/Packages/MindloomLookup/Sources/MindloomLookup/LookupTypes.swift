import CryptoKit
import Foundation

// MARK: - What is missing

/// The kind of fact a matter is missing that a public source may supply
/// (MATTER-MINIMUM §2, §5). Facts a person decides (their own deadline, a
/// decision, whether a step is done) are not lookups; `LookupRouting` says
/// who answers each gap.
public enum LookupGap: String, Codable, Sendable, CaseIterable {
  /// A submission, registration or application deadline.
  case deadline
  case callForPapers
  /// Dates and place of a public event.
  case eventDates
  /// Title, authors, venue and version of a paper.
  case paperInfo
  /// A public place's address.
  case address
  case openingHours
  /// A public product's specifications.
  case specification
  /// A public price.
  case price
  /// A public notice (a government or school call, a public regulation).
  case publicNotice
  /// What a public organization, product or venue is.
  case overview
}

/// What the subject of a lookup is.
public enum LookupSubjectKind: String, Codable, Sendable, CaseIterable {
  case conference
  case journal
  case paper
  case product
  case place
  case organization
  case publicNotice
  case other
}

/// The public thing a lookup is about: its kind and its public name
/// ("NeurIPS", "Marina Bay Sands"). Never a person, never a matter's title.
public struct LookupSubject: Codable, Sendable, Hashable {
  public var kind: LookupSubjectKind
  public var name: String

  public init(kind: LookupSubjectKind, name: String) {
    self.kind = kind
    self.name = name
  }
}

/// A public identifier found in the material (an arXiv number, a DOI).
public enum PublicIdentifier: Codable, Sendable, Hashable {
  case arXiv(String)
  case doi(String)
}

/// The owner tapped 「查找」 on exactly these words (a "freer search": the
/// words include a name that is not on a public list). Words that carry
/// private data are refused even with an approval.
public struct LookupApproval: Codable, Sendable, Hashable {
  public var terms: String
  public var approvedAt: Date

  public init(terms: String, approvedAt: Date = Date()) {
    self.terms = terms
    self.approvedAt = approvedAt
  }
}

/// One gap of one matter, as the organizer's "what is missing" step hands
/// it over. Everything here is already content-free: a public name, a year,
/// the kind of fact, an official domain and identifiers from the material.
public struct LookupRequest: Codable, Sendable, Hashable {
  public var matterID: UUID
  /// The item the new web sources are attached under.
  public var parentItemID: UUID
  public var gap: LookupGap
  public var subject: LookupSubject?
  public var year: Int?
  /// An official domain from a public source ("neurips.cc"), preferred when
  /// choosing which result to read.
  public var officialSite: String?
  public var identifiers: [PublicIdentifier]
  public var approval: LookupApproval?
  /// The matter is about health (MATTER-MINIMUM §5, §8.2): nothing about it
  /// goes online, whatever the gap, the name or the owner's 「查找」. The
  /// organizer decides this from the matter, not from the outgoing words;
  /// the word list in the outbound check is only a backstop. Required, so
  /// no caller forgets it.
  public var healthRelated: Bool

  public init(
    matterID: UUID, parentItemID: UUID, gap: LookupGap, subject: LookupSubject? = nil,
    year: Int? = nil, officialSite: String? = nil, identifiers: [PublicIdentifier] = [],
    approval: LookupApproval? = nil, healthRelated: Bool
  ) {
    self.matterID = matterID
    self.parentItemID = parentItemID
    self.gap = gap
    self.subject = subject
    self.year = year
    self.officialSite = officialSite
    self.identifiers = identifiers
    self.approval = approval
    self.healthRelated = healthRelated
  }

  enum CodingKeys: String, CodingKey {
    case matterID, parentItemID, gap, subject, year, officialSite, identifiers, approval, healthRelated
  }

  /// A request stored before `healthRelated` existed reads as health-related
  /// (nothing is sent until the organizer decides again).
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    matterID = try container.decode(UUID.self, forKey: .matterID)
    parentItemID = try container.decode(UUID.self, forKey: .parentItemID)
    gap = try container.decode(LookupGap.self, forKey: .gap)
    subject = try container.decodeIfPresent(LookupSubject.self, forKey: .subject)
    year = try container.decodeIfPresent(Int.self, forKey: .year)
    officialSite = try container.decodeIfPresent(String.self, forKey: .officialSite)
    identifiers = try container.decodeIfPresent([PublicIdentifier].self, forKey: .identifiers) ?? []
    approval = try container.decodeIfPresent(LookupApproval.self, forKey: .approval)
    healthRelated = (try? container.decodeIfPresent(Bool.self, forKey: .healthRelated)) ?? true
  }
}

// MARK: - What comes back

/// The keyless public sources (WEBSEARCH §4.2, first layer).
public enum PublicSourceID: String, Codable, Sendable, CaseIterable {
  case arXiv = "arxiv"
  case crossref
  case conferenceTable = "ccf-deadlines"
  case wikipedia
  case openStreetMap = "nominatim"
}

/// How a web source was found.
public enum WebSourceOrigin: Codable, Sendable, Hashable {
  /// A link inside the parent item (the owner collected it).
  case collectedLink
  /// A search service's result: which service, the words sent, the rank.
  case search(service: SearchServiceID, terms: String, rank: Int)
  /// A keyless public source and what was asked of it (an identifier or a
  /// public name).
  case publicSource(PublicSourceID, query: String)
  /// A page a public source points to (a conference's official site from
  /// the deadline table).
  case linkedFrom(PublicSourceID)
}

/// How a web source's text was read.
public enum WebSourceReader: Codable, Sendable, Hashable {
  /// Downloaded and read on this device by `extractor` (name and version).
  case onDevice(extractor: String)
  /// A reader service read the page because the device could not
  /// (`r.jina.ai`); only for pages a public index already lists.
  case readerService(host: String)
  /// A public source's structured answer (arXiv, Crossref, Wikipedia …).
  case structured(PublicSourceID)
}

/// How much a source speaks for the fact (MATTER-MINIMUM §7.4: a date from
/// a single unofficial page is not used).
public enum WebSourceAuthority: String, Codable, Sendable {
  /// The official site of the subject, or the registry that issues it
  /// (arXiv for an arXiv paper, Crossref for a DOI).
  case official
  /// A curated public reference (the conference deadline table, Wikipedia,
  /// OpenStreetMap).
  case reference
  case other
}

/// A new source item: one web page or public record, attached under the
/// original item. The original is never changed; this item is evidence, not
/// the owner's words (MATTER-MINIMUM §7.3).
public struct WebSourceItem: Codable, Sendable, Hashable, Identifiable {
  /// Deterministic: the same page with the same bytes under the same item
  /// and gap gets the same ID on every device, so two devices never add it
  /// twice.
  public let id: UUID
  public let parentItemID: UUID
  public let matterID: UUID?
  public let gap: LookupGap?
  public let title: String
  public let requestedURL: URL
  public let finalURL: URL
  /// The site, shown under a fact ("neurips.cc · 10月5日").
  public let host: String
  public let retrievedAt: Date
  /// `ProcessInfo.systemUptime` at retrieval, in nanoseconds (monotonic).
  public let retrievedUptimeNanoseconds: UInt64
  public let origin: WebSourceOrigin
  public let reader: WebSourceReader
  public let authority: WebSourceAuthority
  public let contentType: String
  /// The readable text, cleaned of invisible characters.
  public let text: String
  /// The passages relevant to the gap, each a verbatim run of `text`
  /// (what a model reads; never the matter's own text).
  public let excerpt: String
  /// Hex SHA-256 of the bytes as downloaded.
  public let rawSHA256: String
  /// The bytes as downloaded, LZFSE-compressed, when they fit
  /// `WebSourceItem.maximumRawBytes`; a better extractor can read them again.
  public let rawCompressed: Data?

  public static let maximumRawBytes = 2 * 1024 * 1024
  public static let maximumTextCharacters = 200_000

  public init(
    parentItemID: UUID, matterID: UUID?, gap: LookupGap?, title: String, requestedURL: URL,
    finalURL: URL, retrievedAt: Date, retrievedUptimeNanoseconds: UInt64, origin: WebSourceOrigin,
    reader: WebSourceReader, authority: WebSourceAuthority, contentType: String, text: String,
    excerpt: String, raw: Data
  ) {
    let rawSHA = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    self.id = Self.deterministicID(
      parentItemID: parentItemID, gap: gap, finalURL: finalURL, rawSHA256: rawSHA)
    self.parentItemID = parentItemID
    self.matterID = matterID
    self.gap = gap
    self.title = title
    self.requestedURL = requestedURL
    self.finalURL = finalURL
    self.host = finalURL.host?.lowercased() ?? ""
    self.retrievedAt = retrievedAt
    self.retrievedUptimeNanoseconds = retrievedUptimeNanoseconds
    self.origin = origin
    self.reader = reader
    self.authority = authority
    self.contentType = contentType
    self.text = String(text.prefix(Self.maximumTextCharacters))
    self.excerpt = excerpt
    self.rawSHA256 = rawSHA
    if raw.count <= Self.maximumRawBytes {
      self.rawCompressed = try? (raw as NSData).compressed(using: .lzfse) as Data
    } else {
      self.rawCompressed = nil
    }
  }

  /// The bytes as downloaded, when they were kept.
  public var raw: Data? {
    guard let rawCompressed else { return nil }
    return try? (rawCompressed as NSData).decompressed(using: .lzfse) as Data
  }

  static func deterministicID(
    parentItemID: UUID, gap: LookupGap?, finalURL: URL, rawSHA256: String
  ) -> UUID {
    let seed =
      "mindloom-web-item-v1\n\(parentItemID.uuidString.lowercased())\n\(gap?.rawValue ?? "")\n"
      + "\(finalURL.absoluteString)\n\(rawSHA256)"
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-style (name-based)
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

/// Why a lookup did not go out. Content-free: it names a category, never the
/// word that caused it.
public enum LookupLimit: String, Codable, Sendable, Equatable {
  /// This gap already sent its two requests (all services together).
  case gapLimit
  /// This matter already sent three requests today.
  case matterDailyLimit
  /// Twenty requests today.
  case dailyLimit
}

/// A request the dry run would have sent (kind, service and host only).
public struct PlannedRequest: Codable, Sendable, Hashable {
  public var kind: NetworkActivityKind
  public var service: String
  public var host: String
}

public enum LookupOutcome: Sendable, Equatable {
  /// New source items, attached under the request's parent item.
  case found([WebSourceItem])
  /// The sources answered and had nothing usable.
  case nothingFound
  /// The words include a name that is not on a public list: show the owner
  /// these words; they go out only after 「查找」 (`LookupApproval`).
  case needsApproval(terms: String)
  /// The words or the address carry private data; nothing was sent.
  case refused(OutboundRefusal)
  case limited(LookupLimit)
  /// No source can answer this gap (for example a general question and no
  /// search service has a key).
  case noSource
  /// 「从网络补充信息」 is off (or was turned off during the lookup); nothing
  /// more was sent.
  case off
  /// The caller's task was cancelled; nothing more was sent and no service
  /// was marked as failing.
  case cancelled
  /// Dry run: what would have been sent; nothing was sent.
  case planned([PlannedRequest])
}
