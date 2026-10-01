import CryptoKit
import Foundation

/// The per-library key material of the organizing link (privacy contract §1).
/// Only `libraryKey` ever crosses the link (into the organizing device's
/// memory, through the user's own SSH forward); the other keys are derived on
/// each side.
public struct OrganizerKeyMaterial: Equatable, Sendable {
  public static let byteCount = 32

  public let libraryKey: Data
  /// Lower-case hex of `SHA-256("mindloom-key-id-v1" ‖ library_key)`, first 16.
  public let keyID: String
  /// `HMAC-SHA256(library_key, "mindloom-store-v1")`: the organizing device's
  /// SQLCipher raw key.
  public let storeKey: Data
  /// `HMAC-SHA256(library_key, "mindloom-mask-v1")`: placeholder tags only.
  public let maskKey: Data
  /// Lower-case hex of `HMAC-SHA256(library_key, "mindloom-access-v1")`: the
  /// `X-Mindloom-Access` header of every data request after the unlock, so
  /// the link token (a file anyone on the Spark account can read) does not
  /// read the store by itself (privacy review F1).
  public let accessProof: String

  public enum KeyError: Error, Equatable, Sendable {
    case wrongLength
  }

  public init(libraryKey: Data) throws {
    guard libraryKey.count == Self.byteCount else { throw KeyError.wrongLength }
    self.libraryKey = libraryKey
    let digest = SHA256.hash(data: Data("mindloom-key-id-v1".utf8) + libraryKey)
    keyID = String(Self.hex(Data(digest)).prefix(16))
    let key = SymmetricKey(data: libraryKey)
    storeKey = Data(
      HMAC<SHA256>.authenticationCode(for: Data("mindloom-store-v1".utf8), using: key))
    maskKey = Data(HMAC<SHA256>.authenticationCode(for: Data("mindloom-mask-v1".utf8), using: key))
    accessProof = Self.hex(
      Data(HMAC<SHA256>.authenticationCode(for: Data("mindloom-access-v1".utf8), using: key)))
  }

  /// 32 bytes from the system CSPRNG.
  public static func random() throws -> OrganizerKeyMaterial {
    let key = SymmetricKey(size: .bits256)
    return try OrganizerKeyMaterial(libraryKey: key.withUnsafeBytes { Data($0) })
  }

  /// The value of `POST /v1/unlock`'s `key`: 64 lower-case hex characters.
  public var libraryKeyHex: String { Self.hex(libraryKey) }

  public static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// Keeps the key out of logs and debugger descriptions.
  public var description: String { "OrganizerKeyMaterial(key_id: \(keyID))" }
}

extension OrganizerKeyMaterial: CustomStringConvertible, CustomDebugStringConvertible {
  public var debugDescription: String { description }
}

/// One value masking replaced: what it was and the placeholder that stands
/// for it. `start`/`end` index the original input in UTF-16 units.
public struct PrivacyMaskSpan: Equatable, Sendable {
  public let type: String
  public let label: String
  public let placeholder: String
  public let original: String
  public let start: Int
  public let end: Int
}

/// Masking spec v3 (privacy contract §3; v2 after the v6 privacy review, v3
/// after the masking evaluation), a port of the Python reference (the
/// organizer's `spark/organizer/masking.py`) that must reproduce every shared
/// vector byte for byte.
///
/// A sweep runs the ten detectors in order; each detector's leftmost-longest
/// non-overlapping values (never overlapping a placeholder already in the
/// text) are replaced before the next detector runs, and sweeps repeat until
/// one changes nothing, so masking masked text returns it unchanged.
public struct PrivacyMasker: Sendable {
  public static let spec = "mindloom-mask-v3"

  public let maskKey: Data

  public init(maskKey: Data) throws {
    guard maskKey.count == OrganizerKeyMaterial.byteCount else {
      throw OrganizerKeyMaterial.KeyError.wrongLength
    }
    self.maskKey = maskKey
  }

  public init(keys: OrganizerKeyMaterial) {
    maskKey = keys.maskKey
  }

  /// For finding values only (screenshot redaction): its tags are never
  /// sent or stored.
  public static let detectionOnly = PrivacyMasker(
    unchecked: Data(repeating: 0, count: OrganizerKeyMaterial.byteCount))

  private init(unchecked maskKey: Data) {
    self.maskKey = maskKey
  }

  public func mask(_ text: String) -> String { maskWithSpans(text).text }

