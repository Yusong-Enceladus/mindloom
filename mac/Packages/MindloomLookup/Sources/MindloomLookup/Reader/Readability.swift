import Foundation

// MARK: - What a reader never sees

/// Removes from a parsed page what a person reading it usually never sees,
/// before any text is taken (WEBSEARCH §4.4 step 2: hidden text is where
/// instructions for AI are planted): hidden and `aria-hidden` elements,
/// inline styles and style-sheet rules that hide (display, visibility,
/// opacity, zero or one-pixel type, zero size, off-screen, clipped,
/// transparent colour), "screen reader only" classes, scripts, embedded
/// objects, form controls, and navigation, footer, sidebar and banner
/// chrome.
///
/// Best effort, not a guarantee: text coloured like its background, rules
/// that depend on the screen size, scripts that hide text after loading and
/// other tricks still get through. The text is untrusted data, and the
/// organizer fences web excerpts as such when it shows them to a model.
enum PageCleaner {
  static let dropped: Set<String> = [
    "script", "style", "noscript", "template", "iframe", "frame", "frameset", "object", "embed", "applet",
    "svg", "canvas", "math", "audio", "video", "picture", "img", "select", "option", "button", "input",
    "textarea", "link", "meta", "base", "dialog", "map", "area", "head",
  ]
  static let chrome: Set<String> = ["nav", "footer", "aside", "menu"]
  static let chromeRoles: Set<String> = [
    "navigation", "banner", "contentinfo", "complementary", "search", "menu", "menubar", "dialog",
    "alertdialog", "tooltip", "toolbar",
  ]
  static let hiddenClasses: Set<String> = [
    "sr-only", "visually-hidden", "visuallyhidden", "screen-reader-text", "screen-reader-only", "hidden",
    "hide", "d-none", "is-hidden", "invisible", "offscreen", "a11y-hidden", "u-hidden", "element-invisible",
    "sr-text", "assistive-text",
  ]
  static let overlayWords = ["cookie", "consent", "gdpr"]

  /// One pass from the top: a dropped element's subtree is never visited,
  /// and each parent's children are rebuilt once (linear in the page,
  /// however many siblings are dropped). False when the budget ran out.
  @discardableResult
  static func clean(_ root: HTMLNode, budget: ReadBudget? = nil) -> Bool {
    var sheets: [String] = []
    for node in root.descendants() where node.name == "style" {
      sheets.append(node.children.map(\.text).joined())
    }
    let rules = CSSHiddenRules(styleSheets: sheets)
    var stack = [root]
    while let node = stack.popLast() {
      if budget?.spent() == true { return false }
      var kept: [HTMLNode] = []
      kept.reserveCapacity(node.children.count)
      var changed = false
      for child in node.children {
        if !child.isText, shouldDrop(child, rules) {
          child.parent = nil
          changed = true
        } else {
          kept.append(child)
        }
      }
      if changed { node.children = kept }
      for child in kept.reversed() where !child.isText { stack.append(child) }
    }
    return true
  }

  static func shouldDrop(_ node: HTMLNode, _ rules: CSSHiddenRules) -> Bool {
    if dropped.contains(node.name) || chrome.contains(node.name) { return true }
    let attributes = node.attributes
    if attributes["hidden"] != nil { return true }
    if attributes["aria-hidden"]?.lowercased() == "true" { return true }
    if let role = attributes["role"]?.lowercased(), chromeRoles.contains(role) { return true }
    let classes = node.classes
    if classes.contains(where: hiddenClasses.contains) { return true }
    let identity = (classes.joined(separator: " ") + " " + (attributes["id"] ?? "")).lowercased()
    if overlayWords.contains(where: { identity.contains($0) }) { return true }
    if let style = attributes["style"], StyleRules.hides(style) { return true }
    return rules.matches(node)
  }
}

/// Inline style or a rule's declarations that hide an element.
enum StyleRules {
  static func declarations(_ style: String) -> [String: String] {
    var result: [String: String] = [:]
    for part in style.lowercased().split(separator: ";") {
      guard let colon = part.firstIndex(of: ":") else { continue }
      let name = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      value = value.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
      result[name] = value
    }
    return result
  }

  static func number(_ value: String?) -> Double? {
    guard let value else { return nil }
    let digits = value.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" })
    return Double(digits)
  }

