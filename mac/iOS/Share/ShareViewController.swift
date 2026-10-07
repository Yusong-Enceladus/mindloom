import MindloomDesign
import MindloomLink
import MindloomPhoneIntake
import MindloomPhoneKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

let shareLog = Logger(subsystem: PhoneNames.shareLog, category: "share")

/// The Mindloom share extension (PHONE-SPEC §5.15): a card, not a sheet. What was shared is kept at
/// once (text, links never fetched, photos without location or device, files ≤ 25 MB) and the card
/// says 「已收好」, then leaves by itself after 2.6 s; 「加一句」 adds a note. Video and audio are
/// refused with the card's own words. With the App Group the app sends; without it (a free team's
/// build) the extension sends by itself (`ShareStore`).
final class ShareViewController: UIViewController {
  private let model = ShareModel()

  override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    // A card over the host app: no system sheet behind it.
    modalPresentationStyle = .overFullScreen
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    modalPresentationStyle = .overFullScreen
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    let host = UIHostingController(rootView: ShareCardScreen(model: model))
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
    #if DEBUG
      if let screen = ShareModel.debugScreen() {
        model.debugShow(screen)
        return
      }
    #endif
    Task { await model.take(items) }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    preferredContentSize = CGSize(width: view.bounds.width, height: Self.cardHeight)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // If the system shows us in a sheet we can reach, keep it as small as the card (PHONE-SPEC
    // §5.15 fallback). On iOS 26 the host process owns that sheet and none of these exist; then
    // the composition is laid out for the full sheet instead.
    let sheets = [
      presentationController as? UISheetPresentationController,
      sheetPresentationController,
      parent?.sheetPresentationController,
      navigationController?.sheetPresentationController,
    ].compactMap { $0 }
    for sheet in sheets {
      sheet.animateChanges {
        sheet.detents = [.custom(identifier: .init("card")) { _ in Self.cardHeight }]
        sheet.prefersGrabberVisible = false
      }
    }
    shareLog.notice("sheet controllers reachable: \(sheets.count, privacy: .public)")
  }

  static let cardHeight: CGFloat = 196

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // iOS may present the extension in its own sheet (iOS 26 does, and the extension cannot size
    // it): then the content is laid out for that sheet on paper instead of floating as a card.
    let screen = view.window?.windowScene?.screen.bounds.height ?? .greatestFiniteMagnitude
    let height = view.bounds.height
    let inSheet = height > 0 && height < screen - 24
    if model.inSheet != inSheet || model.sheetHeight != height {
      model.inSheet = inSheet
      model.sheetHeight = height
      shareLog.notice(
        "presented in a sheet: \(inSheet, privacy: .public) height \(Int(height), privacy: .public)")
    }
  }
}

// MARK: - Model

/// Loads, converts and keeps what was shared; drives the card.
@MainActor
@Observable
final class ShareModel {
  enum Card: Equatable {
    case working
    case saved
    case note
    /// Only video or audio was shared: nothing kept.
    case refused
    /// Nothing could be kept (no storage, or a write failed): the share must be tried again.
    case failed
  }

  /// What the card shows.
  struct Summary: Equatable {
    var thumbnails: [UIImage] = []
    /// A tile when there is no picture (link, text, file).
    var symbol: String?
    var lines: [String] = []
    /// The second line is a page title: one line, faded at the end, never 「…」.
    var isTitle = false
  }

  static let autoDismiss: TimeInterval = 2.6
  /// One share keeps at most this much (the share extension has little memory; files over it are
  /// for the Mac).
  static let maxShareBytes = 40 * 1024 * 1024

  private(set) var card: Card = .working
  private(set) var summary = Summary()
  private(set) var failure: (title: String, line: String)?
  private(set) var shown = false
  /// The system presented a sheet around the extension (no transparent full-screen card).
  var inSheet = false
  var sheetHeight: CGFloat = 0
  var note = ""
  var finish: (() -> Void)?

  private var store: ShareStore?
  private var savedIDs: [String] = []
  private var dismissTask: Task<Void, Never>?
  private var closing = false

