import CryptoKit
import Foundation
import MindloomLink
import MindloomPhoneKit
import Observation
import Security

/// The phone's SSH key in the Keychain (PHONE-CONTRACT §4). Only the app
/// reads it; the extensions never need it. Available after first unlock so
/// a background refresh can send, and never synced or backed up to another
/// device.
struct PhoneKeyKeychain: Sendable {
  var service = "com.bestasr.phone.pairing"
  var account = "phone-key"

  enum KeychainError: Error, Equatable {
    case status(OSStatus)
  }

  func save(_ key: Data) throws {
    let query = baseQuery
    SecItemDelete(query as CFDictionary)
    var attributes = query
    attributes[kSecValueData as String] = key
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError.status(status) }
  }

  func load() -> Data? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  func delete() {
    SecItemDelete(baseQuery as CFDictionary)
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}

/// Pairing on the phone: the private key goes to the Keychain, the rest
/// (`PairingRecord`, no secrets) to the App Group so the keyboard and the
/// share extension can seal to the Mac. Pairing again replaces both.
@MainActor
@Observable
final class PairingModel {
  private(set) var record: PairingRecord?

  let recordStore: PairingRecordStore
  let keychain: PhoneKeyKeychain

  init(recordStore: PairingRecordStore, keychain: PhoneKeyKeychain = PhoneKeyKeychain()) {
    self.recordStore = recordStore
    self.keychain = keychain
    reload()
  }

  var isPaired: Bool { record != nil }

  func reload() {
    // A record without its key (for example after a restore to a new
    // phone, where the key does not follow) is not a pairing.
    guard let record = recordStore.read(), keychain.load() != nil else {
      self.record = nil
      return
    }
    self.record = record
  }

  /// Validates the scanned or pasted `mlpair1.` text and stores it.
  @discardableResult
  func pair(text: String) throws -> PairingRecord {
    let payload = try PairingPayload.decode(text: text)
    try keychain.save(payload.phoneKey)
    do {
      try recordStore.write(payload.record)
    } catch {
      keychain.delete()
      throw error
    }
    record = payload.record
    return payload.record
  }

  /// Forgets the pairing on this phone. The Mac's "断开 iPhone" is what
  /// revokes the key on the Spark.
  func unpair() {
    keychain.delete()
    try? recordStore.remove()
    record = nil
  }

  /// The SSH signing key, for the sender.
  func signingKey() -> Curve25519.Signing.PrivateKey? {
    guard let raw = keychain.load() else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
  }

  /// Plain words for a pairing text that was refused.
  static func message(for error: Error) -> String {
    guard let error = error as? PairingPayload.PairingError else {
      return "没能保存配对，请再试一次"
    }
    switch error {
    case .notAPairingCode: return "这不是织机的配对码"
    case .malformed: return "配对码不完整，请在 Mac 上重新复制"
    case .unsupportedVersion: return "这个配对码来自更新版本的织机，请先更新手机上的织机"
    case .invalidHostKey:
      return "配对码里缺少 Spark 的身份，无法确认连接对象。请在 Mac 上重新生成"
    default: return "配对码无效，请在 Mac 上重新生成"
    }
  }
}
