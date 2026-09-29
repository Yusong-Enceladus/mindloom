import BestASRDictation
import BestASRMacPermissions
import Foundation
import XCTest

final class MacDictationPermissionServiceTests: XCTestCase {
  func testMicrophoneNotDeterminedDeniedGrantedAndRevokedStates() async {
    let microphone = FixtureMicrophonePermissionClient(state: .notDetermined)
    let accessibility = FixtureAccessibilityPermissionClient(trusted: false)
    let service = MacDictationPermissionService(
      microphone: microphone,
      accessibility: accessibility,
      history: FixturePermissionHistoryStore()
    )

    let initial = await service.state(for: .microphone)
    XCTAssertEqual(initial, .notDetermined)
    await microphone.setRequestResult(false, resultingState: .denied)
    let denied = await service.request(.microphone)
    XCTAssertEqual(denied, .denied)
    await microphone.setState(.authorized)
    let granted = await service.state(for: .microphone)
    XCTAssertEqual(granted, .granted)
    await microphone.setState(.denied)
    let revoked = await service.state(for: .microphone)
    XCTAssertEqual(revoked, .revoked)
  }

  func testAccessibilityPromptDeniedGrantedRevokedAndRecoverySettings() async {
    let microphone = FixtureMicrophonePermissionClient(state: .authorized)
    let accessibility = FixtureAccessibilityPermissionClient(trusted: false)
    let service = MacDictationPermissionService(
      microphone: microphone,
      accessibility: accessibility,
      history: FixturePermissionHistoryStore()
    )

    let initial = await service.state(for: .accessibility)
    XCTAssertEqual(initial, .notDetermined)
    let denied = await service.request(.accessibility)
    XCTAssertEqual(denied, .denied)
    await accessibility.setTrusted(true)
    let granted = await service.state(for: .accessibility)
    XCTAssertEqual(granted, .granted)
    await accessibility.setTrusted(false)
    let revoked = await service.state(for: .accessibility)
    XCTAssertEqual(revoked, .revoked)
    await service.openRecoverySettings(for: .accessibility)
    let openCount = await accessibility.openCount()
    XCTAssertEqual(openCount, 1)
  }

  func testSystemAudioPermissionDistinguishesDeniedRestartGrantAndRevocation() async {
    let systemAudio = FixtureSystemAudioPermissionClient(
      authorized: false,
      requestResult: false
    )
    let service = MacDictationPermissionService(
      systemAudio: systemAudio,
      history: FixturePermissionHistoryStore()
    )

    let initial = await service.state(for: .systemAudioCapture)
    XCTAssertEqual(initial, .notDetermined)
    let denied = await service.request(.systemAudioCapture)
    XCTAssertEqual(denied, .denied)
    await service.openRecoverySettings(for: .systemAudioCapture)
    let opened = await systemAudio.openCount()
    XCTAssertEqual(opened, 1)

    let restartClient = FixtureSystemAudioPermissionClient(
      authorized: false,
      requestResult: true
    )
    let restartService = MacDictationPermissionService(
      systemAudio: restartClient,
      history: FixturePermissionHistoryStore()
    )
    let restartRequired = await restartService.request(.systemAudioCapture)
    XCTAssertEqual(restartRequired, .restartRequired)
    await restartClient.setAuthorized(true)
    let granted = await restartService.state(for: .systemAudioCapture)
    XCTAssertEqual(granted, .granted)
    await restartClient.setAuthorized(false)
    let revoked = await restartService.state(for: .systemAudioCapture)
    XCTAssertEqual(revoked, .revoked)
  }

