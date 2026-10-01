import Foundation

/// Any JSON value, for the MCP messages the helper forwards and the App
/// answers. Parsing keeps integers and booleans apart from doubles, so a
/// JSON-RPC `id` of `7` comes back as `7`, never `7.0` or `true`.
/// Serialization is deterministic (object keys sorted) and never writes a
/// raw line break, so one message is always one line on the wire.
public enum JSONValue: Equatable, Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  // MARK: Reading

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  /// An integer, also from a double with no fraction (some clients send
  /// `10.0`).
  public var intValue: Int64? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value.rounded() == value && abs(value) < 9e15:
      return Int64(value)
    default: return nil
    }
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  // MARK: Parsing

  public enum ParseError: Error, Equatable, Sendable {
    case notJSON
    case tooDeep
  }

  /// Parses one JSON text (UTF-8). Top-level scalars are allowed.
  public static func parse(_ data: Data) throws -> JSONValue {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw ParseError.notJSON
    }
    return try convert(object, depth: 0)
  }

  public static func parse(_ text: String) throws -> JSONValue {
    try parse(Data(text.utf8))
  }

  private static func convert(_ value: Any, depth: Int) throws -> JSONValue {
    guard depth < 64 else { throw ParseError.tooDeep }
    switch value {
    case is NSNull:
      return .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      let type = String(cString: number.objCType)
      if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) {
        return .int(number.int64Value)
      }
      return .double(number.doubleValue)
    case let string as String:
      return .string(string)
    case let array as [Any]:
      return .array(try array.map { try convert($0, depth: depth + 1) })
    case let dictionary as [String: Any]:
      var object: [String: JSONValue] = [:]
      for (key, element) in dictionary { object[key] = try convert(element, depth: depth + 1) }
      return .object(object)
    default:
      throw ParseError.notJSON
    }
  }

  // MARK: Writing

  /// Compact JSON with sorted keys; non-ASCII characters are written as
  /// they are (UTF-8), control characters escaped.
  public var serialized: String {
    var output = ""
    write(into: &output)
    return output
  }

  public var serializedData: Data { Data(serialized.utf8) }

  private func write(into output: inout String) {
    switch self {
    case .null: output += "null"
    case .bool(let value): output += value ? "true" : "false"
    case .int(let value): output += String(value)
    case .double(let value):
      if value.isNaN || value.isInfinite {
        output += "null"
      } else if value.rounded() == value, abs(value) < 9e15 {
        output += String(Int64(value))
      } else {
        output += String(value)
      }
    case .string(let value): Self.writeString(value, into: &output)
    case .array(let values):
      output += "["
      for (index, value) in values.enumerated() {
        if index > 0 { output += "," }
        value.write(into: &output)
      }
      output += "]"
    case .object(let object):
      output += "{"
      for (index, key) in object.keys.sorted().enumerated() {
        if index > 0 { output += "," }
        Self.writeString(key, into: &output)
        output += ":"
        object[key]!.write(into: &output)
      }
      output += "}"
    }
  }

  private static func writeString(_ value: String, into output: inout String) {
    output += "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      // U+2028/2029 are line terminators for some readers.
      case "\u{2028}": output += "\\u2028"
      case "\u{2029}": output += "\\u2029"
      default:
        if scalar.value < 0x20 {
          output += String(format: "\\u%04x", scalar.value)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int64) { self = .int(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
  /// `.string` or `.null`.
  public static func optional(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }

  public static func strings(_ values: [String]) -> JSONValue {
    .array(values.map(JSONValue.string))
  }
}
