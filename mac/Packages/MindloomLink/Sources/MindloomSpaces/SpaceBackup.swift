import CryptoKit
import Foundation
import MindloomLink

/// A space's encrypted backup (v8 B4; the Spark's `organizer/backup.py`):
/// the `MLBK1` stream an admin's Mac pulls and keeps on itself or an
/// external disk. Only someone who can open the space (its members of that
/// epoch, the org admins' escrow) can derive the key again; the Spark cannot
/// read a backup at rest.
///
///     "MLBK1\n" + header JSON line   (plain: which space, backup and epoch)
///     frames: uint32 BE length + ChaCha20-Poly1305(chunk),
///             nonce = 4 zero bytes ‖ uint64 BE counter,
///             AAD = SHA-256(magic ‖ header line) ‖ uint64 BE counter ‖ final flag
///     records inside: type ‖ uint64 BE length ‖ payload — M manifest, B blob,
///             F organizer file, E end.
public enum SpaceBackup {
  public static let magic = Data("MLBK1\n".utf8)
  public static let format = "mindloom-space-backup-v1"
  public static let fileExtension = "mlbk"
  static let maximumFrame = 1024 * 1024 + 16

  public enum BackupError: Error, Equatable, Sendable {
    /// Not a backup, or a header this Mac does not know.
    case notABackup
    /// Wrong key, a changed byte, truncated, extra data.
    case damaged(String)
  }

  static let keyWrapInfo = "mindloom-space-backup-key-v1"
  public static let keyWrapPrefix = "mlbkey1."

  /// Review V8R-13: a backup's own random key sealed to one admin device (the
  /// receipt keeps one per admin device and org escrow device), so a plain
  /// member who holds the space key cannot open a backup, which carries what
  /// only admins see (takedown reasons, hides, the audit, join requests).
  public static func wrapKey(
    _ key: Data, to sealPublicKey: Data, spaceID: String, backupID: String, deviceID: String
  ) throws -> String {
    guard key.count == SpaceCrypto.keyBytes else { throw SpaceCrypto.CryptoError.invalidKey }
    let raw = try SpaceCrypto.sealToDevice(
      key, recipient: sealPublicKey, info: keyWrapInfo,
      aad: Data("\(keyWrapInfo)|\(spaceID)|\(backupID)|\(deviceID)".utf8),
      ephemeral: .init(), nonce: nil)
    return keyWrapPrefix + Base64URL.encode(raw)
  }

  public static func unwrapKey(
    _ wrap: String, sealKey: Curve25519.KeyAgreement.PrivateKey, spaceID: String,
    backupID: String, deviceID: String
  ) throws -> Data {
    let raw = try SpaceCrypto.payload(
      wrap, prefix: keyWrapPrefix,
      exact: 32 + SpaceCrypto.nonceBytes + SpaceCrypto.keyBytes + SpaceCrypto.tagBytes)
    let key = try SpaceCrypto.openFromDevice(
      raw, sealKey: sealKey, info: keyWrapInfo,
      aad: Data("\(keyWrapInfo)|\(spaceID)|\(backupID)|\(deviceID)".utf8))
    guard key.count == SpaceCrypto.keyBytes else { throw SpaceCrypto.CryptoError.openFailed }
    return key
  }

  /// `HKDF-SHA256(ikm = K_epoch, salt = the backup id's 16 bytes, info =
  /// "mindloom-space-backup-v1")` (`space_member.backup_key`): the key of
  /// backups made before review V8R-13, still opened.
  public static func key(spaceKey: Data, backupID: String) -> Data {
    guard let uuid = UUID(uuidString: backupID) else { return Data() }
    let salt = withUnsafeBytes(of: uuid.uuid) { Data($0) }
    return SpaceCrypto.hkdf(spaceKey, info: "mindloom-space-backup-v1", salt: salt)
      .withUnsafeBytes { Data($0) }
  }

  public struct Header: Codable, Equatable, Sendable {
    public let v: Int
    public let format: String
    public let backupID: String
    public let spaceID: String
    public let epoch: Int
    public let createdAt: String?
    public let chunk: Int?

    enum CodingKeys: String, CodingKey {
      case v, format, epoch, chunk
      case backupID = "backup_id"
      case spaceID = "space_id"
      case createdAt = "created_at"
    }
  }

  /// The plain header (no key needed), and the exact header line.
  public static func header(_ data: Data) throws -> (Header, Data) {
    guard data.count > magic.count, data.prefix(magic.count) == magic else {
      throw BackupError.notABackup
    }
    let rest = data.dropFirst(magic.count)
    guard let newline = rest.prefix(4096).firstIndex(of: 0x0A) else { throw BackupError.notABackup }
    let line = Data(rest[rest.startIndex...newline])
    guard let header = try? JSONDecoder().decode(Header.self, from: line), header.v == 1,
      header.format == format, SpaceID.isValid(header.spaceID), SpaceID.isValid(header.backupID)
    else { throw BackupError.notABackup }
    return (header, line)
  }