  /// The unit after a number ("px", "vw", "%", "" for none).
  static func unit(_ value: String) -> String {
    String(value.drop(while: { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }).prefix(while: { $0.isLetter || $0 == "%" }))
  }

  static func isZeroLength(_ value: String?) -> Bool {
    guard let value, let number = number(value) else { return false }
    return abs(number) < 0.01
  }

  static func isTiny(_ value: String?) -> Bool {
    guard let value, let number = number(value) else { return false }
    return abs(number) <= 1.0 && (value.hasSuffix("px") || abs(number) < 0.01)
  }

  /// Type too small to read: zero, one pixel or less, a tenth of an em or
  /// less.
  static func isTinyType(_ value: String?) -> Bool {
    guard let value, let number = number(value) else { return false }
    if abs(number) < 0.01 { return true }
    switch unit(value) {
    case "px", "pt": return number <= 1
    case "em", "rem": return number <= 0.1
    case "%": return number <= 10
    default: return false
    }
  }

  /// Far off the screen: -999 or less in any length unit, or a whole
  /// screen or more in vw, vh or %.
  static func isOffscreen(_ value: String) -> Bool {
    guard let number = number(value) else { return false }
    switch unit(value) {
    case "vw", "vh", "%", "vmin", "vmax": return number <= -100
    default: return number <= -999
    }
  }

  /// A colour with no opacity: transparent, rgba(…, 0), hsla(…, 0),
  /// rgb(… / 0), #rgba or #rrggbbaa with zero alpha.
  static func isInvisibleColour(_ value: String) -> Bool {
    let value = value.replacingOccurrences(of: " ", with: "")
    if value == "transparent" { return true }
    if value.hasPrefix("#"), value.count == 5 || value.count == 9 {
      return value.hasSuffix(value.count == 5 ? "0" : "00")
    }
    guard let open = value.firstIndex(of: "("), value.hasSuffix(")"),
      ["rgb", "rgba", "hsl", "hsla"].contains(String(value[..<open]))
    else { return false }
    let inside = value[value.index(after: open)..<value.index(before: value.endIndex)]
    let alpha: Substring
    if let slash = inside.lastIndex(of: "/") {
      alpha = inside[inside.index(after: slash)...]
    } else {
      let parts = inside.split(separator: ",")
      guard parts.count == 4 else { return false }
      alpha = parts[3]
    }
    guard let number = number(String(alpha)) else { return false }
    return abs(number) < 0.01
  }

  static func hides(_ style: String) -> Bool {
    let d = declarations(style)
    if d["display"] == "none" { return true }
    if let visibility = d["visibility"], visibility == "hidden" || visibility == "collapse" { return true }
    if let opacity = number(d["opacity"]), opacity <= 0.01 { return true }
    if isTinyType(d["font-size"]) { return true }
    if let indent = number(d["text-indent"]), indent <= -999 { return true }
    for margin in ["margin-left", "margin-top"] {
      if let value = d[margin], isOffscreen(value) { return true }
    }
    let positioned = d["position"] == "absolute" || d["position"] == "fixed"
    if positioned {
      for side in ["left", "top", "right", "bottom"] {
        if let value = d[side], isOffscreen(value) { return true }
      }
    }
    if let clip = d["clip"], clip.hasPrefix("rect(0") || clip.hasPrefix("rect(1px") { return true }
    if let clipPath = d["clip-path"], clipPath.hasPrefix("inset(50%") || clipPath.hasPrefix("inset(100%") {
      return true
    }
    let overflowHidden = d["overflow"] == "hidden"
    if (isTiny(d["width"]) && isTiny(d["height"])) || (overflowHidden && (isZeroLength(d["height"]) || isZeroLength(d["max-height"]))) {
      return true
    }
    if let transform = d["transform"] {
      if transform.contains("scale(0)") || transform.contains("scale(0,") || transform.contains("scalex(0)")
        || transform.contains("scaley(0)")
      {
        return true
      }
      if transform.contains("translate") {
        for argument in transform.split(whereSeparator: { "(),".contains($0) || $0.isWhitespace })
        where argument.first.map({ $0 == "-" }) == true && isOffscreen(String(argument)) {
          return true
        }
      }
    }
    if let color = d["color"], isInvisibleColour(color) { return true }
    return false
  }
}

