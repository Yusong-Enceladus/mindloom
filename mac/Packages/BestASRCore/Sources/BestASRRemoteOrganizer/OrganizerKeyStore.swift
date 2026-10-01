import BestASRDomain
import Darwin
import Foundation
import Security

/// Where one library's organizing-link key lives (privacy contract §1). The
/// key never leaves the Mac except into the organizing device's memory
/// through the user's own SSH forward (`POST /v1/unlock`).
public protocol OrganizerKeyStore: Sendable {
  /// The stored key, or nil when there is none yet.
  func load() throws -> OrganizerKeyMaterial?
  func save(_ keys: OrganizerKeyMaterial) throws
  /// Must not throw when there is no key.
  func delete() throws
}

extension OrganizerKeyStore {
  /// The stored key, or a new random one saved first (the first enable, or
  /// the first enable after "让 Spark 忘掉我的内容" destroyed the old one).
  public func loadOrCreate() throws -> OrganizerKeyMaterial {
    if let keys = try load() { return keys }
    let keys = try OrganizerKeyMaterial.random()
    try save(keys)
    guard let stored = try load(), stored == keys else { throw OrganizerKeyStoreError.unreadable }
    return stored
  }
}

public enum OrganizerKeyStoreError: Error, Equatable, Sendable {
  /// The file store is only for roots marked `SYNTHETIC_DATA_ROOT`.
  case notASyntheticRoot
  case unreadable
  case keychain(OSStatus)
}

/// The identity of a data root shared by the link's "on" marker and the
/// key's Keychain account: the kernel's canonical path of the root, hashed.
public enum OrganizerDataRootIdentity {
  public static func hash(of dataRoot: URL) -> String {
    RemoteOrganizerLinkIntentFile.rootIdentity(dataRoot)
  }
}

/// The key as a generic password in the user's login Keychain: service
/// `com.bestasr.organizer-key`, account = the data root's identity hash,
/// this device only (never synchronized).
public struct KeychainOrganizerKeyStore: OrganizerKeyStore {
  public static let service = "com.bestasr.organizer-key"

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

  public func load() throws -> OrganizerKeyMaterial? {
    var request = query
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
    guard let data = result as? Data, let keys = try? OrganizerKeyMaterial(libraryKey: data) else {
      throw OrganizerKeyStoreError.unreadable
    }
    return keys
  }

  public func save(_ keys: OrganizerKeyMaterial) throws {
    try delete()
    var item = query
    item[kSecValueData] = keys.libraryKey
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom organizer key"
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

/// The key as a 0600 file inside the data root. Allowed only for a root
/// marked `SYNTHETIC_DATA_ROOT` that is not the owner's real library: tests
/// and end-to-end runs use it; the real library never can.
public struct FileOrganizerKeyStore: OrganizerKeyStore {
  public static let fileName = "organizer-link.key"

  public let dataRoot: URL
  private let realLibraryRoot: URL?

  public init(
    dataRoot: URL, realLibraryRoot: URL? = BestASRDataRootSelection.ownerRealLibraryRoot()
  )
    throws
  {
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

  public func load() throws -> OrganizerKeyMaterial? {
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
    let data = try handle.read(upToCount: 64) ?? Data()
    guard let keys = try? OrganizerKeyMaterial(libraryKey: data) else {
      throw OrganizerKeyStoreError.unreadable
    }
    return keys
  }

  public func save(_ keys: OrganizerKeyMaterial) throws {
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
    try handle.write(contentsOf: keys.libraryKey)
    try handle.synchronize()
  }

  public func delete() throws {
    guard unlink(url.path) == 0 || errno == ENOENT else {
      throw OrganizerKeyStoreError.unreadable
    }
  }
}

/// In memory, for tests and previews.
public final class MemoryOrganizerKeyStore: OrganizerKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: OrganizerKeyMaterial?
  public var failLoads = false
  /// Tests: deleting and saving fail (a key store that refuses writes).
  public var failWrites = false

  public init(keys: OrganizerKeyMaterial? = nil) {
    self.keys = keys
  }

  public var stored: OrganizerKeyMaterial? { lock.withLock { keys } }

  public func load() throws -> OrganizerKeyMaterial? {
    try lock.withLock {
      if failLoads { throw OrganizerKeyStoreError.unreadable }
      return keys
    }
  }

  public func save(_ keys: OrganizerKeyMaterial) throws {
    try lock.withLock {
      if failWrites { throw OrganizerKeyStoreError.unreadable }
      self.keys = keys
    }
  }

  public func delete() throws {
    try lock.withLock {
      if failWrites { throw OrganizerKeyStoreError.unreadable }
      keys = nil
    }
  }
}
