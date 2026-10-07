import AppKit
import MindloomShareDrop
import UniformTypeIdentifiers

/// 收进 Mindloom on the Mac (V8 contract A1): the share sheet of Safari, Mail,
/// Notes, Finder and any other App. It collects what was shared — text, a
/// link (never fetched), a file (copied in whole, v12 F10: the App never
/// opens a path a drop names), an image or other bytes — and leaves it in
/// Mindloom's drop folder; the App takes it in through the same intake rules
/// as a paste or a drop.
/// Sandboxed: it can write only that one folder, and it opens nothing but
/// `<scheme>://share-inbox` to tell the App to look. The scheme and the
/// library come from this extension's Info.plist (`MindloomURLScheme`,
/// `MindloomShareDropRoot`): the owner's library for the App, the synthetic
/// preview root for Mindloom Preview.
final class ShareViewController: NSViewController {
  private let titleLabel = NSTextField(labelWithString: "添加到 Mindloom")
  private let summaryLabel = NSTextField(wrappingLabelWithString: "正在读取分享的内容…")
  private let noteLabel = NSTextField(
    wrappingLabelWithString: "添加到这台 Mac 上的 Mindloom。链接按文字添加，文件会拷贝到 Mindloom。")
  private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
  private let sendButton = NSButton(title: "添加", target: nil, action: nil)
  private var collected: ShareCollection?
  private let source = NSWorkspace.shared.frontmostApplication