/// Style-sheet rules that hide: `.class`, `#id`, `tag`, `[attr]`, their
/// compounds and descendant chains (`main .ai`, `.box > p`; a child
/// combinator is read as a descendant one), at the top level and inside
/// `@media all` or `@media screen` without conditions. Rules with sibling
/// combinators, pseudo-classes, or inside other `@` blocks (a media query
/// with a width, `@supports`) are not evaluated. Selectors are indexed by
/// the last compound's id, class, tag or attribute, so a page with many
/// rules and many elements stays linear.
struct CSSHiddenRules {
  struct Compound {
    var tag: String?
    var classes: [String] = []
    var id: String?
    var attributes: [String] = []

    var isBareContentTag: Bool {
      classes.isEmpty && id == nil && attributes.isEmpty
        && ["p", "div", "span", "body", "main", "article", "section", "html"].contains(tag ?? "")
    }

    func matches(_ node: HTMLNode, classes nodeClasses: Set<String>) -> Bool {
      if let tag, tag != node.name { return false }
      if let id, id != node.attributes["id"]?.lowercased() { return false }
      if !classes.allSatisfy(nodeClasses.contains) { return false }
      return attributes.allSatisfy { node.attributes[$0] != nil }
    }
  }

  /// Compounds from the outermost ancestor to the element itself.
  struct Selector {
    var compounds: [Compound]
  }

  private(set) var count = 0
  private var byID: [String: [Selector]] = [:]
  private var byClass: [String: [Selector]] = [:]
  private var byTag: [String: [Selector]] = [:]
  private var byAttribute: [String: [Selector]] = [:]

  init(styleSheets: [String]) {
    for sheet in styleSheets {
      collect(Self.withoutComments(sheet), depth: 0)
    }
  }