  public struct Contents: Sendable {
    public let header: Header
    public let manifest: SpaceJSON
    public let blobIDs: [String]
    public let files: [String]
    public let plaintextBytes: Int

    /// Items active in the space when the backup was made.
    public var activeItems: [String] {
      (manifest["tables"]?["items"]?.array ?? []).compactMap { row in
        row["status"]?.string == "active" ? row["item_id"]?.string?.lowercased() : nil
      }
    }

    /// The op log's last seq in the backup.
    public var head: Int {
      (manifest["tables"]?["ops"]?.array ?? []).compactMap { $0["seq"]?.int }.max() ?? 0
    }
  }

  /// Opens and checks a whole backup: every frame authenticates under the
  /// key, the last one carries the final flag, nothing follows it, and the
  /// records end with `E`.
  public static func open(_ data: Data, key: Data) throws -> Contents {
    let (header, line) = try header(data)
    var plain = Data()
    var offset = magic.count + line.count
    var counter: UInt64 = 0
    var final = false
    let headerDigest = Data(SHA256.hash(data: magic + line))
    let symmetric = SymmetricKey(data: key)
    let bytes = Data(data)
    while !final {
      guard offset + 4 <= bytes.count else { throw BackupError.damaged("truncated") }
      let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      offset += 4
      guard (16...maximumFrame).contains(length), offset + length <= bytes.count else {
        throw BackupError.damaged("bad frame")
      }
      let frame = bytes[offset..<(offset + length)]
      offset += length
      var opened: Data?
      for flag: UInt8 in [0, 1] {
        if let pt = try? openFrame(
          frame, key: symmetric, counter: counter, flag: flag, headerDigest: headerDigest)
        {
          opened = pt
          final = flag == 1
          break
        }
      }
      guard let opened else { throw BackupError.damaged("does not open") }
      plain.append(opened)
      counter += 1
    }
    guard offset == bytes.count else { throw BackupError.damaged("data after the end") }
    var manifest: SpaceJSON?
    var blobs: [String] = []
    var files: [String] = []
    var cursor = 0
    var ended = false
    while cursor < plain.count {
      guard cursor + 9 <= plain.count else { throw BackupError.damaged("record") }
      let type = plain[cursor]
      let length = plain[(cursor + 1)..<(cursor + 9)].reduce(0) { ($0 << 8) | Int($1) }
      cursor += 9
      guard length >= 0, cursor + length <= plain.count else { throw BackupError.damaged("record") }
      let payload = plain[cursor..<(cursor + length)]
      cursor += length
      switch type {
      case UInt8(ascii: "M"):
        manifest = try? SpaceJSON.decode(Data(payload))
      case UInt8(ascii: "B"):
        guard payload.count >= 36 else { throw BackupError.damaged("blob") }
        blobs.append(String(decoding: payload.prefix(36), as: UTF8.self))
      case UInt8(ascii: "F"):
        guard let n = payload.first, payload.count >= 1 + Int(n) else {
          throw BackupError.damaged("file")
        }
        files.append(String(decoding: payload.dropFirst().prefix(Int(n)), as: UTF8.self))
      case UInt8(ascii: "E"):
        ended = true
      default:
        throw BackupError.damaged("record type")
      }
    }
    guard ended, let manifest else { throw BackupError.damaged("incomplete") }
    return Contents(
      header: header, manifest: manifest, blobIDs: blobs, files: files, plaintextBytes: plain.count)
  }

  static func openFrame(
    _ frame: Data, key: SymmetricKey, counter: UInt64, flag: UInt8, headerDigest: Data
  ) throws -> Data {
    let box = try ChaChaPoly.SealedBox(
      nonce: ChaChaPoly.Nonce(data: nonce(counter)), ciphertext: frame.dropLast(16),
      tag: frame.suffix(16))
    return try ChaChaPoly.open(box, using: key, authenticating: aad(headerDigest, counter, flag))
  }

  static func nonce(_ counter: UInt64) -> Data {
    var big = counter.bigEndian
    return Data(count: 4) + withUnsafeBytes(of: &big) { Data($0) }
  }

  static func aad(_ headerDigest: Data, _ counter: UInt64, _ flag: UInt8) -> Data {
    var big = counter.bigEndian
    return headerDigest + withUnsafeBytes(of: &big) { Data($0) } + Data([flag])
  }

