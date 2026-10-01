import BestASRDomain
import BestASRIntake
import Foundation
import MindloomAgentProtocol
import MindloomShareDrop

/// The entries the owner triggers each time: the share extension, the
/// Services menu, Shortcuts and the command line (V8 contract A1–A3). Each
/// turns what it was handed into intake items: text as text, a link as text
/// (never fetched), a file by its path under the drop rules, bytes through
/// the image path or the file rules.
public enum HandEntries {
  // MARK: Share extension (A1)

  /// One share left in the drop folder, as intake items.
  public static func items(from pending: ShareDropbox.Pending) -> (
    items: [EntryIntakeItem], refused: [String]
  ) {
    let entry = pending.entry
    let source =
      ItemSourceApplication(bundleID: entry.sourceBundleID, name: entry.sourceName)
      ?? EntrySource.named(EntrySource.shareFallback)
    let time = entry.createdDate ?? Date()
    var items: [EntryIntakeItem] = []
    var refused: [String] = []
    for part in entry.parts {
      switch part.kind {
      case .text:
        if let candidate = EntryCandidates.text(
          part.text ?? "", extractor: EntryExtractor.shareText)
        {
          items.append(.init(candidate: candidate, source: source, capturedAt: time))
        }
      case .link:
        if let candidate = EntryCandidates.link(
          part.url ?? "", title: part.title, note: part.text, extractor: EntryExtractor.shareLink)
        {
          items.append(.init(candidate: candidate, source: source, capturedAt: time))
        }
      case .file:
        if let candidate = EntryCandidates.file(path: part.path ?? "") {
          items.append(.init(candidate: candidate, source: source, capturedAt: time))
        } else {
          refused.append("只收本机文件，未收进来")
        }
      case .data:
        guard let url = pending.dataURL(part),
          let bytes = readRegularFile(url, limit: ShareDropbox.maximumDataBytes)
        else {
          refused.append("分享的内容读不出来，未收进来")
          continue
        }
        do {
          let (candidate, scratch) = try EntryCandidates.data(
            bytes, filename: part.name ?? "file", typeIdentifier: part.type)
          items.append(
            .init(candidate: candidate, source: source, capturedAt: time, scratch: scratch))
        } catch {
          refused.append("分享的内容读不出来，未收进来")
        }
      }
    }
    return (items, refused)
  }

  // MARK: Services (A1)

  /// Selected text from another App's Services menu.
  public static func servicesText(_ text: String, source: ItemSourceApplication?, at time: Date)
    -> [EntryIntakeItem]
  {
    guard let candidate = EntryCandidates.text(text, extractor: EntryExtractor.servicesText)
    else { return [] }
    return [.init(candidate: candidate, source: source, capturedAt: time)]
  }

  // MARK: Shortcuts (A2)

  /// 「添加到织机」: text, a link, and/or a file's bytes.
  public static func shortcut(
    text: String?, url: String?, file: (data: Data, filename: String, type: String?)?,
    at time: Date
  ) throws -> [EntryIntakeItem] {
    let source = EntrySource.named(EntrySource.shortcuts)
    var items: [EntryIntakeItem] = []
    if let text, let candidate = EntryCandidates.text(text, extractor: EntryExtractor.shortcutText)
    {
      items.append(.init(candidate: candidate, source: source, capturedAt: time))
    }
    if let url,
      let candidate = EntryCandidates.link(url, title: nil, extractor: EntryExtractor.shortcutLink)
    {
      items.append(.init(candidate: candidate, source: source, capturedAt: time))
    }
    if let file {
      let (candidate, scratch) = try EntryCandidates.data(
        file.data, filename: file.filename, typeIdentifier: file.type)
      items.append(.init(candidate: candidate, source: source, capturedAt: time, scratch: scratch))
    }
    return items
  }

  // MARK: Command line (A3)

  /// `mindloom add`: the owner's own intake, source 命令行.
  public static func commandLine(_ request: OwnerAddRequest, at time: Date) -> (
    items: [EntryIntakeItem], refused: [String]
  ) {
    let source = EntrySource.named(EntrySource.commandLine)
    var items: [EntryIntakeItem] = []
    var refused: [String] = []
    if let text = request.text,
      let candidate = EntryCandidates.text(text, extractor: EntryExtractor.commandLineText)
    {
      items.append(.init(candidate: candidate, source: source, capturedAt: time))
    }
    if let url = request.url,
      let candidate = EntryCandidates.link(
        url, title: request.title, extractor: EntryExtractor.commandLineLink)
    {
      items.append(.init(candidate: candidate, source: source, capturedAt: time))
    }
    for path in request.filePaths {
      if let candidate = EntryCandidates.file(path: path) {
        items.append(.init(candidate: candidate, source: source, capturedAt: time))
      } else {
        refused.append("只收本机文件，未收进来")
      }
    }
    return (items, refused)
  }

  // MARK: Chrome extension (A6)

  /// 「收进织机」 in Chrome: the selection (with the page it came from), the
  /// page link, or a link on the page. Links stay text, never fetched.
  public static func browser(_ request: BrowserAddRequest, at time: Date) -> [EntryIntakeItem] {
    let source = EntrySource.named(EntrySource.browser)
    let candidate: IntakeCandidate?
    switch request.kind {
    case .selection:
      guard let text = request.text else { return [] }
      if let url = request.url {
        // The selection first, then where it came from.
        candidate = EntryCandidates.text(
          text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            + IntakeInboxIngestor.linkText(url: url, title: request.title, note: nil),
          extractor: EntryExtractor.browserSelection)
      } else {
        candidate = EntryCandidates.text(text, extractor: EntryExtractor.browserSelection)
      }
    case .page:
      candidate = request.url.flatMap {
        EntryCandidates.link($0, title: request.title, extractor: EntryExtractor.browserPage)
      }
    case .link:
      candidate = request.url.flatMap {
        EntryCandidates.link(
          $0, title: request.title, note: request.text, extractor: EntryExtractor.browserLink)
      }
    }
    guard let candidate else { return [] }
    return [.init(candidate: candidate, source: source, capturedAt: time)]
  }

  static func readRegularFile(_ url: URL, limit: Int) -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else {
      return nil
    }
    return data
  }
}
