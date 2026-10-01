import Foundation

/// RFC 4648 §5 base64url.
///
/// Decoding is canonical: only the url alphabet, no whitespace, and unused
/// trailing bits must be zero. Two different strings therefore never decode to
/// the same bytes, so a changed character in a wire string always changes the
/// bytes that are authenticated.
public enum Base64URL {
  /// Encodes without `=` padding.
  public static func encode(_ data: Data) -> String {
    var text = data.base64EncodedString()
    text = text.replacingOccurrences(of: "+", with: "-")
    text = text.replacingOccurrences(of: "/", with: "_")
    while text.hasSuffix("=") { text.removeLast() }
    return text
  }

  /// Decodes canonical base64url. `allowPadding` also accepts `=` padding of
  /// the correct length (the pairing text may come from other tools).
  public static func decode(_ text: String, allowPadding: Bool = false) -> Data? {
    var body = Substring(text)
    if allowPadding {
      while body.hasSuffix("=") { body.removeLast() }
      let padding = text.count - body.count
      guard padding <= 2, padding == 0 || (body.count + padding) % 4 == 0 else { return nil }
    }
    guard body.count % 4 != 1 else { return nil }
    guard
      body.utf8.allSatisfy({ byte in
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
          || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
      })
    else { return nil }
    var standard = body.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = standard.count % 4
    if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: standard) else { return nil }
    // Canonical: re-encoding must give back exactly the same characters.
    guard encode(data) == String(body) else { return nil }
    return data
  }

  /// Standard base64 (with padding), strict: used for key fields in JSON.
  static func decodeStandard(_ text: String) -> Data? {
    guard
      text.utf8.allSatisfy({ byte in
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
          || (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2F || byte == 0x3D
      })
    else { return nil }
    guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else {
      return nil
    }
    return data
  }
}
