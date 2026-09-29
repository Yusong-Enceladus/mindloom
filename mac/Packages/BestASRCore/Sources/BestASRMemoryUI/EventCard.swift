import AppKit
import BestASRDomain
import BestASRMemory
import SwiftUI

/// A Home card: key visual, title, one status line, date span and people.
struct EventCard: View {
  @Environment(\.zhiji) private var palette
  let entry: MemoryHomeEntry
  let state: MemoryScreenState
  let actions: MemoryActions
  let morph: Namespace.ID
  let open: () -> Void
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      CardCover(entry: entry, state: state, height: 132, radius: ZhijiMetrics.cardRadius)
        .overlay(alignment: .topTrailing) { heart }
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.title)
          .font(.zhiji(15, .semibold))
          .foregroundStyle(palette.label)
          .lineLimit(1)
          .zhijiMorph("title-\(entry.eventID)", in: morph, isSource: true)
        // Only a status someone wrote; an item excerpt is not a status.
        // Up to two lines, so a longer status is not cut off mid-way.
        Text(entry.realStatus ?? " ")
          .font(.zhiji(13))
          .lineSpacing(2)
          .foregroundStyle(palette.label)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Text(entry.metaLine(state))
            .metaStyle(palette)
          Spacer(minLength: 8)
          MiniAvatars(people: entry.shownPeople)
            .accessibilityHidden(true)
        }
        .frame(minHeight: 20)
        .padding(.top, 4)
      }
      .padding(.horizontal, 2)
    }
    .zhijiActivatable(open)
    .onHover { hovering = $0 }
    .contextMenu { CardMenu(eventID: entry.eventID, pinned: entry.pinned, state: state, actions: actions) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.accessibilitySummary(state))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: ZhijiCopy.copyAsText) { actions.copyText(entry.eventID) }
    .accessibilityAction(named: ZhijiCopy.exportAsText) { actions.exportText(entry.eventID) }
    .modifier(PinActions(entry: entry, state: state, actions: actions))
    .accessibilityIdentifier("bestASR.memory.card")
  }

  @ViewBuilder
  private var heart: some View {
    if state.canPin, hovering || entry.pinned {
      Button {
        actions.pin(entry.eventID, !entry.pinned)
      } label: {
        Image(systemName: entry.pinned ? "heart.fill" : "heart")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(entry.pinned ? palette.accent : palette.label)
          .frame(width: 28, height: 28)
          .background(palette.bg.opacity(0.92), in: Circle())
      }
      .buttonStyle(.plain)
      .padding(8)
      .help(entry.pinned ? ZhijiCopy.unpin : ZhijiCopy.pin)
    }
  }
}

/// 置顶 and 少推荐这类 for VoiceOver, where the card's heart and menu are.
private struct PinActions: ViewModifier {
  let entry: MemoryHomeEntry
  let state: MemoryScreenState
  let actions: MemoryActions

  func body(content: Content) -> some View {
    if state.canPin {
      content
        .accessibilityAction(named: entry.pinned ? ZhijiCopy.unpin : ZhijiCopy.pin) {
          actions.pin(entry.eventID, !entry.pinned)
        }
        .accessibilityAction(named: ZhijiCopy.featureLess) { actions.featureLess(entry.eventID) }
    } else {
      content
    }
  }
}

extension MemoryHomeEntry {
  /// The organizer's status line; nil when only an item excerpt stands in.
  var realStatus: String? {
    statusIsFallback || statusLine.isEmpty ? nil : statusLine
  }

  /// "9月22日 – 25日", plus "5 条" when there is no status line to read.
  func metaLine(_ state: MemoryScreenState) -> String {
    let span = state.span(self.span)
    guard realStatus == nil else { return span }
    let count = ZhijiCopy.itemCount(itemCount)
    return span.isEmpty ? count : "\(span) · \(count)"
  }

  func accessibilitySummary(_ state: MemoryScreenState) -> String {
    let names = people.map { $0.isNamed ? $0.name : ZhijiCopy.nameSomeone }
    return ([title, realStatus, metaLine(state)] + names).compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: "，")
  }
}

