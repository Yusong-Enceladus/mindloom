import XCTest

@testable import BestASRCore

final class WorkspaceSmokeTests: XCTestCase {
  func testWorkspaceUsesFrozenPlatformContract() {
    XCTAssertEqual(WorkspaceIdentity().minimumMacOS, "14.2")
    XCTAssertEqual(WorkspaceIdentity().architecture, "arm64")
    XCTAssertEqual(WorkspaceIdentity().swiftLanguageMode, "6")
  }

  func testTelemetryIsOffByDefault() {
    XCTAssertFalse(PlatformContract.productTelemetryEnabledByDefault)
  }
}
