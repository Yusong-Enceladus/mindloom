import MindloomLink
import MindloomPhoneIntake
import MindloomPhoneKit
import SwiftUI
import UIKit

/// 收进织机 (PHONE-CONTRACT §0.5, §1, §5): takes text, links (never
/// fetched), images (normalized, metadata removed, ≤ 12 MiB) and documents
/// (≤ 25 MiB), refuses audio and video, seals each item to the paired Mac and
/// adds it to the outbox. The app sends it.
final class ShareViewController: UIViewController {
  private let model = ShareModel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    let host = UIHostingController(rootView: ShareRootView(model: model))
    host.view.backgroundColor = .clear
    host.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(host)
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    model.finish = { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    Task { await model.take(items) }
  }
}

/// Loads, converts, seals and enqueues what was shared.
@MainActor
final class ShareModel: ObservableObject {
  struct Row: Identifiable {
    enum State: Equatable {
      case collected
      case refused(String)
    }

    let id = UUID()
    let kind: ShareConversion.Kind?
    let title: String
    let detail: String?
    let thumbnail: UIImage?
    let state: State
  }

  enum Phase: Equatable {
    case working
    case done(collected: Int)
    case notPaired
    case failed
  }

  @Published private(set) var phase: Phase = .working
  @Published private(set) var rows: [Row] = []
  var finish: (() -> Void)?

  func take(_ items: [NSExtensionItem]) async {
    let loader = ShareItemLoader.temporary()
    defer { loader.removeCopies() }
    // The extension items are read once, by the loader only.
    nonisolated(unsafe) let handedOver = items
    let inputs = await loader.inputs(from: handedOver)
    let collector = try? InboxCollector.appGroup()
    let paired = collector?.isPaired == true
    var built: [Row] = []
    var collected = 0
    // One item at a time, off the main thread, so at most one document's
    // bytes are in memory at once.
    for input in inputs {
      let outcome = await Task.detached(priority: .userInitiated) {
        Self.process(input, collector: paired ? collector : nil)
      }.value
      if outcome.collected { collected += 1 }
      built.append(
        Row(
          kind: outcome.kind, title: outcome.title, detail: outcome.detail,
          thumbnail: outcome.thumbnail.flatMap(UIImage.init(data:)),
          state: outcome.refusal.map(Row.State.refused) ?? .collected))
    }
    if built.isEmpty {
      built = [
        Row(
          kind: nil, title: "没有可收进的内容", detail: nil, thumbnail: nil,
          state: .refused(ShareRefusal.empty.message))
      ]
    }
    rows = built
    phase = !paired ? .notPaired : (collected > 0 ? .done(collected: collected) : .failed)
  }

  /// What one item became, without its content (Sendable).
  struct Outcome: Sendable {
    var kind: ShareConversion.Kind?
    var title: String
    var detail: String?
    /// A small JPEG for the confirmation row; memory only.
    var thumbnail: Data?
    var refusal: String?
    var collected: Bool
  }

  nonisolated static func process(_ input: ShareInput, collector: InboxCollector?) -> Outcome {
    switch ShareItemConverter().convert(input) {
    case .failure(let refusal):
      return Outcome(
        kind: nil, title: name(of: input), detail: nil, thumbnail: nil, refusal: refusal.message,
        collected: false)
    case .success(let conversion):
      let size = conversion.byteCount.map {
        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
      }
      let detail: String? =
        switch conversion.kind {
        case .link: conversion.payload.url.flatMap { URL(string: $0)?.host() }
        case .image:
          [size, conversion.removedLocation ? "已去掉拍摄地点" : "已去掉拍摄信息"]
            .compactMap { $0 }.joined(separator: " · ")
        case .file: size
        case .text: nil
        }
      var outcome = Outcome(
        kind: conversion.kind, title: conversion.summary,
        detail: detail, thumbnail: conversion.imageBytes.flatMap(thumbnail), refusal: nil,
        collected: false)
      guard let collector else {
        outcome.refusal = "还没连接 Mac，没有保存"
        return outcome
      }
      do {
        try collector.collect(conversion.payload)
        outcome.collected = true
      } catch {
        outcome.refusal = "没能收进，请再试一次"
      }
      return outcome
    }
  }

