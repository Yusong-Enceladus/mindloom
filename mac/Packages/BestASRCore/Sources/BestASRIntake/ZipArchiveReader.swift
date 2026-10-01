import Compression
import Foundation

/// Reads a `.zip` on this Mac, in process (privacy contract §5): stored and
/// DEFLATE entries only (Compression framework, raw DEFLATE), every CRC
/// checked, and hard limits so a crafted archive cannot exhaust memory or
/// disk: at most 2,000 entries, 200 MB uncompressed in total, a
/// compression ratio of at most 100, and zips nested at most two deep. No
/// member is written anywhere by this reader and no member path is used as
/// a path.
public struct ZipArchiveReader: Sendable {
  public struct Limits: Equatable, Sendable {
    public var maximumEntries: Int
    public var maximumTotalBytes: Int
    public var maximumRatio: Int
    public var maximumDepth: Int

    public init(
      maximumEntries: Int = 2_000, maximumTotalBytes: Int = 200 * 1_000 * 1_000,
      maximumRatio: Int = 100, maximumDepth: Int = 2
    ) {
      self.maximumEntries = maximumEntries
      self.maximumTotalBytes = maximumTotalBytes
      self.maximumRatio = maximumRatio
      self.maximumDepth = maximumDepth
    }

    public static let standard = Limits()
  }

  public enum ReadError: Error, Equatable, Sendable {
    case notAZip
    case tooManyEntries
    case tooLarge
    case ratioExceeded
    case tooDeep
    /// ZIP64, multi-disk, or a damaged directory.
    case unsupported
    case corrupt
  }

  /// One file inside the archive.
  public struct Member: Equatable, Sendable {
    /// The path inside the archive, as recorded (never used as a path).
    public let path: String
    public let data: Data

