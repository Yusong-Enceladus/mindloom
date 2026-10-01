import BestASRDomain
import BestASRIntake
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MindloomAgentProtocol

/// One thing an entry hands to intake: a candidate (exactly what a paste or a
/// drop would give), its source and its time. Entries never build items
/// themselves; `EntryCommitter` runs the shared intake rules.
public struct EntryIntakeItem: Equatable, Sendable {
  public let candidate: IntakeCandidate
  public let source: ItemSourceApplication?
  public let capturedAt: Date
  /// Fixed for entries that may see the same thing twice (a calendar event,
  /// a commit); nil gives a fresh ID.
  public let id: SessionID?
  /// A scratch folder to remove once the candidate has been staged.
  public let scratch: URL?

  public init(
    candidate: IntakeCandidate, source: ItemSourceApplication?, capturedAt: Date,
    id: SessionID? = nil, scratch: URL? = nil
  ) {
    self.candidate = candidate
    self.source = source
    self.capturedAt = capturedAt
    self.id = id
    self.scratch = scratch
  }
}

/// The source labels entries give their items ("已收进来 · 来自 日历").
public enum EntrySource {
  public static let shareFallback = "分享"
  public static let shortcuts = "快捷指令"
  public static let commandLine = "命令行"
  public static let browser = BrowserExtension.sourceName
  public static let calendar = "日历"
  public static let zotero = "Zotero"

  public static func folder(_ name: String) -> String { "文件夹 · \(name)" }
  public static func git(_ repository: String) -> String { "Git · \(repository)" }

  public static func named(_ name: String) -> ItemSourceApplication? {
    ItemSourceApplication(bundleID: nil, name: name)
  }
}

/// How each entry's text was made (the item's `extractor`).
public enum EntryExtractor {
  public static let shareText = "share-text-v1"
  public static let shareLink = "share-link-v1"
  public static let servicesText = "services-text-v1"
  public static let shortcutText = "shortcut-text-v1"
  public static let shortcutLink = "shortcut-link-v1"
  public static let commandLineText = "cli-text-v1"
  public static let commandLineLink = "cli-link-v1"
  public static let browserSelection = "browser-selection-v1"
  public static let browserPage = "browser-page-v1"
  public static let browserLink = "browser-link-v1"
  public static let calendarEvent = "calendar-event-v1"
  public static let gitCommit = "git-commit-v1"
  public static let zoteroItem = "zotero-item-v1"
}

public enum EntryIdentity {
  /// A stable item ID for an entry key: the same event or commit always maps
  /// to the same item, so a crash between commit and bookkeeping never takes
  /// it twice.
  public static func itemID(_ kind: EntryKind, key: String) -> SessionID {
    var bytes = Array(SHA256.hash(data: Data("mindloom-entry-v1|\(kind.rawValue)|\(key)".utf8)))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return SessionID(uuid)
  }
}

/// Builds candidates the way paste and drop do. A link is text (its title and
/// its URL on its own line) and is never opened; a file is its local path.
public enum EntryCandidates {
  /// A link as an item: only `http`, `https`, `mailto` and similar text is
  /// kept; nothing is fetched. Nil when the string is empty.
  public static func link(_ url: String, title: String?, note: String? = nil, extractor: String)
    -> IntakeCandidate?
  {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return .text(
      IntakeInboxIngestor.linkText(url: trimmed, title: title, note: note), extractor: extractor)
  }

  public static func text(_ text: String, extractor: String) -> IntakeCandidate? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil : .text(text, extractor: extractor)
  }

  /// A local file by its absolute path; anything else (a web URL) is refused.
  public static func file(path: String) -> IntakeCandidate? {
    guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
    return .file(URL(fileURLWithPath: path).standardizedFileURL)
  }

  /// Bytes that are not a file on disk (a Shortcuts file, a shared image):
  /// an image goes the image path; anything else is written to a private
  /// scratch folder and taken in by the file rules. Returns the scratch
  /// folder to remove after staging.
  public static func data(_ bytes: Data, filename: String, typeIdentifier: String?) throws
    -> (IntakeCandidate, URL?)
  {
    // A PNG, JPEG or HEIC that ImageIO reads, whatever it was called; any
    // other picture keeps its name and goes the file rules (which take a
    // picture under any name as a picture).
    if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?,
      ["public.png", "public.jpeg", "public.heic"].contains(type)
    {
      return (.imageData(bytes, typeIdentifier: type), nil)
    }
    let staged = try IntakeInboxIngestor.writeScratch(
      bytes, filename: InboxSafeName.sanitized(filename))
    return (.file(staged), staged.deletingLastPathComponent())
  }
}