  /// `/* … */` removed in one pass (an unclosed comment runs to the end).
  static func withoutComments(_ text: String) -> String {
    let bytes = Array(text.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
        index += 2
        while index < bytes.count, !(bytes[index] == UInt8(ascii: "*") && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/")) {
          index += 1
        }
        index += 2
        output.append(UInt8(ascii: " "))
        continue
      }
      output.append(bytes[index])
      index += 1
    }
    return String(decoding: output, as: UTF8.self)
  }

  /// The top-level blocks of a sheet: (prelude, body) pairs.
  static func blocks(_ text: String) -> [(String, String)] {
    var result: [(String, String)] = []
    var depth = 0
    var prelude = ""
    var body = ""
    for character in text {
      switch character {
      case "{":
        if depth > 0 { body.append(character) }
        depth += 1
      case "}":
        guard depth > 0 else {
          prelude = ""
          continue
        }
        depth -= 1
        if depth == 0 {
          result.append((prelude.trimmingCharacters(in: .whitespacesAndNewlines), body))
          prelude = ""
          body = ""
        } else {
          body.append(character)
        }
      default:
        if depth == 0 { prelude.append(character) } else { body.append(character) }
      }
    }
    return result
  }

  /// `@media all`, `@media screen`, `@media only screen`: no condition, so
  /// the rules inside apply on every screen.
  static func appliesEverywhere(_ prelude: String) -> Bool {
    let lower = prelude.lowercased()
    guard lower.hasPrefix("@media"), !lower.contains("(") else { return false }
    let words = lower.dropFirst("@media".count).split(whereSeparator: { $0.isWhitespace || $0 == "," })
    return !words.isEmpty && words.allSatisfy { ["all", "screen", "only", "and"].contains($0) }
  }

  private mutating func collect(_ text: String, depth: Int) {
    for (prelude, body) in Self.blocks(text) {
      if prelude.hasPrefix("@") {
        if depth == 0, Self.appliesEverywhere(prelude) { collect(body, depth: 1) }
        continue
      }
      guard StyleRules.hides(body) else { continue }
      for part in prelude.split(separator: ",") {
        if let selector = Self.parse(part.trimmingCharacters(in: .whitespacesAndNewlines)) { add(selector) }
      }
    }
  }

  private mutating func add(_ selector: Selector) {
    guard let last = selector.compounds.last else { return }
    // A bare tag rule such as `p { display: none }` would hide the whole
    // page; it is taken only under an ancestor (`.collapsed p`).
    if selector.compounds.count == 1, last.isBareContentTag { return }
    guard count < Self.maximumRules else { return }
    count += 1
    if let id = last.id {
      byID[id, default: []].append(selector)
    } else if let first = last.classes.first {
      byClass[first, default: []].append(selector)
    } else if let tag = last.tag {
      byTag[tag, default: []].append(selector)
    } else if let attribute = last.attributes.first {
      byAttribute[attribute, default: []].append(selector)
    }
  }

  static func parse(_ text: String) -> Selector? {
    guard !text.isEmpty, !text.contains(where: { ":+~".contains($0) }) else { return nil }
    var compounds: [Compound] = []
    for part in text.split(whereSeparator: { $0.isWhitespace || $0 == ">" }) {
      guard let compound = parseCompound(String(part)) else { return nil }
      compounds.append(compound)
    }
    guard !compounds.isEmpty, compounds.count <= 8 else { return nil }
    return Selector(compounds: compounds)
  }

  static func parseCompound(_ text: String) -> Compound? {
    guard !text.isEmpty else { return nil }
    var compound = Compound()
    var index = text.startIndex
    func readName() -> String {
      let start = index
      while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "-" || text[index] == "_" {
        index = text.index(after: index)
      }
      return String(text[start..<index]).lowercased()
    }
    if text[index] == "*" {
      index = text.index(after: index)
    } else if text[index].isLetter {
      compound.tag = readName()
    }
    while index < text.endIndex {
      let marker = text[index]
      index = text.index(after: index)
      switch marker {
      case ".":
        let name = readName()
        guard !name.isEmpty else { return nil }
        compound.classes.append(name)
      case "#":
        let name = readName()
        guard !name.isEmpty else { return nil }
        compound.id = name
      case "[":
        guard let close = text[index...].firstIndex(of: "]") else { return nil }
        let inside = text[index..<close]
        guard !inside.contains("=") else { return nil }
        compound.attributes.append(inside.lowercased())
        index = text.index(after: close)
      default:
        return nil
      }
    }
    if compound.tag == nil, compound.classes.isEmpty, compound.id == nil, compound.attributes.isEmpty {
      return nil
    }
    return compound
  }

  /// At most this many rules are kept, this many are tried per element,
  /// and this many ancestors are walked for one rule: a page built to make
  /// the check slow stays bounded (the read's time budget covers the rest).
  static let maximumRules = 5_000
  static let maximumCandidates = 32
  static let maximumAncestors = 32

  func matches(_ node: HTMLNode) -> Bool {
    guard count > 0 else { return false }
    let classes = node.classSet
    var tried = 0
    func check(_ selectors: [Selector]?) -> Bool {
      guard let selectors else { return false }
      for selector in selectors {
        guard tried < Self.maximumCandidates else { return false }
        tried += 1
        if Self.matches(selector, node, classes: classes) { return true }
      }
      return false
    }
    if let id = node.attributes["id"]?.lowercased(), check(byID[id]) { return true }
    for name in classes where check(byClass[name]) { return true }
    if check(byTag[node.name]) { return true }
    for name in node.attributes.keys where check(byAttribute[name]) { return true }
    return false
  }

  /// The last compound on the element, each earlier one on some ancestor,
  /// in order.
  static func matches(_ selector: Selector, _ node: HTMLNode, classes: Set<String>) -> Bool {
    guard let last = selector.compounds.last, last.matches(node, classes: classes) else { return false }
    var ancestor = node.parent
    var walked = 0
    for compound in selector.compounds.dropLast().reversed() {
      while let current = ancestor, !compound.matches(current, classes: current.classSet) {
        walked += 1
        if walked > maximumAncestors { return false }
        ancestor = current.parent
      }
      guard let found = ancestor else { return false }
      ancestor = found.parent
    }
    return true
  }
}

// MARK: - Text

/// The visible text of a cleaned tree: block elements on their own lines,
/// table cells separated by tabs, whitespace collapsed outside `pre`.
enum PageText {
  static let blocks: Set<String> = [
    "p", "div", "section", "article", "main", "header", "footer", "aside", "nav", "h1", "h2", "h3", "h4",
    "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "blockquote",
    "pre", "figure", "figcaption", "form", "fieldset", "address", "details", "summary", "hr", "caption",
    "center", "body", "html",
  ]