  func testPermissionHistoryKeepsRelaunchStateConsistentWithPriorDecisions()
    async
  {
    let history = FixturePermissionHistoryStore()
    let accessibility = FixtureAccessibilityPermissionClient(trusted: false)
    let firstAccessibilityService = MacDictationPermissionService(
      accessibility: accessibility,
      history: history
    )
    let firstAccessibilityState = await firstAccessibilityService.request(
      .accessibility
    )
    XCTAssertEqual(firstAccessibilityState, .denied)
    let relaunchedDeniedService = MacDictationPermissionService(
      accessibility: accessibility,
      history: history
    )
    let relaunchedDeniedState = await relaunchedDeniedService.state(
      for: .accessibility
    )
    XCTAssertEqual(relaunchedDeniedState, .denied)

    await accessibility.setTrusted(true)
    let grantedState = await relaunchedDeniedService.state(
      for: .accessibility
    )
    XCTAssertEqual(grantedState, .granted)
    await accessibility.setTrusted(false)
    let relaunchedRevokedService = MacDictationPermissionService(
      accessibility: accessibility,
      history: history
    )
    let relaunchedRevokedState = await relaunchedRevokedService.state(
      for: .accessibility
    )
    XCTAssertEqual(relaunchedRevokedState, .revoked)

    let systemAudio = FixtureSystemAudioPermissionClient(
      authorized: false,
      requestResult: false
    )
    let firstSystemAudioService = MacDictationPermissionService(
      systemAudio: systemAudio,
      history: history
    )
    let firstSystemAudioState = await firstSystemAudioService.request(
      .systemAudioCapture
    )
    XCTAssertEqual(firstSystemAudioState, .denied)
    let relaunchedSystemAudioService = MacDictationPermissionService(
      systemAudio: systemAudio,
      history: history
    )
    let relaunchedSystemAudioState = await relaunchedSystemAudioService.state(
      for: .systemAudioCapture
    )
    XCTAssertEqual(relaunchedSystemAudioState, .denied)
  }

  func testUserDefaultsPermissionHistorySurvivesAStoreRelaunch() async {
    let suiteName = "com.bestasr.tests.permissions.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

    let firstStore = UserDefaultsMacPermissionHistoryStore(
      suiteName: suiteName
    )
    await firstStore.set(true, forKey: "permission-tested")

    let relaunchedStore = UserDefaultsMacPermissionHistoryStore(
      suiteName: suiteName
    )
    let persisted = await relaunchedStore.bool(forKey: "permission-tested")
    XCTAssertTrue(persisted)
  }

  func testShippingConfigurationSupportsAlphaWithoutSystemAudioRequestAPI() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let report = try MacPermissionConfigurationValidator.validate(
      infoPlistURL: repositoryRoot.appendingPathComponent("App/Info.plist"),
      entitlementsURL: repositoryRoot.appendingPathComponent(
        "App/BestASR.entitlements"
      )
    )

    XCTAssertTrue(report.microphoneUsageDescriptionPresent)
    XCTAssertTrue(report.systemAudioUsageDescriptionPresent)
    XCTAssertTrue(report.audioInputEntitlementEnabled)
    XCTAssertEqual(report.alphaRequestableKinds, [.microphone, .accessibility])
  }
}

private actor FixtureMicrophonePermissionClient:
  MacMicrophonePermissionClient
{
  private var state: MacRawPermissionState
  private var requestResult = false
  private var resultingState: MacRawPermissionState?

  init(state: MacRawPermissionState) { self.state = state }

  func authorizationState() async -> MacRawPermissionState { state }

  func requestAccess() async -> Bool {
    if let resultingState { state = resultingState }
    return requestResult
  }

  func setState(_ state: MacRawPermissionState) { self.state = state }

  func setRequestResult(
    _ result: Bool,
    resultingState: MacRawPermissionState
  ) {
    requestResult = result
    self.resultingState = resultingState
  }
}

private actor FixtureAccessibilityPermissionClient:
  MacAccessibilityPermissionClient
{
  private var trusted: Bool
  private var settingsOpenCount = 0

  init(trusted: Bool) { self.trusted = trusted }

  func isTrusted(prompt: Bool) async -> Bool { trusted }
  func openSettings() async { settingsOpenCount += 1 }
  func setTrusted(_ trusted: Bool) { self.trusted = trusted }
  func openCount() -> Int { settingsOpenCount }
}

private actor FixtureSystemAudioPermissionClient:
  MacSystemAudioPermissionClient
{
  private var authorized: Bool
  private let requestResult: Bool
  private var settingsOpenCount = 0

  init(authorized: Bool, requestResult: Bool) {
    self.authorized = authorized
    self.requestResult = requestResult
  }

  func isAuthorized() async -> Bool { authorized }
  func requestAccess() async -> Bool { requestResult }
  func openSettings() async { settingsOpenCount += 1 }
  func setAuthorized(_ authorized: Bool) { self.authorized = authorized }
  func openCount() -> Int { settingsOpenCount }
}

private actor FixturePermissionHistoryStore: MacPermissionHistoryStore {
  private var values: [String: Bool] = [:]

  func bool(forKey key: String) -> Bool { values[key] ?? false }
  func set(_ value: Bool, forKey key: String) { values[key] = value }
}
