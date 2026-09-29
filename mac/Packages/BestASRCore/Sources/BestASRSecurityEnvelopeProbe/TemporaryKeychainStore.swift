import Foundation
import Security

public enum KeychainProbeError: Error, Equatable, Sendable {
  case keyMissing
  case unexpectedData
  case unexpectedStatus(OSStatus)
}

public final class TemporaryKeychainStore {
  private let keychain: SecKeychain

  public init(url: URL, password: String) throws {
    var createdKeychain: SecKeychain?
    let passwordLength = UInt32(password.lengthOfBytes(using: .utf8))
    let status = url.path.withCString { pathPointer in
      password.withCString { passwordPointer in
        SecKeychainCreate(
          pathPointer,
          passwordLength,
          passwordPointer,
          false,
          nil,
          &createdKeychain
        )
      }
    }
    guard status == errSecSuccess, let createdKeychain else {
      throw KeychainProbeError.unexpectedStatus(status)
    }
    keychain = createdKeychain
  }

  public func store(_ data: Data, service: String, account: String) throws {
    _ = try? delete(service: service, account: account)
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData: data,
      kSecUseKeychain: keychain,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainProbeError.unexpectedStatus(status)
    }
  }

  public func load(service: String, account: String) throws -> Data {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecMatchSearchList: [keychain],
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      throw KeychainProbeError.keyMissing
    }
    guard status == errSecSuccess else {
      throw KeychainProbeError.unexpectedStatus(status)
    }
    guard let data = result as? Data else {
      throw KeychainProbeError.unexpectedData
    }
    return data
  }

  @discardableResult
  public func delete(service: String, account: String) throws -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecMatchSearchList: [keychain],
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound {
      return false
    }
    guard status == errSecSuccess else {
      throw KeychainProbeError.unexpectedStatus(status)
    }
    return true
  }

  public func destroy() throws {
    let status = SecKeychainDelete(keychain)
    guard status == errSecSuccess else {
      throw KeychainProbeError.unexpectedStatus(status)
    }
  }
}
