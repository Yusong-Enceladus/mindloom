import MindloomDesign
import MindloomPhoneKit
import SwiftUI
import UIKit

/// One thing the user sent, shown as itself (PHONE-SPEC §5.4): text at reading size, photos as a
/// grid, a link or file as a card, then the meta row (source glyph · word · time, the photo count,
/// and the hollow circle while it is still on this iPhone).
struct ItemView: View {
  let row: HomeRow
  /// The text measure (W − 40).
  let width: CGFloat
  let expanded: Bool
  let onExpand: () -> Void
  let onOpenPhoto: (Int) -> Void
  let onOpenLink: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ItemBody(
        row: row, width: width, expanded: expanded, onExpand: onExpand, onOpenPhoto: onOpenPhoto,
        onOpenLink: onOpenLink)
      if let note = row.item.note, !note.isEmpty {
        BodyText(text: note)
          .frame(width: width, alignment: .leading)
          .padding(.top, 8)
      }
      MetaRow(row: row)
        .padding(.top, 6)
    }
    .frame(width: width, alignment: .leading)
  }
}

/// The item's own body (also the long-press preview's).
struct ItemBody: View {
  let row: HomeRow
  let width: CGFloat
  let expanded: Bool
  var onExpand: () -> Void = {}
  var onOpenPhoto: (Int) -> Void = { _ in }
  var onOpenLink: (URL) -> Void = { _ in }

  var body: some View {
    switch row.item.kind {
    case .text where row.item.recordingID != nil && row.item.text == nil:
      // A recording from Apple Watch: its text is on the way, or nothing was said.
      Text(row.item.awaitingTranscription == true ? "正在转写…" : "无法转写音频")
        .font(.system(size: 17))
        .foregroundStyle(MLColor.ink2)
        .frame(width: width, alignment: .leading)
    case .text:
      ClampedText(text: row.item.text ?? "", width: width, expanded: expanded, onExpand: onExpand)
    case .photos:
      PhotoGrid(previews: row.previews, count: max(1, row.item.photoCount), width: width, onOpen: onOpenPhoto)
    case .link:
      let link = row.item.link ?? PhoneItem.Link(url: "")
      CardRow(
        title: link.title ?? link.domain, subtitle: link.title == nil ? nil : link.domain,
        image: row.previews.first, symbol: "link", width: width
      ) {
        if let url = URL(string: link.url) { onOpenLink(url) }
      }
    case .file:
      CardRow(
        title: row.item.fileTitle ?? "文件", subtitle: nil, image: nil, symbol: "doc", width: width
      ) {}
    }
  }
}

/// Text longer than 42 characters is clamped to two lines: line 1 opaque, line 2 fading out from
/// (width − 6.4 em) to (width − 3.1 em), and 「展开」 right-aligned on line 2.
struct ClampedText: View {
  let text: String
  let width: CGFloat
  let expanded: Bool
  let onExpand: () -> Void

  private let em: CGFloat = 17
  private let line: CGFloat = 26

