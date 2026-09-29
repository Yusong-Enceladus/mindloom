import BestASRDictation
import Carbon
import Foundation
import XCTest

@testable import BestASRMacUI

final class NativeGlobalHotkeyProviderTests: XCTestCase {
  @MainActor
  func testCarbonBackendDeliversAfterConsumerResubscription() async {
    let backend = CarbonHotkeyBackend()

    let firstStream = await backend.events()
    let firstEvent = Task { () -> NativeHotkeyEvent? in
      for await event in firstStream { return event }
      return nil
    }
    backend.emit(identifier: GlobalHotkeyAction.startOrEnd.rawValue)
    let firstValue = await firstEvent.value
    XCTAssertEqual(firstValue, .identifier(1))

    let secondStream = await backend.events()
    let secondEvent = Task { () -> NativeHotkeyEvent? in
      for await event in secondStream { return event }
      return nil
    }
    backend.emit(identifier: GlobalHotkeyAction.pauseOrResume.rawValue)
    let secondValue = await secondEvent.value
    XCTAssertEqual(secondValue, .identifier(2))
  }

  func testAlphaPresetsAreUniqueAndResolveSavedBindings() {
    let presets = DictationHotkeyPreset.alphaPresets

    XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
    XCTAssertEqual(Set(presets.map(\.binding)).count, presets.count)
    XCTAssertEqual(
      DictationHotkeyPreset.preset(
        for: DictationHotkeyConfiguration.defaultAlpha.startOrEnd
      )?.id,
      "function"
    )
  }

  func testEventTapMatchesOnlyRegisteredShortcut() {
    XCTAssertFalse(
      CarbonHotkeyBackend.matches(
        keyCode: 49,
        flags: [],
        registeredKeyCode: 49,
        carbonModifiers: UInt32(optionKey)
      )
    )
    XCTAssertTrue(
      CarbonHotkeyBackend.matches(
        keyCode: 49,
        flags: [.maskAlternate],
        registeredKeyCode: 49,
        carbonModifiers: UInt32(optionKey)
      )
    )
    XCTAssertFalse(
      CarbonHotkeyBackend.matches(
        keyCode: 49,
        flags: [.maskAlternate, .maskShift],
        registeredKeyCode: 49,
        carbonModifiers: UInt32(optionKey)
      )
    )
  }

  @MainActor
  func testEventTapConsumesOnlyUnmodifiedEscapeWhileCancellationIsEnabled() async {
    let backend = CarbonHotkeyBackend()
    let stream = await backend.events()
    let nextEvent = Task { () -> NativeHotkeyEvent? in
      for await event in stream { return event }
      return nil
    }
    backend.setEscapeMonitoringEnabled(true)

    XCTAssertFalse(
      backend.handleKeyDown(keyCode: 53, flags: [.maskCommand])
    )
    XCTAssertTrue(backend.handleKeyDown(keyCode: 53, flags: []))
    let escapeEvent = await nextEvent.value
    XCTAssertEqual(escapeEvent, .escape)

    backend.setEscapeMonitoringEnabled(false)
    XCTAssertFalse(backend.handleKeyDown(keyCode: 53, flags: []))
  }

  @MainActor
  func testEventTapRunsPreflightBeforeDeliveringRegisteredShortcut() async {
    let backend = CarbonHotkeyBackend()
    let identifier = GlobalHotkeyAction.startOrEnd.rawValue
    backend.setBindingForTesting(
      identifier: identifier,
      keyCode: 49,
      carbonModifiers: UInt32(optionKey)
    )
    var preflightIdentifiers: [UInt32] = []
    backend.setPreflightHandler { preflightIdentifiers.append($0) }
    let stream = await backend.events()
    let nextEvent = Task { () -> NativeHotkeyEvent? in
      for await event in stream { return event }
      return nil
    }

    XCTAssertTrue(
      backend.handleKeyDown(keyCode: 49, flags: [.maskAlternate])
    )
    XCTAssertEqual(preflightIdentifiers, [identifier])
    XCTAssertTrue(
      backend.handleKeyDown(keyCode: 49, flags: [.maskAlternate])
    )
    XCTAssertEqual(preflightIdentifiers, [identifier])
    let deliveredEvent = await nextEvent.value
    XCTAssertEqual(deliveredEvent, .identifier(identifier))
    XCTAssertTrue(
      backend.handleKeyUp(keyCode: 49, flags: [.maskAlternate])
    )
  }

