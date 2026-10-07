import Foundation

/// Names known to be public (MATTER-MINIMUM §8.2 「放行」): only these go out
/// without the owner seeing the words first. Sources: a small bundled list of
/// well-known venues, journals, organizations and products; every
/// conference in the downloaded deadline table; names a public record
/// returned (a paper's venue from arXiv or Crossref); names the organizer
/// found in a public page the owner collected.
///
/// Only the bundled list and the conference table are trusted: a name from
/// them may be a matter's title or a dictionary word and still go out. A
/// name from a public record or a page never overrides the owner's words
/// (`OutboundCheck.privateRefusal`).
public struct PublicNameDirectory: Sendable {
  public enum Source: String, Codable, Sendable {
    case bundled
    case conferenceTable
    case publicRecord
    case collectedPublicPage

    /// Higher is more trusted; an entry is never replaced by a less trusted
    /// source.
    var rank: Int {
      switch self {
      case .bundled, .conferenceTable: 2
      case .publicRecord: 1
      case .collectedPublicPage: 0
      }
    }

    public var isTrusted: Bool { rank == 2 }
  }

  public struct Entry: Sendable, Hashable {
    public var name: String
    public var kind: LookupSubjectKind
    /// The official domain, when the source names one.
    public var officialSite: String?
    public var source: Source
  }

  private var entries: [String: Entry] = [:]

  public init() {}

  public var count: Int { entries.count }

  public mutating func add(
    _ name: String, kind: LookupSubjectKind, officialSite: String? = nil, source: Source
  ) {
    let key = Self.normalized(name)
    guard key.count >= 2 else { return }
    if let existing = entries[key] {
      if existing.source.rank > source.rank {
        // Keep the more trusted entry; it may take an official site it lacked.
        if existing.officialSite == nil, let officialSite { entries[key]?.officialSite = officialSite }
        return
      }
      if existing.source.rank == source.rank, existing.officialSite != nil, officialSite == nil { return }
      entries[key] = Entry(
        name: name, kind: kind, officialSite: officialSite ?? existing.officialSite, source: source)
      return
    }
    entries[key] = Entry(name: name, kind: kind, officialSite: officialSite, source: source)
  }

  public mutating func merge(_ other: PublicNameDirectory) {
    for entry in other.entries.values {
      add(entry.name, kind: entry.kind, officialSite: entry.officialSite, source: entry.source)
    }
  }

  /// The entry for a name, matched after normalization (case, width,
  /// spaces and punctuation do not matter).
  public func entry(for name: String) -> Entry? {
    entries[Self.normalized(name)]
  }

  public func contains(_ name: String) -> Bool { entry(for: name) != nil }

  /// On the bundled list or in the conference table.
  public func isTrusted(_ name: String) -> Bool { entry(for: name)?.source.isTrusted ?? false }

  /// NFKC, lower case, letters and digits only.
  public static func normalized(_ text: String) -> String {
    let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
    return String(
      String.UnicodeScalarView(
        folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
  }

  /// The bundled list: names anyone would recognize as public. The
  /// conference deadline table adds several hundred conferences when it is
  /// downloaded.
  public static let bundled: PublicNameDirectory = {
    var directory = PublicNameDirectory()
    let journals: [(String, String?)] = [
      ("Nature", "nature.com"), ("Science", "science.org"), ("Cell", "cell.com"),
      ("PNAS", "pnas.org"), ("Proceedings of the National Academy of Sciences", "pnas.org"),
      ("Nature Machine Intelligence", "nature.com"), ("Nature Communications", "nature.com"),
      ("Science Advances", "science.org"), ("JMLR", "jmlr.org"),
      ("Journal of Machine Learning Research", "jmlr.org"), ("TMLR", "jmlr.org"),
      ("Transactions on Machine Learning Research", "jmlr.org"), ("TPAMI", "computer.org"),
      ("IEEE Transactions on Pattern Analysis and Machine Intelligence", "computer.org"),
      ("IJCV", "springer.com"), ("International Journal of Computer Vision", "springer.com"),
      ("TACL", "transacl.org"),
      ("Transactions of the Association for Computational Linguistics", "transacl.org"),
      ("Communications of the ACM", "acm.org"), ("ACM Computing Surveys", "acm.org"),
      ("IEEE Transactions on Image Processing", "ieee.org"),
      ("IEEE/ACM Transactions on Audio, Speech, and Language Processing", "ieee.org"),
      ("Artificial Intelligence", "sciencedirect.com"), ("Pattern Recognition", "sciencedirect.com"),
      ("Neural Networks", "sciencedirect.com"), ("Science China Information Sciences", "springer.com"),
      ("中国科学：信息科学", nil), ("计算机学报", nil), ("软件学报", nil), ("自动化学报", nil),
    ]
    for (name, site) in journals {
      directory.add(name, kind: .journal, officialSite: site, source: .bundled)
    }
    let organizations: [(String, String?)] = [
      ("arXiv", "arxiv.org"), ("IEEE", "ieee.org"), ("ACM", "acm.org"), ("AAAI", "aaai.org"),
      ("CCF", "ccf.org.cn"), ("中国计算机学会", "ccf.org.cn"), ("NSFC", "nsfc.gov.cn"),
      ("国家自然科学基金委员会", "nsfc.gov.cn"), ("Apple", "apple.com"), ("Google", "google.com"),
      ("Microsoft", "microsoft.com"), ("NVIDIA", "nvidia.com"), ("OpenAI", "openai.com"),
      ("Anthropic", "anthropic.com"), ("Meta", "meta.com"), ("Amazon", "amazon.com"),
      ("腾讯", "tencent.com"), ("阿里巴巴", "alibabagroup.com"), ("百度", "baidu.com"),
      ("字节跳动", "bytedance.com"), ("华为", "huawei.com"), ("小米", "mi.com"),
    ]
    for (name, site) in organizations {
      directory.add(name, kind: .organization, officialSite: site, source: .bundled)
    }
    let products: [(String, String?)] = [
      ("iPhone", "apple.com"), ("iPad", "apple.com"), ("MacBook Pro", "apple.com"),
      ("MacBook Air", "apple.com"), ("Mac mini", "apple.com"), ("Mac Studio", "apple.com"),
      ("Apple Watch", "apple.com"), ("AirPods", "apple.com"), ("Apple Vision Pro", "apple.com"),
      ("DGX Spark", "nvidia.com"), ("NVIDIA DGX Spark", "nvidia.com"),
    ]
    for (name, site) in products {
      directory.add(name, kind: .product, officialSite: site, source: .bundled)
    }
    return directory
  }()
}
