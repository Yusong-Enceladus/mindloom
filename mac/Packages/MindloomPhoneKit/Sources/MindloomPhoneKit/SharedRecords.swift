import Darwin
import Foundation
import Security
import notify

/// Small named records the app and its extensions share: the voice state, partials and finals,
/// the keyboard's acknowledgements, what the keyboard last saw of itself.
///
/// Two places can hold them (PHONE-SPEC §1 App Group, IOS-CODE-MAP §3b):
/// - `FileRecords`: JSON files in the App Group container (`group.app.mindloom`).
/// - `KeychainRecords`: generic-password items in a shared keychain access group
///   (`<team>.app.mindloom.shared`), for a build signed without the App Group (a free
///   Personal Team whose profiles carry no group). Darwin notifications carry the signals in
///   both cases.
///
/// Records are tiny (a few KB at most) and transient: transcripts sit here only until the
/// keyboard has inserted them. Audio is never written anywhere.
public protocol SharedRecords: AnyObject, Sendable {
  /// True for the App Group container (files); false for the keychain fallback.
  var isAppGroup: Bool { get }
  func read(_ name: String) -> Data?
  func write(_ data: Data, as name: String) throws
  func remove(_ name: String)
}

extension SharedRecords {
  public func readJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
    guard let data = read(name) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  public func writeJSON<T: Encodable>(_ value: T, as name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try write(try encoder.encode(value), as: name)
  }
}

/// `<directory>/<name>.json`, written atomically, protected until first unlock, excluded from
/// backups.
public final class FileRecords: SharedRecords, @unchecked Sendable {
  public let directory: URL
  public var isAppGroup: Bool { true }

  public init(directory: URL, fileManager: FileManager = .default) throws {
    self.directory = directory
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mutable = directory
    try? mutable.setResourceValues(excluded)
  }

  public func url(_ name: String) -> URL {
    directory.appendingPathComponent(name + ".json", isDirectory: false)
  }

  public func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

  public func write(_ data: Data, as name: String) throws {
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: url(name), options: options)
  }

  public func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
}

