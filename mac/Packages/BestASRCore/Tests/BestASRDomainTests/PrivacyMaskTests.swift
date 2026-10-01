import BestASRDomain
import CryptoKit
import Foundation
import XCTest

/// Masking spec v3 (privacy contract §3; v2 after the v6 privacy review,
/// finding F8; v3 after the masking evaluation) against the vectors shared with the organizing device. The file
/// must stay byte-identical in both repositories.
final class PrivacyMaskTests: XCTestCase {
  /// The constant published with the vectors; both test suites assert it.
  static let vectorsSHA256 = "b256b5a57ad2bc92e963de5427f247c5255397270ed038bf751f0b18ae9fe71f"

  private struct VectorFile: Decodable {
    struct Derive: Decodable {
      let libraryKeyHex: String
      let keyID: String
      let storeKeyHex: String
      let maskKeyHex: String
      let sqlcipherPragma: String

      enum CodingKeys: String, CodingKey {
        case libraryKeyHex = "library_key_hex"
        case keyID = "key_id"
        case storeKeyHex = "store_key_hex"
        case maskKeyHex = "mask_key_hex"
        case sqlcipherPragma = "sqlcipher_pragma"
      }
    }
    struct Vector: Decodable {
      let input: String
      let expected: String
    }
    let spec: String
    let maskKeyHex: String
    let labels: [String: String]
    let order: [String]
    let derive: [Derive]
    let vectors: [Vector]

    enum CodingKeys: String, CodingKey {
      case spec
      case maskKeyHex = "mask_key_hex"
      case labels, order, derive, vectors
    }
  }

