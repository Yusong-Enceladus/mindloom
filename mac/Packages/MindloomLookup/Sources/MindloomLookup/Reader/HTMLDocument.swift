import Foundation

/// A forgiving HTML parser for reading pages on the device: a tokenizer and
/// a tree builder with the implied-end-tag rules real pages rely on. No
/// script runs, no resource loads, no entity is fetched; scripts are dropped
/// while tokenizing.
final class HTMLNode {
  /// Lower-case tag name, or "#text".
  let name: String
  var attributes: [String: String]
  var text: String
  var children: [HTMLNode] = []
  weak var parent: HTMLNode?

  init(name: String, attributes: [String: String] = [:], text: String = "") {
    self.name = name
    self.attributes = attributes
    self.text = text
  }

  var isText: Bool { name == "#text" }

  func append(_ child: HTMLNode) {
    child.parent = self
    children.append(child)
  }

  func remove() {
    guard let parent else { return }
    parent.children.removeAll { $0 === self }
    self.parent = nil
  }

  /// Every element below this one, depth first.
  func descendants() -> [HTMLNode] {
    var result: [HTMLNode] = []
    var stack = Array(children.reversed())
    while let node = stack.popLast() {
      if !node.isText { result.append(node) }
      stack.append(contentsOf: node.children.reversed())
    }
    return result
  }

  func first(_ tag: String) -> HTMLNode? {
    descendants().first { $0.name == tag }
  }