/// Generic-password items in one keychain access group, available after first unlock and
/// never synced or backed up to another device. Used only when the App Group is missing.
public final class KeychainRecords: SharedRecords, @unchecked Sendable {
  public enum KeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
  }

  public let accessGroup: String?
  public let service: String
  public var isAppGroup: Bool { false }

  /// - Parameters: accessGroup = `<team>.app.mindloom.shared` (nil = the process's default
  ///   group, for tests); service = the record family.
  public init(accessGroup: String?, service: String = PhoneNames.linkService) {
    self.accessGroup = accessGroup
    self.service = service
  }

  public func read(_ name: String) -> Data? {
    var query = base(name)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  public func write(_ data: Data, as name: String) throws {
    let update = SecItemUpdate(
      base(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw KeychainError.status(update) }
    var attributes = base(name)
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(attributes as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError.status(added) }
  }

  public func remove(_ name: String) { SecItemDelete(base(name) as CFDictionary) }

  /// Removes every record of this service in this group (what a build without the App Group left
  /// behind once the group is in use).
  public func removeAll() {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    SecItemDelete(query as CFDictionary)
  }

  /// Whether this process can use the group at all (the entitlement is present).
  public func isUsable() -> Bool {
    let probe = "probe"
    do {
      try write(Data([1]), as: probe)
      remove(probe)
      return true
    } catch {
      return false
    }
  }

  private func base(_ name: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecUseDataProtectionKeychain as String: true,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }
}

/// The input level (0…1) from the app's microphone tap to the keyboard's listening animation, at
/// ≥ 30 Hz. A plain float with no history; nothing of the audio itself.
public protocol LevelLine: AnyObject, Sendable {
  func write(_ level: Float)
  func read() -> Float
}

/// 4 bytes in a file, written in place (`pwrite`, no rename, no sync).
public final class FileLevelLine: LevelLine, @unchecked Sendable {
  public let file: URL
  private let lock = NSLock()
  private var writer: Int32 = -1
  private var reader: Int32 = -1

  public init(file: URL) { self.file = file }

  deinit {
    if writer >= 0 { close(writer) }
    if reader >= 0 { close(reader) }
  }

  public func write(_ level: Float) {
    var value = max(0, min(1, level)).bitPattern.littleEndian
    lock.lock()
    defer { lock.unlock() }
    if writer < 0 {
      writer = open(file.path, O_WRONLY | O_CREAT, 0o600)
      guard writer >= 0 else { return }
    }
    _ = withUnsafeBytes(of: &value) { pwrite(writer, $0.baseAddress, 4, 0) }
  }

  public func read() -> Float {
    lock.lock()
    defer { lock.unlock() }
    if reader < 0 {
      reader = open(file.path, O_RDONLY)
      guard reader >= 0 else { return 0 }
    }
    var raw: UInt32 = 0
    let count = withUnsafeMutableBytes(of: &raw) { pread(reader, $0.baseAddress, 4, 0) }
    guard count == 4 else { return 0 }
    let level = Float(bitPattern: UInt32(littleEndian: raw))
    return level.isFinite ? max(0, min(1, level)) : 0
  }
}

/// The level as the 64-bit state of a Darwin notification name (`notify_set_state` /
/// `notify_get_state`): no file and no entitlement, for the keychain fallback.
public final class NotifyLevelLine: LevelLine, @unchecked Sendable {
  public let name: String
  private let lock = NSLock()
  private var token: Int32 = 0
  private var registered = false

  public init(name: String = PhoneSignal.voiceLevel) { self.name = name }

  deinit {
    if registered { notify_cancel(token) }
  }

  private func ensureToken() -> Bool {
    if registered { return true }
    registered = notify_register_check(name, &token) == 0
    return registered
  }

  public func write(_ level: Float) {
    lock.lock()
    defer { lock.unlock() }
    guard ensureToken() else { return }
    _ = notify_set_state(token, UInt64(max(0, min(1, level)).bitPattern))
  }

  public func read() -> Float {
    lock.lock()
    defer { lock.unlock() }
    guard ensureToken() else { return 0 }
    var state: UInt64 = 0
    guard notify_get_state(token, &state) == 0 else { return 0 }
    let level = Float(bitPattern: UInt32(truncatingIfNeeded: state))
    return level.isFinite ? max(0, min(1, level)) : 0
  }
}

/// How the app and its extensions reach each other on this build.
public enum PhoneLink {
  /// The Info.plist key that holds the shared keychain group
  /// (`$(AppIdentifierPrefix)app.mindloom.shared`).
  public static let keychainGroupInfoKey = "MindloomSharedKeychainGroup"

  /// The shared keychain group of this build, or nil (not declared, or the team prefix is empty
  /// because the build is not signed by a team).
  public static func keychainGroup(bundle: Bundle = .main) -> String? {
    keychainGroup(infoKey: keychainGroupInfoKey, bundle: bundle)
  }

  /// The app-and-share-only group for the pairing handed to the share extension.
  public static let shareKeyGroupInfoKey = "MindloomShareKeyKeychainGroup"
  /// The app's own group (the phone's SSH key).
  public static let privateGroupInfoKey = "MindloomPrivateKeychainGroup"

  /// A keychain group named in Info.plist, or nil (not declared, or no team prefix because the
  /// build is not signed by a team).
  public static func keychainGroup(infoKey: String, bundle: Bundle = .main) -> String? {
    guard let group = bundle.object(forInfoDictionaryKey: infoKey) as? String,
      !group.hasPrefix("."), !group.isEmpty, !group.contains("$(")
    else { return nil }
    return group
  }

  /// The group only when it carries a real team prefix (`ABCDE12345.`): a simulator build signed
  /// ad hoc has none, and naming a group there would fail.
  public static func teamKeychainGroup(infoKey: String, bundle: Bundle = .main) -> String? {
    guard let group = keychainGroup(infoKey: infoKey, bundle: bundle),
      let dot = group.firstIndex(of: "."), group.distance(from: group.startIndex, to: dot) == 10
    else { return nil }
    return group
  }

  /// The voice records: the App Group's `voice/` files, else the shared keychain group.
  public static func records(fileManager: FileManager = .default) -> (any SharedRecords)? {
    if let container = PhoneAppGroup.containerURL(fileManager: fileManager),
      let files = try? FileRecords(directory: PhoneAppGroup.voiceDirectory(in: container))
    {
      return files
    }
    if let group = keychainGroup() {
      let keychain = KeychainRecords(accessGroup: group)
      if keychain.isUsable() { return keychain }
    }
    return nil
  }

  /// The level line that goes with `records`.
  public static func levelLine(for records: any SharedRecords) -> any LevelLine {
    if let files = records as? FileRecords {
      return FileLevelLine(file: files.directory.appendingPathComponent("level.bin"))
    }
    return NotifyLevelLine()
  }

  /// The voice channel between the app and the keyboard on this build, or nil when neither the
  /// App Group nor the shared keychain is available (the keyboard has no Full Access).
  public static func voiceChannel(fileManager: FileManager = .default) -> VoiceChannel? {
    guard let records = records(fileManager: fileManager) else { return nil }
    return VoiceChannel(records: records, level: levelLine(for: records))
  }
}
