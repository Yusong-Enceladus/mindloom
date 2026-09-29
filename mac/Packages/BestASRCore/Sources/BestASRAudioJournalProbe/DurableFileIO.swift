import Darwin
import Foundation

enum DurableFileIO {
  static func write(_ data: Data, to url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw AudioJournalError.posix(operation: "create-file", code: errno)
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  static func atomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp")
    do {
      try write(data, to: temporary)
      try atomicRename(from: temporary, to: destination)
      try synchronizeDirectory(destination.deletingLastPathComponent())
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  /// Appends one already-delimited record and makes it durable before return.
  /// The file is opened with O_APPEND so a crash can leave only one trailing
  /// partial record; every earlier newline-terminated record remains valid.
  static func append(_ data: Data, to destination: URL) throws {
    let created = !FileManager.default.fileExists(atPath: destination.path)
    let descriptor = destination.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else {
      throw AudioJournalError.posix(operation: "open-append", code: errno)
    }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor,
          base.advanced(by: offset),
          rawBuffer.count - offset
        )
        guard written > 0 else {
          throw AudioJournalError.posix(operation: "append", code: errno)
        }
        offset += written
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw AudioJournalError.posix(operation: "fsync-append", code: errno)
    }
    if created {
      try synchronizeDirectory(destination.deletingLastPathComponent())
    }
  }

  /// Removes an incomplete append-only tail and durably publishes the repaired
  /// file length before recording is allowed to continue.
  static func truncate(_ destination: URL, toByteCount byteCount: Int) throws {
    guard byteCount >= 0 else {
      throw AudioJournalError.posix(operation: "truncate-range", code: EINVAL)
    }
    let descriptor = destination.path.withCString {
      Darwin.open($0, O_WRONLY | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw AudioJournalError.posix(operation: "open-truncate", code: errno)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.ftruncate(descriptor, off_t(byteCount)) == 0 else {
      throw AudioJournalError.posix(operation: "truncate", code: errno)
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw AudioJournalError.posix(operation: "fsync-truncate", code: errno)
    }
  }

  static func atomicRename(from source: URL, to destination: URL) throws {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        Darwin.rename(sourcePath, destinationPath)
      }
    }
    guard result == 0 else {
      throw AudioJournalError.posix(operation: "rename", code: errno)
    }
  }

  static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw AudioJournalError.posix(operation: "open-directory", code: errno)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw AudioJournalError.posix(operation: "fsync-directory", code: errno)
    }
  }
}
