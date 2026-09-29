import BestASRDomain
import Foundation

struct LocalStorageSnapshot: Equatable, Sendable {
  var historyBytes: UInt64 = 0
  var sourceAudioBytes: UInt64 = 0
  var modelBytes: UInt64 = 0
  var rebuildableCacheBytes: UInt64 = 0
  var availableBytes: Int64 = 0

  var totalManagedBytes: UInt64 {
    historyBytes + sourceAudioBytes + modelBytes + rebuildableCacheBytes
  }
}

actor LocalStorageInspector {
  private let fileManager = FileManager.default

  func snapshot(dataRoot: URL, cacheRoot: URL) throws -> LocalStorageSnapshot {
    var result = LocalStorageSnapshot()
    result.sourceAudioBytes = try allocatedSize(
      at: dataRoot.appendingPathComponent("assets", isDirectory: true)
    )
    result.modelBytes = try allocatedSize(
      at: dataRoot.appendingPathComponent("models", isDirectory: true)
    )
    result.rebuildableCacheBytes = try allocatedSize(at: cacheRoot)

    let excluded = result.sourceAudioBytes + result.modelBytes
    let dataRootBytes = try allocatedSize(at: dataRoot)
    result.historyBytes =
      dataRootBytes >= excluded
      ? dataRootBytes - excluded
      : 0
    let values = try dataRoot.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    result.availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
    return result
  }

  /// Deletes only explicitly rebuildable download staging. Installed models,
  /// source audio, user data, databases and archive material are outside this
  /// root and are never candidates here.
  func clearRebuildableCache(cacheRoot: URL) throws -> UInt64 {
    let before = try allocatedSize(at: cacheRoot)
    let candidates = [
      cacheRoot.appendingPathComponent("model-downloads", isDirectory: true),
      cacheRoot.appendingPathComponent("diagnostics", isDirectory: true),
    ]
    let resolvedRoot = cacheRoot.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedRoot.path != "/", resolvedRoot.path.count > 12 else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let rootPrefix = resolvedRoot.path + "/"
    for candidate in candidates {
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.path.hasPrefix(rootPrefix) else {
        throw CocoaError(.fileWriteNoPermission)
      }
      if fileManager.fileExists(atPath: candidate.path) {
        try fileManager.removeItem(at: candidate)
      }
    }
    let after = try allocatedSize(at: cacheRoot)
    return before >= after ? before - after : 0
  }

  func sourceAudioBytesByMode(
    dataRoot: URL,
    sessionModes: [SessionID: SessionInputMode]
  ) throws -> [SessionInputMode: UInt64] {
    let sessionsRoot =
      dataRoot
      .appendingPathComponent("assets", isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
    var result: [SessionInputMode: UInt64] = [:]
    for (sessionID, mode) in sessionModes {
      let directory = sessionsRoot.appendingPathComponent(
        sessionID.rawValue.uuidString.lowercased(),
        isDirectory: true
      )
      result[mode, default: 0] += try allocatedSize(at: directory)
    }
    return result
  }

  private func allocatedSize(at url: URL) throws -> UInt64 {
    guard fileManager.fileExists(atPath: url.path) else { return 0 }
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
      .fileAllocatedSizeKey, .isSymbolicLinkKey,
    ])
    guard values.isSymbolicLink != true else {
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL
      guard resolved != url.standardizedFileURL else { return 0 }
      return try allocatedSize(at: resolved)
    }
    if values.isRegularFile == true {
      return UInt64(
        max(
          0,
          values.totalFileAllocatedSize
            ?? values.fileAllocatedSize ?? 0))
    }
    guard values.isDirectory == true else { return 0 }
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in true }
      )
    else { return 0 }
    var total: UInt64 = 0
    for case let child as URL in enumerator {
      let childValues = try child.resourceValues(forKeys: Set(keys))
      if childValues.isSymbolicLink == true {
        if childValues.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard childValues.isRegularFile == true else { continue }
      total += UInt64(
        max(
          0,
          childValues.totalFileAllocatedSize
            ?? childValues.fileAllocatedSize ?? 0))
    }
    return total
  }
}
