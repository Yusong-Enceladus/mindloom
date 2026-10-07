import BestASRDomain
import BestASRIntake
import Foundation
import MindloomAgentProtocol
import MindloomShareDrop

/// The entries the owner triggers each time: the share extension, the
/// Services menu, Shortcuts and the command line (V8 contract A1–A3). Each
/// turns what it was handed into intake items: text as text, a link as text
/// (never fetched), bytes (and, from the share extension, a file it copied
/// in) through the image path or the file rules. Only the owner's own
/// command line names files by their path.
public enum HandEntries {
  // MARK: Share extension (A1)

  /// One share left in the drop folder, as intake items.
  public static func items(from pending: ShareDropbox.Pending) -> (
    items: [EntryIntakeItem], refused: [String]
  ) {
    let entry = pending.entry
    // Whatever App the drop names cannot be checked (F10).
    let source = EntrySource.share(entry)
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
        // A path in a drop is never opened (F10, AGENT-IO N4): any program
        // can write the drop folder, and Mindloom would read the file with
        // its own rights. The extension copies a shared file in instead.
        refused.append(sharedPathRefusal)
      case .data:
        guard let url = pending.dataURL(part),
          let size = ShareDropbox.regularFileSize(url)
        else {
          refused.append("无法读取共享的内容，未添加")
          continue
        }
        do {
          let (candidate, scratch): (IntakeCandidate, URL?)
          if size <= ShareDropbox.maximumDataBytes {
            guard let bytes = readRegularFile(url, limit: ShareDropbox.maximumDataBytes) else {
              refused.append("无法读取共享的内容，未添加")
              continue
            }
            (candidate, scratch) = try EntryCandidates.data(
              bytes, filename: part.name ?? "file", typeIdentifier: part.type)
          } else if size <= ShareDropbox.maximumFileBytes {
            // A shared file the extension copied in: cloned into a scratch
            // folder of its own, read by the file rules.
            (candidate, scratch) = try EntryCandidates.copiedFile(
              url, filename: part.name ?? "file")
          } else {
            refused.append("共享的文件过大，未添加。可以将它拖到 Mindloom 中")
            continue
          }
          items.append(
            .init(candidate: candidate, source: source, capturedAt: time, scratch: scratch))
        } catch {
          refused.append("无法读取共享的内容，未添加")
        }
      }
    }
    return (items, refused)
  }

  /// What a drop that names a path (an extension from before v12, or a
  /// program writing the drop folder) is told.
  public static let sharedPathRefusal = "有一项仅提供了文件位置，未添加。请重新共享此文件"

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
        refused.append("仅支持这台 Mac 上的文件，未添加")
      }
    }
    return (items, refused)
  }

  // MARK: Chrome extension (A6)

  /// 「收进织机」 in Chrome: the selection (with the page it came from), the
  /// page link, or a link on the page. Links stay text, never fetched.
  public static func browser(_ request: BrowserAddRequest, at time: Date) -> [EntryIntakeItem] {
    let source = EntrySource.browser(request)
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