  /// The masked text and every value replaced, in original order.
  public func maskWithSpans(_ text: String) -> (text: String, spans: [PrivacyMaskSpan]) {
    var current = text
    // origin[i]: the UTF-16 offset in the original input of current's unit i,
    // or -1 inside a placeholder this call inserted.
    var origin = Array(0..<text.utf16.count)
    var spans: [PrivacyMaskSpan] = []
    while true {
      var changed = false
      for detector in PrivacyMaskRules.detectors {
        let values = PrivacyMaskRules.detect(detector, in: current)
        guard !values.isEmpty else { continue }
        changed = true
        let units = Array(current.utf16)
        var output: [UInt16] = []
        var newOrigin: [Int] = []
        output.reserveCapacity(units.count)
        var last = 0
        for (v0, v1) in values {
          let original = String(decoding: units[v0..<v1], as: UTF16.self)
          let placeholder = placeholder(type: detector.type, value: original)
          output.append(contentsOf: units[last..<v0])
          newOrigin.append(contentsOf: origin[last..<v0])
          let placeholderUnits = Array(placeholder.utf16)
          output.append(contentsOf: placeholderUnits)
          newOrigin.append(contentsOf: repeatElement(-1, count: placeholderUnits.count))
          last = v1
          let start = origin[v0]
          spans.append(
            PrivacyMaskSpan(
              type: detector.type, label: PrivacyMaskRules.labels[detector.type] ?? "",
              placeholder: placeholder, original: original, start: start,
              end: start + (v1 - v0)))
        }
        output.append(contentsOf: units[last...])
        newOrigin.append(contentsOf: origin[last...])
        current = String(decoding: output, as: UTF16.self)
        origin = newOrigin
      }
      if !changed { break }
    }
    return (current, spans.sorted { $0.start < $1.start })
  }

  /// `〔<label>·<tag>〕` for one value of one type.
  public func placeholder(type: String, value: String) -> String {
    let normalized = PrivacyMaskRules.normalize(type: type, value: value)
    let code = HMAC<SHA256>.authenticationCode(
      for: Data((type + ":" + normalized).utf8), using: SymmetricKey(data: maskKey))
    let tag = String(OrganizerKeyMaterial.hex(Data(code)).prefix(6))
    return PrivacyMaskRules.leftBracket + (PrivacyMaskRules.labels[type] ?? type)
      + PrivacyMaskRules.dot + tag + PrivacyMaskRules.rightBracket
  }
}

/// Putting originals back into text that came back from the organizing
/// device. A placeholder the Mac cannot resolve to exactly one original is
/// shown without its tag (`〔手机号〕`): never a wrong value, never the tag.
public enum PrivacyUnmask {
  public static func unmask(_ text: String, resolve: (String) -> String?) -> String {
    guard text.contains(PrivacyMaskRules.leftBracket) else { return text }
    let ns = text as NSString
    let matches = PrivacyMaskRules.placeholderRegex.matches(
      in: text, options: [], range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }
    var result = ""
    var last = 0
    for match in matches {
      result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
      let placeholder = ns.substring(with: match.range)
      if let original = resolve(placeholder) {
        result += original
      } else {
        result += untagged(placeholder)
      }
      last = match.range.location + match.range.length
    }
    result += ns.substring(from: last)
    return result
  }

  /// Every placeholder in `text`, in order (duplicates kept).
  public static func placeholders(in text: String) -> [String] {
    guard text.contains(PrivacyMaskRules.leftBracket) else { return [] }
    let ns = text as NSString
    return PrivacyMaskRules.placeholderRegex.matches(
      in: text, options: [], range: NSRange(location: 0, length: ns.length)
    ).map { ns.substring(with: $0.range) }
  }

  /// `〔手机号·a1b2c3〕` → `〔手机号〕`.
  public static func untagged(_ placeholder: String) -> String {
    guard let dot = placeholder.firstIndex(of: Character(PrivacyMaskRules.dot)) else {
      return placeholder
    }
    return String(placeholder[..<dot]) + PrivacyMaskRules.rightBracket
  }

  /// Maps a Unicode-scalar offset in text the Mac sent masked back to the
  /// same place in the original text. `replacements` are the masked and
  /// original scalar ranges of each placeholder, in order. An offset inside a
  /// placeholder moves to that value's start (or its end when `isEnd`).
  public static func originalOffset(
    _ offset: Int, replacements: [PrivacyMaskOffset], isEnd: Bool
  ) -> Int {
    var delta = 0
    for replacement in replacements {
      if offset < replacement.maskedStart { break }
      if offset < replacement.maskedEnd || (isEnd && offset == replacement.maskedEnd) {
        return offset == replacement.maskedStart
          ? replacement.originalStart
          : (isEnd ? replacement.originalEnd : replacement.originalStart)
      }
      delta = replacement.originalEnd - replacement.maskedEnd
    }
    return max(0, offset + delta)
  }
}

/// Where one placeholder sits in the text as sent and what it replaced in
/// the original, both in Unicode scalars.
public struct PrivacyMaskOffset: Codable, Equatable, Sendable {
  public let maskedStart: Int
  public let maskedEnd: Int
  public let originalStart: Int
  public let originalEnd: Int

  public init(maskedStart: Int, maskedEnd: Int, originalStart: Int, originalEnd: Int) {
    self.maskedStart = maskedStart
    self.maskedEnd = maskedEnd
    self.originalStart = originalStart
    self.originalEnd = originalEnd
  }

  enum CodingKeys: String, CodingKey {
    case maskedStart = "ms"
    case maskedEnd = "me"
    case originalStart = "os"
    case originalEnd = "oe"
  }

