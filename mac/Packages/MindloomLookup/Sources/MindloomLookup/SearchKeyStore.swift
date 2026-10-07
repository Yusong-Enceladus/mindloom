import Foundation
import MindloomIdentity
import Security

/// Where search keys live: the owner pastes a key once; it is never in the
/// library, an export, a backup, a file or a log (PRD SETUP-003).
public protocol SearchKeyStore: Sendable {
  func key(for service: SearchServiceID) -> String?
  func save(_ key: String, for service: SearchServiceID) throws
  func remove(_ service: SearchServiceID) throws
  /// The stored key follows the owner's iCloud Keychain to their devices.
  func syncsAcrossDevices(_ service: SearchServiceID) -> Bool
}

public enum SearchKeyStoreError: Error, Equatable, Sendable {
  case keychain(OSStatus)
  case notAKey
}

/// One generic password per service in the Keychain: service
/// `app.mindloom.lookup`, account = the service's name, readable after
/// the first unlock (background lookups), synchronizable so iCloud Keychain
/// carries it to the owner's Mac and iPhone (end-to-end encrypted).
///
/// A synchronizable item needs the data-protection keychain, which needs a
/// keychain-access-group entitlement. Where the App has none (a Mac build
/// signed without one), the key is kept in the login keychain on this Mac
/// only, and `syncsAcrossDevices` says so.
public struct KeychainSearchKeyStore: SearchKeyStore {
  public static let defaultService = MindloomIdentity.keychainService("lookup")
  public let keychainService: String
  /// False keeps new items on this device (the tests: nothing reaches the
  /// owner's iCloud Keychain).
  public let synchronizable: Bool

  public init(keychainService: String = KeychainSearchKeyStore.defaultService, synchronizable: Bool = true) {
    self.keychainService = keychainService
    self.synchronizable = synchronizable
  }

  private func query(_ service: SearchServiceID, dataProtection: Bool) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: keychainService,
      kSecAttrAccount: service.rawValue,
    ]
    if dataProtection {
      query[kSecUseDataProtectionKeychain] = true
      query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
    }
    return query
  }

  private func read(_ service: SearchServiceID, dataProtection: Bool) -> (String, Bool)? {
    var request = query(service, dataProtection: dataProtection)
    request[kSecReturnData] = true
    request[kSecReturnAttributes] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
      let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data,
      let key = String(data: data, encoding: .utf8)
    else { return nil }
    let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false
    return (key, synchronizable)
  }

  public func key(for service: SearchServiceID) -> String? {
    if let found = read(service, dataProtection: true) { return found.0 }
    #if os(macOS)
      if let found = read(service, dataProtection: false) { return found.0 }
    #endif
    return nil
  }

  public func syncsAcrossDevices(_ service: SearchServiceID) -> Bool {
    read(service, dataProtection: true)?.1 ?? false
  }

  public func save(_ key: String, for service: SearchServiceID) throws {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SearchServiceID.isPlausibleKey(key) else { throw SearchKeyStoreError.notAKey }
    try remove(service)
    var item = query(service, dataProtection: false)
    item[kSecValueData] = Data(key.utf8)
    item[kSecAttrLabel] = "Mindloom search key (\(service.rawValue))"
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
    var synced = item
    synced[kSecUseDataProtectionKeychain] = true
    synced[kSecAttrSynchronizable] = synchronizable
    let status = SecItemAdd(synced as CFDictionary, nil)
    if status == errSecSuccess { return }
    #if os(macOS)
      if status == errSecMissingEntitlement {
        item[kSecAttrSynchronizable] = false
        let local = SecItemAdd(item as CFDictionary, nil)
        guard local == errSecSuccess else { throw SearchKeyStoreError.keychain(local) }
        return
      }
    #endif
    throw SearchKeyStoreError.keychain(status)
  }

  public func remove(_ service: SearchServiceID) throws {
    let status = SecItemDelete(query(service, dataProtection: true) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
      throw SearchKeyStoreError.keychain(status)
    }
    #if os(macOS)
      let local = SecItemDelete(query(service, dataProtection: false) as CFDictionary)
      guard local == errSecSuccess || local == errSecItemNotFound else {
        throw SearchKeyStoreError.keychain(local)
      }
    #endif
  }
}