  static func text(of node: HTMLNode) -> String {
    var lines: [String] = []
    var line = ""
    func endLine() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { lines.append(trimmed) }
      line = ""
    }
    func walk(_ node: HTMLNode, preformatted: Bool) {
      if node.isText {
        if preformatted {
          let parts = node.text.components(separatedBy: "\n")
          for (index, part) in parts.enumerated() {
            if index > 0 { endLine() }
            line += part
          }
        } else {
          let collapsed = node.text.split(whereSeparator: { $0.isWhitespace && $0 != "\u{00A0}" || $0 == "\n" })
            .joined(separator: " ")
          if collapsed.isEmpty {
            if !line.isEmpty, line.last != " " { line += " " }
            return
          }
          if let first = node.text.first, first.isWhitespace, !line.isEmpty, line.last != " ", line.last != "\t" {
            line += " "
          }
          line += collapsed
          if let last = node.text.last, last.isWhitespace { line += " " }
        }
        return
      }
      switch node.name {
      case "br":
        endLine()
        return
      case "td", "th":
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
          line = line.trimmingCharacters(in: .whitespaces) + "\t"
        }
      default:
        break
      }
      let block = blocks.contains(node.name)
      if block { endLine() }
      let pre = preformatted || node.name == "pre"
      for child in node.children { walk(child, preformatted: pre) }
      if block { endLine() }
    }
    walk(node, preformatted: false)
    endLine()
    return lines.joined(separator: "\n")
  }

  static func characterCount(_ node: HTMLNode) -> Int {
    if node.isText { return node.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    return node.children.reduce(0) { $0 + characterCount($1) }
  }

  static func linkCharacterCount(_ node: HTMLNode) -> Int {
    if node.isText { return 0 }
    if node.name == "a" { return characterCount(node) }
    return node.children.reduce(0) { $0 + linkCharacterCount($1) }
  }

  static func linkDensity(_ node: HTMLNode) -> Double {
    let total = characterCount(node)
    guard total > 0 else { return 0 }
    return Double(linkCharacterCount(node)) / Double(total)
  }
}

// MARK: - Main content

/// For every element, counted in one pass from the leaves up: visible
/// characters, characters inside links (link density without walking a
/// subtree again), the length Readability scores (Han characters count
/// twice) and the commas.
final class TextCounts {
  struct Totals {
    var characters = 0
    var links = 0
    var weighted = 0
    var commas = 0
  }

  private var totals: [ObjectIdentifier: Totals] = [:]

  init(_ root: HTMLNode) {
    _ = count(root, inLink: false)
  }

  private func count(_ node: HTMLNode, inLink: Bool) -> Totals {
    if node.isText {
      var result = Totals()
      var pendingSpace = false
      for scalar in node.text.unicodeScalars {
        if scalar.properties.isWhitespace {
          pendingSpace = result.weighted > 0
          continue
        }
        if pendingSpace {
          result.weighted += 1
          pendingSpace = false
        }
        result.characters += 1
        result.weighted += (0x3000...0x9FFF).contains(scalar.value) ? 2 : 1
        if ",，、。;；".unicodeScalars.contains(scalar) { result.commas += 1 }
      }
      if inLink { result.links = result.characters }
      return result
    }
    var sum = Totals()
    let link = inLink || node.name == "a"
    for child in node.children {
      let part = count(child, inLink: link)
      sum.characters += part.characters
      sum.links += part.links
      sum.weighted += part.weighted
      sum.commas += part.commas
    }
    totals[ObjectIdentifier(node)] = sum
    return sum
  }

  func characters(_ node: HTMLNode) -> Int { totals[ObjectIdentifier(node)]?.characters ?? 0 }
  func weightedLength(_ node: HTMLNode) -> Int { totals[ObjectIdentifier(node)]?.weighted ?? 0 }
  func commas(_ node: HTMLNode) -> Int { totals[ObjectIdentifier(node)]?.commas ?? 0 }

  func linkDensity(_ node: HTMLNode) -> Double {
    guard let total = totals[ObjectIdentifier(node)], total.characters > 0 else { return 0 }
    return Double(total.links) / Double(total.characters)
  }
}

