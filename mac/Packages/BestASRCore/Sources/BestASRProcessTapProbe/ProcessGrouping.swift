import Foundation

public enum ProcessAudioGrouper {
  public static func groups(
    from processes: [AudioProcessSnapshot]
  ) -> [ApplicationAudioGroup] {
    let processByID = Dictionary(
      uniqueKeysWithValues: processes.map { ($0.processID, $0) }
    )
    let grouped = Dictionary(grouping: processes) {
      applicationIdentity(for: $0, processByID: processByID)
    }

    return grouped.map { identity, members in
      let sorted = members.sorted { lhs, rhs in
        if lhs.processID != rhs.processID {
          return lhs.processID < rhs.processID
        }
        return lhs.objectID < rhs.objectID
      }
      let bundleID =
        identity.hasPrefix("bundle:")
        ? String(identity.dropFirst("bundle:".count))
        : nil
      let preferredDisplay =
        sorted.first(where: {
          canonicalBundleID($0.bundleID) == bundleID
            && !isHelperDisplayName($0.displayName)
        })?.displayName
        ?? sorted.first(where: { !isHelperDisplayName($0.displayName) })?
        .displayName
        ?? cleanedDisplayName(sorted.first?.displayName ?? "Unknown")
      return ApplicationAudioGroup(
        identity: identity,
        displayName: preferredDisplay,
        bundleID: bundleID,
        processIDs: sorted.map(\.processID),
        audioObjectIDs: sorted.map(\.objectID),
        hasRunningOutput: sorted.contains(where: \.isRunningOutput)
      )
    }
    .sorted { lhs, rhs in
      if lhs.hasRunningOutput != rhs.hasRunningOutput {
        return lhs.hasRunningOutput && !rhs.hasRunningOutput
      }
      return lhs.identity < rhs.identity
    }
  }

  public static func relatedProcesses(
    to selected: AudioProcessSnapshot,
    in processes: [AudioProcessSnapshot]
  ) -> [AudioProcessSnapshot] {
    let processByID = Dictionary(
      uniqueKeysWithValues: processes.map { ($0.processID, $0) }
    )
    let selectedIdentity = applicationIdentity(
      for: selected,
      processByID: processByID
    )
    return processes.filter {
      applicationIdentity(for: $0, processByID: processByID)
        == selectedIdentity
    }
  }

  /// Core Audio exposes Chromium/Electron helpers as independent audio
  /// processes, often with bundle identifiers such as
  /// `com.google.Chrome.helper.renderer`. The product boundary is the parent
  /// application, so collapse helper suffixes and prefer any ancestor present
  /// in the HAL process list. This keeps helper churn inside one stable source
  /// without pulling an unrelated application's audio into the tap.
  private static func applicationIdentity(
    for process: AudioProcessSnapshot,
    processByID: [Int32: AudioProcessSnapshot]
  ) -> String {
    var current = process
    var visited: Set<Int32> = []
    var rootName = process.displayName
    var bundleID = canonicalBundleID(process.bundleID)
    while visited.insert(current.processID).inserted,
      let parent = processByID[current.parentProcessID]
    {
      current = parent
      rootName = parent.displayName
      if let parentBundleID = canonicalBundleID(parent.bundleID) {
        bundleID = parentBundleID
      }
    }
    // WebKit-based meeting clients can render audio in a launchd-owned
    // `com.apple.WebKit` process whose immediate ancestry no longer reaches
    // the host application's audio process. macOS still gives that helper a
    // host-qualified display name (for example, "<App> Graphics and Media").
    // When exactly that host application is also present in the HAL catalog,
    // adopt its stable bundle identity. This keeps the helper inside the
    // selected-app boundary without merging an unrelated generic WebKit
    // process merely because it shares the framework bundle identifier.
    if let ownerName = helperOwnerDisplayName(process.displayName),
      let namedOwner = processByID.values
        .filter({ candidate in
          candidate.processID != process.processID
            && !isHelperDisplayName(candidate.displayName)
            && cleanedDisplayName(candidate.displayName)
              .caseInsensitiveCompare(ownerName) == .orderedSame
        })
        .sorted(by: { $0.processID < $1.processID })
        .first
    {
      rootName = namedOwner.displayName
      if let ownerBundleID = canonicalBundleID(namedOwner.bundleID) {
        bundleID = ownerBundleID
      }
    }
    if let bundleID { return "bundle:\(bundleID)" }
    return "name:\(cleanedDisplayName(rootName).lowercased())"
  }

  private static func canonicalBundleID(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    let helperComponents: Set<String> = [
      "helper", "renderer", "gpu", "plugin", "utility",
    ]
    guard
      let helperIndex = components.firstIndex(where: {
        helperComponents.contains($0.lowercased())
      }), helperIndex >= 2
    else { return trimmed }
    return components[..<helperIndex].joined(separator: ".")
  }

  private static func isHelperDisplayName(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return [
      " helper", " renderer", " gpu", " utility", " web content",
      " graphics and media",
    ]
    .contains { lowercased.contains($0) }
  }

  private static func helperOwnerDisplayName(_ value: String) -> String? {
    let markers = [
      " Graphics and Media", " Web Content", " Helper", " Renderer",
      " GPU", " Utility",
    ]
    guard
      let match = markers.compactMap({ marker in
        value.range(of: marker, options: .caseInsensitive).map {
          (range: $0, marker: marker)
        }
      }).min(by: { $0.range.lowerBound < $1.range.lowerBound })
    else { return nil }
    let owner = value[..<match.range.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return owner.isEmpty ? nil : owner
  }

  private static func cleanedDisplayName(_ value: String) -> String {
    var result = value
    for marker in [
      " Graphics and Media", " Web Content", " Helper", " Renderer", " GPU",
      " Utility",
    ] {
      if let range = result.range(of: marker, options: .caseInsensitive) {
        result = String(result[..<range.lowerBound])
      }
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? value : trimmed
  }
}
