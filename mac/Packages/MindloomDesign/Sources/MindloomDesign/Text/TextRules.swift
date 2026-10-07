import Foundation

/// Chinese/Latin spacing for organizer text (kit.js `ML.autospace`, SYSTEM.md §4).
///
/// A quarter em (U+2005) between Chinese and a Latin word.  A token that starts with a Latin letter is a Latin word even
/// when it ends in digits or has a hyphen (R2 已完成, TG-2 换 PG-80 夹爪); a number inside a Latin phrase is spaced too
/// (CoRA 2026 新加坡).  Pure numbers and dates are not spaced (9月21日, 120条).  Words people write tight stay tight
/// (T恤, X光, B超, U盘).  Never apply it to quotes (原话): they are evidence and stay as captured.  Idempotent.
public enum MLAutospace {
  static let cjk =
    "\u{2E80}-\u{2FFF}\u{3040}-\u{30FF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{F900}-\u{FAFF}"
  static let reA = try! NSRegularExpression(pattern: "([\(cjk)])([A-Za-z])")
  static let reB = try! NSRegularExpression(
    pattern: "([A-Za-z](?:[A-Za-z0-9]|[-.](?=[A-Za-z0-9]))*)([\(cjk)])")
  static let reC = try! NSRegularExpression(pattern: "([A-Za-z][A-Za-z0-9-]* \\d+)([\(cjk)])")
  /// Words written without a space: never spaced.
  public static let keepTight = [
    "T恤", "X光", "B超", "U盘", "K歌", "Q版", "A股", "N次", "e人", "i人", "AA制", "X射线", "PH值", "pH值", "Wi-Fi",
  ]

  public static func apply(_ s: String) -> String {
    var out = s
    for re in [reA, reB, reC] {
      out = re.stringByReplacingMatches(
        in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1\u{2005}$2")
    }
    for w in keepTight {
      // the spaced form of a tight word: a space after its Latin lead
      guard let lead = w.firstIndex(where: { !($0.isASCII && ($0.isLetter || $0 == "-")) }),
        lead != w.startIndex
      else { continue }
      let spaced = String(w[..<lead]) + "\u{2005}" + String(w[lead...])
      out = out.replacingOccurrences(of: spaced, with: w)
    }
    return out
  }
}

/// The vocabulary check (kit.js `ML.vocab`, VOCABULARY.md): plain words only.  The weaving metaphor lives only in the
/// brand (icon, title, the listening motion); it never becomes a noun the user must learn.
public enum MLVocabulary {
  public struct Hit: Hashable, Sendable {
    public var word: String
    /// UTF-16 offset of the hit.
    public var offset: Int
    public var isBanned: Bool
    /// What to say instead ("—" = say nothing).
    public var use: String
  }

  /// Banned in any UI string, with what to use instead.
  public static let banned: [(String, String)] = [
    ("绳", "分组"), ("股", "—"), ("线索", "进展"), ("主线", "—"), ("支线", "—"), ("子线", "—"), ("织线", "—"),
    ("交叉", "—"),
    ("牵制", "—"), ("整理设备", "DGX Spark"), ("素材", "原话 / 来源"), ("下架", "撤回"), ("事件", "事"), ("收件箱", "—"),
    ("钥匙", "—"), ("锁好", "—"), ("中转", "—"), ("转交", "—"), ("已收进", "已添加"), ("已记下", "已添加"),
    ("已送到", "已发送"), ("lease", "—"), ("relay", "—"), ("inbox", "—"), ("thread", "—"),
    ("knot", "—"),
    ("strand", "—"), ("rope", "—"), ("在等", "—"), ("不对", "—"), ("建议", "—"),
  ]
  /// Avoided, with the preferred word.
  public static let avoid: [(String, String)] = [
    ("离线", "未连接"), ("时间线", "按时间"), ("整理中", "—"), ("正在整理", "—"), ("结构", "—"), ("了结", "完成"),
  ]

  /// Every banned or avoided word in `text`.  织机 is the one allowed brand word (Welcome, About).
  public static func check(_ text: String) -> [Hit] {
    let s = text as NSString
    var out: [Hit] = []
    func scan(_ list: [(String, String)], banned: Bool) {
      for (w, alt) in list {
        let opts: NSString.CompareOptions =
          w.first.map { $0.isASCII && $0.isLowercase } == true ? [.caseInsensitive] : []
        var r = NSRange(location: 0, length: s.length)
        while true {
          let f = s.range(of: w, options: opts, range: r)
          if f.location == NSNotFound { break }
          out.append(Hit(word: w, offset: f.location, isBanned: banned, use: alt))
          r = NSRange(location: f.location + 1, length: s.length - f.location - 1)
        }
      }
    }
    scan(banned, banned: true)
    scan(avoid, banned: false)
    // 结, 线, 网 and 织 as nouns: allow the common words that merely contain them
    func single(_ ch: String, ok: [String], before: Int, after: Int) {
      var r = NSRange(location: 0, length: s.length)
      while true {
        let f = s.range(of: ch, options: [], range: r)
        if f.location == NSNotFound { break }
        let lo = max(0, f.location - before)
        let ctx = s.substring(
          with: NSRange(location: lo, length: min(s.length, f.location + after) - lo))
        if !ok.contains(where: { ctx.contains($0) }) {
          out.append(Hit(word: ch, offset: f.location, isBanned: true, use: "—"))
        }
        r = NSRange(location: f.location + 1, length: s.length - f.location - 1)
      }
    }
    single(
      "结", ok: ["结束", "结果", "结论", "总结", "结尾", "结算", "结账", "结婚", "团结", "连结", "完结"], before: 1,
      after: 2)
    single(
      "线", ok: ["在线", "线上", "线下", "直线", "视线", "路线", "热线", "曲线", "下划线", "天线", "无线", "连线"], before: 2,
      after: 2)
    single(
      "网", ok: ["网站", "网络", "网页", "网址", "网盘", "上网", "网上", "网购", "网速", "网友"], before: 1, after: 2)
    var r = NSRange(location: 0, length: s.length)
    while true {
      let f = s.range(of: "织", options: [], range: r)
      if f.location == NSNotFound { break }
      let next =
        f.location + 1 < s.length
        ? s.substring(with: NSRange(location: f.location + 1, length: 1)) : ""
      if next != "机" { out.append(Hit(word: "织", offset: f.location, isBanned: true, use: "—")) }
      r = NSRange(location: f.location + 1, length: s.length - f.location - 1)
    }
    // drop hits covered by a longer one (线索 also matches 线)
    return out.filter { h in
      !out.contains { o in
        o != h && o.word.utf16.count > h.word.utf16.count && o.offset <= h.offset
          && o.offset + o.word.utf16.count > h.offset
      }
    }
  }
}
