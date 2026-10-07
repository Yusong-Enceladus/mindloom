import Foundation
import MindloomDesign
import XCTest

/// The v10 vocabulary (VOCABULARY.md §6, MAC-SPEC §14.8) on every
/// user-visible string literal of both platforms (see `folders`): no 绳 股 线索 主线 交叉 牵制 整理设备 素材 下架 事件 收件箱
/// 钥匙 锁好 中转 转交 已收进 已记下 已送到 在等 不对 建议, no rope / thread /
/// knot / strand / lease / relay / inbox, no 结 / 线 / 网 / 织 as nouns (织 only
/// in 织机), and avoid 离线 / 时间线 / 整理中 / 正在整理 / 结构 / 了结. 「DGX
/// Spark」 is allowed.
///
/// A literal counts as user-visible when it holds a Chinese character
/// (identifiers, keys and symbol names never do); comments are skipped.
/// Hits the v11 rebuild has not reached yet are listed in
/// `VocabularyBaseline.known` and tolerated; any new hit fails. Fix a hit,
/// then delete its line from the baseline (the test lists lines that no
/// longer occur). Regenerate the list with
/// `BESTASR_VOCAB_BASELINE=<file> v11-test.sh --filter VocabularyGuardTests`.
final class VocabularyGuardTests: XCTestCase {
  struct Hit: Hashable, Comparable {
    let file: String
    let word: String
    let literal: String

    var line: String { "\(file)\t\(word)\t\(literal)" }
    static func < (a: Hit, b: Hit) -> Bool { a.line < b.line }
  }

  static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  /// The folders scanned (relative to the repository root): every source
  /// folder of both platforms (the Mac App, its extensions, the packages and
  /// the iPhone app with its keyboard, share extension and Live Activity).
  static let folders = [
    "App", "ShareExtension", "Packages/BestASRCore/Sources", "Packages/MindloomLink/Sources",
    "Packages/MindloomDesign/Sources", "Packages/MindloomPhoneKit/Sources", "iOS",
    "Packages/MindloomLookup/Sources", "Packages/MindloomWatchHandoff/Sources",
  ]

  /// Files whose CJK literals are never shown to anyone: the checker's own
  /// word lists, an English regex, the labels sent to the DGX Spark's
  /// organizer, test fakes, and the 织 glyph of the 织机 wordmark.
  static let notUserVisible = [
    "Packages/MindloomDesign/Sources/MindloomDesign/Text/TextRules.swift",
    "Packages/MindloomDesign/Sources/MindloomDesign/Brand/TitleCinch.swift",
    "Packages/BestASRCore/Sources/BestASRProcessing/ProtectedFactValidator.swift",
    "Packages/MindloomLink/Sources/MindloomSpacesTestSupport/",
  ]

