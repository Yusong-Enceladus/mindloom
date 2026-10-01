import BestASRDomain
import CryptoKit
import Darwin
import Foundation
import Security

/// Where one library's phone seal key lives (PHONE-CONTRACT §3): an X25519
/// key pair per data root. The phone seals every entry to its public key; the
/// organizing device only relays the sealed bytes; only this private key
/// opens them. The private key never leaves this Mac.
///
/// The same rule as the organizing-link key: the Keychain, or a file only for
/// a root marked `SYNTHETIC_DATA_ROOT`. The key is kept across pairings, so
/// entries still waiting in a phone's outbox open after the phone is paired
/// again.
public protocol PhoneSealKeyStore: Sendable {
  /// The stored private key, or nil when there is none yet.
  func load() throws -> Curve25519.KeyAgreement.PrivateKey?
  func save(_ key: Curve25519.KeyAgreement.PrivateKey) throws
  /// Must not throw when there is no key.
  func delete() throws
}

extension PhoneSealKeyStore {
  /// The stored key, or a new random one saved first (the first pairing).
  public func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey {
    if let key = try load() { return key }
    let key = Curve25519.KeyAgreement.PrivateKey()
    try save(key)
    guard let stored = try load(), stored.rawRepresentation == key.rawRepresentation else {
      throw OrganizerKeyStoreError.unreadable
    }
    return stored
  }
}

/// A raw 32-byte X25519 private key, refusing anything else.
enum PhoneSealKeyBytes {
  static func key(from data: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
    guard data.count == 32,
      let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    else { throw OrganizerKeyStoreError.unreadable }
    return key
  }
}

/// The seal key as a generic password in the user's login Keychain: service
/// `com.bestasr.phone-seal-key`, account = the data root's identity hash
/// (the same account as the organizing-link key), this device only.
public struct KeychainPhoneSealKeyStore: PhoneSealKeyStore {
  public static let service = "com.bestasr.phone-seal-key"

  public let account: String

  public init(dataRoot: URL) {
    account = OrganizerDataRootIdentity.hash(of: dataRoot)
  }

  public init(account: String) {
    self.account = account
  }

  private var query: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: account,
    ]
  }

  public func load() throws -> Curve25519.KeyAgreement.PrivateKey? {
    var request = query
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
    guard let data = result as? Data else { throw OrganizerKeyStoreError.unreadable }
    return try PhoneSealKeyBytes.key(from: data)
  }

  public func save(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
    try delete()
    var item = query
    item[kSecValueData] = key.rawRepresentation
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom phone seal key"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
  }

  public func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OrganizerKeyStoreError.keychain(status)
    }
  }
}

/// The seal key as a 0600 file inside the data root. Allowed only for a root
/// marked `SYNTHETIC_DATA_ROOT` that is not the owner's real library: tests
/// and end-to-end runs use it; the real library never can.
public struct FilePhoneSealKeyStore: PhoneSealKeyStore {
  public static let fileName = "phone-seal.key"

  public let dataRoot: URL
  private let realLibraryRoot: URL?

  public init(
    dataRoot: URL, realLibraryRoot: URL? = BestASRDataRootSelection.ownerRealLibraryRoot()
  ) throws {
    self.dataRoot = dataRoot.standardizedFileURL
    self.realLibraryRoot = realLibraryRoot
    try checkRoot()
  }

  private var url: URL { dataRoot.appendingPathComponent(Self.fileName) }

  private func checkRoot() throws {
    guard let realLibraryRoot,
      !BestASRDataRootSelection.path(dataRoot, isWithinOrEqualTo: realLibraryRoot)
    else { throw OrganizerKeyStoreError.notASyntheticRoot }
    var entry = stat()
    let marker = dataRoot.appendingPathComponent(
      RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    guard lstat(marker.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else {
      throw OrganizerKeyStoreError.notASyntheticRoot
    }
  }

  public func load() throws -> Curve25519.KeyAgreement.PrivateKey? {
    try checkRoot()
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw OrganizerKeyStoreError.unreadable
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1, status.st_mode & 0o077 == 0
    else { throw OrganizerKeyStoreError.unreadable }
    return try PhoneSealKeyBytes.key(from: try handle.read(upToCount: 64) ?? Data())
  }

  public func save(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
    try checkRoot()
    try delete()
    let descriptor = open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw OrganizerKeyStoreError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    // The umask cannot widen it: 0600 exactly.
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw OrganizerKeyStoreError.unreadable
    }
    try handle.write(contentsOf: key.rawRepresentation)
    try handle.synchronize()
  }

  public func delete() throws {
    guard unlink(url.path) == 0 || errno == ENOENT else {
      throw OrganizerKeyStoreError.unreadable
    }
  }
}

/// In memory, for tests and previews.
public final class MemoryPhoneSealKeyStore: PhoneSealKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: Curve25519.KeyAgreement.PrivateKey?
  public var failLoads = false

  public init(key: Curve25519.KeyAgreement.PrivateKey? = nil) {
    self.key = key
  }

  public var stored: Curve25519.KeyAgreement.PrivateKey? { lock.withLock { key } }

  public func load() throws -> Curve25519.KeyAgreement.PrivateKey? {
    try lock.withLock {
      if failLoads { throw OrganizerKeyStoreError.unreadable }
      return key
    }
  }

  public func save(_ key: Curve25519.KeyAgreement.PrivateKey) throws {
    lock.withLock { self.key = key }
  }

  public func delete() throws { lock.withLock { key = nil } }
}
