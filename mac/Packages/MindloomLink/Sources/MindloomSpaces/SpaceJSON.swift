import Foundation

/// A JSON value: op bodies, the parts of a response this module does not
/// model, and the member-visible fields of a shared item. Encoded with sorted
/// keys and unescaped slashes, so the same value always gives the same bytes.
public enum SpaceJSON: Equatable, Hashable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([SpaceJSON])
  case object([String: SpaceJSON])

  public subscript(key: String) -> SpaceJSON? {
    if case .object(let fields) = self { return fields[key] }
    return nil
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var int: Int? {
    switch self {
    case .int(let value): return Int(exactly: value)
    case .double(let value): return Int(exactly: value)
    default: return nil
    }
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var array: [SpaceJSON]? {
    if case .array(let values) = self { return values }
    return nil
  }

  public var object: [String: SpaceJSON]? {
    if case .object(let fields) = self { return fields }
    return nil
  }

  public var isNull: Bool { self == .null }

  /// A copy with `key` set (objects only; anything else is returned as is).
  public func setting(_ key: String, _ value: SpaceJSON?) -> SpaceJSON {
    guard case .object(var fields) = self else { return self }
    fields[key] = value
    return .object(fields)
  }

  /// UTF-8 JSON, keys sorted, slashes unescaped.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) throws -> SpaceJSON {
    try JSONDecoder().decode(SpaceJSON.self, from: data)
  }

  /// Any Encodable value as a JSON value (through its encoding).
  public static func from<Value: Encodable>(_ value: Value) throws -> SpaceJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try decode(encoder.encode(value))
  }

  /// This value decoded as `Value`.
  public func decoded<Value: Decodable>(as type: Value.Type = Value.self) throws -> Value {
    try JSONDecoder().decode(Value.self, from: encoded())
  }
}

extension SpaceJSON: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([SpaceJSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: SpaceJSON].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .object(let fields): try container.encode(fields)
    }
  }
}

extension SpaceJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int64) { self = .int(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: SpaceJSON...) { self = .array(elements) }
  public init(nilLiteral: ()) { self = .null }
  public init(dictionaryLiteral elements: (String, SpaceJSON)...) {
    var fields: [String: SpaceJSON] = [:]
    for (key, value) in elements { fields[key] = value }
    self = .object(fields)
  }
}

extension SpaceJSON {
  public init(_ value: String?) { self = value.map(SpaceJSON.string) ?? .null }
  public init(_ value: Int) { self = .int(Int64(value)) }
  public init(_ value: Bool) { self = .bool(value) }
  public init(_ values: [String]) { self = .array(values.map(SpaceJSON.string)) }
}
