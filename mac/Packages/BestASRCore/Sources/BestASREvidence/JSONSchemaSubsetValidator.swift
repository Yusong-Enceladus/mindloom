import CoreFoundation
import Foundation

public struct JSONSchemaValidationError: Error, CustomStringConvertible, Sendable {
  public let path: String
  public let message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }

  public var description: String {
    "\(path): \(message)"
  }
}

/// A dependency-free validator for the deliberately small JSON Schema subset
/// used by bestASR evidence contracts. Unsupported schema keywords fail closed.
public enum JSONSchemaSubsetValidator {
  private static let supportedKeywords: Set<String> = [
    "$id",
    "$schema",
    "additionalProperties",
    "const",
    "description",
    "enum",
    "examples",
    "format",
    "items",
    "maximum",
    "maxItems",
    "maxLength",
    "minItems",
    "minimum",
    "minLength",
    "minProperties",
    "pattern",
    "properties",
    "required",
    "title",
    "type",
    "uniqueItems",
  ]

  public static func validate(instanceData: Data, schemaData: Data) throws {
    let instance = try JSONSerialization.jsonObject(
      with: instanceData,
      options: [.fragmentsAllowed]
    )
    let schema = try JSONSerialization.jsonObject(
      with: schemaData,
      options: [.fragmentsAllowed]
    )
    try validate(instance: instance, schema: schema, path: "$")
  }

  private static func validate(instance: Any, schema: Any, path: String) throws {
    guard let schemaObject = schema as? [String: Any] else {
      throw JSONSchemaValidationError(path: path, message: "schema must be an object")
    }

    for keyword in schemaObject.keys where !supportedKeywords.contains(keyword) {
      throw JSONSchemaValidationError(
        path: path,
        message: "unsupported schema keyword: \(keyword)"
      )
    }

    if let expectedType = schemaObject["type"] {
      guard let expectedType = expectedType as? String else {
        throw JSONSchemaValidationError(path: path, message: "schema type must be a string")
      }
      guard matches(type: expectedType, value: instance) else {
        throw JSONSchemaValidationError(
          path: path,
          message: "expected type \(expectedType), found \(typeName(of: instance))"
        )
      }
    }

    if let expectedValue = schemaObject["const"],
      try !jsonValuesEqual(instance, expectedValue)
    {
      throw JSONSchemaValidationError(path: path, message: "value does not match const")
    }

    if let enumValues = schemaObject["enum"] {
      guard let enumValues = enumValues as? [Any] else {
        throw JSONSchemaValidationError(path: path, message: "schema enum must be an array")
      }
      let matched = try enumValues.contains { candidate in
        try jsonValuesEqual(instance, candidate)
      }
      guard matched else {
        throw JSONSchemaValidationError(path: path, message: "value is not in enum")
      }
    }

    if let object = instance as? [String: Any] {
      try validateObject(object, schema: schemaObject, path: path)
    }
    if let array = instance as? [Any] {
      try validateArray(array, schema: schemaObject, path: path)
    }
    if let string = instance as? String {
      try validateString(string, schema: schemaObject, path: path)
    }
    if let number = instance as? NSNumber, !isBoolean(number) {
      try validateNumber(number, schema: schemaObject, path: path)
    }
  }

  private static func validateObject(
    _ object: [String: Any],
    schema: [String: Any],
    path: String
  ) throws {
    if let requiredValue = schema["required"] {
      guard let required = requiredValue as? [String] else {
        throw JSONSchemaValidationError(path: path, message: "schema required must be strings")
      }
      for key in required where object[key] == nil {
        throw JSONSchemaValidationError(path: path, message: "missing required property: \(key)")
      }
    }

    let propertySchemas: [String: Any]
    if let propertiesValue = schema["properties"] {
      guard let properties = propertiesValue as? [String: Any] else {
        throw JSONSchemaValidationError(path: path, message: "schema properties must be an object")
      }
      propertySchemas = properties
    } else {
      propertySchemas = [:]
    }

    for (key, propertySchema) in propertySchemas {
      if let value = object[key] {
        try validate(instance: value, schema: propertySchema, path: "\(path).\(key)")
      }
    }

    if let additionalValue = schema["additionalProperties"] {
      guard let allowsAdditional = additionalValue as? Bool else {
        throw JSONSchemaValidationError(
          path: path,
          message: "schema additionalProperties must be a boolean"
        )
      }
      if !allowsAdditional {
        let extras = object.keys.filter { propertySchemas[$0] == nil }.sorted()
        if let firstExtra = extras.first {
          throw JSONSchemaValidationError(
            path: path,
            message: "unexpected property: \(firstExtra)"
          )
        }
      }
    }

    if let minimumValue = schema["minProperties"] {
      let minimum = try schemaInteger(minimumValue, keyword: "minProperties", path: path)
      if object.count < minimum {
        throw JSONSchemaValidationError(
          path: path,
          message: "expected at least \(minimum) properties"
        )
      }
    }
  }