  func take(_ items: [NSExtensionItem]) async {
    let loader = ShareItemLoader.temporary()
    defer { loader.removeCopies() }
    // The extension items are read once, by the loader only.
    nonisolated(unsafe) let handedOver = items
    let inputs = await loader.inputs(from: handedOver)
    let now = Date()
    let store = ShareStore.make()
    self.store = store
    let heldUntil = now.addingTimeInterval(Self.autoDismiss + 0.6)
    var tally = ShareTally()
    // End to end, one input at a time: convert, seal, write, drop. Only ids and small thumbnails
    // stay in memory between inputs, so ten photos cost no more than one.
    for input in inputs {
      let result = await Task.detached(priority: .userInitiated) {
        Converted.make(input, now: now)
      }.value
      let converted: Converted
      switch result {
      case .success(let item): converted = item
      case .failure(.audioOrVideo):
        tally.refusedVideo += 1
        continue
      case .failure(let refusal):
        tally.refusals.append(refusal)
        continue
      }
      tally.bytes += converted.conversion.byteCount ?? 0
      guard tally.bytes <= Self.maxShareBytes else {
        tally.overLimit = true
        continue
      }
      guard let store else {
        tally.failedWrites += 1
        continue
      }
      tally.keep(converted, in: store, now: now, heldUntil: heldUntil)
    }
    // Atomic: when any write failed, what was kept is taken back and the card says so.
    if tally.failedWrites > 0 {
      store?.withdraw(tally.keptIDs)
      shareLog.error("share not kept: \(tally.failedWrites, privacy: .public) writes failed")
      showFailure(title: "未能添加", line: "请重试")
      return
    }
    guard !tally.keptIDs.isEmpty else {
      if tally.refusedVideo > 0 {
        card = .refused
        show()
      } else if tally.overLimit {
        showFailure(title: "未能添加", line: ShareRefusal.fileTooLarge.message)
      } else if let refusal = tally.refusals.first {
        showFailure(title: "未能添加", line: refusal.message)
      } else {
        finish?()
      }
      return
    }
    store?.didKeep()
    savedIDs = tally.keptIDs
    summary = tally.summary(paired: store?.isPaired ?? false)
    card = .saved
    show()
    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.autoDismiss))
      guard !Task.isCancelled, let self, self.card == .saved else { return }
      self.close()
    }
  }

  private func showFailure(title: String, line: String) {
    failure = (title, line)
    card = .failed
    show()
  }

  private func show() {
    withAnimation(MLSpring.smooth.animation) { shown = true }
  }

  /// 「加一句」: the card stays and the item waits for the note.
  func addNote() {
    dismissTask?.cancel()
    store?.hold(savedIDs, until: Date().addingTimeInterval(10 * 60))
    withAnimation(MLSpring.smooth.animation) { card = .note }
  }

  /// 「完成」: the trimmed note goes onto the item (empty means no note).
  func done() {
    if let first = savedIDs.first { store?.attachNote(note, to: first) }
    close()
  }

  /// 「好」, or the card's time is up.
  func close() {
    guard !closing else { return }
    closing = true
    dismissTask?.cancel()
    let ids = savedIDs
    let store = store
    withAnimation(.easeOut(duration: MLMotion.durSlow)) { shown = false }
    Task { [weak self] in
      store?.release(ids)
      try? await Task.sleep(for: .seconds(MLMotion.durSlow))
      // Without the App Group the extension sends by itself, in the time iOS gives it.
      if let store, store.sendsItself, !ids.isEmpty {
        await store.sendWithExpiringActivity()
      }
      self?.finish?()
    }
  }

  #if DEBUG
    /// DEBUG: `share-saved`, `share-note`, `share-video`, `share-mixed`, `share-notpaired`,
    /// `share-link-saved`, `share-failed` with the prototype's synthetic pictures (the app's
    /// `-MindloomDebugShare <state>` writes the state id, with the time, into the shared records);
    /// nothing is kept. A record older than ten minutes is ignored, so a forgotten screenshot
    /// state never turns real shares into pictures.
    static func debugScreen() -> String? {
      guard let raw = PhoneLink.records()?.read("debug-share")
        .flatMap({ String(data: $0, encoding: .utf8) })
      else { return nil }
      let parts = raw.split(separator: "|")
      guard let state = parts.first, state.hasPrefix("share"), parts.count == 2,
        let written = Double(parts[1]), Date().timeIntervalSince1970 - written < 600
      else { return nil }
      return String(state)
    }

    func debugShow(_ screen: String) {
      let photos = ShareDebug.photos()
      switch screen {
      case "share-video":
        card = .refused
      case "share-failed":
        failure = ("未能添加", "请重试")
        card = .failed
      case "share-mixed":
        summary = Summary(thumbnails: Array(photos.prefix(2)), lines: ["2 张照片", "未添加视频"])
        card = .saved
      case "share-notpaired":
        summary = Summary(thumbnails: photos, lines: ["尚未连接 Mac，", "暂存在这台 iPhone 上"])
        card = .saved
      case "share-link-saved":
        summary = Summary(
          thumbnails: [ShareDebug.linkImage()].compactMap { $0 }, lines: ["老旧小区改造的五个误区"],
          isTitle: true)
        card = .saved
      case "share-note":
        summary = Summary(thumbnails: photos, lines: ["3 张照片"])
        note = "白板上第三条，明天会上要问。"
        card = .note
      default:
        summary = Summary(thumbnails: photos, lines: ["3 张照片"])
        card = .saved
      }
      shown = true
    }
  #endif
}