  /// Writes a stream (tests and the in-memory Spark): records sealed into
  /// frames of at most `chunk` bytes.
  public static func seal(
    header: Header, records: [(type: UInt8, payload: Data)], key: Data, chunk: Int = 1024 * 1024
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let line = try encoder.encode(header) + Data("\n".utf8)
    let digest = Data(SHA256.hash(data: magic + line))
    var plain = Data()
    for record in records {
      var length = UInt64(record.payload.count).bigEndian
      plain.append(record.type)
      plain.append(withUnsafeBytes(of: &length) { Data($0) })
      plain.append(record.payload)
    }
    var out = magic + line
    var counter: UInt64 = 0
    var offset = 0
    let symmetric = SymmetricKey(data: key)
    repeat {
      let piece = plain[offset..<min(plain.count, offset + chunk)]
      offset += piece.count
      let final: UInt8 = offset >= plain.count ? 1 : 0
      let box = try ChaChaPoly.seal(
        Data(piece), using: symmetric, nonce: ChaChaPoly.Nonce(data: nonce(counter)),
        authenticating: aad(digest, counter, final))
      var length = UInt32(box.ciphertext.count + 16).bigEndian
      out.append(withUnsafeBytes(of: &length) { Data($0) })
      out.append(box.ciphertext + box.tag)
      counter += 1
      if final == 1 { break }
    } while true
    return out
  }
}

/// A backup as this Mac keeps it: the stream next to a small sidecar (ids,
/// sizes and the digest; no content), so a folder can be listed without
/// opening anything.
public struct SpaceBackupReceipt: Codable, Equatable, Identifiable, Sendable {
  public let backupID: String
  public let spaceID: String
  public let spaceName: String?
  public let epoch: Int
  public let createdAt: Date
  public let bytes: Int
  public let sha256: String
  public let items: Int
  public let blobs: Int
  public let fileName: String
  /// The backup's key sealed to each admin device (device id → `mlbkey1.`;
  /// review V8R-13). Nil for a backup made before (its key is derived from
  /// the epoch's space key).
  public let keyWraps: [String: String]?

  public var id: String { backupID }

  /// `spaceName` is never written (review V8R-13: the receipt beside the
  /// backup on a shared or external disk names no space).
  public init(
    backupID: String, spaceID: String, spaceName: String?, epoch: Int, createdAt: Date, bytes: Int,
    sha256: String, items: Int, blobs: Int, fileName: String, keyWraps: [String: String]? = nil
  ) {
    self.backupID = backupID
    self.spaceID = spaceID
    self.spaceName = spaceName
    self.epoch = epoch
    self.createdAt = createdAt
    self.bytes = bytes
    self.sha256 = sha256
    self.items = items
    self.blobs = blobs
    self.fileName = fileName
    self.keyWraps = keyWraps
  }

  enum CodingKeys: String, CodingKey {
    case backupID = "backup_id"
    case spaceID = "space_id"
    case spaceName = "space_name"
    case epoch
    case createdAt = "created_at"
    case bytes, sha256, items, blobs
    case fileName = "file_name"
    case keyWraps = "key_wraps"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(backupID, forKey: .backupID)
    try container.encode(spaceID, forKey: .spaceID)
    try container.encode(epoch, forKey: .epoch)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(bytes, forKey: .bytes)
    try container.encode(sha256, forKey: .sha256)
    try container.encode(items, forKey: .items)
    try container.encode(blobs, forKey: .blobs)
    try container.encode(fileName, forKey: .fileName)
    try container.encodeIfPresent(keyWraps, forKey: .keyWraps)
  }
}

/// When a space's next scheduled backup is due (B4: daily or weekly, pulled
/// by an admin's Mac to itself or an external disk).
public struct SpaceBackupSchedule: Codable, Equatable, Sendable {
  public enum Interval: String, Codable, CaseIterable, Sendable {
    case off, daily, weekly

    public var seconds: TimeInterval? {
      switch self {
      case .off: return nil
      case .daily: return 86_400
      case .weekly: return 7 * 86_400
      }
    }

    public var title: String {
      switch self {
      case .off: return "不自动备份"
      case .daily: return "每天"
      case .weekly: return "每周"
      }
    }
  }

  public var interval: Interval
  /// The folder backups go to (on this Mac or an external disk).
  public var folder: String?
  public var lastSuccess: Date?
  public var lastAttempt: Date?
  public var lastError: String?

  public init(
    interval: Interval = .off, folder: String? = nil, lastSuccess: Date? = nil,
    lastAttempt: Date? = nil, lastError: String? = nil
  ) {
    self.interval = interval
    self.folder = folder
    self.lastSuccess = lastSuccess
    self.lastAttempt = lastAttempt
    self.lastError = lastError
  }

  /// Due when switched on, a folder is set, and the interval has passed since
  /// the last good backup; a failed try waits an hour before the next.
  public func isDue(now: Date) -> Bool {
    guard let seconds = interval.seconds, folder != nil else { return false }
    if let lastAttempt, lastError != nil, now.timeIntervalSince(lastAttempt) < 3_600 {
      return false
    }
    guard let lastSuccess else { return true }
    return now.timeIntervalSince(lastSuccess) >= seconds
  }
}
