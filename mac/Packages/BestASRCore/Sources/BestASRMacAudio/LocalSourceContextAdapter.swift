import AppKit
import ApplicationServices
import BestASRDomain
import Foundation

/// Runs optional local source adapters away from the App's main actor. Adapter
/// failure always returns `nil`; capture and durable audio never depend on it.
@available(macOS 14.2, *)
public actor LocalSourceContextAdapterRegistry {
  public init() {}

  public func snapshot(
    source: SystemAudioSource,
    sessionID: SessionID,
    revision: Revision,
    monotonicNanoseconds: UInt64
  ) -> SourceContextSnapshot? {
    guard let application = Self.runningApplication(for: source) else {
      return nil
    }
    let windowTitle = Self.frontmostWindowTitle(processID: application.processIdentifier)
    let bundleID = source.bundleID ?? application.bundleIdentifier
    if Self.isTencentMeeting(bundleID: bundleID, displayName: source.displayName) {
      let explicit = AXMeetingContextReader.read(
        processID: application.processIdentifier
      )
      let title = explicit.meetingTitle ?? windowTitle
      guard
        title != nil || !explicit.participants.isEmpty
          || explicit.activeSpeaker != nil
      else { return nil }
      return SourceContextSnapshot(
        sessionID: sessionID,
        revision: revision,
        adapterID: "tencent-meeting-local-v1",
        sourceBundleID: bundleID,
        meetingTitle: title,
        windowTitle: windowTitle,
        participantDisplayNames: explicit.participants,
        activeSpeakerDisplayName: explicit.activeSpeaker,
        monotonicNanoseconds: monotonicNanoseconds,
        reliability: explicit.hasExplicitMeetingEvidence ? .reliable : .advisory
      )
    }
    guard let windowTitle else { return nil }
    return SourceContextSnapshot(
      sessionID: sessionID,
      revision: revision,
      adapterID: "generic-visible-window-v1",
      sourceBundleID: bundleID,
      meetingTitle: nil,
      windowTitle: windowTitle,
      participantDisplayNames: [],
      activeSpeakerDisplayName: nil,
      monotonicNanoseconds: monotonicNanoseconds,
      reliability: .advisory
    )
  }

  private static func runningApplication(
    for source: SystemAudioSource
  ) -> NSRunningApplication? {
    if let bundleID = source.bundleID {
      return NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleID
      ).first(where: { !$0.isTerminated })
    }
    let normalized = source.displayName.lowercased()
    return NSWorkspace.shared.runningApplications.first(where: {
      !$0.isTerminated
        && ($0.localizedName?.lowercased() == normalized
          || $0.executableURL?.deletingPathExtension().lastPathComponent
            .lowercased() == normalized)
    })
  }

  private static func frontmostWindowTitle(processID: pid_t) -> String? {
    guard
      let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else { return nil }
    return raw.compactMap { item -> (title: String, area: Double)? in
      guard
        (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
          == processID,
        (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let title = normalizedText(item[kCGWindowName as String] as? String),
        let bounds = item[kCGWindowBounds as String] as? [String: Any],
        let width = (bounds["Width"] as? NSNumber)?.doubleValue,
        let height = (bounds["Height"] as? NSNumber)?.doubleValue,
        width >= 120, height >= 80
      else { return nil }
      return (title, width * height)
    }.max(by: { $0.area < $1.area })?.title
  }

  private static func isTencentMeeting(
    bundleID: String?,
    displayName: String
  ) -> Bool {
    let identity = "\(bundleID ?? "") \(displayName)".lowercased()
    return ["wemeet", "tencentmeeting", "tencent meeting", "腾讯会议"]
      .contains(where: identity.contains)
  }

  fileprivate static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 1_024,
      !normalized.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else { return nil }
    return normalized
  }
}

@available(macOS 14.2, *)
private enum AXMeetingContextReader {
  struct Result {
    let meetingTitle: String?
    let participants: [String]
    let activeSpeaker: String?
    let hasExplicitMeetingEvidence: Bool
  }

  private struct NodeText {
    let text: String
    let role: String
    let context: String
  }

