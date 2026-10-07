import BestASRMemory
import Foundation

// OWNER: mac-capture. State and actions only mac-capture's pages need (capture, HUD, toasts of capture, drop, menu bar extra, Welcome, Settings, consent, sharing and spaces).
// Add fields here (not to MemoryScreenState / MemoryActions) so the three
// v11 branches never edit the same lines; the App fills them in
// App/MindloomWiring+Capture.swift.

/// Extra values for mac-capture's pages (`MemoryScreenState.captureExtras`).
public struct MemoryCaptureExtras {
  /// The quiet line while the user's own bestASR App holds fn (preview).
  public var fnTaken: Bool

  public init(fnTaken: Bool = false) {
    self.fnTaken = fnTaken
  }
}

/// Extra actions for mac-capture's pages (`MemoryActions.capture`); every
/// default does nothing.
public struct MemoryCaptureActions {
  /// 退出这个共享空间 (the App asks first, then leaves).
  public var leaveSpace: @MainActor (_ spaceID: String) -> Void

  public init(leaveSpace: @escaping @MainActor (String) -> Void = { _ in }) {
    self.leaveSpace = leaveSpace
  }
}