  static func scan() throws -> [Hit] {
    let root = repositoryRoot
    var hits: [Hit] = []
    for folder in folders {
      let base = root.appendingPathComponent(folder)
      guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in walker where url.pathExtension == "swift" {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        if notUserVisible.contains(where: { relative.hasPrefix($0) }) || relative.contains("/Tests/") {
          continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
          let line = String(raw)
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
            continue
          }
          for text in literals(in: line) {
            guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
            else { continue }
            for found in MLVocabulary.check(text) {
              hits.append(Hit(file: relative, word: found.word, literal: text))
            }
          }
        }
      }
    }
    return Array(Set(hits)).sorted()
  }

  /// Every string literal on a line, the ones nested in an interpolation
  /// included (fix-mac: 「…\\(n ? "" : "…素材…")」 hid its inner literal from a
  /// plain `"…"` regex). Escapes are kept as written; a `//` outside a
  /// literal ends the line.
  static func literals(in line: String) -> [String] {
    let chars = Array(line)
    var out: [String] = []
    func string(from start: Int) -> Int {
      var j = start + 1
      var text = "\""
      while j < chars.count {
        let c = chars[j]
        if c == "\\", j + 1 < chars.count {
          if chars[j + 1] == "(" {
            text += "\\("
            j += 2
            var depth = 1
            while j < chars.count, depth > 0 {
              if chars[j] == "\"" {
                j = string(from: j)
                continue
              }
              if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
              if depth > 0 { text.append(chars[j]) }
              j += 1
            }
            text += ")"
            continue
          }
          text.append(c)
          text.append(chars[j + 1])
          j += 2
          continue
        }
        text.append(c)
        j += 1
        if c == "\"" {
          out.append(text)
          return j
        }
      }
      out.append(text)
      return j
    }
    var i = 0
    while i < chars.count {
      if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }
      if chars[i] == "\"" { i = string(from: i) } else { i += 1 }
    }
    return out
  }

  /// A literal nested inside an interpolation is scanned too.
  func testNestedInterpolationLiteralsAreScanned() {
    let line = #"        "固定的摘要\(ref.cites.isEmpty ? "" : "，引用 \(ref.cites.count) 条素材；它们被撤回时这条也会下架")""#
    let found = Self.literals(in: line).flatMap { MLVocabulary.check($0) }.map(\.word)
    XCTAssertTrue(found.contains("素材"), "\(Self.literals(in: line))")
    XCTAssertTrue(found.contains("下架"))
    XCTAssertEqual(Self.literals(in: #"let a = "x" // "素材""#), ["\"x\""])
    XCTAssertEqual(Self.literals(in: #"f("a\"b", "c")"#), [#""a\"b""#, "\"c\""])
  }

  /// v11 integration: no known hits are left on either platform.
  func testNoHitsAreTolerated() {
    XCTAssertEqual(VocabularyBaseline.known, [])
  }

  func testNoNewBannedOrAvoidedWords() throws {
    let hits = try Self.scan()
    if let path = ProcessInfo.processInfo.environment["BESTASR_VOCAB_BASELINE"], !path.isEmpty {
      try hits.map(\.line).joined(separator: "\n").write(
        toFile: path, atomically: true, encoding: .utf8)
    }
    let known = Set(VocabularyBaseline.known)
    let new = hits.filter { !known.contains($0.line) }
    XCTAssertEqual(
      new.map(\.line), [],
      "New vocabulary hits (VOCABULARY.md §6):\n" + new.map(\.line).joined(separator: "\n"))
    let gone = known.subtracting(hits.map(\.line))
    if !gone.isEmpty {
      // Not a failure: delete these lines from VocabularyBaseline.known.
      print("Fixed vocabulary hits still listed in the baseline:\n" + gone.sorted().joined(separator: "\n"))
    }
  }

  /// The checker itself: banned words, the allowed compounds, 「DGX Spark」.
  func testTheCheckerKnowsTheRules() {
    XCTAssertFalse(MLVocabulary.check("DGX Spark 没连上").contains { $0.isBanned })
    XCTAssertFalse(MLVocabulary.check("结束并保存").contains { $0.isBanned })
    XCTAssertFalse(MLVocabulary.check("关于 Mindloom · 织机").contains { $0.isBanned })
    XCTAssertTrue(MLVocabulary.check("按绳").contains { $0.word == "绳" })
    XCTAssertTrue(MLVocabulary.check("交叉 3 次").contains { $0.word == "交叉" })
    XCTAssertTrue(MLVocabulary.check("事件").contains { $0.word == "事件" })
    XCTAssertTrue(MLVocabulary.check("在等").contains { $0.word == "在等" })
  }

  /// The shell's own words are clean (no baseline entry for the new files).
  func testTheShellIsClean() throws {
    let hits = try Self.scan().filter {
      $0.file.contains("BestASRMemoryUI/Shell/") || $0.file.hasSuffix("MemoryScreenState.swift")
        || $0.file.hasSuffix("MindloomNavigation.swift")
    }
    XCTAssertEqual(hits.map(\.line), [])
  }
}
