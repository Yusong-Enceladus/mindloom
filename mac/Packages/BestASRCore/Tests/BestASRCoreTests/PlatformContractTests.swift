import XCTest

@testable import BestASRCore

final class PlatformContractTests: XCTestCase {
  func testFoundationKeepsOfflineAndPlatformBoundary() throws {
    XCTAssertEqual(PlatformContract.minimumMacOS.majorVersion, 14)
    XCTAssertEqual(PlatformContract.minimumMacOS.minorVersion, 2)
    XCTAssertEqual(PlatformContract.supportedArchitecture, "arm64")
    XCTAssertFalse(PlatformContract.productTelemetryEnabledByDefault)
  }

  func testWorkspaceIdentityRoundTrips() throws {
    let value = WorkspaceIdentity()
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceIdentity.self, from: data), value)
  }
}