  @MainActor
  func testSpaceIsNeverConsumedWhileDictating() {
    // Space used to pause a running dictation, and was swallowed rather than
    // delivered. Dictating into a text field and then typing a space put the
    // dictation on hold instead of typing anything, so the key is now left
    // alone in every state.
    let backend = CarbonHotkeyBackend()
    XCTAssertFalse(backend.handleKeyDown(keyCode: 49, flags: []))
    XCTAssertFalse(backend.handleKeyUp(keyCode: 49, flags: []))
    XCTAssertFalse(backend.handleKeyDown(keyCode: 49, flags: [.maskShift]))
  }

  @MainActor
  func testFunctionChordIsReportedOnceAndStillReachesTheApp() async {
    let backend = CarbonHotkeyBackend()
    let identifier = GlobalHotkeyAction.startOrEnd.rawValue
    backend.setBindingForTesting(
      identifier: identifier,
      keyCode: 63,
      carbonModifiers: CarbonHotkeyBackend.functionModifierSentinel
    )
    let stream = await backend.events()
    let events = Task { () -> [NativeHotkeyEvent] in
      var received: [NativeHotkeyEvent] = []
      for await event in stream {
        received.append(event)
        if received.count == 3 { return received }
      }
      return received
    }

    backend.handleFlagsChanged(keyCode: 63, flags: [.maskSecondaryFn])
    XCTAssertFalse(
      backend.handleKeyDown(keyCode: 117, flags: [.maskSecondaryFn]),
      "Fn+Delete must still forward-delete")
    XCTAssertFalse(backend.handleKeyDown(keyCode: 117, flags: [.maskSecondaryFn]))
    backend.handleFlagsChanged(keyCode: 63, flags: [])

    let received = await events.value
    XCTAssertEqual(
      received,
      [
        .identifier(identifier), .functionChord(keyCode: 117),
        .identifierReleased(identifier),
      ])
  }

  func testFunctionAloneStartRejectsAnyFunctionModifiedPause() {
    let functionAlone = GlobalHotkeyBinding(keyCode: 63, modifiers: [.function])
    XCTAssertTrue(
      GlobalHotkeyConfigurationController.overlap(
        functionAlone, GlobalHotkeyBinding(keyCode: 49, modifiers: [.function])))
    XCTAssertFalse(
      GlobalHotkeyConfigurationController.overlap(
        functionAlone, GlobalHotkeyBinding(keyCode: 49, modifiers: [.option])))
  }

  @MainActor
  func testDisabledEventTapClearsAStuckPressBeforeReenabling() async {
    let backend = CarbonHotkeyBackend()
    let identifier = GlobalHotkeyAction.startOrEnd.rawValue
    backend.setBindingForTesting(
      identifier: identifier,
      keyCode: 49,
      carbonModifiers: UInt32(optionKey)
    )
    let stream = await backend.events()
    let events = Task { () -> [NativeHotkeyEvent] in
      var received: [NativeHotkeyEvent] = []
      for await event in stream {
        received.append(event)
        if received.count == 3 { return received }
      }
      return received
    }

    XCTAssertTrue(
      backend.handleKeyDown(keyCode: 49, flags: [.maskAlternate])
    )
    backend.recoverDisabledEventTap()
    XCTAssertTrue(
      backend.handleKeyDown(keyCode: 49, flags: [.maskAlternate])
    )

    let receivedEvents = await events.value
    XCTAssertEqual(
      receivedEvents,
      [
        .identifier(identifier),
        .identifierReleased(identifier),
        .identifier(identifier),
      ]
    )
  }