  /// The replacements of one masking, in Unicode scalars of the original and
  /// of the masked text.
  public static func offsets(original: String, spans: [PrivacyMaskSpan]) -> [PrivacyMaskOffset] {
    guard !spans.isEmpty else { return [] }
    // UTF-16 offset → scalar offset in the original.
    var scalarAt: [Int: Int] = [:]
    var unit = 0
    var scalar = 0
    let wanted = Set(spans.flatMap { [$0.start, $0.end] })
    for value in original.unicodeScalars {
      if wanted.contains(unit) { scalarAt[unit] = scalar }
      unit += value.utf16.count
      scalar += 1
    }
    if wanted.contains(unit) { scalarAt[unit] = scalar }
    var result: [PrivacyMaskOffset] = []
    var shift = 0
    for span in spans {
      guard let originalStart = scalarAt[span.start], let originalEnd = scalarAt[span.end] else {
        continue
      }
      let placeholderLength = span.placeholder.unicodeScalars.count
      let maskedStart = originalStart + shift
      result.append(
        PrivacyMaskOffset(
          maskedStart: maskedStart, maskedEnd: maskedStart + placeholderLength,
          originalStart: originalStart, originalEnd: originalEnd))
      shift += placeholderLength - (originalEnd - originalStart)
    }
    return result
  }
}

/// The rules of masking spec v3, verbatim from the Python reference (every
/// pattern is valid in both Python `re` and ICU). Each pattern has its own
/// validator. v2 adds the formats the v6 privacy review found unmasked
/// (finding F8): codes written before their keyword, other code and password
/// forms, PINs, numbers split by dots, no-break spaces or line breaks,
/// full-width and spoken Chinese digits, bracketed and spaced landlines,
/// numbers abroad, Amex, account numbers, more key formats, grouped and
/// 15-digit ID numbers and full-width at signs. v3 adds a third code
/// pattern: a code handed over later in the same sentence (keyword, up to 40
/// characters with no digit or sentence end, then 是 / 为 / a colon / "is").
public enum PrivacyMaskRules {
  public static let leftBracket = "\u{3014}"
  public static let rightBracket = "\u{3015}"
  public static let dot = "\u{00B7}"

  public static let order = [
    "secret", "password", "otp", "id_card", "bank_card", "phone", "landline", "email", "ip",
    "plate",
  ]

  public static let labels: [String: String] = [
    "secret": "密钥",
    "password": "密码",
    "otp": "验证码",
    "id_card": "身份证号",
    "bank_card": "银行卡号",
    "phone": "手机号",
    "landline": "电话",
    "email": "邮箱",
    "ip": "IP",
    "plate": "车牌号",
  ]

  struct Pattern: Sendable {
    let regex: NSRegularExpression
    let group: Int
    let validator: Validator
  }

  enum Validator: Sendable {
    case none
    case idCard
    /// v2: an ID number written in groups: 18 characters and a valid date.
    case idGrouped
    /// v2: an old 15-digit ID number: a valid 19YY date and an ID word
    /// within 12 characters before.
    case id15
    case bankCard
    /// v2: 15 digits, Luhn.
    case amex
    /// v2: 12 to 20 digits.
    case account
    case landline
    /// v2: a phone word within 12 characters before or after.
    case phoneWordNear
    case plate
  }

  struct Detector: Sendable {
    let type: String
    let patterns: [Pattern]
  }

  private static func compile(_ source: String) -> NSRegularExpression {
    // The sources are constants checked by the shared vectors; a failure is
    // a programming error.
    try! NSRegularExpression(pattern: source, options: [])
  }

  private static func patterns(
    _ sources: [String], groups: [Int], validators: [Validator]
  ) -> [Pattern] {
    precondition(sources.count == groups.count && groups.count == validators.count)
    return zip(zip(sources, groups), validators).map {
      Pattern(regex: compile($0.0), group: $0.1, validator: $1)
    }
  }

  static let placeholderRegex = compile(placeholderSource)

