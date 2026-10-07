import Foundation
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// Welcome after the switch (review of 10-6): the permissions step does not
/// invite trying fn while Welcome blocks it, and says plainly that fn does
/// nothing without 设备控制和数据访问; the devices step offers DGX Spark only
/// when this library may be sent there.
final class WelcomeStepsTests: XCTestCase {
  func testThePermissionsStepDoesNotInviteTryingFn() throws {
    XCTAssertFalse(WelcomeCopy.permissionsTitle.contains("fn"))
    let source = try String(
      contentsOf: VocabularyGuardTests.repositoryRoot.appendingPathComponent(
        "Packages/BestASRCore/Sources/BestASRMemoryUI/Capture/WelcomeView.swift"),
      encoding: .utf8)
    XCTAssertFalse(source.contains(#"title: "按住 fn 说话""#))
    XCTAssertTrue(source.contains("title: WelcomeCopy.permissionsTitle"))
  }

  func testWithoutTheGrantWelcomeSaysFnDoesNothing() {
    let without = WelcomeCopy.fnLine(accessibilityOn: false)
    XCTAssertTrue(without.contains("“设备控制和数据访问”"))
    XCTAssertTrue(without.contains("不能口述"))
    XCTAssertTrue(without.contains("菜单栏"))
    XCTAssertTrue(WelcomeCopy.fnLine(accessibilityOn: true).contains("完成欢迎设置后"))
  }

  func testNoSparkCardWhereTheLibraryMayNotBeSent() {
    XCTAssertTrue(WelcomeCopy.devicesText(sparkAvailable: true).contains("DGX"))
    let without = WelcomeCopy.devicesText(sparkAvailable: false)
    XCTAssertFalse(without.contains("DGX"))
    XCTAssertFalse(without.contains("Spark"))
    XCTAssertTrue(WelcomeInput().sparkAvailable)
    XCTAssertFalse(WelcomeInput(step: .devices, sparkAvailable: false).sparkAvailable)
  }

  @MainActor
  func testTheStepsDrawEitherWay() {
    for input in [
      WelcomeInput(step: .permissions, microphoneOn: true, accessibilityOn: false),
      WelcomeInput(step: .permissions, microphoneOn: true, accessibilityOn: true),
      WelcomeInput(step: .devices, sparkAvailable: false),
      WelcomeInput(step: .devices, sparkConnecting: true),
    ] {
      let renderer = ImageRenderer(
        content: WelcomeView(input: input).environment(\.zhijiSnapshot, true))
      XCTAssertNotNil(renderer.nsImage)
    }
  }
}