/// A file name safe to write into a scratch folder.
enum InboxSafeName {
  static func sanitized(_ name: String) -> String {
    let base = (name as NSString).lastPathComponent
    let cleaned = base.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":"
    }
    var result = String(String.UnicodeScalarView(cleaned))
    while result.hasPrefix(".") { result.removeFirst() }
    if result.isEmpty { result = "file" }
    if result.utf8.count > 200 { result = String(result.prefix(120)) }
    return result
  }
}

/// What committing a batch of entry items gave.
public struct EntryCommitSummary: Equatable, Sendable {
  public var stored: [SessionID] = []
  public var alreadyTaken: [SessionID] = []
  /// Audio or video: for the App's one-at-a-time import pipeline.
  public var media: [URL] = []
  public var rejected: [String] = []

  public init() {}

  public var storedCount: Int { stored.count }

  /// The confirmation text, as paste and drop show it.
  public func confirmation(source: ItemSourceApplication?, mediaStarted: Bool = false) -> String {
    IntakeConfirmation.text(
      stored: stored.count, mediaStarted: mediaStarted, mediaWaiting: media.count,
      rejected: rejected, source: source)
  }
}

/// Runs entry items through the shared intake path: `IntakeProcessor`
/// (`prepareAll`, so a zip is expanded like a drop), the store's
/// `createUserItem`, then the staged files' commit. Idempotent for items with
/// a fixed ID.
public struct EntryCommitter: Sendable {
  public let processor: IntakeProcessor
  public let store: any UserItemCommitting
  /// Awaited before each commit (the App's staging sweep).
  public let ready: @Sendable () async -> Void

  public init(
    processor: IntakeProcessor, store: any UserItemCommitting,
    ready: @escaping @Sendable () async -> Void = {}
  ) {
    self.processor = processor
    self.store = store
    self.ready = ready
  }

  public func commit(_ items: [EntryIntakeItem]) async -> EntryCommitSummary {
    var summary = EntryCommitSummary()
    await ready()
    for (index, item) in items.enumerated() {
      defer { item.scratch.map { try? FileManager.default.removeItem(at: $0) } }
      if let id = item.id,
        (try? await store.existingSessionIDs(among: [id]))?.contains(id) == true
      {
        summary.alreadyTaken.append(id)
        continue
      }
      // Several items given together keep their order.
      let capturedAt = item.capturedAt.addingTimeInterval(Double(index) * 0.000_1)
      let outcomes: [IntakeOutcome]
      if let id = item.id {
        outcomes = [
          processor.prepare(
            item.candidate, id: id, capturedAt: capturedAt, source: item.source, origin: .unknown)
        ]
      } else {
        outcomes = processor.prepareAll(
          item.candidate, capturedAt: capturedAt, source: item.source, origin: .unknown)
      }
      for outcome in outcomes {
        switch outcome {
        case .item(let draft):
          do {
            try await store.createUserItem(draft)
            processor.assetStore.commit(sessionID: draft.id)
            summary.stored.append(draft.id)
          } catch {
            processor.assetStore.discard(sessionID: draft.id)
            if (try? await store.existingSessionIDs(among: [draft.id]))?.contains(draft.id) == true
            {
              summary.alreadyTaken.append(draft.id)
            } else {
              summary.rejected.append("未能保存到资料库，未收进来")
            }
          }
        case .media(let url):
          if item.scratch != nil {
            // Bytes handed over without a file of their own: the import
            // pipeline reads files later, after the scratch copy is gone.
            summary.rejected.append("音视频请在访达里分享文件，或拖进织机导入")
          } else {
            summary.media.append(url)
          }
        case .rejected(let message):
          summary.rejected.append(message)
        }
      }
    }
    return summary
  }
}