/// The main content of a page, scored the way Mozilla's Readability scores
/// it (paragraph length and commas credited to the parent and grandparent,
/// class and id hints, element kinds, link density), so menus and lists of
/// links fall away.
enum Readability {
  static let positive = try! NSRegularExpression(
    pattern: "article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story|abstract|dates|cfp",
    options: [.caseInsensitive])
  static let negative = try! NSRegularExpression(
    pattern:
      "-ad-|hidden|^hid$|banner|combx|comment|com-|contact|foot|footer|footnote|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget|nav|menu|breadcrumb|cookie",
    options: [.caseInsensitive])

  static let candidates: Set<String> = ["p", "pre", "td", "li", "blockquote", "dd"]
  static let containers: Set<String> = [
    "div", "section", "article", "main", "td", "blockquote", "pre", "body", "ul", "ol", "dl", "table",
    "tbody", "tr", "form", "header", "center",
  ]

  static func classWeight(_ node: HTMLNode) -> Double {
    var weight = 0.0
    for value in [node.attributes["class"], node.attributes["id"]].compactMap({ $0 }) where !value.isEmpty {
      let range = NSRange(value.startIndex..., in: value)
      if negative.firstMatch(in: value, range: range) != nil { weight -= 25 }
      if positive.firstMatch(in: value, range: range) != nil { weight += 25 }
    }
    return weight
  }

  static func baseScore(_ node: HTMLNode) -> Double {
    switch node.name {
    case "div", "article", "main", "section": 5
    case "pre", "td", "blockquote": 3
    case "address", "ol", "ul", "dl", "dd", "dt", "li", "form": -3
    case "h1", "h2", "h3", "h4", "h5", "h6", "th": -5
    default: 0
    }
  }

  /// The best container and the siblings that belong with it, in page
  /// order; nil when nothing scores (or the budget ran out). Each candidate's
  /// length and commas come from one bottom-up count, so nested candidates
  /// do not walk their subtrees again.
  static func mainContent(_ root: HTMLNode, budget: ReadBudget? = nil) -> [HTMLNode]? {
    let counts = TextCounts(root)
    var scores: [ObjectIdentifier: Double] = [:]
    var nodes: [ObjectIdentifier: HTMLNode] = [:]
    for paragraph in root.descendants() where candidates.contains(paragraph.name) {
      if budget?.spent() == true { return nil }
      let length = counts.weightedLength(paragraph)
      guard length >= 25 else { continue }
      let commas = counts.commas(paragraph)
      let score = 1.0 + Double(commas) + min(Double(length) / 100.0, 3.0)
      var ancestor = paragraph.parent
      var level = 0
      while let node = ancestor, level < 3, node.name != "#document" {
        let id = ObjectIdentifier(node)
        if scores[id] == nil {
          scores[id] = baseScore(node) + classWeight(node)
          nodes[id] = node
        }
        let divider = level == 0 ? 1.0 : (level == 1 ? 2.0 : Double(level) * 3.0)
        scores[id, default: 0] += score / divider
        ancestor = node.parent
        level += 1
      }
    }
    var best: (HTMLNode, Double)?
    for (id, score) in scores {
      guard let node = nodes[id] else { continue }
      let final = score * (1 - counts.linkDensity(node))
      scores[id] = final
      if best == nil || final > best!.1 { best = (node, final) }
    }
    guard let winner = best, winner.1 > 0 else { return nil }
    let (top, topScore) = winner
    guard let parent = top.parent else { return [top] }
    let threshold = max(10, topScore * 0.2)
    var kept: [HTMLNode] = []
    for sibling in parent.children where !sibling.isText {
      if sibling === top {
        kept.append(sibling)
        continue
      }
      let score = scores[ObjectIdentifier(sibling)] ?? -1
      if score >= threshold {
        kept.append(sibling)
      } else if sibling.name == "p" {
        let length = counts.characters(sibling)
        let density = counts.linkDensity(sibling)
        if (length > 80 && density < 0.25) || (length > 0 && length <= 80 && density == 0 && PageText.text(of: sibling).contains(where: { ".。".contains($0) })) {
          kept.append(sibling)
        }
      }
    }
    return kept
  }
}
