import Foundation
import UniformTypeIdentifiers

/// Reads what the share sheet handed over (`NSExtensionItem` attachments)
/// into `ShareInput`s. Audio and video are recognized by their declared
/// types and refused without their bytes ever being loaded. Files are copied
/// into `workDirectory` (the extension's own temporary folder) because the
/// system removes its copy when the load call returns; `removeCopies()`
/// deletes them once the items are sealed.
public struct ShareItemLoader: Sendable {
  public let workDirectory: URL

  public init(workDirectory: URL) {
    self.workDirectory = workDirectory
  }

  public static func temporary() -> ShareItemLoader {
    ShareItemLoader(
      workDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true))
  }

  public func removeCopies() {
    try? FileManager.default.removeItem(at: workDirectory)
  }

  /// All inputs of all items, in order. Items without attachments contribute
  /// their text.
  public func inputs(from items: [NSExtensionItem]) async -> [ShareInput] {
    var inputs: [ShareInput] = []
    for item in items {
      let title = (item.attributedTitle ?? item.attributedContentText)?.string
      let providers = item.attachments ?? []
      if providers.isEmpty {
        if let text = item.attributedContentText?.string,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          inputs.append(.text(text))
        }
        continue
      }
      for provider in providers {
        if let input = await input(from: provider, title: title) { inputs.append(input) }
      }
    }
    return inputs
  }

  /// One provider's best representation.
  public func input(from provider: NSItemProvider, title: String?) async -> ShareInput? {
    let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
    let name = provider.suggestedName
    let primary = types.first
    if let primary, ShareItemConverter.isAudioOrVideoType(primary) {
      return .audioOrVideo(name: name)
    }
    if let imageType = types.first(where: { $0.conforms(to: .image) }), imageType != .pdf,
      !imageType.conforms(to: .svg)
    {
      guard let file = await copyFile(provider, type: imageType) else { return nil }
      return .image(await withOriginalName(file, provider: provider, types: types))
    }
    if types.contains(where: ShareItemConverter.isAudioOrVideoType) {
      return .audioOrVideo(name: name)
    }
    if types.contains(where: { $0.conforms(to: .url) }) {
      switch await loadItem(provider, type: .url) {
      case .url(let url) where url.isFileURL:
        return await fileInput(provider, types: types)
      case .url(let url):
        return .link(url, title: title)
      case .text(let text):
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme != nil
        {
          return url.isFileURL ? await fileInput(provider, types: types) : .link(url, title: title)
        }
        return .text(text)
      case .none:
        break
      }
    }
    if let textType = types.first(where: { $0.conforms(to: .text) }),
      !types.contains(where: { $0.conforms(to: .fileURL) })
    {
      switch await loadItem(provider, type: textType) {
      case .text(let text):
        return .text(text)
      case .url(let url):
        if url.isFileURL { return await fileInput(provider, types: types) }
        return .link(url, title: title)
      case .none:
        break
      }
    }
    return await fileInput(provider, types: types)
  }

  // MARK: - Loading

  private enum Loaded: Sendable {
    case text(String)
    case url(URL)
  }

  /// Loads a URL or a text: through the provider's object loading first
  /// (NSURL / NSString, which decodes what apps register as objects), then
  /// through the raw item.
  private func loadItem(_ provider: NSItemProvider, type: UTType) async -> Loaded? {
    if type.conforms(to: .url), provider.canLoadObject(ofClass: NSURL.self) {
      let url: URL? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
          continuation.resume(returning: (object as? NSURL).map { $0 as URL })
        }
      }
      if let url { return .url(url) }
    }
    if type.conforms(to: .text), provider.canLoadObject(ofClass: NSString.self) {
      let text: String? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
          continuation.resume(returning: (object as? NSString).map { $0 as String })
        }
      }
      if let text { return .text(text) }
    }
    return await loadRawItem(provider, type: type)
  }

  private func loadRawItem(_ provider: NSItemProvider, type: UTType) async -> Loaded? {
    await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
        switch item {
        case let url as URL:
          continuation.resume(returning: .url(url))
        case let text as String:
          continuation.resume(returning: .text(text))
        case let attributed as NSAttributedString:
          continuation.resume(returning: .text(attributed.string))
        case let data as Data:
          if let text = String(data: data, encoding: .utf8) {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.scheme != nil,
              !text.contains(where: \.isWhitespace), type.conforms(to: .url)
            {
              continuation.resume(returning: .url(url))
            } else {
              continuation.resume(returning: .text(text))
            }
          } else {
            continuation.resume(returning: nil)
          }
        default:
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func fileInput(_ provider: NSItemProvider, types: [UTType]) async -> ShareInput? {
    let type =
      types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) })
      ?? types.first(where: { !$0.conforms(to: .url) }) ?? .data
    guard let copied = await copyFile(provider, type: type) else { return nil }
    let file = await withOriginalName(copied, provider: provider, types: types)
    if ShareItemConverter.isAudioOrVideo(file) { return .audioOrVideo(name: file.suggestedName) }
    return .file(file)
  }

  /// The system's copy has a generic name ("PDF document.pdf") when the
  /// provider suggests none; the file's own name is kept instead.
  private func withOriginalName(_ file: ShareFile, provider: NSItemProvider, types: [UTType]) async
    -> ShareFile
  {
    guard file.suggestedName == nil, types.contains(where: { $0.conforms(to: .fileURL) }),
      case .url(let original) = await loadItem(provider, type: .fileURL), original.isFileURL
    else { return file }
    return ShareFile(
      url: file.url, typeIdentifier: file.typeIdentifier,
      suggestedName: original.deletingPathExtension().lastPathComponent)
  }

  /// Copies the provider's file for `type` into the work directory; falls
  /// back to its in-memory data representation.
  private func copyFile(_ provider: NSItemProvider, type: UTType) async -> ShareFile? {
    let directory = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suggested = provider.suggestedName
    let copied: URL? = await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
        guard let url else {
          continuation.resume(returning: nil)
          return
        }
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let target = directory.appendingPathComponent(url.lastPathComponent)
          try FileManager.default.copyItem(at: url, to: target)
          continuation.resume(returning: target)
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
    if let copied {
      return ShareFile(url: copied, typeIdentifier: type.identifier, suggestedName: suggested)
    }
    let data: Data? = await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, _ in
        continuation.resume(returning: data)
      }
    }
    guard let data else { return nil }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let ext = type.preferredFilenameExtension.map { "." + $0 } ?? ""
      let target = directory.appendingPathComponent("item" + ext)
      try data.write(to: target)
      return ShareFile(url: target, typeIdentifier: type.identifier, suggestedName: suggested)
    } catch {
      return nil
    }
  }
}
