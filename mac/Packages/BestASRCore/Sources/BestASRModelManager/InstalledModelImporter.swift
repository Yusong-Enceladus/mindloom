import Foundation

/// Mindloom Preview's 「使用这台 Mac 上已装的识别模型」 (v11): takes the public
/// model artifacts the owner's bestASR library already installed, without
/// downloading them again.
///
/// Registry-driven and read-only on the source: only `<source>/active/<id>.json`
/// pointers of artifacts the bundled registry lists are read, and only the
/// version directory such a pointer names (`versions/<id>/<version>`, checked
/// against the registry's version and tree digest). The files are then
/// copied by `LocalModelManager.activate`, which takes exactly the registry's
/// files, refuses symbolic links, verifies every size and SHA-256 and keeps
/// the last known-good version; on APFS the copy is a clone, so no space is
/// used twice. Nothing outside `<source>` is opened (never `personal-models`,
/// never the owner's records), and nothing is written there.
public struct InstalledModelImporter: Sendable {
  public struct Candidate: Equatable, Sendable {
    public let artifactID: String
    public let version: String
    public let directory: URL
  }

  public struct Outcome: Equatable, Sendable {
    public var imported: [String] = []
    public var alreadyActive: [String] = []
    public var failed: [String] = []
  }

  /// The source library's `models` folder.
  public let source: URL
  public let registry: ManagedModelRegistry

  public init(source: URL, registry: ManagedModelRegistry) {
    self.source = source
    self.registry = registry
  }

  private struct Pointer: Decodable {
    let schemaVersion: Int
    let artifactID: String
    let version: String
    let activationSequence: UInt64
    let treeSHA256: String
    let relativePath: String
  }

  /// The registry's artifacts the source has an active, matching version of.
  public func candidates() -> [Candidate] {
    let fm = FileManager.default
    guard Self.isPlainDirectory(source) else { return [] }
    let root = source.resolvingSymlinksInPath().standardizedFileURL
    let versionsRoot = root.appendingPathComponent("versions", isDirectory: true).path + "/"
    // Every folder on the way is a plain one: `active/`, `versions/` and
    // `versions/<id>/` included, not only `models` and the leaf (fix-mac).
    let active = root.appendingPathComponent("active", isDirectory: true)
    guard Self.isPlainDirectory(active),
      Self.isPlainDirectory(root.appendingPathComponent("versions", isDirectory: true))
    else { return [] }
    var found: [Candidate] = []
    var seen = Set<String>()
    for artifact in registry.models where seen.insert(artifact.id).inserted {
      guard ManagedModelRegistry.safeComponent(artifact.id) else { continue }
      let pointerURL = active.appendingPathComponent("\(artifact.id).json")
      guard Self.isPlainFile(pointerURL),
        let data = try? Data(contentsOf: pointerURL, options: .uncached),
        data.count < 64 * 1024,
        let pointer = try? JSONDecoder().decode(Pointer.self, from: data),
        pointer.schemaVersion == 1, pointer.artifactID == artifact.id,
        let descriptor = registry.artifact(id: artifact.id, version: pointer.version),
        descriptor.treeSHA256 == pointer.treeSHA256,
        descriptor.activationSequence == pointer.activationSequence,
        pointer.relativePath == "versions/\(descriptor.id)/\(descriptor.version)"
      else { continue }
      let directory = root.appendingPathComponent(pointer.relativePath, isDirectory: true)
      guard Self.isPlainDirectory(directory),
        Self.isPlainDirectory(directory.deletingLastPathComponent()),
        directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(versionsRoot),
        fm.fileExists(atPath: directory.path)
      else { continue }
      found.append(
        Candidate(artifactID: descriptor.id, version: descriptor.version, directory: directory))
    }
    return found
  }

  /// Activates each candidate in `manager` (copy, verify, activate).
  public func importAll(
    into manager: LocalModelManager,
    healthCheck: any ManagedModelHealthChecking = FileSetModelHealthCheck()
  ) async -> Outcome {
    var outcome = Outcome()
    for candidate in candidates() {
      do {
        let result = try await manager.activate(
          artifactID: candidate.artifactID, version: candidate.version,
          from: candidate.directory, healthCheck: healthCheck)
        if result.disposition == .alreadyActive {
          outcome.alreadyActive.append(candidate.artifactID)
        } else {
          outcome.imported.append(candidate.artifactID)
        }
      } catch {
        outcome.failed.append(candidate.artifactID)
      }
    }
    return outcome
  }

  /// A directory that is not a symbolic link.
  static func isPlainDirectory(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return values?.isDirectory == true && values?.isSymbolicLink != true
  }

  /// A regular file that is not a symbolic link.
  static func isPlainFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values?.isRegularFile == true && values?.isSymbolicLink != true
  }
}