/// One converted input (Sendable, no UIKit).
struct Converted: Sendable {
  var conversion: ShareConversion
  /// A preview for Home (≤ 1280 px JPEG, from the already metadata-free image).
  var preview: Data?
  /// A small thumbnail for the card (memory only).
  var thumbnail: Data?

  static func make(_ input: ShareInput, now: Date) -> Result<Converted, ShareRefusal> {
    switch ShareItemConverter().convert(input, now: now) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let conversion):
      var item = Converted(conversion: conversion)
      if let bytes = conversion.imageBytes {
        // ImageIO decodes only the size it is asked for (no full-size bitmap in memory).
        item.preview = jpeg(bytes, maxPixels: 1280, quality: 0.8)
        item.thumbnail = jpeg(bytes, maxPixels: 360, quality: 0.8)
      }
      return .success(item)
    }
  }

  private static func jpeg(_ bytes: Data, maxPixels: Int, quality: Double) -> Data? {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixels,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }
}

/// What one share became, built input by input: all photos as one item (kept photo by photo),
/// every text, link and file as its own item.
@MainActor
struct ShareTally {
  var keptIDs: [String] = []
  var refusedVideo = 0
  var refusals: [ShareRefusal] = []
  var failedWrites = 0
  var overLimit = false
  var bytes = 0
  private var photoItem: PhoneItem?
  private var photoThumbnails: [Data] = []
  private var first: PhoneItem?
  private var firstThumbnail: Data?

  mutating func keep(_ converted: Converted, in store: ShareStore, now: Date, heldUntil: Date) {
    let c = converted.conversion
    if c.kind == .image {
      var next =
        photoItem ?? PhoneItem(createdAt: now, kind: .photos, source: .share, photoCount: 0)
      next.photoCount += 1
      guard
        let saved = store.append(
          c.payload, to: next, preview: converted.preview, index: next.photoCount - 1,
          heldUntil: heldUntil)
      else {
        failedWrites += 1
        return
      }
      if photoItem == nil { keptIDs.insert(saved.id, at: 0) }
      photoItem = saved
      if photoThumbnails.count < 3, let thumbnail = converted.thumbnail {
        photoThumbnails.append(thumbnail)
      }
      return
    }
    var item: PhoneItem
    switch c.kind {
    case .link:
      item = PhoneItem(
        createdAt: now, kind: .link, source: .share,
        link: PhoneItem.Link(url: c.payload.url ?? "", title: c.payload.title))
    case .file:
      item = PhoneItem(createdAt: now, kind: .file, source: .share, fileTitle: c.summary)
    default:
      item = PhoneItem(createdAt: now, kind: .text, source: .share, text: c.payload.text)
    }
    guard
      let saved = store.keep(
        item, payload: c.payload, preview: converted.preview, heldUntil: heldUntil)
    else {
      failedWrites += 1
      return
    }
    keptIDs.append(saved.id)
    if first == nil {
      first = saved
      firstThumbnail = converted.thumbnail
    }
  }