/// Keys in memory (tests, the dry run).
public final class InMemorySearchKeyStore: SearchKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [SearchServiceID: String]

  public init(_ keys: [SearchServiceID: String] = [:]) {
    self.keys = keys
  }

  public func key(for service: SearchServiceID) -> String? { lock.withLock { keys[service] } }

  public func save(_ key: String, for service: SearchServiceID) throws {
    guard SearchServiceID.isPlausibleKey(key) else { throw SearchKeyStoreError.notAKey }
    lock.withLock { keys[service] = key.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  public func remove(_ service: SearchServiceID) throws { lock.withLock { keys[service] = nil } }

  public func syncsAcrossDevices(_ service: SearchServiceID) -> Bool { false }
}

/// Keys in a 0600 file inside a data root marked `SYNTHETIC_DATA_ROOT`: the
/// check and Preview builds on a synthetic clone use this instead of the
/// Keychain, so they never read, replace or delete the owner's item
/// (`app.mindloom.lookup`). The file lives in the lookup folder; it is
/// refused on any other root.
public final class SyntheticSearchKeyStore: SearchKeyStore, @unchecked Sendable {
  public static let markerFileName = "SYNTHETIC_DATA_ROOT"
  public let file: URL
  private let lock = NSLock()

  /// Nil unless `dataRoot` holds the marker as a regular file.
  public init?(dataRoot: URL) {
    var entry = stat()
    let marker = dataRoot.appendingPathComponent(Self.markerFileName)
    guard lstat(marker.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else { return nil }
    file = LookupFolder(dataRoot: dataRoot).url.appendingPathComponent("search-keys.test")
  }

  private func load() -> [String: String] {
    PrivateFiles.readJSON([String: String].self, from: file, maximumBytes: 64 * 1024) ?? [:]
  }

  public func key(for service: SearchServiceID) -> String? { lock.withLock { load()[service.rawValue] } }

  public func save(_ key: String, for service: SearchServiceID) throws {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SearchServiceID.isPlausibleKey(key) else { throw SearchKeyStoreError.notAKey }
    try lock.withLock {
      var keys = load()
      keys[service.rawValue] = key
      try PrivateFiles.writeJSON(keys, to: file)
    }
  }

  public func remove(_ service: SearchServiceID) throws {
    try lock.withLock {
      var keys = load()
      guard keys.removeValue(forKey: service.rawValue) != nil else { return }
      try PrivateFiles.writeJSON(keys, to: file)
    }
  }

  public func syncsAcrossDevices(_ service: SearchServiceID) -> Bool { false }
}

/// Which store a running build uses. Only the owner's own library, in the
/// shipped identity, reaches the Keychain item; a synthetic root uses a file
/// inside it, and any other check or Preview identity keeps keys in memory.
public enum SearchKeyStores {
  public static func make(
    dataRoot: URL, isOwnersLibrary: Bool, bundleIdentifier: String?
  ) -> any SearchKeyStore {
    if !isOwnersLibrary, let synthetic = SyntheticSearchKeyStore(dataRoot: dataRoot) {
      return synthetic
    }
    if !isOwnersLibrary || isVerificationIdentity(bundleIdentifier) {
      return InMemorySearchKeyStore()
    }
    return KeychainSearchKeyStore()
  }

  /// The check App and the preview carry their own bundle ids; the owner's
  /// keychain item is for `app.mindloom` and `app.mindloom.debug`.
  static func isVerificationIdentity(_ identifier: String?) -> Bool {
    guard let identifier else { return false }
    return MindloomIdentity.isCheckIdentity(identifier)
      || identifier.hasPrefix("com.bestasr.mindloom.preview")
  }
}