  func testDistinctBindingsRegisterAndRepeatedNativeEventsMapToActions() async {
    let backend = FixtureNativeHotkeyBackend()
    let provider = NativeGlobalHotkeyProvider(backend: backend)
    let start = await provider.register(
      action: .startOrEnd,
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [.option])
    )
    let pause = await provider.register(
      action: .pauseOrResume,
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [.control])
    )
    XCTAssertEqual(start, .registered)
    XCTAssertEqual(pause, .registered)
    let registrations = await backend.registrations()
    XCTAssertEqual(registrations.map(\.identifier), [1, 2])
    XCTAssertNotEqual(registrations[0].carbonModifiers, registrations[1].carbonModifiers)

    let stream = await provider.actions()
    let nextActions = Task { () -> [GlobalHotkeyAction] in
      var actions: [GlobalHotkeyAction] = []
      for await action in stream {
        actions.append(action)
        if actions.count == 6 { return actions }
      }
      return actions
    }
    await backend.emit(.identifier(GlobalHotkeyAction.pauseOrResume.rawValue))
    await backend.emit(.identifier(GlobalHotkeyAction.startOrEnd.rawValue))
    await backend.emit(.identifier(GlobalHotkeyAction.startOrEnd.rawValue))
    await backend.emit(.identifier(GlobalHotkeyAction.startOrEnd.rawValue))
    await backend.emit(.identifier(GlobalHotkeyAction.pauseOrResume.rawValue))
    await backend.emit(.identifier(GlobalHotkeyAction.startOrEnd.rawValue))
    let actions = await nextActions.value
    XCTAssertEqual(
      actions,
      [
        .pauseOrResume, .startOrEnd, .startOrEnd,
        .startOrEnd, .pauseOrResume, .startOrEnd,
      ]
    )

    await provider.setCancellationEnabled(true)
    let escapeEnabled = await backend.escapeMonitoringEnabled()
    XCTAssertTrue(escapeEnabled)
  }

  func testConflictAndInvalidBindingAreReportedWithoutRegistration() async {
    let backend = FixtureNativeHotkeyBackend()
    await backend.setStatus(.conflict, identifier: 1)
    let provider = NativeGlobalHotkeyProvider(backend: backend)

    let conflict = await provider.register(
      action: .startOrEnd,
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [.option])
    )
    let invalid = await provider.register(
      action: .pauseOrResume,
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [])
    )

    XCTAssertEqual(conflict, .conflict)
    XCTAssertEqual(invalid, .unavailable(code: "invalid-binding"))
  }

  func testConfigurationPersistsOnlyAfterTheBindingRegisters() async {
    let provider = FixtureGlobalHotkeyPort()
    let store = FixtureHotkeyStore()
    let controller = GlobalHotkeyConfigurationController(
      provider: provider,
      store: store
    )

    let result = await controller.activateSavedOrDefault()
    let active = await controller.activeConfiguration()
    let saved = await store.load()
    XCTAssertEqual(result, .registered)
    XCTAssertEqual(active, .defaultAlpha)
    XCTAssertEqual(saved, .defaultAlpha)
    let registered = await provider.registeredBindings()
    XCTAssertEqual(
      registered[.startOrEnd],
      DictationHotkeyConfiguration.defaultAlpha.startOrEnd
    )

    let refreshResult = await controller.refreshActiveRegistration()
    XCTAssertEqual(refreshResult, .registered)
    let refreshed = await provider.registeredBindings()
    XCTAssertEqual(refreshed, registered)

    // A shortcut another app already owns leaves the previous one in place
    // and unsaved, rather than leaving the user with no dictation key.
    await provider.setResult(.conflict, for: .startOrEnd)
    let replacement = DictationHotkeyConfiguration(
      startOrEnd: GlobalHotkeyBinding(keyCode: 8, modifiers: [.control])
    )
    let conflict = await controller.apply(replacement)
    XCTAssertEqual(conflict, .conflict(.startOrEnd))
    let restored = await controller.activeConfiguration()
    let retainedSavedConfiguration = await store.load()
    XCTAssertEqual(restored, .defaultAlpha)
    XCTAssertEqual(retainedSavedConfiguration, .defaultAlpha)
  }

  /// A configuration saved when there was still a second binding decodes
  /// with the extra key ignored, keeping the dictation key the user chose.
  func testAConfigurationSavedWithTheRetiredPauseBindingStillDecodes() throws {
    let stored = Data(
      #"{"startOrEnd":{"keyCode":49,"modifiers":2},"pauseOrResume":{"keyCode":49,"modifiers":4}}"#
        .utf8)
    let decoded = try JSONDecoder().decode(DictationHotkeyConfiguration.self, from: stored)
    XCTAssertEqual(
      decoded.startOrEnd, GlobalHotkeyBinding(keyCode: 49, modifiers: [.option]))
  }
}

