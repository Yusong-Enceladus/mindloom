import Foundation

/// Why something was not sent. A category only: it never carries the word
/// or the address that caused it.
public enum OutboundRefusal: String, Codable, Sendable, CaseIterable, Error {
  case empty
  case tooLong
  /// A masking placeholder (〔手机号·…〕): masked data is never sent, not
  /// even as its placeholder.
  case maskedValue
  case personName
  case matterTitle
  /// A group or space name, a dictionary word that is not on a public list.
  case privateWord
  /// A word or site the owner listed under 「不查找的词和网站」.
  case blockedByOwner
  case health
  case contact
  case secret
  case money
  case date
  /// Digits other than a year or a public name's own digits (phone, ID,
  /// house, plate and account numbers).
  case number
  /// Not an https address on the default port.
  case unsupportedAddress
  /// Loopback, private, link-local or local-network addresses and names.
  case privateAddress
  case credentialsInAddress
  /// An e-mail address, phone number, token or signed credential inside the
  /// address.
  case identifierInAddress
  case blockedSite
}

/// The owner's private words, from the library: never sent, whatever else
/// the request says (MATTER-MINIMUM §8.2 「去掉，或者整个挡下」).
public struct PrivateTerms: Sendable, Hashable {
  /// People's names and aliases, the owner's name and aliases, and names
  /// the device's name recognizer found in the material.
  public var personNames: [String]
  /// Words the owner added to the dictionary.
  public var dictionaryWords: [String]
  /// Group names, space names, project code names.
  public var privateLabels: [String]
  /// Matter titles as written.
  public var matterTitles: [String]

  public init(
    personNames: [String] = [], dictionaryWords: [String] = [], privateLabels: [String] = [],
    matterTitles: [String] = []
  ) {
    self.personNames = personNames
    self.dictionaryWords = dictionaryWords
    self.privateLabels = privateLabels
    self.matterTitles = matterTitles
  }
}

public enum OutboundVerdict: Sendable, Equatable {
  case send(String)
  /// The words name something that is not on a public list: the owner sees
  /// them and taps 「查找」 first.
  case needsApproval(String)
  case refuse(OutboundRefusal)
}

/// Whether a link the owner collected may be read.
public enum CollectedLinkVerdict: Sendable, Equatable {
  case read(URL)
  /// The address carries a query or an opaque identifier: the owner sees
  /// the whole address and taps 「查找」 first.
  case needsApproval(String)
  case refuse(OutboundRefusal)
}

/// The device's outbound check (MATTER-MINIMUM §8.2; WEBSEARCH §4.6). The
/// words are built here from fixed parts (a public name, a year, one fixed
/// phrase), never written by a model, and checked again as a whole. The
/// same rules run on the Mac and the iPhone.
public struct OutboundCheck: Sendable {
  public static let maximumWords = 8
  public static let maximumCharacters = 64

  public var privateTerms: PrivateTerms
  public var publicNames: PublicNameDirectory
  public var blockedTerms: [String]
  public var blockedSites: [String]

  public init(
    privateTerms: PrivateTerms, publicNames: PublicNameDirectory = .bundled,
    blockedTerms: [String] = [], blockedSites: [String] = []
  ) {
    self.privateTerms = privateTerms
    self.publicNames = publicNames
    self.blockedTerms = blockedTerms
    self.blockedSites = blockedSites
  }

  // MARK: Words

  /// The fixed phrase for a gap, in English and Chinese.
  public static func phrase(for gap: LookupGap, chinese: Bool) -> String {
    switch gap {
    case .deadline: chinese ? "截止日期" : "deadline"
    case .callForPapers: chinese ? "征稿" : "call for papers"
    case .eventDates: chinese ? "时间 地点" : "dates venue"
    case .paperInfo: chinese ? "论文" : "paper"
    case .address: chinese ? "地址" : "address"
    case .openingHours: chinese ? "营业时间" : "opening hours"
    case .specification: chinese ? "规格" : "specifications"
    case .price: chinese ? "价格" : "price"
    case .publicNotice: chinese ? "通知" : "notice"
    case .overview: ""
    }
  }

  static let phraseWords: Set<String> = {
    var words: Set<String> = []
    for gap in LookupGap.allCases {
      for chinese in [false, true] {
        for word in phrase(for: gap, chinese: chinese).split(separator: " ") {
          words.insert(PublicNameDirectory.normalized(String(word)))
        }
      }
    }
    return words
  }()

