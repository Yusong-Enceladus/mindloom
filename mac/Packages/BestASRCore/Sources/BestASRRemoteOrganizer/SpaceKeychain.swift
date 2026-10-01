import BestASRDomain
import CryptoKit
import Darwin
import Foundation
import MindloomSpaces
import Security

/// Where one library keeps its shared spaces (SPACES-CONTRACT §3): the
/// spaces' state files under `<root>/spaces/` (members' shared content,
/// never sent anywhere), and the secrets — the device's Ed25519 signing key
/// and every unwrapped space key — in the login Keychain, this Mac only.
/// The device's X25519 seal key is the library's phone seal key.
///
/// A root marked `SYNTHETIC_DATA_ROOT` (tests and end-to-end runs, never the
/// owner's real library) may keep the secrets in 0600 files instead.
public struct SpaceStores: Sendable {
  public let states: any SpaceStateStore
  public let keys: any SpaceKeyStore
  public let device: any SpaceDeviceStore
  /// This Mac's own access to the team Spark (v8 B1): its credential and key.
  public let access: any MemberAccessStore
  /// What this Mac still has to deliver to its spaces (v8 C3), on disk.
  public let outbox: any SpaceOutboxStore
  /// A private 0700 folder for ssh's known_hosts and short-lived key files.
  public let gateDirectory: URL?

  public init(
    states: any SpaceStateStore, keys: any SpaceKeyStore, device: any SpaceDeviceStore,
    access: any MemberAccessStore = MemoryMemberAccessStore(),
    outbox: any SpaceOutboxStore = MemorySpaceOutboxStore(), gateDirectory: URL? = nil
  ) {
    self.states = states
    self.keys = keys
    self.device = device
    self.access = access
    self.outbox = outbox
    self.gateDirectory = gateDirectory
  }

  /// The Keychain stores of a library (the App).
  public static func keychain(dataRoot: URL, sealKeys: any PhoneSealKeyStore) -> SpaceStores {
    let account = OrganizerDataRootIdentity.hash(of: dataRoot)
    let spaces = dataRoot.appendingPathComponent("spaces")
    return SpaceStores(
      states: FileSpaceStateStore(directory: spaces),
      keys: KeychainSpaceKeyStore(account: account),
      device: KeychainSpaceDeviceStore(account: account, sealKeys: sealKeys),
      access: KeychainMemberAccessStore(account: account),
      outbox: FileSpaceOutboxStore(directory: spaces),
      gateDirectory: dataRoot.appendingPathComponent("team-gate", isDirectory: true))
  }

  /// File stores for a synthetic root only (refused anywhere else).
  public static func synthetic(
    dataRoot: URL, realLibraryRoot: URL? = BestASRDataRootSelection.ownerRealLibraryRoot()
  ) throws -> SpaceStores {
    let root = dataRoot.standardizedFileURL
    let allowed: @Sendable () -> Bool = {
      guard let realLibraryRoot,
        !BestASRDataRootSelection.path(root, isWithinOrEqualTo: realLibraryRoot)
      else { return false }
      var entry = stat()
      let marker = root.appendingPathComponent(
        RemoteOrganizerDataProvenance.syntheticMarkerFileName)
      return lstat(marker.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFREG
    }
    let secrets = try FileSpaceSecretStore(
      directory: root.appendingPathComponent("space-keys", isDirectory: true), allowed: allowed)
    let spaces = root.appendingPathComponent("spaces")
    return SpaceStores(
      states: FileSpaceStateStore(directory: spaces), keys: secrets, device: secrets,
      access: FileMemberAccessStore(secrets: secrets),
      outbox: FileSpaceOutboxStore(directory: spaces),
      gateDirectory: root.appendingPathComponent("team-gate", isDirectory: true))
  }

  /// This Mac's device keys, made on first use (a new id and signing key next
  /// to the library's seal key).
  public func loadOrCreateDevice(
    sealKey: () throws -> Curve25519.KeyAgreement.PrivateKey = { .init() }
  ) throws -> SpaceDeviceKeys {
    if let keys = try device.load() { return keys }
    let keys = SpaceDeviceKeys.generate(sealKey: try sealKey())
    try device.save(keys)
    guard let stored = try device.load(), stored.deviceID == keys.deviceID else {
      throw SpaceStoreError.unreadable
    }
    return stored
  }
}

/// Space keys as one generic password per space: service
/// `com.bestasr.space-key`, account `<root hash>|<space id>`, the value a
/// JSON map epoch → hex key; this device only, never synchronized.
public struct KeychainSpaceKeyStore: SpaceKeyStore {
  public static let service = "com.bestasr.space-key"
  public let account: String

