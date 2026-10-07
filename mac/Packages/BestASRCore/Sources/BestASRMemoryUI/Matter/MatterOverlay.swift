import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. The matter page's overlay layer (MAC-SPEC §7.1–§7.3,
// §4.14): where things are (anchor preferences), where a popover goes
// (`placePop`: below or above, the side that covers fewest labels, never its
// own), its arrow, the 25 % dimming of labels it still covers, tooltips.

/// Bounds of the matter page's pieces, by key:
/// - `step:<id>`: what a step's popover points at (its mark, 待定 row, small-page row);
/// - `own:<id>`: the label of the mark holding the step (never covered);
/// - `seg:<part>`: a part's segment;
/// - `lab:<mark>`, `name:<part>`, `q:<step>`, `meta`: labels the popover avoids and dims.
struct MatterAnchorKey: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  /// Publishes this view's bounds under `keys`.
  func matterAnchor(_ keys: [String]) -> some View {
    anchorPreference(key: MatterAnchorKey.self, value: .bounds) { anchor in
      Dictionary(keys.map { ($0, anchor) }, uniquingKeysWith: { a, _ in a })
    }
  }

  func matterAnchor(_ key: String) -> some View { matterAnchor([key]) }
}

/// Places a popover next to its anchor (§7.3) and dims what it covers.
/// Subviews, bottom to top: one veil per avoided label (drawn under the
/// popover), the arrow pointing up (popover below), the arrow pointing down
/// (popover above), the popover, then anything else (kept out of sight).
struct MatterPopoverLayout: Layout {
  static let width: CGFloat = 352
  let anchor: CGRect
  let ownLabel: CGRect?
  let labels: [CGRect]

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  struct Placement {
    let frame: CGRect
    let up: Bool
    let arrowX: CGFloat
  }

  static func place(
    size: CGSize, anchor: CGRect, ownLabel: CGRect?, labels: [CGRect], in bounds: CGSize
  ) -> Placement {
    let ax = anchor.midX
    let left = max(10, min(bounds.width - size.width - 14, ax - size.width / 2))
    func overlap(_ r: CGRect, _ top: CGFloat) -> CGFloat {
      let p = CGRect(x: left, y: top, width: size.width, height: size.height)
      let i = p.intersection(r)
      return i.isNull ? 0 : i.width * i.height
    }
    func cost(_ top: CGFloat) -> CGFloat {
      var c: CGFloat = 0
      if top < 56 { c += 1e6 }
      if top + size.height > bounds.height - 10 { c += 1e6 }
      if let ownLabel, overlap(ownLabel, top) > 0 { c += 1e5 }
      for r in labels { c += overlap(r, top) }
      return c
    }
    let below = anchor.maxY + 12
    let above = anchor.minY - size.height - 12
    let up = cost(above) < cost(below) * 0.7
    let top = up ? above : below
    let arrowX = max(18, min(size.width - 18, ax - left))
    return Placement(
      frame: CGRect(x: left, y: top, width: size.width, height: size.height), up: up, arrowX: arrowX
    )
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let n = labels.count
    guard subviews.count >= n + 3 else { return }
    let popover = subviews[n + 2]
    let size = popover.sizeThatFits(ProposedViewSize(width: Self.width, height: nil))
    let placement = Self.place(
      size: size, anchor: anchor, ownLabel: ownLabel, labels: labels, in: bounds.size)
    let frame = placement.frame.offsetBy(dx: bounds.minX, dy: bounds.minY)
    let hidden = CGPoint(x: bounds.minX, y: bounds.minY)
    for (index, label) in labels.enumerated() {
      let covered = !label.intersection(placement.frame).isNull
      subviews[index].place(
        at: covered ? CGPoint(x: bounds.minX + label.minX, y: bounds.minY + label.minY) : hidden,
        anchor: .topLeading, proposal: covered ? ProposedViewSize(label.size) : .zero)
    }
    // The arrow: 20 × 8, its base on the popover's edge.
    let arrowOrigin = CGPoint(
      x: frame.minX + placement.arrowX - 10, y: placement.up ? frame.maxY - 0.5 : frame.minY - 7.5)
    subviews[n].place(
      at: placement.up ? hidden : arrowOrigin, anchor: .topLeading,
      proposal: placement.up ? .zero : ProposedViewSize(width: 20, height: 8))
    subviews[n + 1].place(
      at: placement.up ? arrowOrigin : hidden, anchor: .topLeading,
      proposal: placement.up ? ProposedViewSize(width: 20, height: 8) : .zero)
    popover.place(
      at: frame.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: Self.width, height: size.height))
    for extra in subviews.dropFirst(n + 3) {
      extra.place(at: hidden, anchor: .topLeading, proposal: .zero)
    }
  }
}