  static let secretSources = [
    #"(?<![A-Za-z0-9_〔〕\-])sk-(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{16,}"#,
    #"(?<![A-Za-z0-9_〔〕])ghp_[A-Za-z0-9]{20,}"#,
    #"(?<![A-Za-z0-9_〔〕])github_pat_[A-Za-z0-9_]{20,}"#,
    #"(?<![A-Za-z0-9_〔〕\-])xox[abprs]-[A-Za-z0-9\-]{10,}"#,
    #"(?<![A-Za-z0-9〔〕])AKIA[0-9A-Z]{16}(?![A-Za-z0-9〔〕])"#,
    #"(?<![A-Za-z0-9_〔〕\-])AIza[0-9A-Za-z_\-]{35}(?![0-9A-Za-z_〔〕\-])"#,
    #"(?<![A-Za-z〔〕])[Bb]earer[ ]+([A-Za-z0-9._~+/\-]{15,}[A-Za-z0-9_~+/\-]=*)"#,
    #"[?&](?:[Aa][Cc][Cc][Ee][Ss][Ss]_[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii]_[Kk][Ee][Yy]|[Ss][Ii][Gg][Nn][Aa][Tt][Uu][Rr][Ee]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ii][Gg])=([A-Za-z0-9._~%+/=\-]*[A-Za-z0-9_~%+/=\-])"#,
    #"(?<![A-Za-z0-9_〔〕\-])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#,
    #"(?<![A-Za-z0-9_〔〕\-])eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]{8,})?"#,
    #"(?<![A-Za-z0-9〔〕])LTAI[A-Za-z0-9]{12,24}(?![A-Za-z0-9〔〕])"#,
    #"(?<![A-Za-z0-9])(?:[Aa][Ww][Ss]_[Ss][Ee][Cc][Rr][Ee][Tt]_[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]_[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]_[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Cc][Cc][Ee][Ss][Ss][Kk][Ee][Yy][Ss][Ee][Cc][Rr][Ee][Tt]|[Cc][Ll][Ii][Ee][Nn][Tt]_[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Pp][Pp]_[Ss][Ee][Cc][Rr][Ee][Tt]|[Ss][Ee][Cc][Rr][Ee][Tt]_[Kk][Ee][Yy]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee]_[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]|[Aa][Pp][Ii]_[Kk][Ee][Yy]|[Aa][Pp][Ii][Kk][Ee][Yy]|[Aa][Uu][Tt][Hh]_[Tt][Oo][Kk][Ee][Nn]|[Aa][Cc][Cc][Ee][Ss][Ss]_[Tt][Oo][Kk][Ee][Nn]|[Rr][Ee][Ff][Rr][Ee][Ss][Hh]_[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn])[\"']?[ ]{0,2}[:=][ ]{0,2}[\"']?(?=[A-Za-z0-9/+_.=\-]*[0-9])([A-Za-z0-9/+_.=\-]{16,})"#,
    #"[A-Za-z][A-Za-z0-9+.\-]{1,15}://[^ \t\r\n:/@〔〕]{1,64}:([^ \t\r\n:/@〔〕]{1,128})@"#,
    #"-----BEGIN[ A-Z]{0,30} PRIVATE KEY-----[ \t\r\n]*([A-Za-z0-9+/=\r\n]{16,}[A-Za-z0-9+/=])"#,
  ]

  static let passwordSources = [
    #"(?:密码|口令|(?<![A-Za-z〔〕])(?:[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Ww][Dd])(?![A-Za-z]))(?:[ ]{0,2}(?:[:：=]|是|为)[ ]{0,2}|[ ]{1,2}[Ii][Ss][ ]{1,2})['\"“‘「]?([A-Za-z0-9!#$%\&*+./:;=?@\^_~\-]{3,63}[A-Za-z0-9!#$%\&*+/=@\^_~\-])"#,
    #"(?:密码|口令|(?<![A-Za-z〔〕])(?:[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Ww][Dd])(?![A-Za-z]))[ ]{0,2}(?=[A-Za-z0-9!#$%\&*+./:;=?@\^_~\-]*[0-9])([A-Za-z0-9!#$%\&*+./:;=?@\^_~\-]{3,63}[A-Za-z0-9!#$%\&*+/=@\^_~\-])"#,
    #"(?:密码|口令)[^:：\n〔〕]{1,8}[:：][ ]{0,2}['\"“‘「]?([A-Za-z0-9!#$%\&*+./:;=?@\^_~\-]{3,63}[A-Za-z0-9!#$%\&*+/=@\^_~\-])"#,
    #"(?<![A-Za-z〔〕])[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][ ][Ff][Oo][Rr][ ][^\n:：〔〕]{1,32}?[ ][Ii][Ss][ ]{1,2}['\"“‘「]?([A-Za-z0-9!#$%\&*+./:;=?@\^_~\-]{3,63}[A-Za-z0-9!#$%\&*+/=@\^_~\-])"#,
    #"(?<![A-Za-z〔〕])(?:PIN|Pin|pin)(?![A-Za-z])[ ]?码?[ ]{0,2}(?:[:：=]|是|为)?[ ]{0,2}([0-9]{4,8})(?![0-9A-Za-z〔〕])(?![.:/\-][0-9])(?![ ]?[年月日号点时分秒次个元条位])"#,
  ]

  static let otpSources = [
    #"(?:验证码|校验码|动态码|短信码|确认码|动态密码|(?<![A-Za-z〔〕])(?:[Vv][Ee][Rr][Ii][Ff][Ii][Cc][Aa][Tt][Ii][Oo][Nn][ ][Cc][Oo][Dd][Ee]|[Cc][Oo][Dd][Ee][ ][Ii][Ss]|[Oo][Tt][Pp])(?![A-Za-z]))[^0-9〔〕]{0,12}([0-9]{4,8})(?![0-9A-Za-z〔〕])(?![.:/\-][0-9〔])(?![ ]?[年月日号点时分秒次个元条位])"#,
    #"(?<![0-9A-Za-z〔〕.:/\-])(?<![0-9][ \-.·\u00a0])([0-9]{4,6})(?![0-9A-Za-z〔〕])(?![.:/\-][0-9])(?![ \u00a0·][0-9])(?![ ]?[年月日号点时分秒次个元条位期届])[^0-9〔〕\n]{0,24}?(?:验证码|校验码|动态码|短信码|确认码|动态密码|(?<![A-Za-z])(?:[Vv][Ee][Rr][Ii][Ff][Ii][Cc][Aa][Tt][Ii][Oo][Nn][ ][Cc][Oo][Dd][Ee]|[Ss][Ee][Cc][Uu][Rr][Ii][Tt][Yy][ ][Cc][Oo][Dd][Ee]|[Ll][Oo][Gg][Ii][Nn][ ][Cc][Oo][Dd][Ee]|[Pp][Aa][Ss][Ss][Cc][Oo][Dd][Ee]|[Oo][Tt][Pp])(?![A-Za-z]))"#,
    // v3: a code handed over later in the same sentence ("…验证码，刚收到的是 2802").
    #"(?:验证码|校验码|动态码|短信码|确认码|动态密码|(?<![A-Za-z〔〕])(?:[Vv][Ee][Rr][Ii][Ff][Ii][Cc][Aa][Tt][Ii][Oo][Nn][ ][Cc][Oo][Dd][Ee]|[Oo][Tt][Pp])(?![A-Za-z]))[^0-9〔〕\n。！？!?；;]{0,40}?(?:是|为|[:：]|(?<![A-Za-z])[Ii][Ss](?![A-Za-z]))[ ]{0,2}([0-9]{4,8})(?![0-9A-Za-z〔〕])(?![.:/\-][0-9〔])(?![ ]?[年月日号点时分秒次个元条位])"#,
  ]

