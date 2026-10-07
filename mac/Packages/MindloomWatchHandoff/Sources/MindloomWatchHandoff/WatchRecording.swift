import CryptoKit
import Darwin
import Foundation

/// One recording made on Apple Watch, as the watch and the iPhone both describe it.
///
/// The audio is AAC in an ADTS stream (`.aac`): every frame carries its own header, so a file cut
/// short (the app ended mid-recording) still plays up to where it stopped. The description travels
/// as the WatchConnectivity file-transfer metadata (`transferMetadata`); the iPhone checks the
/// size and the SHA-256 before it says it has stored the original.
public struct WatchRecording: Codable, Equatable, Sendable, Identifiable {
  public static let currentVersion = 1
  /// The file name extension of the audio on both devices.
  public static let fileExtension = "aac"
  /// A recording stops by itself after this long (WATCH-002); a longer one is never sent.
  public static let maximumDuration: TimeInterval = 30 * 60
  /// Far above what 30 minutes of mono AAC at the watch's settings take (about 15 MB).
  public static let maximumBytes = 96 * 1024 * 1024

  public let v: Int
  /// A random UUID in lowercase text form. The iPhone uses it as the id of the item it shows, so
  /// the same recording never becomes two items.
  public let id: String
  /// When recording started on the watch (the item's time on the iPhone and the Mac).
  public let startedAt: Date
  /// Seconds of audio.
  public let duration: TimeInterval
  public let bytes: Int
  /// Lowercase hex SHA-256 of the file.
  public let sha256: String
  /// The recording ended without the stop button (an interruption, the app ended, the time
  /// limit): what was recorded up to then.
  public let interrupted: Bool

  public init(
    id: String, startedAt: Date, duration: TimeInterval, bytes: Int, sha256: String,
    interrupted: Bool = false
  ) {
    self.v = Self.currentVersion
    self.id = id
    self.startedAt = Self.wholeMilliseconds(startedAt)
    self.duration = duration
    self.bytes = bytes
    self.sha256 = sha256
    self.interrupted = interrupted
  }

  enum CodingKeys: String, CodingKey {
    case v, id, duration, bytes, sha256, interrupted
    case startedAt = "started_at"
  }

  /// The start is kept to the whole millisecond: the stores write milliseconds and the transfer
  /// metadata seconds as a double, and the same recording must compare equal after either.
  static func wholeMilliseconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
  }

  private var startedAtMilliseconds: Int64 {
    Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
  }

  /// Equal when every field is, the start compared to the whole millisecond.
  public static func == (lhs: WatchRecording, rhs: WatchRecording) -> Bool {
    lhs.v == rhs.v && lhs.id == rhs.id && lhs.startedAtMilliseconds == rhs.startedAtMilliseconds
      && lhs.duration == rhs.duration && lhs.bytes == rhs.bytes && lhs.sha256 == rhs.sha256
      && lhs.interrupted == rhs.interrupted
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidID
    case invalidStart
    case invalidDuration
    case invalidSize
    case invalidDigest
    case notARecording
  }

  public func validate() throws {
    guard v == Self.currentVersion else { throw ValidationError.unsupportedVersion }
    guard WatchRecordingID.isValid(id) else { throw ValidationError.invalidID }
    // After 2020 and not more than a day ahead of this device's clock.
    guard startedAt.timeIntervalSince1970 > 1_577_836_800,
      startedAt.timeIntervalSinceNow < 24 * 60 * 60
    else { throw ValidationError.invalidStart }
    guard duration.isFinite, duration >= 0, duration <= Self.maximumDuration + 60 else {
      throw ValidationError.invalidDuration
    }
    guard bytes > 0, bytes <= Self.maximumBytes else { throw ValidationError.invalidSize }
    guard sha256.utf8.count == 64, sha256.utf8.allSatisfy(WatchRecordingID.isLowerHex) else {
      throw ValidationError.invalidDigest
    }
  }

  // MARK: - Transfer metadata

  /// Marks a WatchConnectivity dictionary as ours, with its version.
  public static let marker = "mindloom.watch"

  /// Property-list values only (WatchConnectivity metadata).
  public var transferMetadata: [String: Any] {
    [
      Self.marker: Self.currentVersion,
      "id": id,
      "started_at": startedAt.timeIntervalSince1970,
      "duration": duration,
      "bytes": bytes,
      "sha256": sha256,
      "interrupted": interrupted,
    ]
  }

  /// Reads and validates transfer metadata.
  public init(transferMetadata metadata: [String: Any]?) throws {
    guard let metadata, (metadata[Self.marker] as? NSNumber)?.intValue == Self.currentVersion
    else { throw ValidationError.notARecording }
    guard let id = metadata["id"] as? String,
      let started = (metadata["started_at"] as? NSNumber)?.doubleValue,
      let duration = (metadata["duration"] as? NSNumber)?.doubleValue,
      let bytes = (metadata["bytes"] as? NSNumber)?.intValue,
      let sha256 = metadata["sha256"] as? String
    else { throw ValidationError.notARecording }
    self.init(
      id: id, startedAt: Date(timeIntervalSince1970: started), duration: duration, bytes: bytes,
      sha256: sha256, interrupted: (metadata["interrupted"] as? NSNumber)?.boolValue ?? false)
    try validate()
  }
}

/// Recording ids: random UUIDs, lowercase.
public enum WatchRecordingID {
  public static func make() -> String { UUID().uuidString.lowercased() }

  /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, lowercase hex only (the iPhone's item ids have the
  /// same form).
  public static func isValid(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count == 36 else { return false }
    for (index, byte) in bytes.enumerated() {
      switch index {
      case 8, 13, 18, 23:
        guard byte == 0x2D else { return false }
      default:
        guard isLowerHex(byte) else { return false }
      }
    }
    return true
  }

  static func isLowerHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
  }
}

/// The size and SHA-256 of a file, read in pieces (a long recording is never held in memory).
public enum WatchFileDigest {
  public static func of(_ url: URL) throws -> (bytes: Int, sha256: String) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var total = 0
    while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
      total += chunk.count
    }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (total, hex)
  }
}

/// Files the two stores write: atomically, and readable after the first unlock (a background
/// launch must be able to receive and to send).
enum WatchFiles {
  static func atomicWrite(_ data: Data, to url: URL, staging: URL) throws {
    let temporary = staging.appendingPathComponent(UUID().uuidString + ".tmp")
    var options: Data.WritingOptions = [.withoutOverwriting]
    #if os(iOS) || os(watchOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: temporary, options: options)
    do {
      try replace(url, with: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  /// Moves `source` to `destination`, replacing what is there (rename is atomic on one volume).
  static func replace(_ destination: URL, with source: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }

  /// Names in `directory` ending in `.suffix` whose stem is a recording id.
  static func ids(in directory: URL, suffix: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix("." + suffix) }
      .map { String($0.dropLast(suffix.count + 1)) }
      .filter(WatchRecordingID.isValid)
  }
}
