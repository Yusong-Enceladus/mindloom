import MindloomDesign
import SwiftUI

/// Scroll offsets remembered per page key (`MemoryNavigation.scrollKey`), so
/// back and a lens change return to where the page was (§3.6).
@MainActor
public final class MindloomScrollMemory: ObservableObject {
  public private(set) var offsets: [String: CGFloat] = [:]

  public init() {}

  public func offset(_ key: String) -> CGFloat { offsets[key] ?? 0 }

  public func remember(_ offset: CGFloat, for key: String) { offsets[key] = max(0, offset) }
}

extension EnvironmentValues {
  /// The window's scroll memory (the shell sets it).
  @Entry public var mindloomScrollMemory: MindloomScrollMemory? = nil
  /// While rendering a still image: how far the page is scrolled (points).
  @Entry public var mindloomSnapshotScroll: CGFloat = 0
}

/// The page container (§3.6): 56 pt at the top (under the floating toolbar),
/// 32 at the sides, 48 at the bottom; vertical scrolling with the indicator
/// hidden; the offset remembered under `key` (macOS 15 and later restore
/// it). While rendering a still image the content is drawn from the top (or
/// from `mindloomSnapshotScroll`), because AppKit scroll views do not draw
/// into `ImageRenderer`.
public struct MindloomPageScroll<Content: View>: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.mindloomSnapshotScroll) private var snapshotScroll
  @Environment(\.mindloomScrollMemory) private var memory
  let key: String
  let maxWidth: CGFloat?
  let content: Content

  /// - Parameters:
  ///   - key: the scroll-memory key (`MemoryNavigation.scrollKey`).
  ///   - maxWidth: the column's width (760 matter and person pages, 680 the
  ///     原文 tab and the small page); nil uses the full content width.
  public init(key: String, maxWidth: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.key = key
    self.maxWidth = maxWidth
    self.content = content()
  }

  private var column: some View {
    content
      .frame(maxWidth: maxWidth ?? .infinity, alignment: .topLeading)
      // Left-aligned at the 32 pt gutter like every prototype column (`.ppl`,
      // `.mh`: max-width with no auto margins).
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.top, 56)
      .padding(.horizontal, 32)
      .padding(.bottom, 48)
  }

  public var body: some View {
    if snapshot {
      column
        .fixedSize(horizontal: false, vertical: true)
        .offset(y: -snapshotScroll)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
    } else if #available(macOS 15.0, *) {
      RememberingScroll(key: key, memory: memory) { column }
    } else {
      ScrollView(.vertical) { column }.scrollIndicators(.hidden)
    }
  }
}

@available(macOS 15.0, *)
private struct RememberingScroll<Content: View>: View {
  let key: String
  let memory: MindloomScrollMemory?
  let content: Content
  @State private var position = ScrollPosition(edge: .top)

  init(key: String, memory: MindloomScrollMemory?, @ViewBuilder content: () -> Content) {
    self.key = key
    self.memory = memory
    self.content = content()
  }

  var body: some View {
    ScrollView(.vertical) { content }
      .scrollIndicators(.hidden)
      .scrollPosition($position)
      .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
        memory?.remember(offset, for: key)
      }
      .onAppear { position.scrollTo(y: memory?.offset(key) ?? 0) }
      .onChange(of: key) { _, next in position.scrollTo(y: memory?.offset(next) ?? 0) }
  }
}