  func summary(paired: Bool) -> ShareModel.Summary {
    var summary = ShareModel.Summary()
    if let photoItem, photoItem.photoCount > 0 {
      summary.thumbnails = photoThumbnails.compactMap(UIImage.init(data:))
      summary.lines = ["\(photoItem.photoCount) 张照片"]
    } else if let first {
      switch first.kind {
      case .link:
        summary.symbol = "link"
        summary.lines = [first.link?.title ?? first.link?.domain ?? ""]
      case .file:
        summary.symbol = "doc"
        summary.lines = [first.fileTitle ?? ""]
      default:
        summary.symbol = "text.alignleft"
        summary.lines = [first.text ?? ""]
      }
      summary.thumbnails = [firstThumbnail].compactMap { $0 }.compactMap(UIImage.init(data:))
      summary.isTitle = true
    }
    if refusedVideo > 0 { summary.lines.append("未添加视频") }
    if !paired {
      summary.lines = ["尚未连接 Mac，", "暂存在这台 iPhone 上"]
      summary.isTitle = false
    }
    return summary
  }
}

// MARK: - The card

struct ShareCardScreen: View {
  let model: ShareModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      if model.inSheet {
        ZStack(alignment: .top) {
          MLColor.paper.dynamicColor.ignoresSafeArea()
          if model.card != .working {
            Group {
              if model.sheetHeight > 420 {
                // The system's own tall sheet: a composition made for it, not a card at its top.
                ShareSheetComposition(model: model)
              } else {
                // A sheet sized to the card (§5.15 fallback): the card's own content.
                ShareCard(model: model, bottomInset: 18, plain: true)
                  .padding(.top, 6)
              }
            }
            .opacity(model.shown || reduceMotion ? 1 : 0)
          }
        }
      } else {
        ZStack(alignment: .bottom) {
          Color.black.opacity(model.shown ? 0.2 : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { if model.card == .saved { model.close() } }
          if model.card != .working {
            ShareCard(model: model, bottomInset: geometry.safeAreaInsets.bottom)
              .padding(.horizontal, 8)
              .padding(.bottom, 8)
              .offset(y: model.shown || reduceMotion ? 0 : 420)
              .opacity(reduceMotion && !model.shown ? 0 : 1)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
      }
    }
    .environment(\.mlPlatform, .ios)
  }
}

/// The share in the system's full-height sheet (iOS 26/27 give an extension no smaller one): the
/// stacked pictures large in the middle, the mark and 「已收好」 under them, the second line, and
/// the action in the thumb zone at the bottom. Note mode keeps the compact row at the top, with
/// the field under it and 「完成」 above the keyboard.
struct ShareSheetComposition: View {
  let model: ShareModel
  @FocusState private var noteFocused: Bool

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      if model.card == .note {
        ShareCard(model: model, bottomInset: 0, plain: true, showsDone: false)
          .padding(.top, 6)
        Spacer(minLength: 16)
        BlockButtonShare(title: "完成", kind: .primary) { model.done() }
          .padding(.horizontal, 20)
          .padding(.bottom, 4)
      } else {
        Spacer(minLength: 24)
        centre
        Spacer(minLength: 24)
        actions
          .padding(.horizontal, 20)
          .padding(.bottom, 4)
      }
    }
    .foregroundStyle(MLColor.ink)
  }

  @ViewBuilder
  private var centre: some View {
    VStack(spacing: 0) {
      switch model.card {
      case .refused:
        SymbolTile(symbol: "video", side: 120)
        headline("未添加此视频", mark: false)
        lines(["iPhone 不支持添加视频和录音。", "可以在 Mac 上添加视频。"], title: false)
      case .failed:
        SymbolTile(symbol: "exclamationmark.circle", side: 120)
        headline(model.failure?.title ?? "未能添加", mark: false)
        lines([model.failure?.line ?? ""], title: false)
      default:
        Thumbnails(images: model.summary.thumbnails, symbol: model.summary.symbol, side: 120)
        headline("已添加", mark: true)
        lines(model.summary.lines, title: model.summary.isTitle)
      }
    }
    .padding(.horizontal, 32)
  }

  private func headline(_ text: String, mark: Bool) -> some View {
    HStack(spacing: 10) {
      if mark { MindloomMark(height: 22, form: .glyph) }
      Text(text)
        .font(PhoneTitleFont.font(20))
        .foregroundStyle(MLColor.ink)
    }
    .frame(height: 26)
    .padding(.top, 30)
  }

  private func lines(_ lines: [String], title: Bool) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        if title {
          FadingLine(text: line, centred: true)
        } else {
          Text(line)
            .font(.system(size: 15))
            .foregroundStyle(MLColor.ink2)
            .frame(height: 21)
        }
      }
    }
    .padding(.top, 6)
  }

  @ViewBuilder
  private var actions: some View {
    switch model.card {
    case .saved:
      BlockButtonShare(title: "添加备注", kind: .tinted) { model.addNote() }
    case .refused, .failed:
      BlockButtonShare(title: "好", kind: .neutral) { model.close() }
    default:
      EmptyView()
    }
  }
}