private struct FixtureNativeRegistration: Equatable, Sendable {
  let identifier: UInt32
  let keyCode: UInt32
  let carbonModifiers: UInt32
}

private actor FixtureNativeHotkeyBackend: NativeHotkeyBackend {
  private var registered: [FixtureNativeRegistration] = []
  private var statuses: [UInt32: NativeHotkeyRegistrationStatus] = [:]
  private var escapeEnabled = false
  private let stream: AsyncStream<NativeHotkeyEvent>
  private let continuation: AsyncStream<NativeHotkeyEvent>.Continuation

  init() {
    let pair = AsyncStream.makeStream(of: NativeHotkeyEvent.self)
    stream = pair.stream
    continuation = pair.continuation
  }

  func register(
    identifier: UInt32,
    keyCode: UInt32,
    carbonModifiers: UInt32
  ) async -> NativeHotkeyRegistrationStatus {
    registered.append(
      FixtureNativeRegistration(
        identifier: identifier,
        keyCode: keyCode,
        carbonModifiers: carbonModifiers
      )
    )
    return statuses[identifier] ?? .registered
  }

  func unregister(identifier: UInt32) async {
    registered.removeAll { $0.identifier == identifier }
  }

  func events() async -> AsyncStream<NativeHotkeyEvent> { stream }
  func setEscapeMonitoringEnabled(_ enabled: Bool) async { escapeEnabled = enabled }
  func emit(_ event: NativeHotkeyEvent) { continuation.yield(event) }
  func registrations() -> [FixtureNativeRegistration] { registered }
  func setStatus(_ status: NativeHotkeyRegistrationStatus, identifier: UInt32) {
    statuses[identifier] = status
  }
  func escapeMonitoringEnabled() -> Bool { escapeEnabled }
}

private actor FixtureGlobalHotkeyPort: GlobalHotkeyPort {
  private var bindings: [GlobalHotkeyAction: GlobalHotkeyBinding] = [:]
  private var results: [GlobalHotkeyAction: GlobalHotkeyRegistrationResult] = [:]

  func register(
    action: GlobalHotkeyAction,
    binding: GlobalHotkeyBinding
  ) async -> GlobalHotkeyRegistrationResult {
    let result = results.removeValue(forKey: action) ?? .registered
    if result == .registered { bindings[action] = binding }
    return result
  }

  func unregister(action: GlobalHotkeyAction) async { bindings[action] = nil }
  func actions() async -> AsyncStream<GlobalHotkeyAction> { AsyncStream { _ in } }
  func setCancellationEnabled(_ enabled: Bool) async {}
  func setResult(
    _ result: GlobalHotkeyRegistrationResult,
    for action: GlobalHotkeyAction
  ) { results[action] = result }
  func registeredBindings() -> [GlobalHotkeyAction: GlobalHotkeyBinding] { bindings }
}

private actor FixtureHotkeyStore: HotkeyConfigurationStore {
  private var configuration: DictationHotkeyConfiguration?

  func load() async -> DictationHotkeyConfiguration? { configuration }
  func save(_ configuration: DictationHotkeyConfiguration) async throws {
    self.configuration = configuration
  }
}