  override func loadView() {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 168))
    titleLabel.font = .boldSystemFont(ofSize: 15)
    noteLabel.font = .systemFont(ofSize: 11)
    noteLabel.textColor = .secondaryLabelColor
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    sendButton.target = self
    sendButton.action = #selector(send)
    sendButton.keyEquivalent = "\r"
    sendButton.isEnabled = false
    let buttons = NSStackView(views: [NSView(), cancelButton, sendButton])
    buttons.orientation = .horizontal
    let stack = NSStackView(views: [titleLabel, summaryLabel, noteLabel, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: view.topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
      summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
      noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
    ])
    self.view = view
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    Task { @MainActor in
      let collection = await ShareCollector.collect(items)
      collected = collection
      show(collection)
    }
  }

  private func show(_ collection: ShareCollection) {
    guard let dropbox = Self.dropbox, dropbox.isOpen else {
      summaryLabel.stringValue =
        "共享入口未打开。请在 Mindloom 的“设置”>“入口”中打开“共享菜单”，然后打开一次 Mindloom。"
      sendButton.isEnabled = false
      return
    }
    guard !collection.parts.isEmpty else {
      summaryLabel.stringValue = collection.refused.first ?? "没有可添加的内容。"
      return
    }
    var line = collection.summary
    if let name = source?.localizedName { line += " · 来自 \(name)" }
    if !collection.refused.isEmpty { line += "（\(collection.refused.count) 项无法添加）" }
    summaryLabel.stringValue = line
    sendButton.isEnabled = true
  }

  @objc private func send() {
    guard let collection = collected, let dropbox = Self.dropbox else {
      return
    }
    let entry = ShareDropEntry(
      sourceBundleID: source?.bundleIdentifier, sourceName: source?.localizedName,
      parts: collection.parts)
    // The shared files are read here, inside the share, and copied in.
    let opened = collection.files.values.filter { $0.startAccessingSecurityScopedResource() }
    defer {
      for url in opened { url.stopAccessingSecurityScopedResource() }
    }
    do {
      try dropbox.write(entry, data: collection.data, files: collection.files)
    } catch ShareDropbox.DropError.closed {
      summaryLabel.stringValue = "共享入口未打开。请在 Mindloom 的“设置”>“入口”中打开“共享菜单”。"
      return
    } catch ShareDropbox.DropError.tooLarge {
      summaryLabel.stringValue = "内容过大。请将文件拖到 Mindloom 中。"
      return
    } catch {
      summaryLabel.stringValue = "未能发送到 Mindloom。请重试。"
      return
    }
    // Tell the App to look; the URL carries nothing.
    if let url = URL(string: Self.scheme + "://share-inbox") {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      NSWorkspace.shared.open(url, configuration: configuration)
    }
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// The App's URL scheme (`mindloom`, or `mindloom-preview` for the preview).
  private static var scheme: String {
    let value = Bundle.main.object(forInfoDictionaryKey: "MindloomURLScheme") as? String
    return value.flatMap { $0.isEmpty ? nil : $0 } ?? "mindloom"
  }

  /// The drop folder: the owner's library, unless this build names its own
  /// root (Mindloom Preview's absolute one, a development build's folder in
  /// the owner's home).
  private static var dropbox: ShareDropbox? {
    ShareDropbox.forRootSetting(
      Bundle.main.object(forInfoDictionaryKey: "MindloomShareDropRoot") as? String)
  }

  @objc private func cancel() {
    extensionContext?.cancelRequest(
      withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }
}

/// What the share sheet handed over, as drop-folder parts.
struct ShareCollection: Sendable {
  var parts: [ShareDropEntry.Part] = []
  var data: [String: Data] = [:]
  /// Shared files, copied into the drop when it is written (F10).
  var files: [String: URL] = [:]
  var refused: [String] = []

  var summary: String {
    var counts: [String] = []
    let texts = parts.filter { $0.kind == .text }.count
    let links = parts.filter { $0.kind == .link }.count
    let files = parts.filter { $0.kind == .file || $0.kind == .data }.count
    if texts > 0 { counts.append("\(texts) 段文字") }
    if links > 0 { counts.append("\(links) 个链接") }
    if files > 0 { counts.append("\(files) 个文件或图片") }
    return counts.joined(separator: "、")
  }
}

@MainActor
enum ShareCollector {
  static func collect(_ items: [NSExtensionItem]) async -> ShareCollection {
    var collection = ShareCollection()
    var total = 0
    var fileTotal = 0
    for item in items {
      if let text = item.attributedContentText?.string.trimmingCharacters(
        in: .whitespacesAndNewlines), !text.isEmpty
      {
        collection.parts.append(.text(text))
      }
      let title = item.attributedTitle?.string
      for provider in item.attachments ?? [] {
        guard collection.parts.count < ShareDropEntry.maximumParts else { break }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          guard let url = await loadURL(provider), url.isFileURL else { continue }
          // The file itself is copied into the drop (F10): the App never
          // opens a path a drop names.
          let scoped = url.startAccessingSecurityScopedResource()
          let size = ShareDropbox.regularFileSize(url)
          if scoped { url.stopAccessingSecurityScopedResource() }
          guard let size else {
            collection.refused.append("有一项不是文件，无法添加")
            continue
          }
          let ext = url.pathExtension.lowercased()
          let type = UTType(filenameExtension: ext)
          if type?.conforms(to: .audiovisualContent) == true {
            // The import reads the original later; sharing hands over a copy.
            collection.refused.append("音视频请拖到 Mindloom 中，或使用“文件”>“导入…”")
            continue
          }
          guard size <= ShareDropbox.maximumFileBytes,
            fileTotal + size <= ShareDropbox.maximumShareFileBytes
          else {
            collection.refused.append("有一项过大")
            continue
          }
          fileTotal += size
          let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
          let count = collection.data.count + collection.files.count + 1
          let name =
            "\(count)-\(base.isEmpty ? "shared" : base)" + (ext.isEmpty ? "" : ".\(ext)")
          guard ShareDropEntry.isPlainFileName(name) else { continue }
          collection.files[name] = url
          collection.parts.append(.data(name: name, type: type?.identifier))
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          if let url = await loadURL(provider), !url.isFileURL {
            // A link: its text only. It is never opened here or in the App.
            collection.parts.append(.link(url.absoluteString, title: title))
          }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          if let text = await loadText(provider), !text.isEmpty {
            collection.parts.append(.text(text))
          }
        } else if let type = [UTType.image, .pdf, .data].first(where: {
          provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) {
          let declared =
            provider.registeredTypeIdentifiers.first {
              UTType($0)?.conforms(to: type) == true
            } ?? type.identifier
          guard let bytes = await loadData(provider, type: declared) else {
            collection.refused.append("有一项无法读取")
            continue
          }
          guard bytes.count <= ShareDropbox.maximumDataBytes,
            total + bytes.count <= ShareDropbox.maximumShareBytes
          else {
            collection.refused.append("有一项过大")
            continue
          }
          total += bytes.count
          let ext = UTType(declared)?.preferredFilenameExtension ?? "bin"
          let base = (provider.suggestedName ?? "shared")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
          let name =
            "\(collection.data.count + collection.files.count + 1)-\(base.isEmpty ? "shared" : base).\(ext)"
          guard ShareDropEntry.isPlainFileName(name) else { continue }
          collection.data[name] = bytes
          collection.parts.append(.data(name: name, type: declared))
        }
      }
    }
    return collection
  }

  private static func loadURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
        continuation.resume(returning: url)
      }
    }
  }

  private static func loadText(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in
        continuation.resume(returning: text)
      }
    }
  }

  private static func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable data, _ in
        continuation.resume(returning: data)
      }
    }
  }
}