  static let idSources = [
    #"(?<![0-9〔〕])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9〔〕])"#,
    #"(?<![0-9〔〕])[1-9][0-9]{5}([ \-])(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])\1[0-9]{3}[0-9Xx](?![0-9A-Za-z〔〕])"#,
    #"(?<![0-9A-Za-z〔〕])[1-9][0-9]{5}[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}(?![0-9A-Za-z〔〕])"#,
  ]

  static let bankSources = [
    #"(?<![0-9A-Za-z〔〕])[0-9]{16,19}(?![0-9A-Za-z〔〕])"#,
    #"(?<![0-9A-Za-z〔〕])(?<![0-9〕][ \-])[0-9]{4}([ \-])[0-9]{4}\1[0-9]{4}\1[0-9]{4}(?:\1[0-9]{1,3})?(?![0-9A-Za-z〔〕])(?![ \-][0-9〔])"#,
    #"(?<![0-9A-Za-z〔〕])(?<![0-9〕][ \-\n])[0-9]{4}[ \-\n]{1,2}[0-9]{4}[ \-\n]{1,2}[0-9]{4}[ \-\n]{1,2}[0-9]{4}(?:[ \-\n]{1,2}[0-9]{1,3})?(?![0-9A-Za-z〔〕])(?![ \-\n][0-9〔])"#,
    #"(?<![0-9A-Za-z〔〕])3[47][0-9]{2}([ \-]?)[0-9]{6}\1[0-9]{5}(?![0-9A-Za-z〔〕])(?![ \-][0-9〔])"#,
    #"(?:对公账号|对公账户|银行账号|银行账户|收款账号|收款账户|账号|账户|帐号|帐户|(?<![A-Za-z])[Aa][Cc][Cc][Oo][Uu][Nn][Tt](?:[ ](?:[Nn][Oo]\.?|[Nn][Uu][Mm][Bb][Ee][Rr]))?)[ ]{0,2}[:：]?[ ]{0,2}([0-9](?:[0-9]|[ \-](?=[0-9])){10,26}[0-9])(?![0-9A-Za-z〔〕])"#,
  ]

  static let phoneSources = [
    #"(?<![0-9〔〕])(?<![0-9〕]\.)(?:\+?86[ \-]?)?1[3-9][0-9]([ \-]?)[0-9]{4}\1[0-9]{4}(?![0-9〔〕])(?!\.[0-9〔])"#,
    #"(?<![0-9〔〕])(?<![0-9〕][.·])(?:\+?86[ \-]?)?1[3-9][0-9][ \-.·\u00a0\n]{1,2}[0-9]{4}[ \-.·\u00a0\n]{1,2}[0-9]{4}(?![0-9〔〕])(?![.·][0-9〔])"#,
    #"(?<![0-9０-９〔〕])(?:[＋+]?[８8][６6][ \-]?)?１[３-９][０-９]{9}(?![0-9０-９〔〕])"#,
    #"(?<![〇零一二三四五六七八九幺两〔〕])[一幺][三四五六七八九][〇零一二三四五六七八九幺两]{9}(?![〇零一二三四五六七八九幺两〔〕])"#,
  ]