/// 复制为文本 / 导出为文本… / 置顶 / 少推荐这类.
struct CardMenu: View {
  let eventID: String
  let pinned: Bool
  let state: MemoryScreenState
  let actions: MemoryActions

  var body: some View {
    Button(ZhijiCopy.copyAsText) { actions.copyText(eventID) }
    Button(ZhijiCopy.exportAsText) { actions.exportText(eventID) }
    if state.canPin {
      Divider()
      Button(pinned ? ZhijiCopy.unpin : ZhijiCopy.pin) { actions.pin(eventID, !pinned) }
      Button(ZhijiCopy.featureLess) { actions.featureLess(eventID) }
    }
  }
}

/// The key visual: the first screenshot; else a sheet with the first lines of
/// the newest text, on a quiet field in the colours of the people involved;
/// else that field alone.
struct CardCover: View {
  @Environment(\.zhiji) private var palette
  let entry: MemoryHomeEntry
  let state: MemoryScreenState
  let height: CGFloat
  let radius: CGFloat
  var compact = false

  var body: some View {
    let image = self.image
    return GeometryReader { geometry in
      ZStack(alignment: .top) {
        if let image {
          // The whole cover, cropped from the top: a chat's first messages
          // and its names stay in view, at a size that can be read.
          fieldColor
          ScreenshotCrop(image: image)
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else if let text = entry.coverText {
          // Two events with the same people differ by what was written.
          field(width: geometry.size.width)
          TextSheet(text: text, compact: compact)
        } else {
          peopleField(width: geometry.size.width)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .overlay {
      // A white screenshot keeps its edge on a white page.
      if image != nil {
        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.hairline)
      }
    }
    .accessibilityHidden(true)
  }

  private var image: NSImage? {
    guard let cover = entry.cover, cover.itemKind == .image,
      let path = cover.thumbnailAssetPath
    else { return nil }
    return state.thumbnail(path)
  }

  private var fieldColor: Color {
    palette.isDark ? palette.surface : .hex(0xEEF1F6)
  }

  @ViewBuilder
  private func peopleField(width: CGFloat) -> some View {
    if entry.shownPeople.isEmpty {
      ZStack(alignment: .bottom) {
        field(width: width)
        PaperSheet(compact: compact)
      }
    } else {
      field(width: width)
    }
  }

  /// The people's tints side by side, or a paper colour with nobody.
  @ViewBuilder
  private func field(width: CGFloat) -> some View {
    let people = entry.shownPeople
    switch people.count {
    case 0:
      palette.isDark ? palette.surface : Color.hex(0xF1EFEA)
    case 1:
      field(people[0], opacity: 0.18)
    default:
      HStack(spacing: 0) {
        field(people[0], opacity: 0.20)
        field(people[1], opacity: 0.20)
          .frame(width: width * 0.38)
      }
    }
  }

  /// A person's tint, or a neutral field for someone nobody named.
  private func field(_ person: MemoryPersonRef, opacity: Double) -> Color {
    guard person.isNamed else { return palette.isDark ? palette.surface : .hex(0xECECEF) }
    return palette.personTint(person.colorIndex, opacity: opacity)
  }
}

/// A quiet page glyph for an event with nobody in it.
private struct PaperSheet: View {
  @Environment(\.zhiji) private var palette
  let compact: Bool

  var body: some View {
    let lines: [CGFloat] = [0.5, 0.9, 0.9, 0.7]
    VStack(alignment: .leading, spacing: compact ? 4 : 7) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, fraction in
        RoundedRectangle(cornerRadius: 3)
          .fill(palette.isDark ? Color.white.opacity(index == 0 ? 0.18 : 0.10) : .hex(index == 0 ? 0xD9D4C9 : 0xE8E4DC))
          .frame(width: (compact ? 34 : 94) * fraction, height: index == 0 ? (compact ? 4 : 7) : (compact ? 3 : 5))
      }
    }
    .padding(.horizontal, compact ? 8 : 12)
    .padding(.vertical, compact ? 8 : 14)
    .frame(width: compact ? 50 : 118, height: compact ? 44 : 108, alignment: .topLeading)
    .background(
      palette.isDark ? Color.white.opacity(0.06) : .white,
      in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
    )
    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
  }
}

/// The first lines of an event's newest text on a sheet of paper, anchored
/// at the bottom of the cover like the design's document card. Only whole
/// lines: as many as fit, each on one line.
private struct TextSheet: View {
  @Environment(\.zhiji) private var palette
  let text: MemoryCoverText
  let compact: Bool

