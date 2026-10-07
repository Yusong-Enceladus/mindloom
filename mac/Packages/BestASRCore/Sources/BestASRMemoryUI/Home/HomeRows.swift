import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. The pieces Home, the group and space pages, the person
// page and search share (MAC-SPEC §4.1–§4.5, §4.11, §4.14): one line that
// fades instead of 「…」, group headers, the matter row with its track and
// hover tips, the sticky axis, the waiting-capture row and the offline line.

// MARK: - Text

/// One line whose end fades over its last `fade` points (2.5 em) instead of
/// an ellipsis (§2.3), for styled `Text`.
struct FadingText: View {
  let text: Text
  let fade: CGFloat

  init(_ text: Text, fade: CGFloat = 36) {
    self.text = text
    self.fade = fade
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      text.lineLimit(1).fixedSize()
      OneLineClip { text.lineLimit(1).fixedSize() }
        .mask {
          HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: fade)
          }
        }
        .clipped()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Lays one child out at its own (single-line) width but never asks for
/// more than it is offered: the part beyond is clipped by the caller.
struct OneLineClip: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
    return CGSize(width: min(proposal.width ?? ideal.width, ideal.width), height: ideal.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
  }
}

/// At most two lines; when longer, the second line's last 4 em fade out
/// (§2.3: never cut content with 「…」).
struct TwoLineText: View {
  let text: Text
  /// The font size and line height (14/22 body).
  var size: CGFloat = 14
  var lineHeight: CGFloat = 22
  var fade: CGFloat = 56
  /// The line was cut before its start: the first 2.5 em fade in (the
  /// mirror of the end fade).
  var leadFade = false

  /// The spacing that makes a `lineHeight` pitch from SwiftUI's own line
  /// (the kit measures it).
  private var spacing: CGFloat {
    MLTextStyle(size: size, weight: .regular, lineHeight: lineHeight).lineSpacing
  }

  var body: some View {
    let text = self.text
    ViewThatFits(in: .vertical) {
      text.fixedSize(horizontal: false, vertical: true)
      text
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: 2 * lineHeight, alignment: .top)
        .clipped()
        .mask {
          VStack(spacing: 0) {
            Rectangle().frame(height: lineHeight)
            HStack(spacing: 0) {
              Rectangle()
              LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
            }
          }
        }
    }
    .lineSpacing(spacing)
    .mask(alignment: .topLeading) {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          if leadFade {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
              .frame(width: 2.5 * size)
          }
          Rectangle()
        }
        .frame(height: lineHeight)
        Rectangle()
      }
    }
    .frame(maxHeight: 2 * lineHeight + 4, alignment: .top)
  }
}

/// The 0.5 em gap after 「已过期」/「今天」/「明天」 (an en space).
let halfEm = "\u{2002}"

extension HomeDerivation.SecondLine {
  /// 「{name}共享 · 」 (ink2) + 「已过期」 (alert) + words (ink2) + 「 · risk」 (ink).
  var styled: Text {
    var out = Text("")
    if let sharedBy { out = out + Text(sharedBy).foregroundStyle(MLColor.ink2) }
    if let alertWord {
      out = out + Text(alertWord + halfEm).foregroundStyle(MLColor.alert)
    }
    out = out + Text(words).foregroundStyle(MLColor.ink2)
    if let risk { out = out + Text(" · " + risk).foregroundStyle(MLColor.ink) }
    return out
  }
}

/// A group header (`.grp`): 11/14 600 `ink2`, padding 24 0 6 (12 for the
/// first), an optional range in 400.
struct HomeGroupHeader: View {
  let title: String
  var range: String? = nil
  var first = false

