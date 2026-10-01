import BestASRRemoteOrganizer
import CryptoKit
import Darwin
import Foundation
import Security

/// Where each grant's secret lives (AGENT-CONTRACT §2: "a per-client secret
/// in the Keychain"). The secret signs the grant's row in the library (a row
/// edited there, or one whose secret is gone, is no grant) and keys the
/// client's placeholders, so two agents never see the same placeholder for
/// the same number, and a new grant gets new placeholders.
public protocol AgentGrantSecretStore: Sendable {
  func secret(for grantID: UUID) throws -> Data?
  func save(_ secret: Data, for grantID: UUID) throws
  /// Must not throw when there is none.
  func delete(for grantID: UUID) throws
}

public enum AgentGrantSecretError: Error, Equatable, Sendable {
  case notASyntheticRoot
  case unreadable
  case keychain(OSStatus)
}

public enum AgentGrantSecret {
  public static let byteCount = 32

  public static func random() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
      throw AgentGrantSecretError.unreadable
    }
    return Data(bytes)
  }

  /// `hex(HMAC-SHA256(secret, canonical record))`.
  public static func mac(_ text: String, secret: Data) -> String {
    let code = HMAC<SHA256>.authenticationCode(
      for: Data(text.utf8), using: SymmetricKey(data: secret))
    return Data(code).map { String(format: "%02x", $0) }.joined()
  }

  /// The client's placeholder key: `HMAC-SHA256(secret, "mindloom-agent-mask-v1")`.
  public static func maskKey(secret: Data) -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: Data("mindloom-agent-mask-v1".utf8), using: SymmetricKey(data: secret)))
  }
}

/// Generic passwords in the login Keychain: service `com.bestasr.agent-grant`,
/// account = the data root's identity hash + ":" + the grant ID, this device
/// only (never synchronized).
public struct KeychainAgentGrantSecretStore: AgentGrantSecretStore {
  public static let service = "com.bestasr.agent-grant"
  public let rootIdentity: String

  public init(dataRoot: URL) {
    rootIdentity = OrganizerDataRootIdentity.hash(of: dataRoot)
  }

  private func query(_ grantID: UUID) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: "\(rootIdentity):\(grantID.uuidString.lowercased())",
    ]
  }

  public func secret(for grantID: UUID) throws -> Data? {
    var request = query(grantID)
    request[kSecReturnData] = true
    request[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw AgentGrantSecretError.keychain(status) }
    guard let data = result as? Data, data.count == AgentGrantSecret.byteCount else {
      throw AgentGrantSecretError.unreadable
    }
    return data
  }

  public func save(_ secret: Data, for grantID: UUID) throws {
    try delete(for: grantID)
    var item = query(grantID)
    item[kSecValueData] = secret
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecAttrSynchronizable] = false
    item[kSecAttrLabel] = "Mindloom agent grant"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw AgentGrantSecretError.keychain(status) }
  }

  public func delete(for grantID: UUID) throws {
    let status = SecItemDelete(query(grantID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AgentGrantSecretError.keychain(status)
    }
  }
}

/// 0600 files in `<root>/agent/grants/`, allowed only for a root marked
/// `SYNTHETIC_DATA_ROOT` that is not the owner's real library: tests and the
/// end-to-end harness use it; the real library never can.
public struct FileAgentGrantSecretStore: AgentGrantSecretStore {
  public let dataRoot: URL
  private let realLibraryRoot: URL?

  public init(
    dataRoot: URL, realLibraryRoot: URL? = BestASRDataRootSelection.ownerRealLibraryRoot()
  ) throws {
    self.dataRoot = dataRoot.standardizedFileURL
    self.realLibraryRoot = realLibraryRoot
    try checkRoot()
  }

  private var folder: URL {
    dataRoot.appendingPathComponent("agent/grants", isDirectory: true)
  }

  private func url(_ grantID: UUID) -> URL {
    folder.appendingPathComponent(grantID.uuidString.lowercased() + ".key")
  }

  private func checkRoot() throws {
    guard let realLibraryRoot,
      !BestASRDataRootSelection.path(dataRoot, isWithinOrEqualTo: realLibraryRoot)
    else { throw AgentGrantSecretError.notASyntheticRoot }
    var entry = stat()
    let marker = dataRoot.appendingPathComponent(
      RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    guard lstat(marker.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else {
      throw AgentGrantSecretError.notASyntheticRoot
    }
  }

  public func secret(for grantID: UUID) throws -> Data? {
    try checkRoot()
    let descriptor = open(url(grantID).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw AgentGrantSecretError.unreadable
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1, status.st_mode & 0o077 == 0
    else { throw AgentGrantSecretError.unreadable }
    let data = try handle.read(upToCount: 64) ?? Data()
    guard data.count == AgentGrantSecret.byteCount else { throw AgentGrantSecretError.unreadable }
    return data
  }

  public func save(_ secret: Data, for grantID: UUID) throws {
    try checkRoot()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try delete(for: grantID)
    let descriptor = open(
      url(grantID).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw AgentGrantSecretError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw AgentGrantSecretError.unreadable }
    try handle.write(contentsOf: secret)
    try handle.synchronize()
  }

  public func delete(for grantID: UUID) throws {
    guard unlink(url(grantID).path) == 0 || errno == ENOENT else {
      throw AgentGrantSecretError.unreadable
    }
  }
}

/// In memory, for tests.
public final class MemoryAgentGrantSecretStore: AgentGrantSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var secrets: [UUID: Data] = [:]
  public var failReads = false

  public init() {}

  public var count: Int { lock.withLock { secrets.count } }

  public func secret(for grantID: UUID) throws -> Data? {
    try lock.withLock {
      if failReads { throw AgentGrantSecretError.unreadable }
      return secrets[grantID]
    }
  }

  public func save(_ secret: Data, for grantID: UUID) throws {
    lock.withLock { secrets[grantID] = secret }
  }

  public func delete(for grantID: UUID) throws {
    lock.withLock { secrets[grantID] = nil }
  }
}
