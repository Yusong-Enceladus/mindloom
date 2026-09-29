import Foundation

public enum AtomicEnvelopeFault: Sendable {
  case beforeCommit
  case none
}

public enum AtomicEnvelopeFileError: Error, Equatable, Sendable {
  case injectedBeforeCommit
  case stagingFileRemained
}

public enum AtomicEnvelopeFile {
  public static func commit(
    _ envelope: EncryptedEnvelope,
    to destination: URL,
    fault: AtomicEnvelopeFault = .none,
    fileManager: FileManager = .default
  ) throws {
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )
    let staging = parent.appendingPathComponent(
      ".\(UUID().uuidString).envelope-staging"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(envelope)

    do {
      try data.write(to: staging, options: .withoutOverwriting)
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: staging.path
      )
      if fault == .beforeCommit {
        throw AtomicEnvelopeFileError.injectedBeforeCommit
      }
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
          destination,
          withItemAt: staging,
          backupItemName: nil,
          options: .usingNewMetadataOnly
        )
      } else {
        try fileManager.moveItem(at: staging, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }

    if fileManager.fileExists(atPath: staging.path) {
      throw AtomicEnvelopeFileError.stagingFileRemained
    }
  }

  public static func read(
    from source: URL
  ) throws -> EncryptedEnvelope {
    try JSONDecoder().decode(
      EncryptedEnvelope.self,
      from: Data(contentsOf: source)
    )
  }
}