  var body: some View {
    let lines = Array(text.lines.prefix(3))
    VStack(alignment: .leading, spacing: compact ? 2 : 6) {
      if !compact {
        Text(text.heading)
          .font(.zhiji(11, .semibold))
          .foregroundStyle(palette.secondary)
          .lineLimit(1)
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.zhiji(compact ? 9 : 13))
          .foregroundStyle(palette.label)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, compact ? 7 : 14)
    .padding(.top, compact ? 6 : 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      palette.isDark ? Color.hex(0x2F2F31) : .white,
      in: UnevenRoundedRectangle(
        topLeadingRadius: compact ? 6 : 10, topTrailingRadius: compact ? 6 : 10,
        style: .continuous)
    )
    .shadow(color: .black.opacity(palette.isDark ? 0.25 : 0.08), radius: 5, y: 2)
    .padding(.horizontal, compact ? 8 : 26)
    .padding(.top, compact ? 8 : 20)
  }
}

/// A screenshot filling its frame, cropped from the top (centred across):
/// the same crop on Home, person cards and timeline rows. When the frame
/// ends inside the screenshot, the crop ends in a gap between lines or
/// bubbles instead, and that gap is carried down to the frame's edge, so no
/// line of text is cut in half. Without such a gap the bottom fades out.
struct ScreenshotCrop: View {
  let image: NSImage

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      switch ScreenshotCut.cached(image, aspect: size.width / max(size.height, 1)) {
      case .clean(let cut):
        Image(decorative: cut, scale: 1)
          .resizable()
          .interpolation(.high)
          .frame(width: size.width, height: size.height)
      case .fade:
        fill(size)
          .mask(
            LinearGradient(
              stops: [
                .init(color: .black, location: 0), .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1),
              ], startPoint: .top, endPoint: .bottom))
      case .whole:
        fill(size)
      }
    }
  }

  private func fill(_ size: CGSize) -> some View {
    Image(nsImage: image)
      .resizable()
      .aspectRatio(contentMode: .fill)
      .frame(width: size.width, height: size.height, alignment: .top)
      .clipped()
  }
}

/// Where a top crop of a screenshot may end without cutting text.
enum ScreenshotCut {
  /// The crop, ending in a gap that is carried down to the frame's edge; its
  /// aspect is the frame's.
  case clean(CGImage)
  /// The frame ends inside the screenshot and no gap was found near it.
  case fade
  /// The frame shows the screenshot's whole height.
  case whole

  /// Rows are judged on the screenshot sampled down to this width.
  static let sampleWidth = 200
  /// A row is a gap when its grey level changes sharply at most this often
  /// across (a bubble's two edges and an avatar's two edges), and never
  /// twice within `narrowest` samples (a stroke of a character does).
  static let gapEdges = 4
  static let narrowest = 3
  /// How sharp a change is, in grey levels (0–255).
  static let edgeContrast = 12
  /// The crop may end no higher than this share of the frame.
  static let lowestShare: CGFloat = 0.6

  /// `aspect` is the frame's width over its height.
  static func cut(_ image: CGImage, aspect: CGFloat) -> ScreenshotCut {
    let (width, height) = (image.width, image.height)
    guard aspect > 0, width > 0, height > 0 else { return .whole }
    let visible = Int((CGFloat(width) / aspect).rounded(.down))
    guard visible > 0, visible < height else { return .whole }
    guard let cutRow = gapRow(image, visible: visible),
      let clean = extend(image, cut: cutRow, to: visible)
    else { return .fade }
    return .clean(clean)
  }