  var classes: [String] {
    (attributes["class"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  /// `classes` as a set, computed once (style rules test it often).
  lazy var classSet: Set<String> = Set(classes)
}

/// How long reading one page may take, so a hostile or huge page cannot
/// hold the lookup: checked every 256 steps (the clock and cancellation);
/// once spent, the read gives up and the page counts as unreadable.
final class ReadBudget {
  private let deadline: UInt64?
  private var steps = 0
  private(set) var exceeded = false

  /// `seconds` nil: no time limit, only cancellation.
  init(seconds: TimeInterval?) {
    deadline = seconds.map { DispatchTime.now().uptimeNanoseconds + UInt64(max(0, $0) * 1_000_000_000) }
  }

  func spent() -> Bool {
    if exceeded { return true }
    steps &+= 1
    guard steps & 255 == 0 else { return false }
    if Task.isCancelled || deadline.map({ DispatchTime.now().uptimeNanoseconds > $0 }) == true {
      exceeded = true
    }
    return exceeded
  }
}

enum HTMLParser {
  static let voidElements: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
    "track", "wbr",
  ]
  /// Elements whose content is raw text: scripts are dropped; the others
  /// keep their text.
  static let rawTextElements: Set<String> = ["script", "style", "title", "textarea", "xmp", "noscript"]
  /// Elements nest at most this deep; deeper ones are flattened into the
  /// last open element (every later walk over the tree is recursive).
  static let maximumDepth = 256
  /// A page with more elements and text runs than this is read up to there.
  static let maximumNodes = 200_000

  static let headElements: Set<String> = [
    "head", "title", "meta", "link", "style", "script", "base", "noscript", "template",
  ]

  static let closesParagraph: Set<String> = [
    "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption",
    "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav",
    "ol", "p", "pre", "section", "table", "ul",
  ]

  /// The document root (a synthetic "#document" element). Stops at
  /// `maximumNodes`, or when `budget` is spent.
  static func parse(_ html: String, budget: ReadBudget? = nil) -> HTMLNode {
    let root = HTMLNode(name: "#document")
    var stack: [HTMLNode] = [root]
    let bytes = Array(html.utf8)
    let count = bytes.count
    var i = 0
    var textStart = 0
    var nodes = 0

    func current() -> HTMLNode { stack[stack.count - 1] }

    func flushText(upTo end: Int) {
      guard end > textStart else { return }
      let raw = String(decoding: bytes[textStart..<end], as: UTF8.self)
      let decoded = HTMLEntities.decode(raw)
      if !decoded.isEmpty {
        nodes += 1
        current().append(HTMLNode(name: "#text", text: decoded))
      }
    }

    func popTo(_ name: String, stopAt boundaries: Set<String>) {
      for index in stride(from: stack.count - 1, to: 0, by: -1) {
        let node = stack[index]
        if node.name == name {
          stack.removeSubrange(index...)
          return
        }
        if boundaries.contains(node.name) { return }
      }
    }

    func open(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
      // Anything that belongs in the body ends an open head (a missing
      // </head> must not put the page inside it).
      if !headElements.contains(name), stack.contains(where: { $0.name == "head" }) {
        popTo("head", stopAt: [])
      }
      if closesParagraph.contains(name) { popTo("p", stopAt: ["button", "table", "td", "th", "li"]) }
      switch name {
      case "li": popTo("li", stopAt: ["ul", "ol", "menu"])
      case "dt", "dd":
        popTo("dt", stopAt: ["dl"])
        popTo("dd", stopAt: ["dl"])
      case "tr": popTo("tr", stopAt: ["table", "tbody", "thead", "tfoot"])
      case "td", "th":
        popTo("td", stopAt: ["tr", "table"])
        popTo("th", stopAt: ["tr", "table"])
      case "tbody", "thead", "tfoot":
        popTo("tbody", stopAt: ["table"])
        popTo("thead", stopAt: ["table"])
      case "option": popTo("option", stopAt: ["select"])
      default: break
      }
      let node = HTMLNode(name: name, attributes: attributes)
      nodes += 1
      current().append(node)
      if !selfClosing && !voidElements.contains(name) && stack.count < maximumDepth { stack.append(node) }
    }

    func close(_ name: String) {
      guard name != "html", name != "body" else { return }
      popTo(name, stopAt: [])
    }

    while i < count {
      guard bytes[i] == UInt8(ascii: "<"), i + 1 < count else {
        i += 1
        continue
      }
      if nodes >= maximumNodes || budget?.spent() == true {
        textStart = i
        break
      }
      let next = bytes[i + 1]
      if next == UInt8(ascii: "!") {
        flushText(upTo: i)
        if i + 3 < count, bytes[i + 2] == UInt8(ascii: "-"), bytes[i + 3] == UInt8(ascii: "-") {
          i = find(bytes, Array("-->".utf8), from: i + 4).map { $0 + 3 } ?? count
        } else {
          i = (find(bytes, [UInt8(ascii: ">")], from: i + 2) ?? count - 1) + 1
        }
        textStart = i
        continue
      }
      if next == UInt8(ascii: "?") {
        flushText(upTo: i)
        i = (find(bytes, [UInt8(ascii: ">")], from: i + 2) ?? count - 1) + 1
        textStart = i
        continue
      }
      if next == UInt8(ascii: "/") {
        var j = i + 2
        let nameStart = j
        while j < count, isNameByte(bytes[j]) { j += 1 }
        guard j > nameStart else {
          i += 1
          continue
        }
        flushText(upTo: i)
        let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
        i = (find(bytes, [UInt8(ascii: ">")], from: j) ?? count - 1) + 1
        textStart = i
        close(name)
        continue
      }
      guard isLetter(next) else {
        i += 1
        continue
      }
      flushText(upTo: i)
      var j = i + 1
      while j < count, isNameByte(bytes[j]) { j += 1 }
      let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self).lowercased()
      var attributes: [String: String] = [:]
      var selfClosing = false
      // Attributes.
      while j < count {
        while j < count, isSpace(bytes[j]) { j += 1 }
        guard j < count else { break }
        if bytes[j] == UInt8(ascii: ">") {
          j += 1
          break
        }
        if bytes[j] == UInt8(ascii: "/") {
          if j + 1 < count, bytes[j + 1] == UInt8(ascii: ">") {
            selfClosing = true
            j += 2
            break
          }
          j += 1
          continue
        }
        let attributeStart = j
        while j < count, !isSpace(bytes[j]), bytes[j] != UInt8(ascii: "="), bytes[j] != UInt8(ascii: ">"),
          !(bytes[j] == UInt8(ascii: "/") && j + 1 < count && bytes[j + 1] == UInt8(ascii: ">"))
        {
          j += 1
        }
        let attributeName = String(decoding: bytes[attributeStart..<j], as: UTF8.self).lowercased()
        while j < count, isSpace(bytes[j]) { j += 1 }
        var value = ""
        if j < count, bytes[j] == UInt8(ascii: "=") {
          j += 1
          while j < count, isSpace(bytes[j]) { j += 1 }
          if j < count, bytes[j] == UInt8(ascii: "\"") || bytes[j] == UInt8(ascii: "'") {
            let quote = bytes[j]
            let valueStart = j + 1
            let end = find(bytes, [quote], from: valueStart) ?? count
            value = String(decoding: bytes[valueStart..<end], as: UTF8.self)
            j = min(end + 1, count)
          } else {
            let valueStart = j
            while j < count, !isSpace(bytes[j]), bytes[j] != UInt8(ascii: ">") { j += 1 }
            value = String(decoding: bytes[valueStart..<j], as: UTF8.self)
          }
        }
        if !attributeName.isEmpty, attributes[attributeName] == nil {
          attributes[attributeName] = HTMLEntities.decode(value)
        }
      }
      i = j
      textStart = i
      if rawTextElements.contains(name), !selfClosing {
        let closing = Array("</\(name)".utf8)
        let end = findCaseInsensitive(bytes, closing, from: i) ?? count
        let raw = String(decoding: bytes[i..<end], as: UTF8.self)
        open(name, attributes, selfClosing: false)
        if name != "script" {
          let text = name == "style" ? raw : HTMLEntities.decode(raw)
          current().append(HTMLNode(name: "#text", text: text))
        }
        popTo(name, stopAt: [])
        i = end < count ? (find(bytes, [UInt8(ascii: ">")], from: end) ?? count - 1) + 1 : count
        textStart = i
        continue
      }
      open(name, attributes, selfClosing: selfClosing)
    }
    if nodes < maximumNodes, budget?.exceeded != true { flushText(upTo: count) }
    return root
  }

  static func isLetter(_ byte: UInt8) -> Bool {
    (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
  }

  static func isNameByte(_ byte: UInt8) -> Bool {
    isLetter(byte) || (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
      || byte == UInt8(ascii: "_")
  }

  static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
  }

  static func find(_ bytes: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
    guard !needle.isEmpty, start < bytes.count else { return nil }
    var i = start
    let last = bytes.count - needle.count
    while i <= last {
      if bytes[i] == needle[0] {
        var matched = true
        for k in 1..<needle.count where bytes[i + k] != needle[k] {
          matched = false
          break
        }
        if matched { return i }
      }
      i += 1
    }
    return nil
  }

  static func findCaseInsensitive(_ bytes: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
    func lower(_ byte: UInt8) -> UInt8 { (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte }
    let needle = needle.map(lower)
    guard !needle.isEmpty, start < bytes.count else { return nil }
    var i = start
    let last = bytes.count - needle.count
    while i <= last {
      var matched = true
      for k in 0..<needle.count where lower(bytes[i + k]) != needle[k] {
        matched = false
        break
      }
      if matched { return i }
      i += 1
    }
    return nil
  }
}

/// Character references: the named ones pages commonly use, and numeric
/// ones. Unknown names are left as written.
enum HTMLEntities {
  static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ensp": " ",
    "emsp": " ", "thinsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
    "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©",
    "reg": "®", "trade": "™", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "para": "¶",
    "sect": "§", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "frac12": "½", "frac14": "¼",
    "frac34": "¾", "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "harr": "↔", "le": "≤",
    "ge": "≥", "ne": "≠", "minus": "−", "shy": "\u{00AD}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    "lrm": "\u{200E}", "rlm": "\u{200F}", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä",
    "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à",
    "aacute": "á", "ccedil": "ç", "ntilde": "ñ", "oacute": "ó", "iacute": "í", "uacute": "ú",
  ]

  static func decode(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = ""
    result.reserveCapacity(text.count)
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      guard character == "&" else {
        result.append(character)
        index = text.index(after: index)
        continue
      }
      let limit = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
      if let semicolon = text[index..<limit].firstIndex(of: ";") {
        let body = text[text.index(after: index)..<semicolon]
        if let value = reference(body) {
          result += value
          index = text.index(after: semicolon)
          continue
        }
      }
      result.append("&")
      index = text.index(after: index)
    }
    return result
  }

  static func reference(_ body: Substring) -> String? {
    if body.hasPrefix("#x") || body.hasPrefix("#X") {
      guard let value = UInt32(body.dropFirst(2), radix: 16) else { return nil }
      return scalar(value)
    }
    if body.hasPrefix("#") {
      guard let value = UInt32(body.dropFirst()) else { return nil }
      return scalar(value)
    }
    return named[String(body)]
  }

  static func scalar(_ value: UInt32) -> String? {
    guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
    return String(Character(scalar))
  }
}
