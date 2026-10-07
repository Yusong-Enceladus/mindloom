import CryptoKit
import Foundation

/// A dropped media file's SHA-256, with what the file looked like while it
/// was hashed (size, modification time, file number). The drop path hashes a
/// recording once to recognise the same bytes; the import that copies it into
/// the library reuses that digest when the file is still the one that was
/// hashed, instead of reading the whole recording a second time (finish-mac).
public struct HashedSourceFile: Equatable, Sendable {
  public struct Fingerprint: Equatable, Sendable {
    public let size: Int
    public let modified: Date
    public let fileNumber: UInt64

    /// The file's fingerprint now; nil when it is not a readable regular file.
    /// A symbolic link is followed (the file it names is what gets read).
    public static func read(_ url: URL) -> Fingerprint? {
      guard
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: url.resolvingSymlinksInPath().path),
        (attributes[.type] as? FileAttributeType) == .typeRegular,
        let size = (attributes[.size] as? NSNumber)?.intValue,
        let modified = attributes[.modificationDate] as? Date,
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
      else { return nil }
      return Fingerprint(size: size, modified: modified, fileNumber: number)
    }
  }

  /// Lower-case hex SHA-256 of the bytes.
  public let digest: String
  public let fingerprint: Fingerprint

  public init(digest: String, fingerprint: Fingerprint) {
    self.digest = digest
    self.fingerprint = fingerprint
  }

  /// Hashes `url` in chunks. Nil when it cannot be read, when a read fails
  /// part way (a digest of part of the file would be recorded as the whole
  /// file's), when fewer bytes than its size were read, or when it changed
  /// while it was being read (the digest would describe no version of it).
  public static func hash(_ url: URL, chunk: Int = 4 << 20) -> HashedSourceFile? {
    hash(url, chunk: chunk) { handle, count in try handle.read(upToCount: count) }
  }

  /// `hash` with the chunk reader given (tests make it fail part way).
  static func hash(
    _ url: URL, chunk: Int, reader: (FileHandle, Int) throws -> Data?
  ) -> HashedSourceFile? {
    guard let before = Fingerprint.read(url),
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    var total = 0
    do {
      // Each chunk released as soon as it is hashed (see LocalModelManager.sha256).
      while try autoreleasepool(invoking: {
        guard let data = try reader(handle, chunk), !data.isEmpty else { return false }
        hasher.update(data: data)
        total += data.count
        return true
      }) {}
    } catch {
      return nil
    }
    guard total == before.size, Fingerprint.read(url) == before else { return nil }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return HashedSourceFile(digest: digest, fingerprint: before)
  }

  /// The digest still describes `url`: same size, modification time and
  /// file number as when it was hashed.
  public func stillDescribes(_ url: URL) -> Bool {
    Fingerprint.read(url) == fingerprint
  }
}