  var body: some View {
    HStack(spacing: 6) {
      Text(title).mlFont(\.section).foregroundStyle(MLColor.ink2)
      if let range {
        Text(range).font(.system(size: 11, weight: .regular)).foregroundStyle(MLColor.ink2)
          .monospacedDigit()
      }
    }
    .padding(.top, first ? 12 : 24)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Row chrome

/// The row background: hover `fill2`; selected / menu `accentTint`; lit
/// (just filed) `accentTint`, fading to clear over 1.2 s after 1.8 s (M9).
struct HomeRowChrome: ViewModifier {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var lit = false
  var selected = false
  var radius: CGFloat = 10
  @State private var hovering = false
  @State private var faded = false

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(fill)
      }
      .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .onHover { inside in
        withAnimation(MLMotion.easeOut(MLMotion.durFast)) { hovering = inside }
      }
      .task(id: lit) {
        faded = false
        guard lit, !snapshot else { return }
        try? await Task.sleep(for: .seconds(1.8))
        guard !Task.isCancelled else { return }
        withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 1.2)) { faded = true }
      }
  }

  private var fill: MLColor {
    if selected || (lit && !faded) { return .accentTint }
    return hovering ? .fill2 : .transparent
  }
}

/// The keyboard focus ring (3 pt `focus`, inset −2).
struct HomeFocusRing: ViewModifier {
  let on: Bool

  func body(content: Content) -> some View {
    content.overlay {
      if on {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(MLColor.focus, lineWidth: 3)
          .padding(-2)
          .allowsHitTesting(false)
      }
    }
  }
}

// MARK: - Matter row (按时间)