  private static let participantMarkers = [
    "参会者", "与会者", "成员", "participants", "attendees",
  ]
  private static let speakingMarkers = [
    "正在说话", "正在发言", "发言中", "speaking", "active speaker",
  ]
  private static let ignoredParticipantLabels: Set<String> = [
    "参会者", "与会者", "成员", "participants", "attendees", "邀请",
    "invite", "静音", "mute", "解除静音", "unmute", "更多", "more",
    "搜索", "search", "主持人", "host", "联席主持人", "co-host",
  ]

  static func read(processID: pid_t) -> Result {
    guard AXIsProcessTrusted() else {
      return Result(
        meetingTitle: nil,
        participants: [],
        activeSpeaker: nil,
        hasExplicitMeetingEvidence: false
      )
    }
    let app = AXUIElementCreateApplication(processID)
    var nodes: [NodeText] = []
    var visited = 0
    collect(
      element: app,
      inheritedContext: "",
      depth: 0,
      visited: &visited,
      output: &nodes
    )
    var participants: [String] = []
    var activeSpeaker: String?
    var meetingTitle: String?
    for node in nodes {
      let lowerContext = node.context.lowercased()
      let lowerText = node.text.lowercased()
      if activeSpeaker == nil,
        speakingMarkers.contains(where: {
          lowerContext.contains($0) || lowerText.contains($0)
        }), let candidate = speakerName(from: node.text)
      {
        activeSpeaker = candidate
      }
      if participantMarkers.contains(where: lowerContext.contains),
        isPlausibleParticipantName(node.text),
        !participants.contains(node.text)
      {
        participants.append(node.text)
      }
      if meetingTitle == nil,
        lowerContext.contains("会议主题") || lowerContext.contains("meeting title"),
        node.text.count >= 2
      {
        meetingTitle = node.text
      }
    }
    if let activeSpeaker, !participants.contains(activeSpeaker) {
      participants.append(activeSpeaker)
    }
    return Result(
      meetingTitle: meetingTitle,
      participants: Array(participants.prefix(500)),
      activeSpeaker: activeSpeaker,
      hasExplicitMeetingEvidence:
        meetingTitle != nil || !participants.isEmpty || activeSpeaker != nil
    )
  }

  private static func collect(
    element: AXUIElement,
    inheritedContext: String,
    depth: Int,
    visited: inout Int,
    output: inout [NodeText]
  ) {
    guard depth <= 9, visited < 2_000 else { return }
    visited += 1
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
    let pieces = [
      stringAttribute(element, kAXTitleAttribute as CFString),
      stringAttribute(element, kAXDescriptionAttribute as CFString),
      stringAttribute(element, kAXHelpAttribute as CFString),
      stringAttribute(element, kAXValueAttribute as CFString),
    ].compactMap(LocalSourceContextAdapterRegistry.normalizedText)
    let ownContext = pieces.joined(separator: " ")
    let context = [inheritedContext, ownContext]
      .filter { !$0.isEmpty }.joined(separator: " ")
    for text in pieces
    where !output.contains(where: {
      $0.text == text && $0.context == context
    }) {
      output.append(NodeText(text: text, role: role, context: context))
    }
    for child in elementsAttribute(element, kAXChildrenAttribute as CFString) {
      collect(
        element: child,
        inheritedContext: context,
        depth: depth + 1,
        visited: &visited,
        output: &output
      )
      guard visited < 2_000 else { return }
    }
  }

  private static func stringAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success
    else { return nil }
    return value as? String
  }

  private static func elementsAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
      let values = value as? [CFTypeRef]
    else { return [] }
    return values.compactMap { value in
      guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      return unsafeDowncast(value, to: AXUIElement.self)
    }
  }

  private static func speakerName(from text: String) -> String? {
    var candidate = text
    for marker in speakingMarkers {
      candidate = candidate.replacingOccurrences(
        of: marker,
        with: "",
        options: [.caseInsensitive]
      )
    }
    candidate = candidate.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "·:：-—()（）[]【】")
      )
    )
    return isPlausibleParticipantName(candidate) ? candidate : nil
  }

  private static func isPlausibleParticipantName(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count >= 1, normalized.count <= 64,
      normalized.split(whereSeparator: { $0.isWhitespace }).count <= 8,
      !ignoredParticipantLabels.contains(normalized.lowercased()),
      !normalized.contains("http"), !normalized.contains("@")
    else { return false }
    return normalized.unicodeScalars.contains(where: {
      CharacterSet.letters.contains($0)
    })
  }
}
