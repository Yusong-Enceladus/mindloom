import Foundation

/// A pinned SSH host public key in OpenSSH text form (`ssh-ed25519 AAAA…`), as
/// the Mac reads it from its own `known_hosts`. The phone refuses any server
/// that presents a different key; there is no trust-on-first-use.
public struct SSHHostKey: Equatable, Hashable, Sendable, CustomStringConvertible {
  /// Key types swift-nio-ssh can verify. `ssh-rsa` is deliberately absent.
  public static let supportedTypes: Set<String> = [
    "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
  ]

  public let type: String
  /// The SSH wire encoding of the key (the base64 part, decoded).
  public let blob: Data

  /// `type base64`, without any comment: the canonical pinned form.
  public var openSSH: String { "\(type) \(blob.base64EncodedString())" }
  public var description: String { openSSH }

  public init?(openSSH text: String) {
    // `type base64 [comment…]`; a comment is allowed and dropped.
    let fields = text.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 2, text.utf8.count <= 4096 else { return nil }
    let type = String(fields[0])
    guard Self.supportedTypes.contains(type),
      let blob = Base64URL.decodeStandard(String(fields[1])),
      Self.isWellFormed(blob: blob, type: type)
    else { return nil }
    self.type = type
    self.blob = blob
  }

  /// The blob starts with the type string again, and the key material has the
  /// size its type requires.
  static func isWellFormed(blob: Data, type: String) -> Bool {
    var reader = SSHWireReader(blob)
    guard let embeddedType = reader.readString(),
      String(decoding: embeddedType, as: UTF8.self) == type
    else { return false }
    switch type {
    case "ssh-ed25519":
      guard let key = reader.readString(), key.count == 32 else { return false }
    default:
      let curve = String(type.dropFirst("ecdsa-sha2-".count))
      let pointBytes = ["nistp256": 65, "nistp384": 97, "nistp521": 133][curve]
      guard let name = reader.readString(), String(decoding: name, as: UTF8.self) == curve,
        let point = reader.readString(), point.count == pointBytes, point.first == 0x04
      else { return false }
    }
    return reader.isAtEnd
  }
}

struct SSHWireReader {
  private let bytes: [UInt8]
  private var offset = 0

  init(_ data: Data) { bytes = [UInt8](data) }

  var isAtEnd: Bool { offset == bytes.count }

  mutating func readString() -> [UInt8]? {
    guard bytes.count - offset >= 4 else { return nil }
    let length =
      Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
      | Int(bytes[offset + 3])
    offset += 4
    guard length <= bytes.count - offset else { return nil }
    defer { offset += length }
    return Array(bytes[offset..<(offset + length)])
  }
}