/// One matter on 按时间 (`rowHTML`): title + second line | the 300 pt track.
/// Click or Return opens it; right-click shows the matter menu; it can be
/// dragged onto a sidebar group or a group page.
struct HomeMatterRow: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.mindloomForcedHover) private var forcedHover
  let context: MindloomPageContext
  let matter: MatterDigest
  let second: HomeDerivation.SecondLine
  /// nil: a plain row without a track (person page, 一起在做).
  let track: HomeTrack?
  var lit = false
  var selected = false
  var focused = false
  @State private var hoveringTrack = false

  var body: some View {
    HStack(alignment: .center, spacing: 32) {
      VStack(alignment: .leading, spacing: 2) {
        FadingText(Text(MLAutospace.apply(matter.title)), fade: 37.5)
          .mlFont(\.headline)
          .foregroundStyle(MLColor.ink)
          .mlLineBox(\.headline)
        FadingText(second.styled, fade: 32.5)
          .mlFont(\.sub)
          .mlLineBox(\.sub)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let track {
        HomeTrackView(
          track: track, hovering: $hoveringTrack, forced: forcedHover == matter.eventID
        )
        .frame(width: HomeTrackWindow.width, height: 20)
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .frame(minHeight: 56)
    .modifier(HomeRowChrome(lit: lit, selected: selected))
    .modifier(HomeFocusRing(on: focused && !snapshot))
    .padding(.horizontal, -12)
    .zIndex(hoveringTrack ? 2 : 0)
    .onTapGesture { context.navigator.openMatter(matter.eventID) }
    .contextMenu {
      MatterMenu(
        context: context,
        input: MatterMenuInput(
          eventID: matter.eventID,
          memberView: context.state.sharing[matter.eventID]?.isMemberView ?? false))
    }
    .modifier(MatterDrag(eventID: matter.eventID, snapshot: snapshot))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(MLAutospace.apply(matter.title) + "，" + second.plain)
    .accessibilityAddTraits(.isLink)
    .accessibilityAction { context.navigator.openMatter(matter.eventID) }
  }
}

/// Rows can be dragged (event ID as text) onto a sidebar group or a group page.
struct MatterDrag: ViewModifier {
  let eventID: String
  let snapshot: Bool

  func body(content: Content) -> some View {
    if snapshot {
      content
    } else {
      content.draggable(eventID)
    }
  }
}

// MARK: - Track

/// A row's track (`trackSVG`): the solid line of activity, the dashed
/// future, ● / ○ marks; hovering a dot shows its tooltip (§4.14).
struct HomeTrackView: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let track: HomeTrack
  @Binding var hovering: Bool
  /// Shows the latest dot's tooltip as if hovered (`mindloomForcedHover`).
  var forced = false
  @State private var hovered: String?

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let old = track.oldLabel {
        Text(old)
          .mlFont(\.foot)
          .monospacedDigit()
          .foregroundStyle(MLColor.ink2)
          .fixedSize()
          .padding(.top, 2)
      } else {
        lines
        ForEach(track.dots) { dot in
          HomeTrackDotView(dot: dot, hovered: hovered == dot.id)
            .position(x: dot.x, y: 10)
        }
      }
    }
    .frame(width: HomeTrackWindow.width, height: 20, alignment: .topLeading)
    .contentShape(Rectangle().inset(by: -6))
    .onContinuousHover { phase in
      switch phase {
      case .active(let point):
        let next = target(at: point)
        if next != hovered {
          withAnimation(MLMotion.easeOut(MLMotion.durFast)) { hovered = next }
        }
      case .ended:
        withAnimation(MLMotion.easeOut(MLMotion.durFast)) { hovered = nil }
      }
      hovering = hovered != nil
    }
    .overlay(alignment: .topLeading) {
      if let tip = tipText {
        HomeTooltip(text: tip.text)
          .alignmentGuide(.top) { $0[.bottom] + 2 }
          .alignmentGuide(.leading) { d in
            let left = min(tip.x - d.width / 2, HomeTrackWindow.width + 16 - d.width)
            return -left
          }
          .transition(.opacity)
          .allowsHitTesting(false)
      }
    }
    .onChange(of: forced, initial: true) { _, on in
      guard on || hovered != nil else { return }
      hovered = on ? (track.oldLabel != nil ? "old" : track.dots.last?.id) : nil
      hovering = hovered != nil
    }
    .accessibilityElement()
    .accessibilityLabel(track.accessibilityLabel)
  }

  private var tipText: (x: CGFloat, text: String)? {
    guard let hovered else { return nil }
    if hovered == "old", track.oldLabel != nil {
      return (24, track.accessibilityLabel)
    }
    guard let dot = track.dots.first(where: { $0.id == hovered }) else { return nil }
    return (dot.x, dot.tip)
  }

  private func target(at point: CGPoint) -> String? {
    if track.oldDate != nil { return point.x < 60 ? "old" : nil }
    let near = track.dots.map { ($0, abs($0.x - point.x)) }.filter { $0.1 <= 7 }
    return near.min { $0.1 < $1.1 }?.0.id
  }

  @ViewBuilder
  private var lines: some View {
    let ink4 = MLColor.ink4.color(for: scheme)
    if let solid = track.solid {
      let length = max(1, solid.upperBound - solid.lowerBound)
      Path { path in
        path.move(to: CGPoint(x: solid.lowerBound, y: 10))
        path.addLine(to: CGPoint(x: solid.upperBound, y: 10))
      }
      .stroke(
        track.fadesIn
          ? AnyShapeStyle(
            LinearGradient(
              stops: [
                .init(color: ink4.opacity(0), location: 0),
                .init(color: ink4, location: min(1, 36 / length)),
              ], startPoint: UnitPoint(x: solid.lowerBound / HomeTrackWindow.width, y: 0.5),
              endPoint: UnitPoint(x: solid.upperBound / HomeTrackWindow.width, y: 0.5)))
          : AnyShapeStyle(ink4),
        lineWidth: 1)
    }
    if let dashed = track.dashed {
      Path { path in
        path.move(to: CGPoint(x: dashed.lowerBound, y: 10))
        path.addLine(to: CGPoint(x: dashed.upperBound, y: 10))
      }
      .stroke(ink4, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }
  }
}