/// The block buttons in the extension (50 high, capsule): primary, tinted, neutral.
struct BlockButtonShare: View {
  enum Kind {
    case primary
    case tinted
    case neutral
  }

  let title: String
  let kind: Kind
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 17, weight: .medium))
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Capsule())
    }
    .buttonStyle(ShareBlockStyle(kind: kind))
  }
}

struct ShareBlockStyle: ButtonStyle {
  let kind: BlockButtonShare.Kind

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let (fg, bg): (Color, Color) =
      switch kind {
      case .primary:
        (.white, (pressed ? MLColor.accentFill3 : MLColor.accentFill).dynamicColor)
      case .tinted:
        (MLColor.accent.dynamicColor, (pressed ? MLColor.accentTint2 : MLColor.accentTint).dynamicColor)
      case .neutral:
        (MLColor.ink.dynamicColor, (pressed ? MLColor.fill3 : MLColor.fill).dynamicColor)
      }
    return configuration.label
      .foregroundStyle(fg)
      .background(Capsule().fill(bg))
  }
}

/// A symbol on a `fill` tile (video refused, nothing kept).
struct SymbolTile: View {
  let symbol: String
  var side: CGFloat = 52

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: side * 0.46, weight: .light))
      .foregroundStyle(MLColor.ink2)
      .frame(width: side, height: side)
      .background(
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous).fill(MLColor.fill))
      .accessibilityHidden(true)
  }
}

struct ShareCard: View {
  let model: ShareModel
  let bottomInset: CGFloat
  /// Inside the system's sheet: no glass of our own.
  var plain = false
  /// The note mode's 「完成」 (the tall sheet puts it at the bottom itself).
  var showsDone = true
  @FocusState private var noteFocused: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 16) {
      if model.card == .refused {
        refused
      } else if model.card == .failed {
        failed
      } else {
        row
        if model.card == .note {
          noteField(text: $model.note)
          if showsDone { primary("完成") { model.done() } }
        }
      }
    }
    .padding(EdgeInsets(top: 18, leading: 20, bottom: max(18, bottomInset - 8), trailing: 18))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      if !plain {
        Color.clear.mlGlass(.thick, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
      }
    }
    .foregroundStyle(MLColor.ink)
  }

  private var row: some View {
    HStack(spacing: 14) {
      Thumbnails(images: model.summary.thumbnails, symbol: model.summary.symbol)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          MindloomMark(height: 17, form: .glyph)
          Text("已添加")
            .font(.system(size: 17, weight: .medium))
        }
        ForEach(Array(model.summary.lines.enumerated()), id: \.offset) { _, line in
          if model.summary.isTitle {
            FadingLine(text: line)
          } else {
            Text(line)
              .font(.system(size: 15))
              .foregroundStyle(MLColor.ink2)
              .lineLimit(1)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if model.card == .saved {
        Button("添加备注") { model.addNote() }
          .buttonStyle(TintedSmallButton())
      }
    }
    .frame(minHeight: 52)
  }

  private func noteField(text: Binding<String>) -> some View {
    TextField("添加备注（可选）", text: text, axis: .vertical)
      .font(.system(size: 17))
      .lineSpacing(5)
      .lineLimit(1...4)
      .focused($noteFocused)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(minHeight: 52, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MLColor.surface))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(MLColor.rule2, lineWidth: 0.5))
      .task {
        try? await Task.sleep(for: .seconds(0.38))
        noteFocused = true
      }
  }

  private var refused: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        Image(systemName: "video")
          .font(.system(size: 24))
          .foregroundStyle(MLColor.ink2)
          .frame(width: 52, height: 52)
          .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MLColor.fill))
        VStack(alignment: .leading, spacing: 2) {
          Text("未添加此视频")
            .font(.system(size: 17, weight: .medium))
          Text("iPhone 不支持添加视频和录音。\n可以在 Mac 上添加视频。")
            .font(.system(size: 15))
            .lineSpacing(3)
            .foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      primary("好", neutral: true) { model.close() }
    }
  }

  private var failed: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        SymbolTile(symbol: "exclamationmark.circle")
        VStack(alignment: .leading, spacing: 2) {
          Text(model.failure?.title ?? "未能添加")
            .font(.system(size: 17, weight: .medium))
          Text(model.failure?.line ?? "")
            .font(.system(size: 15))
            .foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      primary("好", neutral: true) { model.close() }
    }
  }

  private func primary(_ title: String, neutral: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.system(size: 17, weight: .medium))
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Capsule())
    }
    .buttonStyle(BlockStyle(neutral: neutral))
  }
}

