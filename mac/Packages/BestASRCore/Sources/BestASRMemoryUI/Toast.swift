import SwiftUI

/// "已收进来 · 来自 微信" with 改来源, bottom centre.
struct ToastView: View {
  @Environment(\.zhiji) private var palette
  let toast: MemoryToast
  let changeSource: @MainActor (String, String) -> Void
  @State private var editing = false

  var body: some View {
    HStack(spacing: 14) {
      Text(toast.message)
        .font(.zhiji(13))
        .foregroundStyle(.white)
        .lineLimit(1)
      if let itemID = toast.itemID {
        Button {
          editing = true
        } label: {
          Text(ZhijiCopy.changeSource)
            .font(.zhiji(12))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .top) {
          NamePopover(
            prompt: ZhijiCopy.sourcePrompt, initial: toast.sourceName ?? "",
            save: { name in
              editing = false
              changeSource(itemID, name)
            },
            cancel: { editing = false })
        }
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, toast.itemID == nil ? 16 : 8)
    .frame(height: 40)
    .background(palette.toast, in: Capsule())
    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.intake.confirmation")
    .onAppear { announce(toast.message) }
    .onChange(of: toast.message) { _, message in announce(message) }
  }

  /// VoiceOver says what was taken in; the toast itself never takes focus.
  private func announce(_ message: String) {
    AccessibilityNotification.Announcement(message).post()
  }
}