/// ● / ○ on a track; hovered: scale 1.15 with a `fill2` halo; a fresh ●
/// pops in (M10: scale 0.3 → 1 + fade, spring gentle).
struct HomeTrackDotView: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let dot: HomeTrackDot
  let hovered: Bool
  @State private var shown = false

  var body: some View {
    let r = dot.radius
    ZStack {
      if hovered {
        Circle().fill(MLColor.fill2).frame(width: 2 * r + 9, height: 2 * r + 9)
      }
      // ● is a fill only (r 3.5 → 7 pt, `.tk-done`); ○ keeps the
      // prototype's centred 1.5 stroke on r 3.25.
      Circle()
        .fill(fill)
        .overlay {
          if dot.style != .done { Circle().stroke(stroke, lineWidth: 1.5) }
        }
        .frame(width: 2 * r, height: 2 * r)
        .scaleEffect(hovered ? 1.15 : 1)
    }
    .frame(width: 20, height: 20)
    .scaleEffect(appeared || reduceMotion ? 1 : 0.3)
    .opacity(appeared ? 1 : 0)
    .onAppear {
      guard dot.fresh, !snapshot else { return }
      withAnimation(reduceMotion ? .easeOut(duration: 0.2) : MLSpring.gentle.animation) { shown = true }
    }
  }

  private var appeared: Bool { !dot.fresh || snapshot || shown }

  private var fill: MLColor {
    switch dot.style {
    case .done: .ink2
    case .next, .due: .paper
    }
  }

  private var stroke: MLColor {
    switch dot.style {
    case .done, .next: .ink2
    case .due: .alert
    }
  }
}

/// A tooltip (§4.14): thick glass, padding 8 10, radius 10, 13/18 `ink`,
/// at most 300 wide.
struct HomeTooltip: View {
  let text: String