  nonisolated static func name(of input: ShareInput) -> String {
    switch input {
    case .audioOrVideo(let name): name ?? "音视频"
    case .image(let file), .file(let file): file.suggestedName ?? file.url.lastPathComponent
    case .text: "文字"
    case .link(let url, _): url.host() ?? "链接"
    }
  }

  /// A small thumbnail in memory only; nothing of the image is kept.
  nonisolated static func thumbnail(_ data: Data) -> Data? {
    UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 120, height: 120))?
      .jpegData(compressionQuality: 0.8)
  }
}

// MARK: - View

struct ShareRootView: View {
  @ObservedObject var model: ShareModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(Loom.hairline)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          summary
          if !model.rows.isEmpty {
            VStack(spacing: 0) {
              ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().overlay(Loom.hairline).padding(.leading, 64) }
                ShareRowView(row: row)
              }
            }
            .background(Loom.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Loom.hairline, lineWidth: 1))
          }
          footnote
        }
        .padding(20)
      }
      Button("完成") { model.finish?() }
        .buttonStyle(LoomPrimaryButtonStyle())
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .disabled(model.phase == .working)
    }
    .background(Loom.page.ignoresSafeArea())
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "tray.and.arrow.down.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Loom.onAccent)
        .frame(width: 30, height: 30)
        .background(Loom.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      Text("收进织机").font(.loom(17, .semibold)).foregroundStyle(Loom.ink)
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  @ViewBuilder
  private var summary: some View {
    switch model.phase {
    case .working:
      HStack(spacing: 10) {
        ProgressView()
        Text("正在收进…").font(.loom(17, .medium)).foregroundStyle(Loom.secondary)
      }
      .padding(.vertical, 12)
    case .done(let collected) where collected > 0:
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 30))
          .foregroundStyle(Loom.green)
          .symbolEffect(.bounce, value: collected)
        VStack(alignment: .leading, spacing: 4) {
          Text("已收进织机 · \(collected)").font(.loom(22, .semibold)).foregroundStyle(Loom.ink)
          Text("已在手机上锁好，只有你的 Mac 能打开。织机会把它送到 Mac。")
            .font(.loom(14))
            .foregroundStyle(Loom.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    case .done, .failed:
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 30))
          .foregroundStyle(Loom.amber)
        Text("这次没有收进任何内容").font(.loom(20, .semibold)).foregroundStyle(Loom.ink)
      }
    case .notPaired:
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
          .font(.system(size: 26))
          .foregroundStyle(Loom.amber)
        VStack(alignment: .leading, spacing: 4) {
          Text("还没连接 Mac").font(.loom(20, .semibold)).foregroundStyle(Loom.ink)
          Text("打开「织机」，扫描 Mac 上「连接 iPhone」的二维码。连接之前，分享的内容不会被保存。")
            .font(.loom(14))
            .foregroundStyle(Loom.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var footnote: some View {
    Text("链接只记下地址，不会打开网页。图片会先去掉拍摄地点和设备信息。录音和视频请在 Mac 上导入。")
      .font(.loom(12))
      .foregroundStyle(Loom.tertiary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct ShareRowView: View {
  let row: ShareModel.Row

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let thumbnail = row.thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(row.state == .collected ? Loom.accent : Loom.amber)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(row.state == .collected ? Loom.accentTint : Loom.amberTint)
        }
      }
      .frame(width: 40, height: 40)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title).font(.loom(15)).foregroundStyle(Loom.ink).lineLimit(2)
        switch row.state {
        case .collected:
          Text(["已锁好", row.detail].compactMap { $0 }.joined(separator: " · "))
            .font(.loom(12))
            .foregroundStyle(Loom.secondary)
        case .refused(let message):
          Text(message).font(.loom(12, .medium)).foregroundStyle(Loom.amber)
        }
      }
      Spacer(minLength: 0)
      if row.state == .collected {
        Image(systemName: "lock.fill")
          .font(.system(size: 12))
          .foregroundStyle(Loom.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var symbol: String {
    switch row.kind {
    case .text: "text.alignleft"
    case .link: "link"
    case .image: "photo"
    case .file: "doc"
    case nil: row.state == .collected ? "tray" : "film"
    }
  }
}
