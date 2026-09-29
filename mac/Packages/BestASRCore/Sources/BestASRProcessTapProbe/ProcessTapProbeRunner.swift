import CoreAudio
import Darwin
import Foundation

public struct ProcessTapProbeConfiguration: Sendable {
  public let selectedPlayerURL: URL
  public let nonselectedPlayerURL: URL
  public let summaryURL: URL
  public let matrixURL: URL
  public let allowOutputDeviceSwitch: Bool
  public let tccDenialEvidenceURL: URL?

  public init(
    selectedPlayerURL: URL,
    nonselectedPlayerURL: URL,
    summaryURL: URL,
    matrixURL: URL,
    allowOutputDeviceSwitch: Bool = false,
    tccDenialEvidenceURL: URL? = nil
  ) {
    self.selectedPlayerURL = selectedPlayerURL
    self.nonselectedPlayerURL = nonselectedPlayerURL
    self.summaryURL = summaryURL
    self.matrixURL = matrixURL
    self.allowOutputDeviceSwitch = allowOutputDeviceSwitch
    self.tccDenialEvidenceURL = tccDenialEvidenceURL
  }
}

@available(macOS 14.2, *)
public enum ProcessTapProbeRunner {
  public static func run(
    configuration: ProcessTapProbeConfiguration
  ) throws -> String {
    let runID = UUID()
    let baselineTapCount = try CoreAudioHAL.tapCount()
    let baselineAggregateCount = try CoreAudioHAL.aggregateDeviceCount()
    let baselineResidentBytes = residentBytes()
    var scenarios: [ProcessTapMatrixScenario] = []

    scenarios.append(
      evaluate(
        "audio-processes-group-as-applications",
        evidenceMode: "live-catalog"
      ) {
        let processes = try CoreAudioHAL.audioProcesses()
        let groups = ProcessAudioGrouper.groups(from: processes)
        guard !processes.isEmpty, !groups.isEmpty else {
          throw RunnerError.invariant("empty-audio-process-catalog")
        }
        return ScenarioResult(metrics: [
          "applicationGroupCount": String(groups.count),
          "audioProcessCount": String(processes.count),
          "rawIdentityPersisted": "false",
        ])
      }
    )

    scenarios.append(
      evaluate(
        "selected-app-captured-nonselected-app-excluded",
        evidenceMode: "live-watermark"
      ) {
        try selectedBoundaryScenario(configuration: configuration)
      }
    )

    scenarios.append(
      evaluate(
        "helper-child-process-auto-joins-selected-app",
        evidenceMode: "live-watermark+lifecycle"
      ) {
        try helperLifecycleScenario(configuration: configuration)
      }
    )

    scenarios.append(
      evaluate(
        "selected-app-exit-and-restart-preserves-capture",
        evidenceMode: "live-watermark+lifecycle"
      ) {
        try restartScenario(configuration: configuration)
      }
    )

    scenarios.append(
      evaluate(
        "silent-selected-source-keeps-io-alive",
        evidenceMode: "live-silent-output"
      ) {
        try silentSourceScenario(configuration: configuration)
      }
    )

    scenarios.append(
      evaluate(
        "output-device-change-is-explicit",
        evidenceMode:
          "live-watermark+opt-in-physical-route+deterministic-transition"
      ) {
        try outputDeviceChangeScenario(configuration: configuration)
      }
    )

    let permissionEvidenceMode =
      configuration.tccDenialEvidenceURL == nil
      ? "deterministic-denial+live-authorized-capture"
      : "actual-tcc-denial+signed-synthetic-source"
    scenarios.append(
      evaluate(
        "permission-denial-blocks-audio-content",
        evidenceMode: permissionEvidenceMode
      ) {
        if let evidenceURL = configuration.tccDenialEvidenceURL {
          let evidence = try readTCCDenialEvidence(from: evidenceURL)
          guard evidence.isConfirmedDenial else {
            throw RunnerError.invariant("actual-tcc-denial-evidence")
          }
          return ScenarioResult(
            metrics: [
              "actualTCCDenial": "true",
              "aggregateDeviceDelta": String(
                evidence.aggregateDeviceCountAfter
                  - evidence.aggregateDeviceCountBefore
              ),
              "createTapStatus": String(evidence.createTapStatus),
              "ioStartReturnedSuccessAfterDenial": String(
                evidence.captureStarted
              ),
              "audioContentSuppressed": String(
                evidence.audioContentSuppressed
              ),
              "callbackCount": String(evidence.callbackCount),
              "capturedRMS": decimal(evidence.capturedRMS),
              "capturedWatermarkAmplitude": decimal(
                evidence.capturedWatermarkAmplitude
              ),
              "frameCount": String(evidence.frameCount),
              "startCaptureStatus": String(evidence.startCaptureStatus),
              "syntheticSourceOnly": String(evidence.syntheticSourceOnly),
              "tapCreatedBeforeDenial": String(evidence.tapCreated),
              "tapDelta": String(
                evidence.tapCountAfter - evidence.tapCountBefore
              ),
              "watermarkDetected": String(evidence.watermarkDetected),
            ],
            events: [
              ProcessTapLifecycleEvent(
                kind: .permissionRejected,
                monotonicNanoseconds: monotonicNanoseconds(),
                detail: evidence.captureStarted
                  ? "actual-tcc-denial-audio-content-suppressed"
                  : "actual-tcc-denial-before-capture-start"
              )
            ]
          )
        }

        let before = try CoreAudioHAL.tapCount()
        var rejected = false
        do {
          try ProcessTapPermissionPolicy.requireAuthorized(.denied)
        } catch ProcessTapPermissionPolicyError.denied {
          rejected = true
        }
        let after = try CoreAudioHAL.tapCount()
        guard rejected, before == after else {
          throw RunnerError.invariant("permission-denial-boundary")
        }
        return ScenarioResult(
          metrics: [
            "actualTCCDenial": "false",
            "liveSystemAudioPermission": "authorized-for-live-matrix",
            "tapCreatedAfterInjectedDenial": "false",
          ],
          events: [
            ProcessTapLifecycleEvent(
              kind: .permissionRejected,
              monotonicNanoseconds: monotonicNanoseconds(),
              detail: "authorization-rejected-before-hal-call"
            )
          ]
        )
      }
    )

    Thread.sleep(forTimeInterval: 0.2)
    scenarios.append(
      evaluate(
        "tap-and-aggregate-lifecycle-cleans-up",
        evidenceMode: "live-hal-inventory+process-resource"
      ) {
        let finalTapCount = try CoreAudioHAL.tapCount()
        let finalAggregateCount = try CoreAudioHAL.aggregateDeviceCount()
        let finalResidentBytes = residentBytes()
        guard finalTapCount == baselineTapCount,
          finalAggregateCount == baselineAggregateCount
        else {
          throw RunnerError.invariant("hal-object-leak")
        }
        return ScenarioResult(metrics: [
          "aggregateDeviceDelta": String(
            finalAggregateCount - baselineAggregateCount
          ),
          "residentByteDelta": String(
            Int64(finalResidentBytes) - Int64(baselineResidentBytes)
          ),
          "tapDelta": String(finalTapCount - baselineTapCount),
        ])
      }
    )

    let matrix = ProcessTapMatrixEvidence(
      runID: runID,
      generatedAt: Date(),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      hardwareArchitecture: architecture,
      scenarios: scenarios
    )
    try writeJSON(matrix, to: configuration.matrixURL)

    let failures = scenarios.filter { $0.status == "fail" }
    let matrixReference = repositoryRelativeEvidencePath(
      configuration.matrixURL,
      fallback: "artifacts/evidence/SPIKE-CAP-001/matrix.json"
    )
    let physicalSwitchPerformed =
      scenarios.first(where: {
        $0.scenarioID == "output-device-change-is-explicit"
      })?.metrics["physicalSwitchPerformed"] == "true"
    let actualTCCDenialUsed =
      scenarios.first(where: {
        $0.scenarioID == "permission-denial-blocks-audio-content"
      })?.metrics["actualTCCDenial"] == "true"
    let decision = releaseDecision(
      failedScenarioIDs: failures.map(\.scenarioID),
      physicalSwitchPerformed: physicalSwitchPerformed,
      actualTCCDenialUsed: actualTCCDenialUsed
    )
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-CAP-001",
      runID: runID,
      question:
        "Can a macOS Core Audio Process Tap preserve an application boundary across helper and restart lifecycle events without leaking a nonselected watermark?",
      environmentRef: "artifacts/evidence/environment/check-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "The selected synthetic application watermark is captured while the nonselected application watermark remains below the detection threshold.",
          "A same-bundle child helper and a restarted source process are added to the existing tap without discarding prior captured frames.",
          "A real secondary-output transition is observed and restored while selected-source capture remains continuous.",
          "Silence does not end authorized capture; permission denial makes the selected watermark unreadable by rejecting I/O start or supplying only digital zero, and all private tap and aggregate objects are destroyed without leakage.",
        ],
        fail: [
          "A nonselected watermark is detected, a selected helper/restart watermark is missing, or a failure path leaks a tap or aggregate device."
        ]
      ),
      commands: [["script/run_process_tap_probe.sh"]],
      matrix: scenarios.map {
        var evidenceReferences = [matrixReference]
        if $0.scenarioID == "permission-denial-blocks-audio-content",
          let evidenceURL = configuration.tccDenialEvidenceURL
        {
          evidenceReferences.append(
            repositoryRelativeEvidencePath(
              evidenceURL,
              fallback:
                "artifacts/evidence/SPIKE-CAP-001/tcc-denial.json"
            )
          )
        }
        return SpikeMatrixReference(
          scenarioID: $0.scenarioID,
          status: $0.status,
          evidenceRefs: evidenceReferences
        )
      },
      conclusion: decision.conclusion,
      unmetCriteria: decision.unmetCriteria
    )
    try writeJSON(summary, to: configuration.summaryURL)
    return decision.conclusion
  }

  static func releaseDecision(
    failedScenarioIDs: [String],
    physicalSwitchPerformed: Bool,
    actualTCCDenialUsed: Bool
  ) -> (conclusion: String, unmetCriteria: [String]) {
    if !failedScenarioIDs.isEmpty {
      return (
        "fail",
        failedScenarioIDs.map { "Failed scenario: \($0)" }
      )
    }

    var unmetCriteria: [String] = []
    if !physicalSwitchPerformed {
      unmetCriteria.append(
        "A real Bluetooth or secondary-output switch was not performed; rerun with --allow-output-device-switch on a device with a second physical output."
      )
    }
    if !actualTCCDenialUsed {
      unmetCriteria.append(
        "The denied-permission path is injected before HAL object creation; a separate signed bundle with an actual TCC denial remains a manual device-lab run."
      )
    }
    return (unmetCriteria.isEmpty ? "pass" : "conditional", unmetCriteria)
  }

  private static func outputDeviceChangeScenario(
    configuration: ProcessTapProbeConfiguration
  ) throws -> ScenarioResult {
    let devices = try CoreAudioHAL.outputDevices()
    let originalDeviceID = try CoreAudioHAL.defaultOutputDeviceID()
    guard configuration.allowOutputDeviceSwitch else {
      var tracker = OutputDeviceChangeTracker()
      _ = tracker.observe(
        deviceID: originalDeviceID,
        monotonicNanoseconds: monotonicNanoseconds()
      )
      let fixtureAlternate =
        originalDeviceID == UInt32.max
        ? originalDeviceID - 1
        : originalDeviceID + 1
      let event = try require(
        tracker.observe(
          deviceID: fixtureAlternate,
          monotonicNanoseconds: monotonicNanoseconds()
        ),
        "device-transition"
      )
      return ScenarioResult(
        metrics: [
          "defaultOutputRestored": "true",
          "liveOutputDeviceCount": String(devices.count),
          "physicalSwitchPerformed": "false",
          "rawDeviceIdentityPersisted": "false",
          "transitionEventRecorded": "true",
        ],
        events: [event]
      )
    }

    guard try CoreAudioHAL.defaultOutputDeviceIsSettable() else {
      throw RunnerError.invariant("default-output-not-settable")
    }
    guard
      let alternateDevice = CoreAudioHAL.alternatePhysicalOutputDevice(
        from: devices,
        excluding: originalDeviceID
      )
    else {
      throw RunnerError.unavailable("second-physical-output-unavailable")
    }
    let listener = try DefaultOutputDeviceListener()
    var tracker = OutputDeviceChangeTracker()
    _ = tracker.observe(
      deviceID: originalDeviceID,
      monotonicNanoseconds: monotonicNanoseconds()
    )

    let watermarkFrequency = 15_300.0
    let player = try launchPlayer(
      configuration.selectedPlayerURL,
      frequency: watermarkFrequency,
      leadIn: 0.8,
      duration: 5.5
    )
    defer { terminateIfNeeded(player) }
    let process = try CoreAudioHAL.process(for: player.processIdentifier)
    let session = try ProcessTapCaptureSession(
      processObjectIDs: [process.objectID],
      maximumDuration: 8
    )
    defer { session.close() }
    try session.start()

    var restoreRequired = false
    defer {
      if restoreRequired {
        _ = restoreDefaultOutputDevice(
          originalDeviceID,
          listener: listener
        )
      }
    }

    Thread.sleep(forTimeInterval: 1.2)
    let preSwitchSamples = session.drainSamples(maximumFrames: Int.max)
    try CoreAudioHAL.setDefaultOutputDeviceID(alternateDevice.objectID)
    restoreRequired = true
    let switchTimestamp = try require(
      listener.wait(for: alternateDevice.objectID, timeout: 3),
      "alternate-output-listener-timeout"
    )
    let switchEvent = try require(
      tracker.observe(
        deviceID: alternateDevice.objectID,
        monotonicNanoseconds: switchTimestamp
      ),
      "alternate-output-transition"
    )

    Thread.sleep(forTimeInterval: 0.8)
    let alternateOutputSamples = session.drainSamples(maximumFrames: Int.max)
    guard restoreDefaultOutputDevice(originalDeviceID, listener: listener) else {
      throw RunnerError.invariant("default-output-restore-failed")
    }
    restoreRequired = false
    let restoreTimestamp = try require(
      listener.wait(for: originalDeviceID, timeout: 1),
      "restored-output-listener-timeout"
    )
    let restoreEvent = try require(
      tracker.observe(
        deviceID: originalDeviceID,
        monotonicNanoseconds: restoreTimestamp
      ),
      "restored-output-transition"
    )

    player.waitUntilExit()
    let tailSnapshot = session.finish()
    let restoredOutputSamples = tailSnapshot.samples
    let allSamples =
      preSwitchSamples + alternateOutputSamples + restoredOutputSamples
    let snapshot = ProcessTapCaptureSnapshot(
      samples: allSamples,
      sampleRate: tailSnapshot.sampleRate,
      frameCount: allSamples.count,
      droppedFrameCount: tailSnapshot.droppedFrameCount,
      callbackCount: tailSnapshot.callbackCount,
      firstHostTime: tailSnapshot.firstHostTime,
      lastHostTime: tailSnapshot.lastHostTime
    )
    let preSwitchWatermark = WatermarkDetector.measure(
      samples: preSwitchSamples,
      sampleRate: snapshot.sampleRate,
      frequency: watermarkFrequency,
      threshold: 0.002
    )
    let alternateOutputWatermark = WatermarkDetector.measure(
      samples: alternateOutputSamples,
      sampleRate: snapshot.sampleRate,
      frequency: watermarkFrequency,
      threshold: 0.002
    )
    guard snapshot.callbackCount > 0 else {
      throw RunnerError.invariant("output-switch-no-callbacks")
    }
    guard snapshot.droppedFrameCount == 0 else {
      throw RunnerError.invariant("output-switch-dropped-frames")
    }
    guard try CoreAudioHAL.defaultOutputDeviceID() == originalDeviceID else {
      throw RunnerError.invariant("output-switch-default-not-restored")
    }
    guard preSwitchWatermark.detected else {
      throw RunnerError.invariant("output-switch-watermark-missing-before")
    }
    guard alternateOutputWatermark.detected else {
      throw RunnerError.invariant("output-switch-watermark-missing-alternate")
    }

    return ScenarioResult(
      metrics: captureMetrics(
        snapshot,
        additional: [
          "defaultOutputRestored": "true",
          "listenerNotificationCount": String(listener.notificationCount),
          "liveOutputDeviceCount": String(devices.count),
          "physicalSwitchPerformed": "true",
          "preSwitchWatermarkDetected": String(
            preSwitchWatermark.detected
          ),
          "rawDeviceIdentityPersisted": "false",
          "alternateOutputWatermarkDetected": String(
            alternateOutputWatermark.detected
          ),
          "transitionEventRecorded": "true",
          "watermarkDetectedAcrossSwitch": "true",
        ]
      ),
      events: [
        event(.captureStarted, processID: player.processIdentifier),
        switchEvent,
        restoreEvent,
        event(.captureStopped, processID: player.processIdentifier),
      ]
    )
  }

  private static func restoreDefaultOutputDevice(
    _ deviceID: AudioObjectID,
    listener: DefaultOutputDeviceListener
  ) -> Bool {
    for _ in 0..<3 {
      try? CoreAudioHAL.setDefaultOutputDeviceID(deviceID)
      if listener.wait(for: deviceID, timeout: 1) != nil,
        (try? CoreAudioHAL.defaultOutputDeviceID()) == deviceID
      {
        return true
      }
    }
    return (try? CoreAudioHAL.defaultOutputDeviceID()) == deviceID
  }

  private static func selectedBoundaryScenario(
    configuration: ProcessTapProbeConfiguration
  ) throws -> ScenarioResult {
    progress("boundary:launch-players")
    let selectedFrequency = 18_300.0
    let nonselectedFrequency = 19_100.0
    let selected = try launchPlayer(
      configuration.selectedPlayerURL,
      frequency: selectedFrequency,
      leadIn: 1.5,
      duration: 3.5
    )
    let nonselected = try launchPlayer(
      configuration.nonselectedPlayerURL,
      frequency: nonselectedFrequency,
      leadIn: 1.5,
      duration: 3.5
    )
    defer {
      terminateIfNeeded(selected)
      terminateIfNeeded(nonselected)
    }

    let selectedAudioProcess = try CoreAudioHAL.process(
      for: selected.processIdentifier
    )
    progress("boundary:create-tap")
    let session = try ProcessTapCaptureSession(
      processObjectIDs: [selectedAudioProcess.objectID],
      maximumDuration: 7
    )
    var events = [
      event(.tapCreated, processID: selected.processIdentifier),
      event(.aggregateCreated),
    ]
    progress("boundary:start-io")
    try session.start()
    progress("boundary:io-started")
    events.append(event(.captureStarted))
    selected.waitUntilExit()
    nonselected.waitUntilExit()
    let snapshot = session.finish()
    events.append(event(.captureStopped))
    session.close()

    let selectedMeasurement = WatermarkDetector.measure(
      samples: snapshot.samples,
      sampleRate: snapshot.sampleRate,
      frequency: selectedFrequency,
      threshold: 0.003
    )
    let nonselectedMeasurement = WatermarkDetector.measure(
      samples: snapshot.samples,
      sampleRate: snapshot.sampleRate,
      frequency: nonselectedFrequency,
      threshold: 0.003
    )
    guard selectedMeasurement.detected, !nonselectedMeasurement.detected,
      snapshot.callbackCount > 0, snapshot.droppedFrameCount == 0
    else {
      throw RunnerError.invariant("selected-boundary-watermark")
    }
    return ScenarioResult(
      metrics: captureMetrics(
        snapshot,
        additional: [
          "nonselectedAmplitude": decimal(nonselectedMeasurement.amplitude),
          "nonselectedDetected": String(nonselectedMeasurement.detected),
          "selectedAmplitude": decimal(selectedMeasurement.amplitude),
          "selectedDetected": String(selectedMeasurement.detected),
        ]
      ),
      events: events
    )
  }

  private static func helperLifecycleScenario(
    configuration: ProcessTapProbeConfiguration
  ) throws -> ScenarioResult {
    progress("helper:launch-parent")
    let parentFrequency = 17_900.0
    let helperFrequency = 17_300.0
    let parent = try launchPlayer(
      configuration.selectedPlayerURL,
      frequency: parentFrequency,
      leadIn: 1,
      duration: 4.5,
      helperFrequency: helperFrequency,
      helperDelay: 1.4,
      helperDuration: 3
    )
    defer { terminateIfNeeded(parent) }
    let selected = try CoreAudioHAL.process(for: parent.processIdentifier)
    progress("helper:create-tap")
    let session = try ProcessTapCaptureSession(
      processObjectIDs: [selected.objectID],
      maximumDuration: 8
    )
    var events = [
      event(.tapCreated, processID: parent.processIdentifier),
      event(.aggregateCreated),
    ]
    progress("helper:start-io")
    try session.start()
    progress("helper:io-started")
    events.append(event(.captureStarted))

    var tappedObjectIDs: Set<UInt32> = [selected.objectID]
    var seenProcessIDs: Set<Int32> = [selected.processID]
    let deadline = Date().addingTimeInterval(7)
    while Date() < deadline, parent.isRunning {
      let processes = try CoreAudioHAL.audioProcesses()
      let related = ProcessAudioGrouper.relatedProcesses(
        to: selected,
        in: processes
      )
      let currentObjectIDs = Set(related.map(\.objectID))
      let currentProcessIDs = Set(related.map(\.processID))
      let added = currentProcessIDs.subtracting(seenProcessIDs)
      if !currentObjectIDs.isEmpty, currentObjectIDs != tappedObjectIDs {
        try session.updateProcessObjectIDs(currentObjectIDs.sorted())
        events.append(event(.tapReconfigured))
        tappedObjectIDs = currentObjectIDs
      }
      for processID in added.sorted() {
        events.append(event(.processAdded, processID: processID))
      }
      seenProcessIDs.formUnion(currentProcessIDs)
      Thread.sleep(forTimeInterval: 0.08)
    }
    parent.waitUntilExit()
    let snapshot = session.finish()
    events.append(event(.captureStopped))
    session.close()

    let parentMeasurement = WatermarkDetector.measure(
      samples: snapshot.samples,
      sampleRate: snapshot.sampleRate,
      frequency: parentFrequency,
      threshold: 0.002
    )
    let helperMeasurement = WatermarkDetector.measure(
      samples: snapshot.samples,
      sampleRate: snapshot.sampleRate,
      frequency: helperFrequency,
      threshold: 0.002
    )
    guard parentMeasurement.detected, helperMeasurement.detected,
      seenProcessIDs.count >= 2
    else {
      throw RunnerError.invariant("helper-auto-join")
    }
    return ScenarioResult(
      metrics: captureMetrics(
        snapshot,
        additional: [
          "helperAmplitude": decimal(helperMeasurement.amplitude),
          "helperDetected": String(helperMeasurement.detected),
          "relatedProcessCount": String(seenProcessIDs.count),
        ]
      ),
      events: events
    )
  }

  private static func restartScenario(
    configuration: ProcessTapProbeConfiguration
  ) throws -> ScenarioResult {
    progress("restart:launch-first")
    let firstFrequency = 16_700.0
    let secondFrequency = 16_100.0
    let first = try launchPlayer(
      configuration.selectedPlayerURL,
      frequency: firstFrequency,
      leadIn: 0.8,
      duration: 2
    )
    defer { terminateIfNeeded(first) }
    let firstAudioProcess = try CoreAudioHAL.process(for: first.processIdentifier)
    progress("restart:create-tap")
    let session = try ProcessTapCaptureSession(
      processObjectIDs: [firstAudioProcess.objectID],
      maximumDuration: 8
    )
    var events = [
      event(.tapCreated, processID: first.processIdentifier),
      event(.aggregateCreated),
    ]
    progress("restart:start-io")
    try session.start()
    progress("restart:io-started")
    events.append(event(.captureStarted))
    first.waitUntilExit()
    events.append(event(.processRemoved, processID: first.processIdentifier))
    Thread.sleep(forTimeInterval: 0.25)

    let second = try launchPlayer(
      configuration.selectedPlayerURL,
      frequency: secondFrequency,
      leadIn: 0.8,
      duration: 2
    )
    progress("restart:launched-second")
    defer { terminateIfNeeded(second) }
    let secondAudioProcess = try CoreAudioHAL.process(for: second.processIdentifier)
    guard firstAudioProcess.bundleID == secondAudioProcess.bundleID,
      !secondAudioProcess.bundleID.isEmpty
    else {
      throw RunnerError.invariant("restart-bundle-identity")
    }
    try session.updateProcessObjectIDs([secondAudioProcess.objectID])
    events.append(event(.sourceRestarted, processID: second.processIdentifier))
    events.append(event(.tapReconfigured, processID: second.processIdentifier))
    second.waitUntilExit()
    let snapshot = session.finish()
    events.append(event(.captureStopped))
    session.close()

    let firstMeasurement = WatermarkDetector.measure(
      samples: snapshot.samples,
      sampleRate: snapshot.sampleRate,
      frequency: firstFrequency,
      threshold: 0.002
    )
    let secondMeasurement = WatermarkDetector.measure(
      samples: snapshot.samples,
      sampleRate: snapshot.sampleRate,
      frequency: secondFrequency,
      threshold: 0.002
    )
    guard firstMeasurement.detected, secondMeasurement.detected else {
      throw RunnerError.invariant("restart-watermarks")
    }
    return ScenarioResult(
      metrics: captureMetrics(
        snapshot,
        additional: [
          "firstGenerationDetected": "true",
          "secondGenerationDetected": "true",
          "stableBundleIdentity": "true",
        ]
      ),
      events: events
    )
  }

  private static func silentSourceScenario(
    configuration: ProcessTapProbeConfiguration
  ) throws -> ScenarioResult {
    progress("silence:launch-player")
    let player = try launchPlayer(
      configuration.selectedPlayerURL,
      frequency: 15_700,
      amplitude: 0,
      leadIn: 0,
      duration: 2
    )
    defer { terminateIfNeeded(player) }
    let process = try CoreAudioHAL.process(for: player.processIdentifier)
    progress("silence:create-tap")
    let session = try ProcessTapCaptureSession(
      processObjectIDs: [process.objectID],
      maximumDuration: 4
    )
    progress("silence:start-io")
    try session.start()
    progress("silence:io-started")
    player.waitUntilExit()
    let snapshot = session.finish()
    session.close()
    let rms = WatermarkDetector.rootMeanSquare(snapshot.samples)
    guard snapshot.callbackCount > 0, snapshot.frameCount > 0, rms < 0.000_1 else {
      throw RunnerError.invariant("silent-source-lifecycle")
    }
    return ScenarioResult(
      metrics: captureMetrics(
        snapshot,
        additional: [
          "captureEndedBecauseOfSilence": "false",
          "rootMeanSquare": decimal(rms),
        ]
      ),
      events: [event(.captureStarted), event(.captureStopped)]
    )
  }

  private static func evaluate(
    _ scenarioID: String,
    evidenceMode: String,
    body: () throws -> ScenarioResult
  ) -> ProcessTapMatrixScenario {
    progress("scenario-start:\(scenarioID)")
    do {
      let result = try body()
      progress("scenario-pass:\(scenarioID)")
      return ProcessTapMatrixScenario(
        scenarioID: scenarioID,
        status: "pass",
        evidenceMode: evidenceMode,
        metrics: result.metrics,
        lifecycleEvents: result.events
      )
    } catch RunnerError.unavailable(let detail) {
      progress("scenario-conditional:\(scenarioID):\(detail)")
      return ProcessTapMatrixScenario(
        scenarioID: scenarioID,
        status: "conditional",
        evidenceMode: evidenceMode,
        metrics: [
          "defaultOutputRestored": "true",
          "physicalSwitchPerformed": "false",
          "rawDeviceIdentityPersisted": "false",
          "unavailableReason": detail,
        ]
      )
    } catch {
      progress("scenario-fail:\(scenarioID):\(String(describing: error))")
      return ProcessTapMatrixScenario(
        scenarioID: scenarioID,
        status: "fail",
        evidenceMode: evidenceMode,
        metrics: ["errorCategory": String(describing: error)]
      )
    }
  }

  private static func launchPlayer(
    _ executableURL: URL,
    frequency: Double,
    amplitude: Double = 0.03,
    leadIn: TimeInterval,
    duration: TimeInterval,
    helperFrequency: Double? = nil,
    helperDelay: TimeInterval = 0,
    helperDuration: TimeInterval = 0
  ) throws -> Process {
    let process = Process()
    process.executableURL = executableURL
    var arguments = [
      "--frequency", String(frequency),
      "--amplitude", String(amplitude),
      "--lead-in", String(leadIn),
      "--duration", String(duration),
    ]
    if let helperFrequency {
      arguments.append(contentsOf: [
        "--helper-frequency", String(helperFrequency),
        "--helper-delay", String(helperDelay),
        "--helper-duration", String(helperDuration),
      ])
    }
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  private static func terminateIfNeeded(_ process: Process) {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }

  private static func captureMetrics(
    _ snapshot: ProcessTapCaptureSnapshot,
    additional: [String: String]
  ) -> [String: String] {
    var metrics = additional
    metrics["callbackCount"] = String(snapshot.callbackCount)
    metrics["droppedFrameCount"] = String(snapshot.droppedFrameCount)
    metrics["frameCount"] = String(snapshot.frameCount)
    metrics["hostTimeMonotonic"] = String(
      snapshot.lastHostTime >= snapshot.firstHostTime
        && snapshot.firstHostTime > 0
    )
    metrics["sampleRate"] = decimal(snapshot.sampleRate)
    return metrics
  }

  private static func event(
    _ kind: ProcessTapLifecycleEventKind,
    processID: Int32? = nil
  ) -> ProcessTapLifecycleEvent {
    ProcessTapLifecycleEvent(
      kind: kind,
      monotonicNanoseconds: monotonicNanoseconds(),
      processID: processID,
      detail: syntheticDetail(for: kind)
    )
  }

  private static func syntheticDetail(
    for kind: ProcessTapLifecycleEventKind
  ) -> String {
    switch kind {
    case .processAdded, .processRemoved, .sourceRestarted:
      return "synthetic-source-lifecycle"
    case .tapReconfigured:
      return "synthetic-group-membership-change"
    default:
      return "probe-lifecycle"
    }
  }

  private static func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private static func progress(_ message: String) {
    fputs("SPIKE-CAP-001 \(message)\n", stderr)
    fflush(stderr)
  }

  private static func decimal(_ value: Double) -> String {
    String(format: "%.8f", value)
  }

  private static func require<T>(_ value: T?, _ detail: String) throws -> T {
    guard let value else { throw RunnerError.invariant(detail) }
    return value
  }

  private static func writeJSON<T: Encodable>(
    _ value: T,
    to url: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static func readTCCDenialEvidence(
    from url: URL
  ) throws -> ProcessTapTCCDenialEvidence {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      ProcessTapTCCDenialEvidence.self,
      from: Data(contentsOf: url)
    )
  }

  private static func repositoryRelativeEvidencePath(
    _ url: URL,
    fallback: String
  ) -> String {
    let path = url.standardizedFileURL.path
    guard let range = path.range(of: "/artifacts/evidence/") else {
      return fallback
    }
    return "artifacts/evidence/" + path[range.upperBound...]
  }

  private static func residentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
  }

  private static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "unsupported"
    #endif
  }
}

private struct ScenarioResult {
  let metrics: [String: String]
  let events: [ProcessTapLifecycleEvent]

  init(
    metrics: [String: String],
    events: [ProcessTapLifecycleEvent] = []
  ) {
    self.metrics = metrics
    self.events = events
  }
}

private enum RunnerError: Error {
  case invariant(String)
  case unavailable(String)
}

private struct SpikeCriteria: Codable {
  let pass: [String]
  let fail: [String]
}

private struct SpikeMatrixReference: Codable {
  let scenarioID: String
  let status: String
  let evidenceRefs: [String]
}

private struct SpikeSummary: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let question: String
  let environmentRef: String
  let criteria: SpikeCriteria
  let commands: [[String]]
  let matrix: [SpikeMatrixReference]
  let conclusion: String
  let unmetCriteria: [String]
}
