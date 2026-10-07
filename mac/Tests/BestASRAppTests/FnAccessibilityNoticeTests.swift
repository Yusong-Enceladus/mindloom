import BestASRDictation
import XCTest

@testable import bestASR

/// fn without 设备控制和数据访问 does nothing, so the main window and the
/// menu bar say so until it is allowed (review of 10-6), whatever Welcome
/// was finished with.
final class FnAccessibilityNoticeTests: XCTestCase {
  func testShownUntilTheOwnerAllowsIt() {
    for state in [
      DictationPermissionState.notDetermined, .denied, .restricted, .revoked,
    ] {
      XCTAssertTrue(
        FnAccessibilityNotice.shows(accessibility: state, fnEntryOn: true, noArm: false), "\(state)"
      )
    }
    XCTAssertFalse(
      FnAccessibilityNotice.shows(accessibility: .granted, fnEntryOn: true, noArm: false))
    // Allowed; the system asks for a relaunch, which says so itself.
    XCTAssertFalse(
      FnAccessibilityNotice.shows(accessibility: .restartRequired, fnEntryOn: true, noArm: false))
  }

  func testNotShownWhenFnIsNotWanted() {
    // 「按住 fn 说话」 off in Settings › 入口, or a verification run.
    XCTAssertFalse(
      FnAccessibilityNotice.shows(accessibility: .denied, fnEntryOn: false, noArm: false))
    XCTAssertFalse(
      FnAccessibilityNotice.shows(accessibility: .denied, fnEntryOn: true, noArm: true))
  }

  func testTheLineNamesThePermissionAsMacOSDoes() {
    XCTAssertTrue(FnAccessibilityNotice.line.contains("“设备控制和数据访问”"))
    XCTAssertEqual(FnAccessibilityNotice.allow, "允许…")
  }
}