/// Up to three thumbnails stacked (46 pt, radius 10, offsets 3i / 6 − 3i, rotation (i − 1)·4°),
/// or one tile with a symbol; `side` scales the whole stack (120 in the tall sheet).
struct Thumbnails: View {
  let images: [UIImage]
  let symbol: String?
  var side: CGFloat = 46

  var body: some View {
    let k = side / 46
    ZStack(alignment: .topLeading) {
      if images.isEmpty {
        Image(systemName: symbol ?? "doc")
          .font(.system(size: 20 * k, weight: k > 1.5 ? .light : .regular))
          .foregroundStyle(MLColor.ink2)
          .frame(width: side, height: side)
          .background(RoundedRectangle(cornerRadius: 10 * k, style: .continuous).fill(MLColor.fill))
          .offset(x: 3 * k, y: 3 * k)
      } else {
        let shown = Array(images.prefix(3))
        let start = 3 - shown.count
        ForEach(Array(shown.enumerated()), id: \.offset) { offset, image in
          let i = Double(start + offset)
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10 * k, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10 * k, style: .continuous)
                .strokeBorder(MLColor.surface, lineWidth: 1.5 * min(k, 2)))
            .shadow(color: .black.opacity(0.15), radius: 1.5 * k, y: k)
            .rotationEffect(.degrees((i - 1) * 4))
            .offset(x: 3 * i * k, y: (6 - 3 * i) * k)
        }
      }
    }
    .frame(width: side + 6 * k, height: side + 6 * k, alignment: .topLeading)
    .accessibilityHidden(true)
  }
}

/// One line that fades over its last 2.5 em when it does not fit; never 「…」.
struct FadingLine: View {
  let text: String
  var centred = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      label
      label
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .mask(
          HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: 37.5)
          })
    }
  }

  private var label: some View {
    Text(text)
      .font(.system(size: 15))
      .foregroundStyle(MLColor.ink2)
      .lineLimit(1)
      .fixedSize()
  }
}

/// 「加一句」: tinted small button, 36 high, 15/20/500 `accent` on `accentTint`.
struct TintedSmallButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .medium))
      .foregroundStyle(MLColor.accent)
      .padding(.horizontal, 16)
      .frame(height: 36)
      .background(Capsule().fill(configuration.isPressed ? MLColor.accentTint2 : MLColor.accentTint))
  }
}

/// The block buttons (50 high, capsule): primary `accentFill`, neutral `fill`.
struct BlockStyle: ButtonStyle {
  let neutral: Bool

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    return configuration.label
      .foregroundStyle(neutral ? MLColor.ink.dynamicColor : .white)
      .background(
        Capsule().fill(
          neutral
            ? (pressed ? MLColor.fill3 : MLColor.fill).dynamicColor
            : (pressed ? MLColor.accentFill3 : MLColor.accentFill).dynamicColor))
  }
}