  static func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
  }

  /// The words a request sends to a search service or a name lookup:
  /// 「NeurIPS 2026 deadline」, 「首台套 2026 申报截止」.
  public func terms(for request: LookupRequest, includePhrase: Bool = true) -> OutboundVerdict {
    guard let subject = request.subject else { return .refuse(.empty) }
    let name = subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .refuse(.empty) }
    var parts = [name]
    if let year = request.year {
      guard (1900...2100).contains(year) else { return .refuse(.number) }
      parts.append(String(year))
    }
    var phrase: String?
    if includePhrase {
      let fixed = Self.phrase(for: request.gap, chinese: Self.containsHan(name))
      if !fixed.isEmpty {
        parts.append(fixed)
        phrase = fixed
      }
    }
    let text = parts.joined(separator: " ")
    let isPublic = publicNames.contains(name)
    if let refusal = refusal(in: text, publicName: isPublic ? name : nil, phrase: phrase) {
      return .refuse(refusal)
    }
    if isPublic { return .send(text) }
    if let approval = request.approval, approval.terms == text { return .send(text) }
    return .needsApproval(text)
  }

  /// A public identifier as it goes out (an arXiv number, a DOI), or why not.
  /// Identifiers go out without the owner's 「查找」, so a DOI's free-form
  /// suffix must not carry a contact, a token or a long number.
  public func check(identifier: PublicIdentifier) -> Result<String, OutboundRefusal> {
    switch identifier {
    case .arXiv(let raw):
      guard let id = ArXivSource.normalizedID(raw) else { return .failure(.number) }
      return .success(id)
    case .doi(let raw):
      guard let doi = CrossrefSource.normalizedDOI(raw) else { return .failure(.number) }
      if let refusal = privateRefusal(in: doi) { return .failure(refusal) }
      if let refusal = Self.identifierRefusal(in: doi) { return .failure(refusal) }
      return .success(doi)
    }
  }

  /// The first rule the words break, or nil. `publicName`: the public name
  /// in the words; its own digits and punctuation (「GPT-4」, 「RTX 5090」)
  /// are not a number, a date or a code.
  public func refusal(in text: String, publicName: String? = nil) -> OutboundRefusal? {
    refusal(in: text, publicName: publicName, phrase: nil)
  }

  /// `phrase`: the fixed phrase this code appended (「deadline」, 「论文」); the
  /// owner's titles and dictionary words are looked for in the rest only.
  func refusal(in text: String, publicName: String?, phrase: String?) -> OutboundRefusal? {
    let folded = text.precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if folded.isEmpty { return .empty }
    let words = folded.split(whereSeparator: { $0.isWhitespace })
    if words.count > Self.maximumWords || folded.count > Self.maximumCharacters { return .tooLong }
    var body = folded
    if let phrase, !phrase.isEmpty, body.hasSuffix(phrase) {
      body = String(body.dropLast(phrase.count))
    }
    if let refusal = privateRefusal(in: folded, body: body) { return refusal }
    var remainder = folded
    if let publicName {
      let name = publicName.precomposedStringWithCompatibilityMapping
      if let range = remainder.range(of: name, options: [.caseInsensitive]) {
        remainder.replaceSubrange(range, with: " ")
      }
    }
    if let refusal = Self.patternRefusal(in: remainder) { return refusal }
    if let refusal = Self.addressRefusal(in: remainder) { return refusal }
    return Self.numberRefusal(in: remainder)
  }

  /// Masked values, the owner's words, names, titles, health words.
  func privateRefusal(in text: String) -> OutboundRefusal? {
    privateRefusal(in: text, body: text)
  }

  /// `body`: `text` without the fixed phrase. Names and the owner's blocked
  /// words are looked for everywhere; titles, labels, dictionary words and
  /// health words in the body.
  func privateRefusal(in text: String, body: String) -> OutboundRefusal? {
    if text.contains("\u{3014}") || text.contains("\u{3015}") { return .maskedValue }
    let whole = Self.fold(text)
    for term in blockedTerms {
      let key = Self.foldedKey(term)
      if !key.isEmpty, whole.key.contains(key) { return .blockedByOwner }
    }
    for name in privateTerms.personNames where Self.matches(name, in: whole) {
      return .personName
    }
    let rest = body == text ? whole : Self.fold(body)
    // A matter titled exactly with a name from a trusted public list (the
    // bundled list, the conference table) does not block that name; a name
    // the organizer learned from a page never overrides the owner's words.
    for title in privateTerms.matterTitles where !publicNames.isTrusted(title) {
      if Self.matches(title, in: rest) { return .matterTitle }
    }
    for label in privateTerms.privateLabels where Self.matches(label, in: rest) {
      return .privateWord
    }
    for word in privateTerms.dictionaryWords {
      guard !Self.phraseWords.contains(PublicNameDirectory.normalized(word)), !publicNames.isTrusted(word) else {
        continue
      }
      if Self.matches(word, in: rest) { return .privateWord }
    }
    if HealthWords.matches(rest) { return .health }
    return nil
  }

  /// Text as the private-word rules compare it: compatibility forms folded,
  /// lower case, traditional Han folded to simplified (「張偉」 is 「张伟」).
  struct Folded {
    /// Letters and digits only.
    var key: String
    var tokens: [String]
  }

  static func simplified(_ text: String) -> String {
    let folded = text.precomposedStringWithCompatibilityMapping
    guard containsHan(folded) else { return folded }
    return folded.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? folded
  }

  static func foldedKey(_ text: String) -> String {
    PublicNameDirectory.normalized(simplified(text))
  }

  static func fold(_ text: String) -> Folded {
    let simple = simplified(text)
    return Folded(key: PublicNameDirectory.normalized(simple), tokens: latinTokens(simple))
  }

  /// Han names match as a run of characters (two or more); Latin names as
  /// whole words, or written together (「AliceChen」, 「alice_chen」); a
  /// Latin word of six letters or more also inside a longer word.
  static func matches(_ term: String, in text: Folded) -> Bool {
    let key = foldedKey(term)
    guard !key.isEmpty else { return false }
    if containsHan(key) {
      return key.count >= 2 && text.key.contains(key)
    }
    let termTokens = latinTokens(simplified(term))
    let joined = termTokens.joined()
    guard !termTokens.isEmpty, joined.count >= 2 else { return false }
    if termTokens.count <= text.tokens.count {
      for start in 0...(text.tokens.count - termTokens.count)
      where Array(text.tokens[start..<(start + termTokens.count)]) == termTokens {
        return true
      }
    }
    if termTokens.count > 1 || joined.count >= 6 {
      if text.tokens.contains(where: { $0.contains(joined) }) { return true }
    }
    return false
  }

  static func latinTokens(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) || containsHan(String($0)) })
      .map(String.init)
  }

  // MARK: Patterns (the patterns themselves are in OutboundPatterns.swift)

  static func regex(_ source: String) -> NSRegularExpression {
    // Constant patterns checked by the tests; a failure is a programming error.
    try! NSRegularExpression(pattern: source, options: [])
  }

  static func found(_ pattern: NSRegularExpression, in text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  static func patternRefusal(in text: String) -> OutboundRefusal? {
    if found(contactPattern, in: text) { return .contact }
    if found(secretPattern, in: text) { return .secret }
    if found(moneyPattern, in: text) { return .money }
    if found(datePattern, in: text) { return .date }
    return nil
  }

  /// House numbers and plates.
  static func addressRefusal(in text: String) -> OutboundRefusal? {
    if found(houseNumberPattern, in: text) { return .number }
    let range = NSRange(text.startIndex..., in: text)
    for match in platePattern.matches(in: text, range: range) {
      guard let group = Range(match.range(at: 1), in: text) else { continue }
      if text[group].filter(\.isNumber).count >= 3 { return .number }
    }
    return nil
  }

  /// Letters that make a code an address or a phone ("Room1203", "Tel88",
  /// "Apt 5B").
  static let addressWords: Set<String> = [
    "room", "rm", "unit", "apt", "suite", "floor", "fl", "flat", "no", "building", "bldg", "blk", "block",
    "tel", "phone", "fax", "ext", "id", "house", "lot",
  ]
  /// Words after a house number ("2048 Elm Street").
  static let streetWords: Set<String> = [
    "street", "st", "road", "rd", "avenue", "ave", "av", "lane", "ln", "drive", "dr", "boulevard", "blvd",
    "way", "court", "ct", "place", "pl", "terrace", "highway", "hwy", "parkway", "pkwy", "square", "sq",
    "crescent", "close", "alley", "circle", "cir", "jalan", "jln",
  ]

  /// Digits are a number unless they are a four-digit year (1900–2100) or
  /// part of a short model code written with Latin letters ("PG-80",
  /// "H100", "GPT-4o"); next to a word like "Apt" or before a word like
  /// "Street" they are a number whatever their shape; a run of four or more
  /// spoken Chinese digits is a number too.
  static func numberRefusal(in text: String) -> OutboundRefusal? {
    if found(spokenDigitsPattern, in: text) { return .number }
    // A decimal digit of another script (Han numerals are letters and are
    // covered by the spoken-digits rule).
    for character in text where !character.isASCII {
      if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .decimalNumber }) {
        return .number
      }
    }
    let runs = asciiRuns(text)
    if isAddressNumber(runs) { return .number }
    for run in runs where run.contains(where: \.isNumber) {
      let digits = run.filter(\.isNumber)
      if digits.count == run.count {
        guard digits.count == 4, let year = Int(digits), (1900...2100).contains(year) else { return .number }
        continue
      }
      let letters = run.filter(\.isLetter).lowercased()
      if letters.isEmpty || digits.count > 5 || run.count > 16 || addressWords.contains(letters) { return .number }
    }
    return nil
  }

  /// Runs of ASCII letters, digits and 「-_.」.
  static func asciiRuns(_ text: String) -> [String] {
    var runs: [String] = []
    var run = ""
    for character in text {
      if character.isASCII, character.isLetter || character.isNumber || "-_.".contains(character) {
        run.append(character)
      } else {
        if !run.isEmpty { runs.append(run) }
        run = ""
      }
    }
    if !run.isEmpty { runs.append(run) }
    return runs
  }

  /// Digits next to "Apt", "Room", "Tel" …, or digits before "Street",
  /// "Road" … within three words: a house, room or phone number whatever
  /// its shape ("Apt 5B", "2048 Elm Street").
  static func isAddressNumber(_ runs: [String]) -> Bool {
    let words = runs.map { $0.filter(\.isLetter).lowercased() }
    for (index, run) in runs.enumerated() where run.contains(where: \.isNumber) {
      let before = index > 0 ? words[index - 1] : ""
      let after = index + 1 < runs.count ? words[index + 1] : ""
      if addressWords.contains(before) || addressWords.contains(after) { return true }
      if run.allSatisfy(\.isNumber), words[(index + 1)..<min(runs.count, index + 4)].contains(where: streetWords.contains) {
        return true
      }
    }
    return false
  }

  static func identifierRefusal(in text: String) -> OutboundRefusal? {
    if found(contactPattern, in: text) { return .contact }
    let range = NSRange(text.startIndex..., in: text)
    if let match = identifierSecretPattern.firstMatch(in: text, range: range),
      let found = Range(match.range, in: text)
    {
      return text[found].allSatisfy(\.isNumber) ? .number : .secret
    }
    return nil
  }

  /// A name the organizer learned from a page (`WebLookup.learn`): the
  /// owner's words, contacts, secrets, money, dates, house numbers, plates
  /// and long numbers keep it off the public list. Its own short digits
  /// ("RTX 5090") are allowed, as for any public name.
  func learnedNameRefusal(_ name: String) -> OutboundRefusal? {
    let folded = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    if folded.isEmpty { return .empty }
    if folded.count > Self.maximumCharacters { return .tooLong }
    if let refusal = privateRefusal(in: folded) { return refusal }
    if let refusal = Self.patternRefusal(in: folded) { return refusal }
    if let refusal = Self.addressRefusal(in: folded) { return refusal }
    if Self.isAddressNumber(Self.asciiRuns(folded)) { return .number }
    if folded.range(of: #"[0-9]{6,}"#, options: .regularExpression) != nil { return .number }
    return nil
  }

  // MARK: Addresses

  static let sensitiveQueryNames: Set<String> = [
    "token", "access_token", "id_token", "refresh_token", "key", "api_key", "apikey", "sig",
    "signature", "password", "pwd", "passwd", "secret", "auth", "authorization", "code",
    "session", "sessionid", "sid", "ticket", "email", "phone", "mobile", "tel",
    // Trackers and one-time links: who opened it, and links that work once.
    "t", "u", "e", "uid", "userid", "user_id", "invite", "invitation", "magic", "magic_link", "otp", "nonce",
    "jwt", "awsaccesskeyid", "expires", "credential", "credentials",
  ]
  /// Parts of a query name that mark a credential wherever they appear
  /// ("X-Amz-Signature", "auth_token", "session_id").
  static let sensitiveQueryParts = [
    "token", "signature", "secret", "password", "passwd", "credential", "session", "apikey", "api_key",
  ]

  static func isSensitiveQueryName(_ name: String) -> Bool {
    let name = name.lowercased()
    if sensitiveQueryNames.contains(name) { return true }
    if name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") || name.hasPrefix("x-oss-") { return true }
    return sensitiveQueryParts.contains { name.contains($0) }
  }

  /// The address as it is fetched (https, no fragment), or why it is not.
  /// An http address is fetched as https. Every hop is checked with this:
  /// the owner's words, names and blocked words never go out in a path or a
  /// query either.
  public func check(address url: URL) -> Result<URL, OutboundRefusal> {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased()
    else { return .failure(.unsupportedAddress) }
    switch scheme {
    case "https": break
    case "http": components.scheme = "https"
    default: return .failure(.unsupportedAddress)
    }
    if components.user != nil || components.password != nil { return .failure(.credentialsInAddress) }
    guard let host = components.host?.lowercased(), !host.isEmpty else {
      return .failure(.unsupportedAddress)
    }
    if let port = components.port, port != 443 { return .failure(.unsupportedAddress) }
    if HostPolicy.isPrivate(hostName: host) { return .failure(.privateAddress) }
    for site in blockedSites {
      let site = site.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
      if !site.isEmpty, host == site || host.hasSuffix("." + site) { return .failure(.blockedSite) }
    }
    components.fragment = nil
    guard let clean = components.url, clean.absoluteString.count <= 2048 else {
      return .failure(.unsupportedAddress)
    }
    for item in components.queryItems ?? [] where Self.isSensitiveQueryName(item.name) {
      return .failure(.identifierInAddress)
    }
    let decoded = Self.decodedPathAndQuery(components)
    if Self.found(Self.addressIdentifierPattern, in: decoded) { return .failure(.identifierInAddress) }
    if let refusal = privateRefusal(in: decoded) {
      return .failure(refusal == .maskedValue ? .identifierInAddress : refusal)
    }
    return .success(clean)
  }

  static func decodedPathAndQuery(_ components: URLComponents) -> String {
    let raw = components.percentEncodedPath + "?" + (components.percentEncodedQuery ?? "")
    return (raw.removingPercentEncoding ?? components.path).replacingOccurrences(of: "+", with: " ")
  }

  /// A link the owner collected (ENTRY-011): the address checks above, and an
  /// address with a query or an opaque identifier in its path (a tracker, a
  /// one-time or signed link, an account page) is read only after the owner
  /// saw the whole address and tapped 「查找」 (`approval` is that address).
  public func check(collectedLink url: URL, approval: LookupApproval?) -> CollectedLinkVerdict {
    let clean: URL
    switch check(address: url) {
    case .failure(let refusal): return .refuse(refusal)
    case .success(let value): clean = value
    }
    guard let components = URLComponents(url: clean, resolvingAgainstBaseURL: false) else {
      return .refuse(.unsupportedAddress)
    }
    let hasQuery = !(components.percentEncodedQuery ?? "").isEmpty
    guard hasQuery || Self.hasOpaqueSegment(components.percentEncodedPath) else { return .read(clean) }
    if let approval, approval.terms == clean.absoluteString { return .read(clean) }
    return .needsApproval(clean.absoluteString)
  }

  /// A path piece that looks like an identifier rather than a word: twelve
  /// or more letters and digits mixed ("8f3a9c2e1b4d"), eight or more
  /// digits, or one unbroken run of twenty-four or more characters.
  static func hasOpaqueSegment(_ path: String) -> Bool {
    for segment in path.split(separator: "/") {
      let decoded = String(segment).removingPercentEncoding ?? String(segment)
      for piece in decoded.split(whereSeparator: { "-_.~+=,;".contains($0) }) {
        let digits = piece.filter(\.isNumber).count
        let letters = piece.filter(\.isLetter).count
        if piece.count >= 12, digits >= 3, letters >= 3 { return true }
        if digits >= 8 { return true }
        if piece.count >= 24 { return true }
      }
    }
    return false
  }

  /// The site a host belongs to ("docs.example.com" → "example.com",
  /// "www.example.co.uk" → "example.co.uk"), for keeping a collected link's
  /// redirects on its own site. No public-suffix list: two labels, or three
  /// under a country code's common second level.
  public static func site(of host: String) -> String {
    var host = host.lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    if IPAddress(host) != nil { return host }
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return host }
    let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "mil", "gob", "nic"]
    let count = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
    return labels.suffix(count).joined(separator: ".")
  }
}
