import Foundation

/// The text around the caret in the focused field, read once before a
/// delivery and never during one.
public struct CaretContext: Equatable, Sendable {
  public let value: String
  public let selectionLocation: Int
  public let selectionLength: Int

  public init(value: String, selectionLocation: Int, selectionLength: Int) {
    self.value = value
    self.selectionLocation = selectionLocation
    self.selectionLength = selectionLength
  }
}

/// English dictated after English needs the space the speaker did not say.
/// "hello" followed by "world" is "hello world"; after Chinese, after a
/// space, or over a selection, nothing is added.
public enum BoundarySpacing {
  public static func apply(_ text: String, before caret: CaretContext?) -> String {
    guard let caret,
      caret.selectionLength == 0,
      caret.selectionLocation > 0,
      caret.selectionLocation <= caret.value.utf16.count,
      let first = text.utf16.first,
      first < 128,
      isASCIIAlphaNumeric(first)
    else { return text }
    let previous = (caret.value as NSString).character(at: caret.selectionLocation - 1)
    guard previous < 128,
      isASCIIAlphaNumeric(previous) || asciiClosingPunctuation.contains(previous)
    else { return text }
    return " " + text
  }

  private static let asciiClosingPunctuation: Set<UInt16> = [
    0x21, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D,
  ]

  private static func isASCIIAlphaNumeric(_ value: UInt16) -> Bool {
    (0x30...0x39).contains(value)
      || (0x41...0x5A).contains(value)
      || (0x61...0x7A).contains(value)
  }
}