  public init(account: String) { self.account = account }

  private func query(_ spaceID: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
      kSecAttrAccount: "\(account)|\(spaceID.lowercased())",
    ]
  }

  public func keys(_ spaceID: String) throws -> [Int: Data] {
    var request = query(spaceID)
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return [:] }
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
    guard let data = result as? Data,
      let map = try? JSONDecoder().decode([String: String].self, from: data)
    else { throw OrganizerKeyStoreError.unreadable }
    var keys: [Int: Data] = [:]
    for (epoch, hex) in map {
      guard let e = Int(epoch), let key = Data(spaceHex: hex), key.count == 32 else {
        throw OrganizerKeyStoreError.unreadable
      }
      keys[e] = key
    }
    return keys
  }

  public func save(_ key: Data, space spaceID: String, epoch: Int) throws {
    var all = try keys(spaceID)
    all[epoch] = key
    let map = Dictionary(uniqueKeysWithValues: all.map { ("\($0.key)", SpaceCrypto.hex($0.value)) })
    try delete(spaceID)
    var item = query(spaceID)
    item[kSecValueData] = try JSONEncoder().encode(map)
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom shared space key"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
  }

  public func delete(_ spaceID: String) throws {
    let status = SecItemDelete(query(spaceID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OrganizerKeyStoreError.keychain(status)
    }
  }
}

/// The device's signing key and id: service `com.bestasr.space-device-key`,
/// account = the root hash. Its seal key is the library's phone seal key.
public struct KeychainSpaceDeviceStore: SpaceDeviceStore {
  public static let service = "com.bestasr.space-device-key"
  public let account: String
  private let sealKeys: any PhoneSealKeyStore

  public init(account: String, sealKeys: any PhoneSealKeyStore) {
    self.account = account
    self.sealKeys = sealKeys
  }

  private var query: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: account]
  }

  public func load() throws -> SpaceDeviceKeys? {
    var request = query
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
    guard let data = result as? Data,
      let record = try? JSONDecoder().decode([String: String].self, from: data),
      let id = record["device_id"], SpaceID.isValid(id),
      let raw = record["sign_priv"].flatMap({ Data(spaceHex: $0) }),
      let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { throw OrganizerKeyStoreError.unreadable }
    return SpaceDeviceKeys(deviceID: id, signingKey: signing, sealKey: try sealKeys.loadOrCreate())
  }

  public func save(_ keys: SpaceDeviceKeys) throws {
    if try sealKeys.load()?.rawRepresentation != keys.sealKey.rawRepresentation {
      try sealKeys.save(keys.sealKey)
    }
    let record = [
      "device_id": keys.deviceID, "sign_priv": SpaceCrypto.hex(keys.signingKey.rawRepresentation),
    ]
    _ = SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData] = try JSONEncoder().encode(record)
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom space device key"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
  }
}

/// This Mac's own access record to the team Spark (credential, the seed of
/// its SSH key, the route): service `com.bestasr.member-access`, account =
/// the root hash; this device only, never synchronized.
public struct KeychainMemberAccessStore: MemberAccessStore {
  public static let service = "com.bestasr.member-access"
  public let account: String

  public init(account: String) { self.account = account }

  private var query: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: account]
  }

  public func load() throws -> MemberAccessRecord? {
    var request = query
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OrganizerKeyStoreError.keychain(status) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let data = result as? Data,
      let record = try? decoder.decode(MemberAccessRecord.self, from: data)
    else { throw OrganizerKeyStoreError.unreadable }
    return record
  }

  public func save(_ record: MemberAccessRecord) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    _ = SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData] = try encoder.encode(record)
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom team access"
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
