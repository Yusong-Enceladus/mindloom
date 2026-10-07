import SwiftUI

// Hooks for the preview's live verification run (App/LiveShots.swift, built
// only with MINDLOOM_PREVIEW). In the App nothing sets them, so they change
// nothing: a hover a script cannot make with the pointer is shown as if the
// pointer were there.

private struct MindloomForcedHoverKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  /// A Home row (event ID) whose track shows its latest dot's tooltip as if
  /// hovered (live verification only; nil in use).
  public var mindloomForcedHover: String? {
    get { self[MindloomForcedHoverKey.self] }
    set { self[MindloomForcedHoverKey.self] = newValue }
  }
}