  var body: some View {
    Text(text)
      .mlFont(\.sub)
      .foregroundStyle(MLColor.ink)
      .lineLimit(3)
      .frame(maxWidth: 280, alignment: .leading)
      .fixedSize()
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

// MARK: - Axis

/// The sticky axis over the tracks (§4.1): 26 high, right-aligned 300 pt
/// strip, Monday dates and an indigo 「今天」, on a paper gradient so rows
/// scroll under it. Sticks 50 pt below the top of the page.
struct HomeAxisView: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let days: HomeDays
  /// `top: 50` under the page's 56 pt top padding, as the prototype's
  /// sticky box measures (axis labels at y ≈ 118 in the window).
  static let stickTop: CGFloat = 106

  var body: some View {
    GeometryReader { geometry in
      let top = snapshot ? geometry.frame(in: .global).minY : geometry.frame(in: .scrollView).minY
      strip
        .frame(width: geometry.size.width, height: 26, alignment: .trailing)
        .offset(y: max(0, Self.stickTop - top))
    }
    .frame(height: 26)
    .padding(.top, 14)
    .zIndex(3)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var strip: some View {
    ZStack(alignment: .topLeading) {
      ForEach(HomeTrackWindow.axis(days), id: \.text) { label in
        Text(label.text)
          .font(.system(size: 12, weight: label.today ? .medium : .regular))
          .monospacedDigit()
          .foregroundStyle(label.today ? MLColor.accent : MLColor.ink2)
          .fixedSize()
          .position(x: 16 + label.x, y: 4 + 8)
      }
    }
    .frame(width: HomeTrackWindow.width + 32, height: 26)
    .background {
      Rectangle().fill(MLColor.paper)
        .mask(
          LinearGradient(
            stops: [
              .init(color: .black, location: 0.7), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
    }
    .padding(.trailing, -16)
  }
}

// MARK: - Waiting captures

/// A capture that cannot be filed yet (「刚收进来」): optional thumbnail, its
/// first line (15 pt, 400), then glyph + 「{kind} · {HH:mm}」. Never a file
/// name.
struct WaitingCaptureRow: View {
  let state: MemoryScreenState
  let capture: MemoryWaitingCapture

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      if let thumb = capture.thumbnail {
        WaitingThumbnail(
          kind: thumb, image: capture.thumbnailPath.flatMap { state.thumbnail($0) })
      }
      VStack(alignment: .leading, spacing: 2) {
        FadingText(Text(capture.firstLine), fade: 37.5)
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(MLColor.ink)
          .mlLineBox(\.headline)
        HStack(spacing: 5) {
          MLSymbol(capture.symbol, size: 12, box: 13)
            .foregroundStyle(MLColor.ink2)
          Text(capture.kind + " · " + MindloomDates.clock(capture.capturedAt, calendar: state.calendar))
            .mlFont(\.sub)
            .monospacedDigit()
            .foregroundStyle(MLColor.ink2)
        }
        .mlLineBox(\.sub)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .frame(minHeight: 56)
    .modifier(HomeRowChrome())
    .padding(.horizontal, -12)
    .accessibilityElement(children: .combine)
  }
}

/// PDF 34 × 40 with a 「PDF」 badge; photo / video 46 × 34 gradients.
struct WaitingThumbnail: View {
  let kind: MemoryWaitingCapture.Thumbnail
  let image: NSImage?

  var body: some View {
    let size = kind == .pdf ? CGSize(width: 34, height: 40) : CGSize(width: 46, height: 34)
    ZStack {
      switch kind {
      case .pdf:
        Rectangle().fill(MLColor.surface)
        Text("PDF")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 3)
          .padding(.vertical, 2)
          .background(Color(red: 0xB5 / 255, green: 0x37 / 255, blue: 0x1E / 255), in: RoundedRectangle(cornerRadius: 2))
          .offset(y: 6)
      case .photo:
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
          LinearGradient(
            stops: [
              .init(color: Color(red: 0xDC / 255, green: 0xE4 / 255, blue: 0xF2 / 255), location: 0),
              .init(color: Color(red: 0xF4 / 255, green: 0xEF / 255, blue: 0xE6 / 255), location: 0.6),
              .init(color: Color(red: 0xE9 / 255, green: 0xDF / 255, blue: 0xD0 / 255), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
      case .video:
        LinearGradient(
          colors: [
            Color(red: 0x3B / 255, green: 0x44 / 255, blue: 0x58 / 255),
            Color(red: 0x23 / 255, green: 0x28 / 255, blue: 0x36 / 255),
          ], startPoint: .topLeading, endPoint: .bottomTrailing)
        Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(MLColor.rule2, lineWidth: 0.5)
    )
    .mlShadow(.thumb)
    .accessibilityHidden(true)
  }
}

// MARK: - Offline line

/// DGX Spark not connected (§4.1): `paper2`, radius 12, padding 10 12,
/// bleeding 12; device.box + the sentence + 「重新连接」.
struct HomeOfflineLine: View {
  let context: MindloomPageContext

  var body: some View {
    let n = waitingCount
    HStack(spacing: 10) {
      HomeDeviceBoxGlyph()
        .foregroundStyle(MLColor.ink2)
        .frame(width: 16, height: 16)
      Text(
        n > 0
          ? "DGX Spark 未连接 · \(n) 条内容暂存在这台 Mac 上，连接后整理"
          : "DGX Spark 未连接 · 新添加的内容暂存在这台 Mac 上"
      )
      .mlFont(\.sub)
      .foregroundStyle(MLColor.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("重新连接") { context.actions.reconnect() }
        .buttonStyle(MLButtonStyle(.standard, small: true))
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .background(MLColor.paper2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.horizontal, -12)
    .padding(.top, 14)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.updatesFrequently)
  }

  private var waitingCount: Int {
    let link = context.state.link
    return link.waiting > 0 ? link.waiting : context.state.waitingCaptures.count
  }
}

/// The DGX Spark glyph (`device.box`): an 18 × 8.4 rounded box (r 2.2) with
/// a dot at the left and a 7.2 pt slot, drawn in a 24 grid.
struct HomeDeviceBoxGlyph: View {
  var body: some View {
    Canvas { context, size in
      let s = size.width / 24
      let box = CGRect(x: 3 * s, y: 7.8 * s, width: 18 * s, height: 8.4 * s)
      context.stroke(
        Path(roundedRect: box, cornerRadius: 2.2 * s), with: .foreground, lineWidth: 1.35 * s * 1.1)
      context.fill(
        Path(ellipseIn: CGRect(x: 6.1 * s, y: 11.1 * s, width: 1.8 * s, height: 1.8 * s)),
        with: .foreground)
      var slot = Path()
      slot.move(to: CGPoint(x: 10.6 * s, y: 12 * s))
      slot.addLine(to: CGPoint(x: 17.8 * s, y: 12 * s))
      context.stroke(slot, with: .foreground, style: StrokeStyle(lineWidth: 1.35 * s * 1.1, lineCap: .round))
    }
    .accessibilityHidden(true)
  }
}