  static let landlineSources = [
    #"(?<![0-9A-Za-z〔〕\-])0[0-9]{2,3}-[0-9]{7,8}(?![0-9〔〕])"#,
    #"(?<![0-9A-Za-z〔〕\-])0[0-9]{2,3}-[0-9]{3,4}-[0-9]{4}(?![0-9〔〕])"#,
    #"(?<![0-9A-Za-z〔〕+])\+[0-9]{1,3}[ \-][0-9]{6,14}(?![0-9〔〕])"#,
    #"(?<![0-9A-Za-z〔〕+])\+[0-9]{1,3}(?:[ \-][0-9]{1,5}){2,5}(?![0-9〔〕])(?![ \-][0-9〔])"#,
    #"(?<![0-9A-Za-z〔〕\-])0[0-9]{2,3}[ ][0-9]{3,4}[ ][0-9]{4}(?![0-9〔〕])(?![ \-][0-9〔])"#,
    #"(?<![0-9A-Za-z〔〕])[(（]0[0-9]{2,3}[)）][ \-]?[0-9]{3,4}[ \-]?[0-9]{4}(?![0-9〔〕])(?![ \-][0-9〔])"#,
    #"(?<![0-9A-Za-z〔〕+])\+[0-9]{1,3}[ ]?[(（][0-9]{1,4}[)）][ \-]?[0-9]{2,4}(?:[ \-][0-9]{2,5}){0,2}(?![0-9〔〕])(?![ \-][0-9〔])"#,
    #"(?<![0-9A-Za-z〔〕\-])[2-9][0-9]{3}[ \-][0-9]{4}(?![0-9〔〕])(?![ \-][0-9〔])"#,
  ]

  static let emailSources = [
    #"(?<![A-Za-z0-9._%+〔〕\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?![A-Za-z0-9〔〕])"#,
    #"(?<![A-Za-z0-9._%+〔〕\-])[A-Za-z0-9._%+\-]+＠[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?![A-Za-z0-9〔〕])"#,
  ]

  static let ipSources = [
    #"(?<![0-9A-Za-z〔〕])(?<![0-9〕]\.)(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9〔〕])(?!\.[0-9〔])"#
  ]

  static let plateSources = [
    #"(?<![A-Za-z0-9〔〕])[京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼][A-HJ-NP-Z][ ·•・\-]?(?:[A-HJ-NP-Z0-9]{5,6}|[A-HJ-NP-Z0-9]{4}[挂学警港澳])(?![A-Za-z0-9〔〕])"#
  ]

  static let bankKeywordSource = #"卡号|银行卡|储蓄卡|信用卡|账号|(?<![A-Za-z])[Cc][Aa][Rr][Dd]"#
  static let bankIINSource = #"62|4|5[1-5]|3[47]"#
  /// Keyword windows are searched with a range end: no lookahead in these, so
  /// ICU and Python agree at the window's edge.
  static let idKeywordSource = #"身份证|证件|身份号|(?<![A-Za-z])(?:ID|Id|id)"#
  static let phoneWordSource =
    #"电话|手机|座机|号码|联系|致电|拨打|打给|微信|(?<![A-Za-z])(?:[Ww][Hh][Aa][Tt][Ss][Aa][Pp][Pp]|[Tt][Ee][Ll]|[Pp][Hh][Oo][Nn][Ee]|[Cc][Aa][Ll][Ll]|[Mm][Oo][Bb][Ii][Ll][Ee])"#
  static let placeholderSource = #"〔(?:密钥|密码|验证码|身份证号|银行卡号|手机号|电话|邮箱|IP|车牌号)(?:·[0-9a-f]{6})?〕"#

  static let bankKeywordRegex = compile(bankKeywordSource)
  static let bankIINRegex = compile(bankIINSource)
  static let idKeywordRegex = compile(idKeywordSource)
  static let phoneWordRegex = compile(phoneWordSource)
  static let bankKeywordWindow = 12
  static let phoneWordWindow = 12

  static let detectors: [Detector] = [
    Detector(
      type: "secret",
      patterns: patterns(
        secretSources, groups: [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1],
        validators: Array(repeating: .none, count: 14))),
    Detector(
      type: "password",
      patterns: patterns(
        passwordSources, groups: [1, 1, 1, 1, 1], validators: Array(repeating: .none, count: 5))),
    Detector(
      type: "otp",
      patterns: patterns(otpSources, groups: [1, 1, 1], validators: [.none, .none, .none])),
    Detector(
      type: "id_card",
      patterns: patterns(idSources, groups: [0, 0, 0], validators: [.idCard, .idGrouped, .id15])),
    Detector(
      type: "bank_card",
      patterns: patterns(
        bankSources, groups: [0, 0, 0, 0, 1],
        validators: [.bankCard, .bankCard, .bankCard, .amex, .account])),
    Detector(
      type: "phone",
      patterns: patterns(
        phoneSources, groups: [0, 0, 0, 0], validators: Array(repeating: .none, count: 4))),
    Detector(
      type: "landline",
      patterns: patterns(
        landlineSources, groups: Array(repeating: 0, count: 8),
        validators: Array(repeating: .landline, count: 7) + [.phoneWordNear])),
    Detector(
      type: "email",
      patterns: patterns(emailSources, groups: [0, 0], validators: [.none, .none])),
    Detector(type: "ip", patterns: patterns(ipSources, groups: [0], validators: [.none])),
    Detector(type: "plate", patterns: patterns(plateSources, groups: [0], validators: [.plate])),
  ]

  /// v2: separators that may sit inside a number (removed before tagging).
  static let numberSeparators: Set<Unicode.Scalar> = [
    " ", "-", ".", "\u{00B7}", "\u{00A0}", "\n", "(", ")", "\u{FF08}", "\u{FF09}",
  ]