  /// The row (in the screenshot's pixels, exclusive) the crop ends at: the
  /// middle of the lowest gap at least a few pixels tall that lies between
  /// `lowestShare` of the frame and its bottom edge, so the row carried down
  /// is clear of the text on either side.
  static func gapRow(_ image: CGImage, visible: Int) -> Int? {
    let scale = min(1, CGFloat(sampleWidth) / CGFloat(image.width))
    let sampleWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let sampleHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
        bytesPerRow: sampleWidth, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue),
      let data = context.data
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
    let pixels = data.bindMemory(to: UInt8.self, capacity: sampleWidth * sampleHeight)
    // The bitmap's first row in memory is the image's top row.
    func isGap(_ row: Int) -> Bool {
      var edges = 0
      var lastEdge = -narrowest
      var lastRising = false
      let start = row * sampleWidth
      for x in 1..<max(sampleWidth, 1) {
        let step = Int(pixels[start + x]) - Int(pixels[start + x - 1])
        guard abs(step) > edgeContrast else { continue }
        let rising = step > 0
        // A soft edge spreads over neighbouring samples in one direction.
        if x == lastEdge + 1, rising == lastRising {
          lastEdge = x
          continue
        }
        edges += 1
        if edges > gapEdges || x - lastEdge < narrowest { return false }
        lastEdge = x
        lastRising = rising
      }
      return true
    }
    let bottom = min(sampleHeight, Int(CGFloat(visible) * scale)) - 1
    let top = Int(CGFloat(visible) * scale * lowestShare)
    // At least ~8 screenshot pixels of gap, so the carried-down row holds
    // no tip of a character.
    let run = max(2, Int((8 * scale).rounded(.up)))
    guard bottom - run >= top else { return nil }
    var row = bottom
    while row - run + 1 >= top {
      if (row - run + 1...row).allSatisfy(isGap) {
        let middle = row - run / 2
        return min(visible, Int((CGFloat(middle + 1) / scale).rounded(.down)))
      }
      row -= 1
    }
    return nil
  }

  /// The screenshot's top `cut` rows, then its row just above the cut
  /// stretched down to `visible` rows.
  static func extend(_ image: CGImage, cut: Int, to visible: Int) -> CGImage? {
    let width = image.width
    guard cut > 1, cut <= visible,
      let top = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: cut)),
      let slice = image.cropping(to: CGRect(x: 0, y: cut - 1, width: width, height: 1)),
      let context = CGContext(
        data: nil, width: width, height: visible, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .none
    // Core Graphics counts rows from the bottom.
    context.draw(top, in: CGRect(x: 0, y: visible - cut, width: width, height: cut))
    if visible > cut {
      context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: visible - cut))
    }
    return context.makeImage()
  }

  /// One result per screenshot and frame shape, kept while the screenshot is.
  @MainActor
  static func cached(_ image: NSImage, aspect: CGFloat) -> ScreenshotCut {
    let key = NSNumber(value: Int((aspect * 1_000).rounded()))
    let table = ScreenshotCutCache.shared.table
    let entry: ScreenshotCutCache.Entry
    if let held = table.object(forKey: image) {
      entry = held
    } else {
      entry = ScreenshotCutCache.Entry()
      table.setObject(entry, forKey: image)
    }
    if let known = entry.cuts[key] { return known }
    let result =
      image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      .map { cut($0, aspect: aspect) } ?? .whole
    entry.cuts[key] = result
    return result
  }
}

@MainActor
private final class ScreenshotCutCache {
  static let shared = ScreenshotCutCache()

  final class Entry {
    var cuts: [NSNumber: ScreenshotCut] = [:]
  }

  let table = NSMapTable<NSImage, Entry>(
    keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
}
