import Foundation

/// The id of one inbox entry: a random UUID in lowercase text form.
///
/// It is bound into the seal as associated data, is the Spark's `inbox_id`,
/// and is the outbox file name on the phone, so it is validated everywhere it
/// crosses a boundary.
public enum EntryID {
  public static func make() -> String { UUID().uuidString.lowercased() }

  /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, lowercase hex only.
  public static func isValid(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count == 36 else { return false }
    for (index, byte) in bytes.enumerated() {
      switch index {
      case 8, 13, 18, 23:
        guard byte == 0x2D else { return false }
      default:
        guard (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) else {
          return false
        }
      }
    }
    return true
  }
}
