import CoreAudio
import Foundation
import XCTest

@testable import BestASRProcessTapProbe

final class ProcessTapProbeTests: XCTestCase {
  @available(macOS 14.2, *)
  func testReleaseDecisionPassesOnlyWithCompleteLiveBoundaries() {
    let pass = ProcessTapProbeRunner.releaseDecision(
      failedScenarioIDs: [],
      physicalSwitchPerformed: true,
      actualTCCDenialUsed: true
    )
    XCTAssertEqual(pass.conclusion, "pass")
    XCTAssertTrue(pass.unmetCriteria.isEmpty)

    let conditional = ProcessTapProbeRunner.releaseDecision(
      failedScenarioIDs: [],
      physicalSwitchPerformed: false,
      actualTCCDenialUsed: true
    )
    XCTAssertEqual(conditional.conclusion, "conditional")
    XCTAssertEqual(conditional.unmetCriteria.count, 1)

    let failed = ProcessTapProbeRunner.releaseDecision(
      failedScenarioIDs: ["fixture-failure"],
      physicalSwitchPerformed: true,
      actualTCCDenialUsed: true
    )
    XCTAssertEqual(failed.conclusion, "fail")
    XCTAssertEqual(failed.unmetCriteria, ["Failed scenario: fixture-failure"])
  }

  func testProcessesWithSameBundleAreOneApplicationGroup() {
    let processes = [
      process(
        objectID: 1,
        processID: 101,
        parentProcessID: 1,
        bundleID: "com.example.meeting",
        name: "Meeting"
      ),
      process(
        objectID: 2,
        processID: 102,
        parentProcessID: 101,
        bundleID: "com.example.meeting",
        name: "Meeting Helper"
      ),
      process(
        objectID: 3,
        processID: 201,
        parentProcessID: 1,
        bundleID: "com.example.music",
        name: "Music"
      ),
    ]

    let groups = ProcessAudioGrouper.groups(from: processes)

    XCTAssertEqual(groups.count, 2)
    let meeting = groups.first { $0.bundleID == "com.example.meeting" }
    XCTAssertEqual(meeting?.processIDs, [101, 102])
    XCTAssertEqual(meeting?.audioObjectIDs, [1, 2])
  }

  func testChromiumHelperBundleVariantsStayInsideParentApplicationGroup() {
    let processes = [
      process(
        objectID: 1,
        processID: 101,
        parentProcessID: 1,
        bundleID: "com.google.Chrome",
        name: "Google Chrome"
      ),
      process(
        objectID: 2,
        processID: 102,
        parentProcessID: 101,
        bundleID: "com.google.Chrome.helper.renderer",
        name: "Google Chrome Helper (Renderer)"
      ),
      process(
        objectID: 3,
        processID: 201,
        parentProcessID: 1,
        bundleID: "com.apple.Music",
        name: "Music"
      ),
    ]

    let groups = ProcessAudioGrouper.groups(from: processes)

    XCTAssertEqual(groups.count, 2)
    let chrome = groups.first { $0.bundleID == "com.google.Chrome" }
    XCTAssertEqual(chrome?.displayName, "Google Chrome")
    XCTAssertEqual(chrome?.processIDs, [101, 102])
    XCTAssertEqual(chrome?.audioObjectIDs, [1, 2])
  }

  func testHostNamedWebKitMediaHelperStaysInsideMeetingApplicationGroup() {
    let processes = [
      process(
        objectID: 1,
        processID: 101,
        parentProcessID: 1,
        bundleID: "com.tencent.meeting",
        name: "腾讯会议"
      ),
      process(
        objectID: 2,
        processID: 102,
        parentProcessID: 999,
        bundleID: "com.apple.WebKit",
        name: "腾讯会议 Graphics and Media"
      ),
      process(
        objectID: 3,
        processID: 201,
        parentProcessID: 1,
        bundleID: "com.apple.Music",
        name: "Music"
      ),
    ]

    let groups = ProcessAudioGrouper.groups(from: processes)

    XCTAssertEqual(groups.count, 2)
    let meeting = groups.first { $0.bundleID == "com.tencent.meeting" }
    XCTAssertEqual(meeting?.displayName, "腾讯会议")
    XCTAssertEqual(meeting?.processIDs, [101, 102])
    XCTAssertEqual(meeting?.audioObjectIDs, [1, 2])
    XCTAssertNil(groups.first { $0.bundleID == "com.apple.WebKit" })
  }

