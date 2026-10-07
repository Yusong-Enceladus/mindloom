import Foundation
import MindloomIdentity

/// Carrying the owner's login-keychain items from bestASR (`com.bestasr.app`)
/// to Mindloom (`app.mindloom`) without a password prompt (owner's decision
/// 2026-10-06: a new identity).
///
/// Every item the Mac App keeps is a generic password in the login (file)
/// keychain, made by the App itself, so its access list trusts only the App
/// that made it (its designated requirement). A new identity cannot read them
/// without asking for the keychain password. The switch therefore runs a
/// one-shot helper signed with bestASR's identifier and certificate, which
/// satisfies those access lists, reads the items of the library being moved,
/// and hands them to Mindloom over a private Unix socket after both sides
/// checked each other's code signature (`CarryOverChannel`). Mindloom makes
/// them again under its own services and the moved library's identity; the
/// originals stay as they are, so going back to bestASR needs nothing.
///
/// The secrets travel only through that socket, in memory: never through
/// arguments, the environment, files or logs.
public enum KeychainCarryOver {
  /// 2: the offer names the library folder it was read for (review of 10-6).
  public static let version = 2
  /// More is not an owner's library (a guard against a confused peer).
  public static let maximumItems = 4_096
  public static let maximumValueBytes = 64 * 1_024

  /// What each item is, its services before and after, and how its account
  /// names the library (`<root>`, `<root>|<space id>`, `<root>:<grant id>`).
  public enum Kind: String, CaseIterable, Codable, Sendable {
    /// The organizing link's library key (`KeychainOrganizerKeyStore`).
    case organizerKey = "organizer-key"
    /// The X25519 key the iPhone seals to (`KeychainPhoneSealKeyStore`).
    case phoneSealKey = "phone-seal-key"
    /// One shared space's keys by epoch (`KeychainSpaceKeyStore`).
    case spaceKey = "space-key"
    /// This Mac's space signing key and id (`KeychainSpaceDeviceStore`).
    case spaceDeviceKey = "space-device-key"
    /// This Mac's access to the team Spark (`KeychainMemberAccessStore`).
    case memberAccess = "member-access"
    /// One outside agent's grant secret (`KeychainAgentGrantSecretStore`).
    case agentGrant = "agent-grant"

    public var service: String { MindloomIdentity.keychainService(rawValue) }
    public var previousService: String { MindloomIdentity.Previous.keychainService(rawValue) }

    /// The label Keychain Access shows (the App's own stores write the same).
    public var label: String {
      switch self {
      case .organizerKey: "Mindloom organizer key"
      case .phoneSealKey: "Mindloom phone seal key"
      case .spaceKey: "Mindloom shared space key"
      case .spaceDeviceKey: "Mindloom space device key"
      case .memberAccess: "Mindloom team access"
      case .agentGrant: "Mindloom agent grant"
      }
    }

    /// What follows the root's identity in the account.
    var separator: Character? {
      switch self {
      case .spaceKey: "|"
      case .agentGrant: ":"
      default: nil
      }
    }

    /// The part of `account` after `root`, when the account is this root's.
    public func suffix(ofAccount account: String, root: String) -> String? {
      guard account.hasPrefix(root) else { return nil }
      let rest = String(account.dropFirst(root.count))
      return isValid(suffix: rest) ? rest : nil
    }

    public func account(root: String, suffix: String) -> String { root + suffix }

    /// `""` for the per-root kinds; `|<space id>` or `:<grant id>` (lower-case
    /// letters, digits and dashes) for the others.
    public func isValid(suffix: String) -> Bool {
      guard let separator else { return suffix.isEmpty }
      guard suffix.first == separator else { return false }
      let id = suffix.dropFirst()
      return (1...64).contains(id.count)
        && id.unicodeScalars.allSatisfy {
          ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }
  }

  /// One item: its kind, the account after the root's identity, the secret.
  public struct Item: Codable, Equatable, Sendable {
    public let kind: Kind
    public let suffix: String
    public let value: Data

    public init(kind: Kind, suffix: String, value: Data) {
      self.kind = kind
      self.suffix = suffix
      self.value = value
    }
  }

  /// The helper's side: the items of the moved library and whether
  /// bestASR's 「登录时打开」 was on.
  public struct Offer: Codable, Equatable, Sendable {
    public let version: Int
    public let items: [Item]
    /// Items of that library the helper could not read without asking.
    public let unreadable: Int
    public let loginItemWasEnabled: Bool
    /// The library folder the items were read for (the helper's
    /// `--library`). Mindloom takes the offer only when this is bestASR's
    /// folder beside the library it opened (`CarryOverSource.isPreviousLibrary`),
    /// so a helper started on another folder cannot add that folder's items
    /// under the owner's library.
    public let library: String?

    public init(
      items: [Item], unreadable: Int, loginItemWasEnabled: Bool, library: String? = nil
    ) {
      version = KeychainCarryOver.version
      self.items = items
      self.unreadable = unreadable
      self.loginItemWasEnabled = loginItemWasEnabled
      self.library = library
    }

    /// Refuses anything an owner's library cannot have made.
    public func validate() throws {
      guard version == KeychainCarryOver.version else { throw CarryOverError.unsupportedVersion }
      guard items.count <= KeychainCarryOver.maximumItems, unreadable >= 0 else {
        throw CarryOverError.malformed
      }
      var seen = Set<String>()
      for item in items {
        guard item.kind.isValid(suffix: item.suffix),
          (1...KeychainCarryOver.maximumValueBytes).contains(item.value.count),
          seen.insert(item.kind.rawValue + "\u{0}" + item.suffix).inserted
        else { throw CarryOverError.malformed }
      }
    }
  }