/// The popover's arrow (a rounded triangle), pointing up or down.
struct PopoverArrow: Shape {
  let up: Bool

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let tip = up ? CGPoint(x: rect.midX, y: rect.minY) : CGPoint(x: rect.midX, y: rect.maxY)
    let baseY = up ? rect.maxY : rect.minY
    path.move(to: CGPoint(x: rect.minX, y: baseY))
    let d: CGFloat = 2.2
    let k = up ? d : -d
    path.addLine(to: CGPoint(x: tip.x - d * 1.25, y: tip.y + k))
    path.addQuadCurve(to: CGPoint(x: tip.x + d * 1.25, y: tip.y + k), control: tip)
    path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
    path.closeSubpath()
    return path
  }
}

/// The arrow's two slanted edges (the 0.5 pt ring the popover has).
struct PopoverArrowEdge: Shape {
  let up: Bool

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let tip = up ? CGPoint(x: rect.midX, y: rect.minY) : CGPoint(x: rect.midX, y: rect.maxY)
    let baseY = up ? rect.maxY : rect.minY
    let d: CGFloat = 2.2
    let k = up ? d : -d
    path.move(to: CGPoint(x: rect.minX, y: baseY))
    path.addLine(to: CGPoint(x: tip.x - d * 1.25, y: tip.y + k))
    path.addQuadCurve(to: CGPoint(x: tip.x + d * 1.25, y: tip.y + k), control: tip)
    path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
    return path
  }
}

/// The arrow: the popover's fill with its edge.
struct PopoverArrowView: View {
  let up: Bool

  var body: some View {
    ZStack {
      PopoverArrow(up: up).fill(MatterPopoverChrome<EmptyView>.fill)
      PopoverArrowEdge(up: up).stroke(MLColor.rule2, lineWidth: 0.5)
    }
  }
}

/// The popover's chrome (§7.1): thick glass, 352 wide, radius 14, padding
/// 14 16, callout type.
struct MatterPopoverChrome<Content: View>: View {
  /// The thick glass's warm tint, nearly opaque: the prototype's 36 pt
  /// backdrop blur leaves nothing readable behind a popover, and neither
  /// may ours (Liquid Glass alone lets the time view show through).
  static var fill: MLColor {
    MLColor(light: MLRGBA(252, 251, 248, 0.94), dark: MLRGBA(44, 42, 39, 0.94))
  }

  let label: String
  let content: Content

  init(label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .mlFont(\.callout)
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .frame(width: MatterPopoverLayout.width, alignment: .leading)
      .background(
        MatterPopoverChrome<EmptyView>.fill,
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(label)
      .accessibilityAddTraits(.isModal)
  }
}

/// A hover tooltip (§4.14): thick glass, max 300 wide, padding 8 10, radius
/// 10, sub type, 6 pt above its element, fades in 160 ms.
struct MatterTooltip: View {
  let text: Text

  var body: some View {
    text
      .mlFont(\.sub)
      .foregroundStyle(MLColor.ink)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 280, alignment: .leading)
      .fixedSize()
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .allowsHitTesting(false)
  }
}

/// Positions a tooltip centred 6 pt above `rect` (in the parent's space),
/// kept inside `width`.
struct TooltipLayout: Layout {
  let rect: CGRect
  let width: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let tip = subviews.first else { return }
    let size = tip.sizeThatFits(.unspecified)
    let x = max(-20, min(width - size.width + 20, rect.midX - size.width / 2))
    tip.place(
      at: CGPoint(x: bounds.minX + x, y: bounds.minY + rect.minY - 6 - size.height),
      anchor: .topLeading, proposal: ProposedViewSize(size))
  }
}

/// A quote with its span marked (`--accent-tint-2`, radius 3); never
/// autospaced.
func markedQuote(_ words: String, quote: String?, scheme: ColorScheme) -> Text {
  guard let quote, !quote.isEmpty, let range = words.range(of: quote) else { return Text(words) }
  var marked = AttributedString(words[range])
  marked.backgroundColor = MLColor.accentTint2.color(for: scheme)
  return Text(String(words[..<range.lowerBound])) + Text(marked)
    + Text(String(words[range.upperBound...]))
}

/// One quote line: 「{name}：」 in `--ink-2`, then the words.
func quoteLine(_ line: MemoryQuoteLine, quote: String?, scheme: ColorScheme) -> Text {
  let speaker =
    line.speaker.isEmpty
    ? Text("") : Text(line.speaker + "：").foregroundStyle(MLColor.ink2)
  return speaker + markedQuote(line.words, quote: quote, scheme: scheme)
}
