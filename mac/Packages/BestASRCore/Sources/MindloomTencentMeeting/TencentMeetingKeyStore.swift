import BestASRRemoteOrganizer
import Darwin
import Foundation
import MindloomIdentity
import Security

/// Where Mindloom keeps the 32-byte master key that encrypts tmeet's login
/// on this Mac (patch 0003): a generic password in the login Keychain,
/// service `app.mindloom.tencent-meeting`, account = the library's identity
/// hash, this device only, never synchronized. Mindloom created it, so other
/// programs cannot read it without the owner's approval (upstream tmeet
/// writes its key through `/usr/bin/security`, which any program running as
/// the owner can read silently).
public protocol TencentMeetingKeyStore: Sendable {
  func key() throws -> Data?
  func save(_ key: Data) throws
  /// Must not throw when there is none.
  func delete() throws
}

public enum TencentMeetingKeyError: Error, Equatable, Sendable {
  case notASyntheticRoot
  case unreadable
  case keychain(OSStatus)
}

extension TencentMeetingKeyStore {
  /// The key, made on first use.
  public func existingOrNewKey() throws -> Data {
    if let key = try key() { return key }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw TencentMeetingKeyError.unreadable
    }
    let key = Data(bytes)
    try save(key)
    return key
  }
}

public struct KeychainTencentMeetingKeyStore: TencentMeetingKeyStore {
  public static let service = MindloomIdentity.keychainService("tencent-meeting")
  public let account: String

  public init(dataRoot: URL) {
    account = OrganizerDataRootIdentity.hash(of: dataRoot)
  }

  private var query: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: account,
    ]
  }

  public func key() throws -> Data? {
    var request = query
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw TencentMeetingKeyError.keychain(status) }
    guard let data = result as? Data, data.count == 32 else {
      throw TencentMeetingKeyError.unreadable
    }
    return data
  }

  public func save(_ key: Data) throws {
    guard key.count == 32 else { throw TencentMeetingKeyError.unreadable }
    try delete()
    var item = query
    item[kSecValueData] = key
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom Tencent Meeting"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw TencentMeetingKeyError.keychain(status) }
  }

  public func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TencentMeetingKeyError.keychain(status)
    }
  }
}

/// A 0600 file inside a data root marked `SYNTHETIC_DATA_ROOT` (and not the
/// owner's real library): tests and development harnesses only.
public struct SyntheticTencentMeetingKeyStore: TencentMeetingKeyStore {
  public let file: URL

  public init(
    dataRoot: URL, realLibraryRoot: URL? = BestASRDataRootSelection.ownerRealLibraryRoot()
  ) throws {
    let root = dataRoot.standardizedFileURL
    guard let realLibraryRoot,
      !BestASRDataRootSelection.path(root, isWithinOrEqualTo: realLibraryRoot)
    else { throw TencentMeetingKeyError.notASyntheticRoot }
    var entry = stat()
    let marker = root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    guard lstat(marker.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else {
      throw TencentMeetingKeyError.notASyntheticRoot
    }
    file = root.appendingPathComponent("entries/tencent-meeting-key.test")
  }

  public func key() throws -> Data? {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw TencentMeetingKeyError.unreadable
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let data = try handle.read(upToCount: 64) ?? Data()
    guard data.count == 32 else { throw TencentMeetingKeyError.unreadable }
    return data
  }

  public func save(_ key: Data) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    unlink(file.path)
    let descriptor = open(
      file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw TencentMeetingKeyError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: key)
  }

  public func delete() throws {
    guard unlink(file.path) == 0 || errno == ENOENT else { throw TencentMeetingKeyError.unreadable }
  }
}