  /// v2: full-width digits, the full-width plus sign and spoken Chinese digits
  /// as ASCII.
  static func asciiDigits(_ value: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0xFF10...0xFF19:
        result.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
      case 0xFF0B:
        result.append("+")
      default:
        if let digit = spokenDigits[scalar] {
          result.append(Unicode.Scalar(0x30 + UInt32(digit))!)
        } else {
          result.append(scalar)
        }
      }
    }
    return String(result)
  }

  private static let spokenDigits: [Unicode.Scalar: Int] = [
    "〇": 0, "零": 0, "一": 1, "幺": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6,
    "七": 7, "八": 8, "九": 9,
  ]

  static func strippingSeparators(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter { !numberSeparators.contains($0) }))
  }

  /// The string that is tagged: formatting separators go, content stays.
  /// v2: full-width and spoken Chinese digits become ASCII digits, a
  /// full-width at sign becomes @, and dots, middle dots, no-break spaces,
  /// line breaks and brackets inside a number go too.
  public static func normalize(type: String, value: String) -> String {
    switch type {
    case "plate":
      var result = value.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
      for separator in [" ", "·", "•", "・", "-"] {
        result = result.replacingOccurrences(of: separator, with: "")
      }
      return result
    case "phone", "landline", "id_card", "bank_card":
      var result = strippingSeparators(asciiDigits(value))
      switch type {
      case "phone":
        if result.hasPrefix("+86") {
          result = String(result.unicodeScalars.dropFirst(3))
        } else if result.hasPrefix("86"), result.unicodeScalars.count == 13 {
          result = String(result.unicodeScalars.dropFirst(2))
        }
      case "id_card":
        result = result.uppercased()
      default:
        break
      }
      return result
    case "email":
      return value.replacingOccurrences(of: "\u{FF20}", with: "@").lowercased()
    default:
      return value
    }
  }

  /// Value ranges (UTF-16) one detector masks in `text`, in text order.
  static func detect(_ detector: Detector, in text: String) -> [(Int, Int)] {
    let ns = text as NSString
    let length = ns.length
    let whole = NSRange(location: 0, length: length)
    let claimed = placeholderRegex.matches(in: text, options: [], range: whole).map {
      ($0.range.location, $0.range.location + $0.range.length)
    }
    struct Candidate {
      let start: Int
      let length: Int
      let pattern: Int
      let valueStart: Int
      let valueEnd: Int
    }
    var candidates: [Candidate] = []
    for (index, pattern) in detector.patterns.enumerated() {
      var position = 0
      while position <= length {
        guard
          let match = pattern.regex.firstMatch(
            in: text, options: [.withTransparentBounds],
            range: NSRange(location: position, length: length - position))
        else { break }
        let value = match.range(at: pattern.group)
        if value.location != NSNotFound, value.length > 0 {
          candidates.append(
            Candidate(
              start: match.range.location, length: match.range.length, pattern: index,
              valueStart: value.location, valueEnd: value.location + value.length))
        }
        position = match.range.location + 1
      }
    }
    candidates.sort {
      if $0.start != $1.start { return $0.start < $1.start }
      if $0.length != $1.length { return $0.length > $1.length }
      return $0.pattern < $1.pattern
    }
    var taken: [(Int, Int)] = []
    var values: [(Int, Int)] = []
    for candidate in candidates {
      let range = (candidate.start, candidate.start + candidate.length)
      if overlaps(range, claimed) || overlaps(range, taken) { continue }
      let value = ns.substring(
        with: NSRange(
          location: candidate.valueStart, length: candidate.valueEnd - candidate.valueStart))
      guard
        validate(
          detector.patterns[candidate.pattern].validator, text: text,
          valueStart: candidate.valueStart, valueEnd: candidate.valueEnd, value: value,
          claimed: claimed)
      else { continue }
      taken.append(range)
      values.append((candidate.valueStart, candidate.valueEnd))
    }
    return values.sorted { $0.0 < $1.0 }
  }

  private static func overlaps(_ a: (Int, Int), _ spans: [(Int, Int)]) -> Bool {
    spans.contains { a.0 < $0.1 && $0.0 < a.1 }
  }

  private static func validate(
    _ validator: Validator, text: String, valueStart: Int, valueEnd: Int, value: String,
    claimed: [(Int, Int)]
  ) -> Bool {
    switch validator {
    case .none: return true
    case .idCard: return idCardIsValid(value)
    case .idGrouped:
      let digits = Array(strippingSeparators(value).unicodeScalars)
      guard digits.count == 18 else { return false }
      return dateIsValid(
        year: number(digits[6..<10]), month: number(digits[10..<12]), day: number(digits[12..<14]))
    case .id15:
      let digits = Array(value.unicodeScalars)
      guard digits.count == 15,
        dateIsValid(
          year: 1900 + number(digits[6..<8]), month: number(digits[8..<10]),
          day: number(digits[10..<12]))
      else { return false }
      return keyword(
        idKeywordRegex, in: text,
        from: scalarOffset(before: valueStart, scalars: bankKeywordWindow, in: text as NSString),
        to: valueStart, claimed: claimed)
    case .landline:
      guard value.hasPrefix("+") else { return true }
      let parts = value.split(whereSeparator: { $0 == " " || $0 == "-" }).dropFirst()
      // v2: digits only (a bracketed area code counts its digits).
      let digits = parts.reduce(0) { total, part in
        total + part.unicodeScalars.filter { ("0"..."9").contains($0) }.count
      }
      return (6...14).contains(digits)
    case .phoneWordNear:
      let ns = text as NSString
      return keyword(
        phoneWordRegex, in: text,
        from: scalarOffset(before: valueStart, scalars: phoneWordWindow, in: ns), to: valueStart,
        claimed: claimed)
        || keyword(
          phoneWordRegex, in: text, from: valueEnd,
          to: scalarOffset(after: valueEnd, scalars: phoneWordWindow, in: ns), claimed: claimed)
    case .plate:
      return value.unicodeScalars.dropFirst(2).filter { ("0"..."9").contains($0) }.count >= 3
    case .bankCard:
      return bankCardIsValid(text: text, valueStart: valueStart, value: value, claimed: claimed)
    case .amex:
      let digits = strippingSeparators(value)
      return digits.unicodeScalars.count == 15 && luhnIsValid(digits)
    case .account:
      return (12...20).contains(strippingSeparators(value).unicodeScalars.count)
    }
  }

  private static func number(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
    scalars.reduce(0) { $0 * 10 + Int($1.value) - 48 }
  }

  static func luhnIsValid(_ digits: String) -> Bool {
    var total = 0
    for (index, scalar) in digits.unicodeScalars.reversed().enumerated() {
      var digit = Int(scalar.value) - 48
      if index % 2 == 1 {
        digit *= 2
        if digit > 9 { digit -= 9 }
      }
      total += digit
    }
    return total % 10 == 0
  }

  static func idCardIsValid(_ value: String) -> Bool {
    let characters = Array(value.uppercased().unicodeScalars)
    guard characters.count == 18 else { return false }
    let digits = characters.prefix(17).map { Int($0.value) - 48 }
    guard digits.allSatisfy({ (0...9).contains($0) }) else { return false }
    let year = digits[6] * 1000 + digits[7] * 100 + digits[8] * 10 + digits[9]
    let month = digits[10] * 10 + digits[11]
    let day = digits[12] * 10 + digits[13]
    guard dateIsValid(year: year, month: month, day: day) else { return false }
    let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    let sum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
    let check = Array("10X98765432".unicodeScalars)[sum % 11]
    return characters[17] == check
  }

  /// Proleptic Gregorian calendar, as Python's `datetime.date`.
  static func dateIsValid(year: Int, month: Int, day: Int) -> Bool {
    guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return false }
    return day <= daysIn(month: month, year: year)
  }

  private static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2:
      let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  /// The UTF-16 offset `scalars` Unicode scalars before `offset` (or 0).
  static func scalarOffset(before offset: Int, scalars count: Int, in ns: NSString) -> Int {
    var position = offset
    var scalars = 0
    while position > 0, scalars < count {
      let unit = ns.character(at: position - 1)
      if UTF16.isTrailSurrogate(unit), position >= 2,
        UTF16.isLeadSurrogate(ns.character(at: position - 2))
      {
        position -= 2
      } else {
        position -= 1
      }
      scalars += 1
    }
    return position
  }

  /// The UTF-16 offset `scalars` Unicode scalars after `offset` (or the end).
  static func scalarOffset(after offset: Int, scalars count: Int, in ns: NSString) -> Int {
    var position = offset
    var scalars = 0
    while position < ns.length, scalars < count {
      let unit = ns.character(at: position)
      if UTF16.isLeadSurrogate(unit), position + 1 < ns.length,
        UTF16.isTrailSurrogate(ns.character(at: position + 1))
      {
        position += 2
      } else {
        position += 1
      }
      scalars += 1
    }
    return position
  }

  /// Whether `regex` matches inside `from..<to` (lookbehind sees the whole
  /// text) outside every claimed span.
  private static func keyword(
    _ regex: NSRegularExpression, in text: String, from start: Int, to end: Int,
    claimed: [(Int, Int)]
  ) -> Bool {
    var position = start
    while position < end {
      guard
        let match = regex.firstMatch(
          in: text, options: [.withTransparentBounds],
          range: NSRange(location: position, length: end - position))
      else { return false }
      let range = (match.range.location, match.range.location + match.range.length)
      if !overlaps(range, claimed) { return true }
      position = match.range.location + 1
    }
    return false
  }

  private static func bankCardIsValid(
    text: String, valueStart: Int, value: String, claimed: [(Int, Int)]
  ) -> Bool {
    let digits = strippingSeparators(value)
    let count = digits.unicodeScalars.count
    guard (16...19).contains(count), luhnIsValid(digits) else { return false }
    if let match = bankIINRegex.firstMatch(
      in: digits, options: [.anchored],
      range: NSRange(location: 0, length: (digits as NSString).length)),
      match.range.location == 0
    {
      return true
    }
    // The keyword window: the 12 Unicode scalars before the number.
    return keyword(
      bankKeywordRegex, in: text,
      from: scalarOffset(before: valueStart, scalars: bankKeywordWindow, in: text as NSString),
      to: valueStart, claimed: claimed)
  }
}
