import BestASRDomain
import CryptoKit
import Darwin
import Foundation

/// Reads an item's normalized image, or a file item's original, for sending
/// to the user's own Spark.
///
/// Rooted at `<dataRoot>/assets`, a directory the provenance guard already
/// checked before the link started. A reference must be a plain relative
/// path under `sessions/`; every component is opened without following
/// symbolic links, and the bytes must match the stored size, the stored
/// SHA-256, the image limit, and a PNG or JPEG signature. Anything else is
/// refused and the item is parked instead of sent.
public struct RemoteOrganizerItemAssetReader: RemoteOrganizerItemAssetReading {
  public enum ReadError: Error, Equatable, Sendable {
    case invalidReference
    case unreadable
    case sizeMismatch
    case tooLarge
    case digestMismatch
    case notAnImage
  }

  private let assetRoot: URL
  private let maximumBytes: Int
  private let maximumFileBytes: Int

  public init(
    assetRoot: URL, maximumBytes: Int = UserItemLimits.maximumSendableImageBytes,
    maximumFileBytes: Int = Int(UserItemLimits.maximumSendableFileBytes)
  ) {
    self.assetRoot = assetRoot.standardizedFileURL
    self.maximumBytes = maximumBytes
    self.maximumFileBytes = maximumFileBytes
  }

  public func imageData(for asset: RemoteOrganizerImageAsset) throws -> Data {
    let data = try verifiedData(for: asset, maximumBytes: maximumBytes)
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    let jpeg: [UInt8] = [0xFF, 0xD8]
    guard data.starts(with: png) || data.starts(with: jpeg) else { throw ReadError.notAnImage }
    return data
  }

  /// Any file type; the same path, size and digest checks as an image.
  public func fileData(for asset: RemoteOrganizerImageAsset) throws -> Data {
    try verifiedData(for: asset, maximumBytes: maximumFileBytes)
  }

  private func verifiedData(for asset: RemoteOrganizerImageAsset, maximumBytes: Int) throws
    -> Data
  {
    let components = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard asset.relativePath.hasPrefix("sessions/"), !asset.relativePath.hasPrefix("/"),
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
    else { throw ReadError.invalidReference }
    guard asset.sizeBytes > 0 else { throw ReadError.sizeMismatch }
    guard asset.sizeBytes <= Int64(maximumBytes) else { throw ReadError.tooLarge }

    // Walk from the root with O_NOFOLLOW at every step, so neither a linked
    // directory nor a linked file can redirect the read outside the root.
    var directory = open(assetRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw ReadError.unreadable }
    for component in components.dropLast() {
      let next = openat(
        directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      close(directory)
      guard next >= 0 else { throw ReadError.invalidReference }
      directory = next
    }
    let descriptor = openat(
      directory, String(components[components.count - 1]), O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    close(directory)
    guard descriptor >= 0 else { throw ReadError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw ReadError.unreadable
    }
    guard Int64(status.st_size) == asset.sizeBytes else { throw ReadError.sizeMismatch }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw ReadError.tooLarge }
    guard Int64(data.count) == asset.sizeBytes else { throw ReadError.sizeMismatch }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == asset.sha256.lowercased() else { throw ReadError.digestMismatch }
    return data
  }
}
