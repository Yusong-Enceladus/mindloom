import BestASRInferenceXPCProtocol
import Foundation
import XCTest

final class InferenceXPCProtocolTests: XCTestCase {
  func testRequestSecureCodingRoundTrip() throws {
    let request = InferenceXPCRequest(
      jobID: "job-1",
      idempotencyKey: "asr:1:model:config",
      inputRevision: UInt64.max,
      modelVersion: "model-v1",
      configHash: "config-hash",
      audioRangeDigest: "sha256:audio",
      simulatedDelayMilliseconds: 25,
      modelLoadBytes: 1_048_576
    )
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: request,
      requiringSecureCoding: true
    )
    let decoded = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(
        ofClass: InferenceXPCRequest.self,
        from: data
      )
    )
    XCTAssertEqual(decoded.protocolVersion, InferenceXPCContract.currentVersion)
    XCTAssertEqual(decoded.jobID, request.jobID)
    XCTAssertEqual(decoded.idempotencyKey, request.idempotencyKey)
    XCTAssertEqual(decoded.inputRevision, UInt64.max)
    XCTAssertEqual(decoded.simulatedDelayMilliseconds, 25)
    XCTAssertEqual(decoded.modelLoadBytes, 1_048_576)
  }

  func testResponseSecureCodingRoundTrip() throws {
    let response = InferenceXPCResponse(
      jobID: "job-1",
      status: "succeeded",
      resultDigest: "sha256:result",
      errorCategory: "none",
      elapsedNanoseconds: 10,
      residentBeforeBytes: 20,
      residentPeakBytes: 30,
      residentAfterBytes: 21
    )
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: response,
      requiringSecureCoding: true
    )
    let decoded = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(
        ofClass: InferenceXPCResponse.self,
        from: data
      )
    )
    XCTAssertEqual(decoded.status, "succeeded")
    XCTAssertEqual(decoded.resultDigest, "sha256:result")
    XCTAssertEqual(decoded.elapsedNanoseconds, 10)
    XCTAssertEqual(decoded.residentBeforeBytes, 20)
    XCTAssertEqual(decoded.residentPeakBytes, 30)
    XCTAssertEqual(decoded.residentAfterBytes, 21)
  }

  func testInterfaceExposesVersionedProtocol() {
    let interface = InferenceXPCContract.interface()
    XCTAssertNotNil(interface)
    XCTAssertEqual(InferenceXPCContract.currentVersion, 1)
  }
}
