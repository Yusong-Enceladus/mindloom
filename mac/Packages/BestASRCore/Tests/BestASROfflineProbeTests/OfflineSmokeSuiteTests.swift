import XCTest

@testable import BestASROfflineProbe

final class OfflineSmokeSuiteTests: XCTestCase {
  func testAllLocalCapabilitiesPassWithoutNetworkRequests() {
    let result = LocalOfflineSmokeSuite.run()

    XCTAssertEqual(result.status, .pass)
    XCTAssertEqual(Set(result.capabilities.map(\.capability)), Set(OfflineCapability.allCases))
    XCTAssertTrue(result.capabilities.allSatisfy { $0.status == .pass })
    XCTAssertTrue(result.capabilities.allSatisfy { $0.outputDigest.count == 64 })
    XCTAssertEqual(result.requestAudit.attemptedRequests, 0)
    XCTAssertEqual(result.requestAudit.allowedRequests, 0)
  }

  func testDenyAllAuditRecordsAndRejectsInjectedRequest() {
    var audit = DenyAllNetworkAudit()

    XCTAssertThrowsError(try audit.request(destination: "fixture.invalid"))
    XCTAssertEqual(audit.report.attemptedRequests, 1)
    XCTAssertEqual(audit.report.deniedRequests, 1)
    XCTAssertEqual(audit.report.allowedRequests, 0)
  }
}
