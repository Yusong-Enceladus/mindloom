import Darwin
import Foundation

enum ProductionDurableFileIO {
  static func atomicWrite(_ data: Data, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
    )
    do {
      guard FileManager.default.createFile(atPath: temporary.path, contents: nil)
      else {
        throw ProductionAudioJournalError.fileOperation("create")
      }
      let handle = try FileHandle(forWritingTo: temporary)
      do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      let result = temporary.path.withCString { source in
        destination.path.withCString { target in
          Darwin.rename(source, target)
        }
      }
      guard result == 0 else {
        throw ProductionAudioJournalError.fileOperation("rename")
      }
      try synchronizeDirectory(directory)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else {
      throw ProductionAudioJournalError.fileOperation("open-directory")
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw ProductionAudioJournalError.fileOperation("fsync-directory")
    }
  }
}
