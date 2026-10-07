import Foundation
import Security

/// Generic passwords in the login keychain, or in one keychain file (the dry
/// run's temporary keychain), never asking: a read that would need the
/// keychain password or a confirmation fails instead (`nil`).
public final class SystemCarryOverKeychain: CarryOverKeychain {
  private let keychain: SecKeychain?

  /// `file`: a keychain file to use instead of the login keychain (dry runs);
  /// it must already be unlocked.
  public init(file: URL? = nil) throws {
    guard let file else {
      keychain = nil
      return
    }
    var opened: SecKeychain?
    let status = file.path.withCString { SecKeychainOpen($0, &opened) }
    guard status == errSecSuccess, let opened else { throw CarryOverError.keychain(status) }
    var keychainStatus = SecKeychainStatus()
    guard SecKeychainGetStatus(opened, &keychainStatus) == errSecSuccess,
      keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) != 0
    else { throw CarryOverError.keychainLocked }
    keychain = opened
  }

  /// Runs `body` with keychain dialogs off for this process, then puts the
  /// setting back as it was.
  private func quietly<T>(_ body: () -> T) -> T {
    var allowed: DarwinBoolean = true
    let known = SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess
    SecKeychainSetUserInteractionAllowed(false)
    defer { if known { SecKeychainSetUserInteractionAllowed(allowed.boolValue) } }
    return body()
  }

  private func base(service: String, account: String? = nil) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
    ]
    if let account { query[kSecAttrAccount] = account }
    if let keychain { query[kSecMatchSearchList] = [keychain] }
    return query
  }

  public func accounts(service: String) -> [String] {
    var query = base(service: service)
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitAll
    var result: CFTypeRef?
    guard quietly({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess,
      let items = result as? [[String: Any]]
    else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  public func read(service: String, account: String) -> Data? {
    var query = base(service: service, account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard quietly({ SecItemCopyMatching(query as CFDictionary, &result) }) == errSecSuccess else {
      return nil
    }
    return result as? Data
  }

  public func exists(service: String, account: String) -> Bool? {
    var query = base(service: service, account: account)
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    switch quietly({ SecItemCopyMatching(query as CFDictionary, &result) }) {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: return nil
    }
  }

  public func add(service: String, account: String, label: String, value: Data) -> Bool {
    var item: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrLabel: label,
      kSecValueData: value,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable: false,
    ]
    if let keychain { item[kSecUseKeychain] = keychain }
    return quietly { SecItemAdd(item as CFDictionary, nil) } == errSecSuccess
  }
}