  func testHostNamedMediaHelperDoesNotMergeWithoutMatchingApplication() {
    let processes = [
      process(
        objectID: 1,
        processID: 101,
        parentProcessID: 1,
        bundleID: "com.tencent.meeting",
        name: "腾讯会议"
      ),
      process(
        objectID: 2,
        processID: 102,
        parentProcessID: 999,
        bundleID: "com.apple.WebKit",
        name: "Other Client Graphics and Media"
      ),
    ]

    let groups = ProcessAudioGrouper.groups(from: processes)

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(
      groups.first { $0.bundleID == "com.tencent.meeting" }?.audioObjectIDs,
      [1]
    )
    XCTAssertEqual(
      groups.first { $0.bundleID == "com.apple.WebKit" }?.audioObjectIDs,
      [2]
    )
  }

  func testBundlelessChildProcessesRemainRelatedToSelectedRoot() {
    let root = process(
      objectID: 1,
      processID: 101,
      parentProcessID: 1,
      bundleID: "",
      name: "Synthetic Player"
    )
    let child = process(
      objectID: 2,
      processID: 102,
      parentProcessID: 101,
      bundleID: "",
      name: "Synthetic Helper"
    )
    let grandchild = process(
      objectID: 3,
      processID: 103,
      parentProcessID: 102,
      bundleID: "",
      name: "Synthetic Helper"
    )
    let unrelated = process(
      objectID: 4,
      processID: 201,
      parentProcessID: 1,
      bundleID: "",
      name: "Other"
    )

    let related = ProcessAudioGrouper.relatedProcesses(
      to: root,
      in: [unrelated, grandchild, child, root]
    )

    XCTAssertEqual(Set(related.map(\.processID)), [101, 102, 103])
  }

  func testWatermarkDetectorSeparatesSelectedAndNonselectedTags() {
    let sampleRate = 48_000.0
    let samples = (0..<48_000).map { frame -> Float in
      let time = Double(frame) / sampleRate
      return Float(0.2 * sin(2 * Double.pi * 697 * time))
    }

    let selected = WatermarkDetector.measure(
      samples: samples,
      sampleRate: sampleRate,
      frequency: 697
    )
    let nonselected = WatermarkDetector.measure(
      samples: samples,
      sampleRate: sampleRate,
      frequency: 941
    )

    XCTAssertTrue(selected.detected)
    XCTAssertGreaterThan(selected.amplitude, 0.19)
    XCTAssertFalse(nonselected.detected)
    XCTAssertLessThan(nonselected.amplitude, 0.001)
  }

  func testMatrixEvidenceRoundTrips() throws {
    let matrix = ProcessTapMatrixEvidence(
      runID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
      generatedAt: Date(timeIntervalSince1970: 0),
      osVersion: "fixture",
      hardwareArchitecture: "arm64",
      scenarios: [
        ProcessTapMatrixScenario(
          scenarioID: "fixture",
          status: "pass",
          evidenceMode: "deterministic",
          metrics: ["captured": "true"]
        )
      ]
    )

    let encoded = try JSONEncoder().encode(matrix)
    let decoded = try JSONDecoder().decode(
      ProcessTapMatrixEvidence.self,
      from: encoded
    )

    XCTAssertEqual(decoded, matrix)
  }

  func testTCCDenialEvidenceRequiresObservationAndOperatorConfirmation() {
    let observation = tccDenialEvidence(operatorConfirmed: false)
    XCTAssertFalse(observation.isConfirmedDenial)

    let confirmed = tccDenialEvidence(operatorConfirmed: true)
    XCTAssertTrue(confirmed.isConfirmedDenial)

    let suppressedAfterIOStart = tccDenialEvidence(
      operatorConfirmed: true,
      captureStarted: true,
      audioContentSuppressed: true
    )
    XCTAssertTrue(suppressedAfterIOStart.isConfirmedDenial)

    let readableAfterIOStart = tccDenialEvidence(
      operatorConfirmed: true,
      captureStarted: true,
      audioContentSuppressed: false
    )
    XCTAssertFalse(readableAfterIOStart.isConfirmedDenial)
  }

  func testPermissionDenialStopsAtPolicyBoundary() {
    XCTAssertThrowsError(
      try ProcessTapPermissionPolicy.requireAuthorized(.denied)
    ) { error in
      XCTAssertEqual(error as? ProcessTapPermissionPolicyError, .denied)
    }
    XCTAssertNoThrow(
      try ProcessTapPermissionPolicy.requireAuthorized(.authorized)
    )
  }