  var body: some View {
    if expanded || !PhoneText.needsClamp(text) {
      BodyText(text: text)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      ZStack(alignment: .bottomTrailing) {
        BodyText(text: text)
          .frame(width: width, alignment: .topLeading)
          .frame(height: 2 * line, alignment: .top)
          .clipped()
          .mask(alignment: .topLeading) {
            VStack(spacing: 0) {
              Rectangle().frame(height: line)
              LinearGradient(
                stops: [
                  .init(color: .black, location: (width - 6.4 * em) / width),
                  // Fully clear 4 pt before the fade's end, so no glyph edge leaks before 「展开」.
                  .init(color: .black.opacity(0), location: (width - 3.1 * em - 4) / width),
                ], startPoint: .leading, endPoint: .trailing
              )
              .frame(height: line)
            }
          }
        Button(action: onExpand) {
          Text("展开")
            .font(.system(size: 17))
            .foregroundStyle(MLColor.accent)
            .padding(.leading, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
      }
      .frame(width: width, height: 2 * line, alignment: .topLeading)
    }
  }
}

/// Photos: 3+ → the first three in 3 square columns (gap 4); 2 → 2 columns; 1 → one image 220
/// high at its natural width. The container is rounded 12.
struct PhotoGrid: View {
  let previews: [URL]
  let count: Int
  let width: CGFloat
  let onOpen: (Int) -> Void

  var body: some View {
    if count == 1 {
      let image = previews.first.flatMap { UIImage(contentsOfFile: $0.path) }
      let natural = image.map { min(width, 220 * $0.size.width / max(1, $0.size.height)) } ?? 220
      Button {
        onOpen(0)
      } label: {
        PhotoTile(url: previews.first)
          .frame(width: natural, height: 220)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .buttonStyle(PressFade())
    } else {
      let columns = min(3, count)
      let cell = (width - 4 * CGFloat(columns - 1)) / CGFloat(columns)
      HStack(spacing: 4) {
        ForEach(0..<columns, id: \.self) { index in
          Button {
            onOpen(index)
          } label: {
            PhotoTile(url: index < previews.count ? previews[index] : nil)
              .frame(width: cell, height: cell)
              .clipped()
          }
          .buttonStyle(PressFade())
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}

/// One photo preview, filling its frame (placeholder `paper3`).
struct PhotoTile: View {
  let url: URL?

  var body: some View {
    ZStack {
      MLColor.paper3.dynamicColor
      if let url, let image = PreviewCache.image(url) {
        Image(uiImage: image).resizable().scaledToFill()
      }
    }
    .accessibilityLabel("照片")
  }
}

/// Decoded previews, kept while the app runs.
@MainActor
enum PreviewCache {
  private static var images: [URL: UIImage] = [:]

  static func image(_ url: URL) -> UIImage? {
    if let image = images[url] { return image }
    guard let image = UIImage(contentsOfFile: url.path) else { return nil }
    images[url] = image
    return image
  }
}

/// The link (or file) card: 80 high, `surface`, radius 16, hairline; 60 pt image or tile; title
/// 15/21 500 and the domain under it.
struct CardRow: View {
  let title: String
  let subtitle: String?
  let image: URL?
  let symbol: String
  let width: CGFloat
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        ZStack {
          if let image, let ui = PreviewCache.image(image) {
            Image(uiImage: ui).resizable().scaledToFill()
          } else {
            MLColor.fill.dynamicColor
            Image(systemName: symbol)
              .font(.system(size: 22))
              .foregroundStyle(MLColor.ink2)
          }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 15, weight: .medium))
            .lineSpacing(PhoneLine.spacing(size: 15, lineHeight: 21))
            .foregroundStyle(MLColor.ink)
            .lineLimit(2)
          if let subtitle {
            Text(subtitle)
              .font(.system(size: 13))
              .foregroundStyle(MLColor.ink2)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 12))
      .frame(width: width, height: 80)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MLColor.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(MLColor.rule2, lineWidth: 0.5)
      )
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(PressFade())
  }
}

/// Glyph + 「键盘 · 9:41」 (+ 「· 3 张」) and, right-aligned, the hollow circle while on the phone.
struct MetaRow: View {
  let row: HomeRow
  static let separator = "\u{2009}·\u{2009}"

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: row.item.source.symbol)
        .font(.system(size: 12.5))
        .foregroundStyle(MLColor.ink2)
        .frame(width: 14)
      // Thin spaces around 「·」: the prototype's PingFang spacing (SF's spaces are wider).
      Text(row.item.source.word + Self.separator + PhoneFormat.time(row.item.createdAt))
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(MLColor.ink2)
      if let seconds = row.item.recordingSeconds {
        Text("·\u{2009}" + PhoneFormat.duration(seconds))
          .font(.system(size: 13).monospacedDigit())
          .foregroundStyle(MLColor.ink2)
      }
      if row.item.kind == .photos, row.item.photoCount > 1 {
        Text("·\u{2009}\(row.item.photoCount) 张")
          .font(.system(size: 13).monospacedDigit())
          .foregroundStyle(MLColor.ink2)
      }
      if row.notSent {
        Text("·\u{2009}未能发送")
          .font(.system(size: 13))
          .foregroundStyle(MLColor.alert)
      }
      Spacer(minLength: 0)
      Circle()
        .strokeBorder(MLColor.ink3, lineWidth: 1.25)
        .frame(width: 8, height: 8)
        .opacity(row.onPhone ? 1 : 0)
        .animation(.easeOut(duration: MLMotion.durBase), value: row.onPhone)
        .accessibilityLabel(row.onPhone ? "仍在 iPhone 上" : "")
        .accessibilityHidden(!row.onPhone)
    }
    .frame(height: 18)
  }
}

extension PhoneItem.Source {
  /// 键盘 · 口述 · 分享 · Apple Watch.
  var word: String {
    switch self {
    case .keyboard: "键盘"
    case .voice: "口述"
    case .share: "分享"
    case .watch: "Apple Watch"
    }
  }

  var symbol: String {
    switch self {
    case .keyboard: "keyboard"
    case .voice: "mic"
    case .share: "square.and.arrow.up"
    case .watch: "applewatch"
    }
  }
}