  private func vectorData() throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "mask_vectors", withExtension: "json", subdirectory: "privacy")
    )
    return try Data(contentsOf: url)
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      data.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return data
  }

  private func vectors() throws -> VectorFile {
    try JSONDecoder().decode(VectorFile.self, from: try vectorData())
  }

  private var testMasker: PrivacyMasker {
    get throws { try PrivacyMasker(maskKey: Data(repeating: 0x11, count: 32)) }
  }

  func testVectorFileIsTheSharedOneByteForByte() throws {
    XCTAssertEqual(Self.hex(Data(SHA256.hash(data: try vectorData()))), Self.vectorsSHA256)
    // The repository copy at `privacy/mask_vectors.json` is the same file.
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let repositoryCopy = root.appendingPathComponent("privacy/mask_vectors.json")
    XCTAssertEqual(
      Self.hex(Data(SHA256.hash(data: try Data(contentsOf: repositoryCopy)))), Self.vectorsSHA256)
  }

  func testEveryVectorMasksExactlyAsTheReference() throws {
    let file = try vectors()
    XCTAssertEqual(file.spec, PrivacyMasker.spec)
    XCTAssertEqual(file.order, PrivacyMaskRules.order)
    XCTAssertEqual(file.labels, PrivacyMaskRules.labels)
    XCTAssertEqual(Self.bytes(file.maskKeyHex), Data(repeating: 0x11, count: 32))
    XCTAssertGreaterThanOrEqual(file.vectors.count, 100)
    let masker = try testMasker
    var failures: [String] = []
    for vector in file.vectors {
      let masked = masker.mask(vector.input)
      if masked != vector.expected {
        failures.append("\(vector.input)\n  got      \(masked)\n  expected \(vector.expected)")
      }
    }
    XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
  }

  func testMaskingIsIdempotentOnEveryVector() throws {
    let masker = try testMasker
    for vector in try vectors().vectors {
      XCTAssertEqual(masker.mask(vector.expected), vector.expected, vector.input)
    }
  }

  func testKeyDerivationMatchesTheSharedVector() throws {
    let derive = try XCTUnwrap(try vectors().derive.first)
    let keys = try OrganizerKeyMaterial(libraryKey: Self.bytes(derive.libraryKeyHex))
    XCTAssertEqual(keys.keyID, derive.keyID)
    XCTAssertEqual(Self.hex(keys.storeKey), derive.storeKeyHex)
    XCTAssertEqual(Self.hex(keys.maskKey), derive.maskKeyHex)
    XCTAssertEqual(keys.libraryKeyHex, derive.libraryKeyHex)
    XCTAssertTrue(derive.sqlcipherPragma.contains(derive.storeKeyHex))
    // The key never shows up in a description or a log line.
    XCTAssertFalse(String(describing: keys).contains(derive.libraryKeyHex))
    XCTAssertFalse(String(reflecting: keys).contains(derive.libraryKeyHex))
    // Privacy review F1: the access proof every data request carries after the unlock (the Spark derives
    // the same value from the key it received; computed with spark/organizer/keys.py access_proof).
    XCTAssertEqual(
      keys.accessProof, "2440d76126ad041498355b0f25784929f4c59af47a352cae66e96e1c833958c9")
    XCTAssertFalse(String(describing: keys).contains(keys.accessProof))
    XCTAssertThrowsError(try OrganizerKeyMaterial(libraryKey: Data(count: 16)))
    XCTAssertNotEqual(
      try OrganizerKeyMaterial.random().libraryKey, try OrganizerKeyMaterial.random().libraryKey)
  }

  func testSpansRecordEveryOriginalAndPlaceholder() throws {
    let masker = try testMasker
    let input = "请打 138 1234 5678 或发 a.b@Example.com，验证码 482913。"
    let (masked, spans) = masker.maskWithSpans(input)
    XCTAssertEqual(spans.map(\.type), ["phone", "email", "otp"])
    XCTAssertEqual(spans.map(\.original), ["138 1234 5678", "a.b@Example.com", "482913"])
    for span in spans {
      XCTAssertTrue(masked.contains(span.placeholder))
      XCTAssertEqual(
        (input as NSString).substring(
          with: NSRange(location: span.start, length: span.end - span.start)),
        span.original)
    }
    // The same value spelled differently gets the same placeholder.
    XCTAssertEqual(masker.mask("13812345678"), masker.mask("+86 138 1234 5678"))
  }

  /// Spec v2 (review F8): a number written with dots, a line break,
  /// full-width or spoken Chinese digits is the same number (the tags below
  /// were computed with the Python reference, spark/organizer/masking.py).
  func testV2SpellingsOfOneNumberShareItsPlaceholder() throws {
    let masker = try testMasker
    for spelling in [
      "13812345678", "１３８１２３４５６７８", "一三八一二三四五六七八", "138.1234.5678", "138 1234\n5678",
      "138\u{00A0}1234\u{00A0}5678",
    ] {
      XCTAssertEqual(masker.mask(spelling), "〔手机号·f02e0a〕", spelling)
    }
    XCTAssertEqual(masker.mask("+1 (415) 555-0100"), "〔电话·7b02c4〕")
    XCTAssertEqual(masker.mask("li.mu＠example.com"), "〔邮箱·5a8bce〕")
    let (masked, spans) = masker.maskWithSpans("我的手机号是一三八一二三四五六七八，卡号 6222 0212\n3456 7894")
    XCTAssertEqual(spans.map(\.type), ["phone", "bank_card"])
    XCTAssertEqual(spans.map(\.original), ["一三八一二三四五六七八", "6222 0212\n3456 7894"])
    XCTAssertFalse(masked.contains("7894"))
  }

  /// Spec v3 (masking evaluation): a code handed over later in the same
  /// sentence, after a cue (是 / 为 / a colon / "is"), within 40 characters of
  /// its keyword. A sentence end in between stops it. Expected values were
  /// computed with the Python reference (`mask_ref.py`, v3).
  func testV3CodeHandedOverLaterInTheSentence() throws {
    let masker = try testMasker
    let (masked, spans) = masker.maskWithSpans("宠物店会员积分兑换要短信验证码，刚收到的是 2802")
    XCTAssertEqual(masked, "宠物店会员积分兑换要短信验证码，刚收到的是 〔验证码·e70421〕")
    XCTAssertEqual(spans.map(\.type), ["otp"])
    XCTAssertEqual(
      masker.mask("your verification code, as I said on the phone, is 739201"),
      "your verification code, as I said on the phone, is 〔验证码·e3a6ac〕")
    XCTAssertEqual(
      masker.mask("验证码已经发过去了，你先别急，我们住的房间号是 2802"),
      "验证码已经发过去了，你先别急，我们住的房间号是 〔验证码·e70421〕")
    // A sentence end between the keyword and the number: not a code.
    for guarded in ["验证码已经发过去了，你先别急。我们住的房间号是 2802", "OTP sent; the balance is 4521"] {
      XCTAssertEqual(masker.mask(guarded), guarded)
    }
  }

  func testUnmaskRestoresKnownAndHidesTheTagOfUnknownPlaceholders() throws {
    let masker = try testMasker
    let input = "联系 13812345678，邮箱 a@b.com"
    let (masked, spans) = masker.maskWithSpans(input)
    let map = Dictionary(uniqueKeysWithValues: spans.map { ($0.placeholder, $0.original) })
    XCTAssertEqual(PrivacyUnmask.unmask(masked) { map[$0] }, input)
    // A placeholder the Mac cannot resolve loses its tag, never shows a guess.
    XCTAssertEqual(PrivacyUnmask.unmask("电话 〔手机号·abcdef〕") { _ in nil }, "电话 〔手机号〕")
    XCTAssertEqual(PrivacyUnmask.unmask("无占位符的文字") { _ in "x" }, "无占位符的文字")
    XCTAssertEqual(PrivacyUnmask.placeholders(in: masked).count, 2)
  }

  func testOffsetsMapTheSentTextBackToTheOriginal() throws {
    let masker = try testMasker
    let original = "甲：请打13812345678。乙：好的，发到a@b.com。"
    let (masked, spans) = masker.maskWithSpans(original)
    let offsets = PrivacyMaskOffset.offsets(original: original, spans: spans)
    XCTAssertEqual(offsets.count, 2)
    // "乙" in the masked text maps to "乙" in the original.
    let maskedScalars = Array(masked.unicodeScalars)
    let originalScalars = Array(original.unicodeScalars)
    let maskedIndex = try XCTUnwrap(maskedScalars.firstIndex(of: "乙"))
    let mapped = PrivacyUnmask.originalOffset(maskedIndex, replacements: offsets, isEnd: false)
    XCTAssertEqual(originalScalars[mapped], "乙")
    // The end of the text maps to the end of the original.
    XCTAssertEqual(
      PrivacyUnmask.originalOffset(maskedScalars.count, replacements: offsets, isEnd: true),
      originalScalars.count)
    // An offset inside a placeholder snaps to the value's start or end.
    let inside = offsets[0].maskedStart + 3
    XCTAssertEqual(
      PrivacyUnmask.originalOffset(inside, replacements: offsets, isEnd: false),
      offsets[0].originalStart)
    XCTAssertEqual(
      PrivacyUnmask.originalOffset(inside, replacements: offsets, isEnd: true),
      offsets[0].originalEnd)
  }
}