  /// Mindloom's side: what it made of the offer.
  public struct Receipt: Codable, Equatable, Sendable {
    public let version: Int
    public let created: Int
    /// Already there under Mindloom's identity (left as they were).
    public let existing: Int
    public let failed: Int
    public let loginItemRegistered: Bool

    public init(created: Int, existing: Int, failed: Int, loginItemRegistered: Bool) {
      version = KeychainCarryOver.version
      self.created = created
      self.existing = existing
      self.failed = failed
      self.loginItemRegistered = loginItemRegistered
    }
  }

  /// Makes the offered items again under Mindloom's services and the new
  /// root's identity. An item already there is left alone (never
  /// overwritten); each one made is read back and compared.
  public static func receive(
    _ offer: Offer, newRoot: String, keychain: some CarryOverKeychain
  ) -> (created: Int, existing: Int, failed: Int) {
    var created = 0
    var existing = 0
    var failed = 0
    for item in offer.items {
      let account = item.kind.account(root: newRoot, suffix: item.suffix)
      switch keychain.exists(service: item.kind.service, account: account) {
      case .some(true):
        existing += 1
        continue
      case .none:
        failed += 1
        continue
      case .some(false):
        break
      }
      guard
        keychain.add(
          service: item.kind.service, account: account, label: item.kind.label, value: item.value),
        keychain.read(service: item.kind.service, account: account) == item.value
      else {
        failed += 1
        continue
      }
      created += 1
    }
    return (created, existing, failed)
  }

  /// The helper's reading: every item of the previous services whose account
  /// names `oldRoot`; values it cannot read without asking are counted, not
  /// asked for.
  public static func collect(
    oldRoot: String, keychain: some CarryOverKeychain
  ) -> (items: [Item], unreadable: Int) {
    var items: [Item] = []
    var unreadable = 0
    for kind in Kind.allCases {
      for account in keychain.accounts(service: kind.previousService).sorted() {
        guard let suffix = kind.suffix(ofAccount: account, root: oldRoot) else { continue }
        guard let value = keychain.read(service: kind.previousService, account: account),
          (1...maximumValueBytes).contains(value.count)
        else {
          unreadable += 1
          continue
        }
        items.append(Item(kind: kind, suffix: suffix, value: value))
      }
    }
    return (items, unreadable)
  }
}

public enum CarryOverError: Error, Equatable, Sendable {
  case unsupportedVersion
  case malformed
  /// The offer was read for another folder than bestASR's beside the
  /// library Mindloom opened.
  case otherLibrary
  case tooLarge
  case closed
  case peerRejected
  case socket(Int32)
  case unsafeDirectory
  case pathTooLong
  case timedOut
  case keychain(Int32)
  case keychainLocked
}

/// The keychain operations the carry-over needs (the login keychain in the
/// App and the helper, a temporary keychain file in the dry run, memory in
/// tests). None of them may show UI.
public protocol CarryOverKeychain {
  /// Accounts of `service` (attributes only: nothing is asked).
  func accounts(service: String) -> [String]
  /// nil when it cannot be read without asking (or is not there).
  func read(service: String, account: String) -> Data?
  /// nil when the keychain could not say.
  func exists(service: String, account: String) -> Bool?
  func add(service: String, account: String, label: String, value: Data) -> Bool
}

/// Length-prefixed JSON frames (4 bytes, big-endian), at most 32 MB.
public enum CarryOverFrame {
  public static let maximumBytes = 32 * 1_024 * 1_024

  public static func encode(_ value: some Encodable) throws -> Data {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maximumBytes else { throw CarryOverError.tooLarge }
    var length = UInt32(body.count).bigEndian
    return Data(bytes: &length, count: 4) + body
  }

  public static func length(of header: Data) throws -> Int {
    guard header.count == 4 else { throw CarryOverError.malformed }
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= maximumBytes else { throw CarryOverError.tooLarge }
    return length
  }

  public static func decode<T: Decodable>(_ type: T.Type, body: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: body) } catch {
      throw CarryOverError.malformed
    }
  }
}

/// In memory, for tests.
public final class MemoryCarryOverKeychain: CarryOverKeychain, @unchecked Sendable {
  private let lock = NSLock()
  public private(set) var values: [String: Data] = [:]
  /// Accounts that need a password (as an item another App made).
  public var locked: Set<String> = []
  public var failAdds = false

  public init(values: [String: Data] = [:]) { self.values = values }

  public static func key(_ service: String, _ account: String) -> String {
    service + "\u{0}" + account
  }

  public func accounts(service: String) -> [String] {
    lock.withLock {
      values.keys.compactMap { key in
        let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == service ? String(parts[1]) : nil
      }
    }
  }

  public func read(service: String, account: String) -> Data? {
    lock.withLock {
      let key = Self.key(service, account)
      return locked.contains(key) ? nil : values[key]
    }
  }

  public func exists(service: String, account: String) -> Bool? {
    lock.withLock { values[Self.key(service, account)] != nil }
  }

  public func add(service: String, account: String, label: String, value: Data) -> Bool {
    lock.withLock {
      let key = Self.key(service, account)
      guard !failAdds, values[key] == nil else { return false }
      values[key] = value
      return true
    }
  }
}