  private static func validateArray(
    _ array: [Any],
    schema: [String: Any],
    path: String
  ) throws {
    if let minimumValue = schema["minItems"] {
      let minimum = try schemaInteger(minimumValue, keyword: "minItems", path: path)
      if array.count < minimum {
        throw JSONSchemaValidationError(path: path, message: "expected at least \(minimum) items")
      }
    }
    if let maximumValue = schema["maxItems"] {
      let maximum = try schemaInteger(maximumValue, keyword: "maxItems", path: path)
      if array.count > maximum {
        throw JSONSchemaValidationError(path: path, message: "expected at most \(maximum) items")
      }
    }
    if schema["uniqueItems"] as? Bool == true {
      var values = Set<Data>()
      for value in array {
        let canonical = try canonicalData(for: value)
        guard values.insert(canonical).inserted else {
          throw JSONSchemaValidationError(path: path, message: "array items must be unique")
        }
      }
    }
    if let itemSchema = schema["items"] {
      for (index, value) in array.enumerated() {
        try validate(instance: value, schema: itemSchema, path: "\(path)[\(index)]")
      }
    }
  }

  private static func validateString(
    _ string: String,
    schema: [String: Any],
    path: String
  ) throws {
    if let minimumValue = schema["minLength"] {
      let minimum = try schemaInteger(minimumValue, keyword: "minLength", path: path)
      if string.count < minimum {
        throw JSONSchemaValidationError(
          path: path,
          message: "expected string length of at least \(minimum)"
        )
      }
    }
    if let maximumValue = schema["maxLength"] {
      let maximum = try schemaInteger(maximumValue, keyword: "maxLength", path: path)
      if string.count > maximum {
        throw JSONSchemaValidationError(
          path: path,
          message: "expected string length of at most \(maximum)"
        )
      }
    }
    if let patternValue = schema["pattern"] {
      guard let pattern = patternValue as? String else {
        throw JSONSchemaValidationError(path: path, message: "schema pattern must be a string")
      }
      let expression = try NSRegularExpression(pattern: pattern)
      let range = NSRange(string.startIndex..., in: string)
      if expression.firstMatch(in: string, range: range) == nil {
        throw JSONSchemaValidationError(path: path, message: "string does not match pattern")
      }
    }
    if let formatValue = schema["format"] {
      guard let format = formatValue as? String else {
        throw JSONSchemaValidationError(path: path, message: "schema format must be a string")
      }
      try validateFormat(format, string: string, path: path)
    }
  }

  private static func validateNumber(
    _ number: NSNumber,
    schema: [String: Any],
    path: String
  ) throws {
    let value = number.doubleValue
    if let minimumValue = schema["minimum"] {
      guard let minimum = minimumValue as? NSNumber, !isBoolean(minimum) else {
        throw JSONSchemaValidationError(path: path, message: "schema minimum must be numeric")
      }
      if value < minimum.doubleValue {
        throw JSONSchemaValidationError(path: path, message: "number is below minimum")
      }
    }
    if let maximumValue = schema["maximum"] {
      guard let maximum = maximumValue as? NSNumber, !isBoolean(maximum) else {
        throw JSONSchemaValidationError(path: path, message: "schema maximum must be numeric")
      }
      if value > maximum.doubleValue {
        throw JSONSchemaValidationError(path: path, message: "number is above maximum")
      }
    }
  }

  private static func validateFormat(_ format: String, string: String, path: String) throws {
    switch format {
    case "uuid":
      guard UUID(uuidString: string) != nil else {
        throw JSONSchemaValidationError(path: path, message: "invalid UUID format")
      }
    case "date-time":
      let formatter = ISO8601DateFormatter()
      guard formatter.date(from: string) != nil else {
        throw JSONSchemaValidationError(path: path, message: "invalid ISO 8601 date-time")
      }
    default:
      throw JSONSchemaValidationError(path: path, message: "unsupported string format: \(format)")
    }
  }

  private static func matches(type: String, value: Any) -> Bool {
    switch type {
    case "object":
      return value is [String: Any]
    case "array":
      return value is [Any]
    case "string":
      return value is String
    case "boolean":
      guard let number = value as? NSNumber else { return false }
      return isBoolean(number)
    case "integer":
      guard let number = value as? NSNumber, !isBoolean(number) else { return false }
      return number.doubleValue.rounded(.towardZero) == number.doubleValue
    case "number":
      guard let number = value as? NSNumber else { return false }
      return !isBoolean(number)
    case "null":
      return value is NSNull
    default:
      return false
    }
  }

  private static func typeName(of value: Any) -> String {
    if value is [String: Any] { return "object" }
    if value is [Any] { return "array" }
    if value is String { return "string" }
    if let number = value as? NSNumber {
      if isBoolean(number) { return "boolean" }
      if number.doubleValue.rounded(.towardZero) == number.doubleValue { return "integer" }
      return "number"
    }
    if value is NSNull { return "null" }
    return "unknown"
  }

  private static func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func schemaInteger(_ value: Any, keyword: String, path: String) throws -> Int {
    guard let number = value as? NSNumber,
      !isBoolean(number),
      number.doubleValue >= 0,
      number.doubleValue.rounded(.towardZero) == number.doubleValue
    else {
      throw JSONSchemaValidationError(
        path: path,
        message: "schema \(keyword) must be a non-negative integer"
      )
    }
    return number.intValue
  }

  private static func jsonValuesEqual(_ lhs: Any, _ rhs: Any) throws -> Bool {
    try canonicalData(for: lhs) == canonicalData(for: rhs)
  }

  private static func canonicalData(for value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
  }
}
