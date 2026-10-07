import MindloomDesign
import SwiftUI

// OWNER: mac-capture. S22 · The drop overlay (MAC-SPEC §5.4): the window
// tinted, a 2 pt inset accent outline, a thick-glass capsule 「松开，收进
// Mindloom」 rising from 6 pt below. The App's drop handler sets
// `MindloomShell(dropTargeted:)`.

public struct DropOverlayInput: Equatable, Sendable {
  public let targeted: Bool

  public init(targeted: Bool) { self.targeted = targeted }
}

public struct DropOverlay: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.zhijiSnapshot) private var snapshot
  let input: DropOverlayInput
  @State private var risen = false

  public init(input: DropOverlayInput) { self.input = input }

  public var body: some View {
    ZStack {
      Rectangle().fill(MLColor.dropDim)
      HStack(spacing: 10) {
        Image(systemName: "square.and.arrow.down")
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(MLColor.accent)
        Text("松开以添加到 Mindloom").mlFont(\.control).foregroundStyle(MLColor.ink)
      }
      .padding(.leading, 14)
      .padding(.trailing, 18)
      .frame(height: 40)
      .mlGlass(.thick)
      .offset(y: risen || snapshot || reduceMotion ? 0 : 6)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(MLColor.accent, lineWidth: 2)
    }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .onAppear {
      withAnimation(MLSpring.smooth.animation) { risen = true }
    }
    .onDisappear { risen = false }
  }
}