  func testOutputDeviceTrackerEmitsOnlyRealTransitions() {
    var tracker = OutputDeviceChangeTracker()

    XCTAssertNil(
      tracker.observe(deviceID: 10, monotonicNanoseconds: 100)
    )
    XCTAssertNil(
      tracker.observe(deviceID: 10, monotonicNanoseconds: 200)
    )
    let event = tracker.observe(deviceID: 11, monotonicNanoseconds: 300)

    XCTAssertEqual(event?.kind, .deviceChanged)
    XCTAssertEqual(event?.monotonicNanoseconds, 300)
  }

  func testAlternatePhysicalOutputExcludesCurrentAndVirtualDevices() {
    let current = AudioOutputDeviceSnapshot(
      objectID: 10,
      uid: "fixture-current",
      name: "fixture-current",
      transportType: kAudioDeviceTransportTypeBuiltIn,
      isDefaultOutput: true
    )
    let virtual = AudioOutputDeviceSnapshot(
      objectID: 11,
      uid: "fixture-virtual",
      name: "fixture-virtual",
      transportType: kAudioDeviceTransportTypeVirtual,
      isDefaultOutput: false
    )
    let physical = AudioOutputDeviceSnapshot(
      objectID: 12,
      uid: "fixture-physical",
      name: "fixture-physical",
      transportType: kAudioDeviceTransportTypeUSB,
      isDefaultOutput: false
    )

    XCTAssertEqual(
      CoreAudioHAL.alternatePhysicalOutputDevice(
        from: [current, virtual, physical],
        excluding: current.objectID
      ),
      physical
    )
  }

  func testAlternatePhysicalOutputAcceptsDisplayTransports() {
    let current = AudioOutputDeviceSnapshot(
      objectID: 10,
      uid: "fixture-current",
      name: "fixture-current",
      transportType: kAudioDeviceTransportTypeBuiltIn,
      isDefaultOutput: true
    )
    let hdmi = AudioOutputDeviceSnapshot(
      objectID: 11,
      uid: "fixture-hdmi",
      name: "fixture-hdmi",
      transportType: kAudioDeviceTransportTypeHDMI,
      isDefaultOutput: false
    )
    let displayPort = AudioOutputDeviceSnapshot(
      objectID: 12,
      uid: "fixture-display-port",
      name: "fixture-display-port",
      transportType: kAudioDeviceTransportTypeDisplayPort,
      isDefaultOutput: false
    )

    XCTAssertEqual(
      CoreAudioHAL.alternatePhysicalOutputDevice(
        from: [current, hdmi, displayPort],
        excluding: current.objectID
      ),
      hdmi
    )
  }

  private func tccDenialEvidence(
    operatorConfirmed: Bool,
    captureStarted: Bool = false,
    audioContentSuppressed: Bool = true
  ) -> ProcessTapTCCDenialEvidence {
    let failureCategory: String
    if captureStarted {
      if audioContentSuppressed {
        failureCategory = "tcc-denied-audio-content-suppressed"
      } else {
        failureCategory = "audio-content-accessible-permission-was-not-denied"
      }
    } else {
      failureCategory = "tcc-denied-before-capture-start"
    }

    return ProcessTapTCCDenialEvidence(
      runID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
      generatedAt: Date(timeIntervalSince1970: 0),
      osVersion: "fixture",
      hardwareArchitecture: "arm64",
      probeBundleIdentifier:
        ProcessTapTCCDenialEvidence.expectedProbeBundleIdentifier,
      status: operatorConfirmed ? "pass" : "conditional",
      denialObserved: true,
      operatorConfirmedDenial: operatorConfirmed,
      tapCreated: true,
      createTapStatus: 0,
      captureStarted: captureStarted,
      startCaptureStatus: captureStarted ? 0 : -1,
      callbackCount: captureStarted ? 100 : 0,
      frameCount: captureStarted ? 48_000 : 0,
      capturedRMS: audioContentSuppressed ? 0 : 0.02,
      capturedWatermarkAmplitude: audioContentSuppressed ? 0 : 0.02,
      watermarkDetected: captureStarted && !audioContentSuppressed,
      audioContentSuppressed: audioContentSuppressed,
      tapCountBefore: 3,
      tapCountAfter: 3,
      aggregateDeviceCountBefore: 2,
      aggregateDeviceCountAfter: 2,
      syntheticSourceOnly: true,
      sourceAudioPersisted: false,
      failureCategory: failureCategory
    )
  }

  private func process(
    objectID: UInt32,
    processID: Int32,
    parentProcessID: Int32,
    bundleID: String,
    name: String
  ) -> AudioProcessSnapshot {
    AudioProcessSnapshot(
      objectID: objectID,
      processID: processID,
      parentProcessID: parentProcessID,
      bundleID: bundleID,
      displayName: name,
      isRunningOutput: true
    )
  }
}
