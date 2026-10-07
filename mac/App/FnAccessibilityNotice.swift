import BestASRDictation
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. fn needs 设备控制和数据访问 (review of 10-6): the fn
// event tap exists only while Mindloom has that permission, so without it fn
// does nothing at all and the HUD's hints never show. On the switch day
// Mindloom is a new App to macOS and starts without it; Welcome's 继续 and
// 以后 do not wait for it. Until it is allowed, the main window and the menu
// bar say so, with 允许… (the system's prompt, or its settings).

enum FnAccessibilityNotice {
  static let line = "按住 fn 口述需要允许“设备控制和数据访问”。"
  static let allow = "允许…"

  /// fn is wanted (「按住 fn 说话」 on, not a verification run) and the
  /// permission is not there.
  static func shows(accessibility: DictationPermissionState, fnEntryOn: Bool, noArm: Bool)
    -> Bool
  {
    guard fnEntryOn, !noArm else { return false }
    return accessibility != .granted && accessibility != .restartRequired
  }
}

/// The main window's line along its bottom edge.
struct FnAccessibilityBar: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject var onboarding: OnboardingModel

  var body: some View {
    if FnAccessibilityNotice.shows(
      accessibility: onboarding.accessibilityPermission, fnEntryOn: model.fnEntryEnabled,
      noArm: MindloomLaunch.noArm)
    {
      HStack(spacing: 10) {
        Image(systemName: "keyboard").foregroundStyle(MLColor.alert)
        Text(FnAccessibilityNotice.line).mlFont(\.sub).foregroundStyle(MLColor.ink)
        Button(FnAccessibilityNotice.allow) { model.resolvePermission(.accessibility) }
          .buttonStyle(MLButtonStyle(.primary, small: true))
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 14)
      .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
          MLColor.rule2, lineWidth: 0.5)
      )
      .padding(.bottom, 16)
      .accessibilityElement(children: .contain)
    }
  }
}

/// The menu bar menu's first rows.
struct FnAccessibilityMenuRows: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject var onboarding: OnboardingModel

  var body: some View {
    if FnAccessibilityNotice.shows(
      accessibility: onboarding.accessibilityPermission, fnEntryOn: model.fnEntryEnabled,
      noArm: MindloomLaunch.noArm)
    {
      Text(FnAccessibilityNotice.line)
      Button(FnAccessibilityNotice.allow) { model.resolvePermission(.accessibility) }
      Divider()
    }
  }
}
