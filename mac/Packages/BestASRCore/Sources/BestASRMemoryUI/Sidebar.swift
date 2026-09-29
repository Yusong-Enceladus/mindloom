import SwiftUI

/// 首页 · 人物 · 词典, then the recording indicator and 设置 at the bottom.
struct Sidebar: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  @Binding var navigation: MemoryNavigation
  let capture: MemoryCaptureIndicator?
  let openCapture: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      // The window's own traffic lights sit here (hidden title bar); a still
      // image draws them so it reads like the window.
      HStack(spacing: 8) {
        if snapshot {
          ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { color in
            Circle().fill(Color.hex(color)).frame(width: 12, height: 12)
          }
        }
      }
      .frame(height: 12)
      .padding(.horizontal, 6)
      .padding(.top, 2)
      .padding(.bottom, 18)

      row(.home, ZhijiCopy.home, symbol: "square.grid.2x2", shortcut: "1")
      row(.people, ZhijiCopy.people, symbol: "person", shortcut: "2")
      row(.dictionary, ZhijiCopy.dictionary, symbol: "doc.text", shortcut: "3")

      Spacer(minLength: 16)

      if let capture {
        RecordingIndicator(capture: capture, action: openCapture)
      }
      settingsRow
        .padding(.top, capture == nil ? 0 : 6)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 14)
    .frame(width: ZhijiMetrics.sidebarWidth)
    .frame(maxHeight: .infinity)
    .background(palette.sidebar)
    .overlay(alignment: .trailing) {
      Rectangle().fill(palette.isDark ? Color.white.opacity(0.08) : .black.opacity(0.08))
        .frame(width: 1)
    }
  }

  private func row(
    _ tab: MemoryTab, _ title: String, symbol: String, shortcut: KeyEquivalent
  ) -> some View {
    // A Person page belongs to 人物 wherever it was opened from.
    let showing: MemoryTab =
      if case .person? = navigation.path.last { .people } else { navigation.tab }
    let selected = showing == tab
    return Button {
      navigation.tab = tab
      navigation.path = []
    } label: {
      SidebarRowLabel(title: title, symbol: symbol, selected: selected)
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcut, modifiers: .command)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("bestASR.sidebar.\(title)")
  }

  @ViewBuilder
  private var settingsRow: some View {
    let label = SidebarRowLabel(title: ZhijiCopy.settings, symbol: "gearshape", selected: false)
    if snapshot {
      label
    } else {
      SettingsLink { label }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bestASR.openSettings")
    }
  }
}

private struct SidebarRowLabel: View {
  @Environment(\.zhiji) private var palette
  let title: String
  let symbol: String
  let selected: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(selected ? palette.accent : palette.secondary)
        .frame(width: 16, height: 16)
      Text(title)
        .font(.zhiji(13, selected ? .semibold : .regular))
        .foregroundStyle(palette.label)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.selectionFill)
      }
    }
    .contentShape(Rectangle())
  }
}

/// "正在记录 · 腾讯会议 · 12:04" as a small card; clicking it opens the capture.
struct RecordingIndicator: View {
  @Environment(\.zhiji) private var palette
  let capture: MemoryCaptureIndicator
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Circle()
          .fill(capture.paused ? Color.orange : palette.recording)
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 1) {
          Text(capture.title)
            .font(.zhiji(12, .semibold))
            .foregroundStyle(palette.label)
          Text(capture.detail)
            .font(.zhiji(11))
            .monospacedDigit()
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .background(
        palette.isDark ? palette.surface : .white,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(palette.isDark ? Color.white.opacity(0.08) : .black.opacity(0.06))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("bestASR.activeCapture.return")
  }
}