    /// The last path component, safe to show and to use as a file name.
    public var name: String {
      let last =
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
      let cleaned = last.filter { !$0.isNewline && $0 != "\0" && $0 != ":" }
      guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "file" }
      return String(cleaned.prefix(200))
    }
  }

  /// What reading kept and what it left out.
  public struct Contents: Equatable, Sendable {
    public var members: [Member]
    /// Encrypted entries and entries in a method this reader does not
    /// decode: left inside the archive (kept on the Mac with it).
    public var skipped: [String]
  }

  public let limits: Limits

  public init(limits: Limits = .standard) {
    self.limits = limits
  }

  /// True when the bytes start like a zip (a local file header or an empty
  /// archive's end record).
  public static func looksLikeZip(_ data: Data) -> Bool {
    let prefix = [UInt8](data.prefix(4))
    return prefix == [0x50, 0x4B, 0x03, 0x04] || prefix == [0x50, 0x4B, 0x05, 0x06]
  }

  /// The archive's files. `depth` is 1 for a dropped zip, 2 for a zip in it.
  public func read(_ data: Data, depth: Int = 1) throws -> Contents {
    guard depth <= limits.maximumDepth else { throw ReadError.tooDeep }
    let bytes = [UInt8](data)
    guard Self.looksLikeZip(data), bytes.count >= 22 else { throw ReadError.notAZip }
    // The end of central directory record, within the last 64 KiB + 22.
    var end = -1
    var index = bytes.count - 22
    let floor = max(0, bytes.count - 22 - 65_535)
    while index >= floor {
      if Self.u32(bytes, index) == 0x0605_4B50 {
        end = index
        break
      }
      index -= 1
    }
    guard end >= 0 else { throw ReadError.notAZip }
    let disk = Self.u16(bytes, end + 4)
    let directoryDisk = Self.u16(bytes, end + 6)
    let entriesHere = Int(Self.u16(bytes, end + 8))
    let entries = Int(Self.u16(bytes, end + 10))
    let directorySize = Int(Self.u32(bytes, end + 12))
    let directoryOffset = Int(Self.u32(bytes, end + 16))
    guard disk == 0, directoryDisk == 0, entriesHere == entries else { throw ReadError.unsupported }
    // ZIP64 markers.
    guard entries != 0xFFFF, directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
      throw ReadError.unsupported
    }
    guard entries <= limits.maximumEntries else { throw ReadError.tooManyEntries }
    guard directoryOffset + directorySize <= end else { throw ReadError.corrupt }

    struct Entry {
      let path: String
      let flags: UInt16
      let method: UInt16
      let crc: UInt32
      let compressedSize: Int
      let size: Int
      let localOffset: Int
    }
    var directory: [Entry] = []
    var cursor = directoryOffset
    var declaredTotal = 0
    for _ in 0..<entries {
      guard cursor + 46 <= end, Self.u32(bytes, cursor) == 0x0201_4B50 else {
        throw ReadError.corrupt
      }
      let flags = Self.u16(bytes, cursor + 8)
      let method = Self.u16(bytes, cursor + 10)
      let crc = Self.u32(bytes, cursor + 16)
      let compressedSize = Int(Self.u32(bytes, cursor + 20))
      let size = Int(Self.u32(bytes, cursor + 24))
      let nameLength = Int(Self.u16(bytes, cursor + 28))
      let extraLength = Int(Self.u16(bytes, cursor + 30))
      let commentLength = Int(Self.u16(bytes, cursor + 32))
      let localOffset = Int(Self.u32(bytes, cursor + 42))
      guard cursor + 46 + nameLength <= end else { throw ReadError.corrupt }
      guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
        throw ReadError.unsupported
      }
      let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
      let path = Self.decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)
      directory.append(
        Entry(
          path: path, flags: flags, method: method, crc: crc, compressedSize: compressedSize,
          size: size, localOffset: localOffset))
      declaredTotal += size
      guard declaredTotal <= limits.maximumTotalBytes else { throw ReadError.tooLarge }
      cursor += 46 + nameLength + extraLength + commentLength
    }
    var contents = Contents(members: [], skipped: [])
    var total = 0
    for entry in directory {
      // Folders carry no bytes.
      if entry.path.hasSuffix("/") || entry.path.hasSuffix("\\") { continue }
      guard entry.flags & 0x0001 == 0, entry.method == 0 || entry.method == 8 else {
        contents.skipped.append(entry.path)
        continue
      }
      if entry.size > 0 {
        guard entry.size <= limits.maximumRatio * max(1, entry.compressedSize) else {
          throw ReadError.ratioExceeded
        }
      }
      let local = entry.localOffset
      guard local + 30 <= directoryOffset, Self.u32(bytes, local) == 0x0403_4B50 else {
        throw ReadError.corrupt
      }
      let start = local + 30 + Int(Self.u16(bytes, local + 26)) + Int(Self.u16(bytes, local + 28))
      guard start + entry.compressedSize <= directoryOffset else { throw ReadError.corrupt }
      let compressed = Array(bytes[start..<(start + entry.compressedSize)])
      let output: [UInt8]
      if entry.method == 0 {
        guard entry.compressedSize == entry.size else { throw ReadError.corrupt }
        output = compressed
      } else {
        output = try Self.inflate(compressed, expected: entry.size)
      }
      guard Self.crc32(output) == entry.crc else { throw ReadError.corrupt }
      total += output.count
      guard total <= limits.maximumTotalBytes else { throw ReadError.tooLarge }
      contents.members.append(Member(path: entry.path, data: Data(output)))
    }
    return contents
  }

  /// Raw DEFLATE into exactly `expected` bytes; more output than declared
  /// (a lying header) is refused.
  static func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
    guard expected > 0 else { return [] }
    guard !input.isEmpty else { throw ReadError.corrupt }
    var output = [UInt8](repeating: 0, count: expected + 1)
    let written = input.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer { destination in
        compression_decode_buffer(
          destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil,
          COMPRESSION_ZLIB)
      }
    }
    guard written == expected else {
      throw written > expected ? ReadError.ratioExceeded : ReadError.corrupt
    }
    return Array(output.prefix(expected))
  }

  /// UTF-8 when flagged or valid; otherwise GB 18030 (Chinese Windows
  /// archives), then Latin-1.
  static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
    if let name = String(bytes: bytes, encoding: .utf8) { return name }
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    if !utf8Flag, let name = String(bytes: bytes, encoding: gb18030) { return name }
    return String(bytes: bytes, encoding: .isoLatin1) ?? "file"
  }

  private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    return crc
  }

  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
  }
}
