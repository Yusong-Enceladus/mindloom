import AppKit
import BestASRDictation
import Carbon
import Foundation
import OSLog

private let hotkeyLogger = Logger(
  subsystem: "com.bestasr.app",
  category: "global-hotkey"
)

public enum NativeHotkeyRegistrationStatus: Equatable, Sendable {
  case registered
  case conflict
  case unavailable(OSStatus)
}

public enum NativeHotkeyEvent: Equatable, Sendable {
  case identifier(UInt32)
  case identifierReleased(UInt32)
  case escape
  /// Another key went down while an Fn-alone shortcut was physically held,
  /// carrying that key's code so a chord the user meant — Fn Space, Fn Shift —
  /// can be told apart from Fn Delete and the other system Fn combinations.
  case functionChord(keyCode: UInt32)
}

public struct NativeHotkeyTransition: Equatable, Sendable {
  public let action: GlobalHotkeyAction
  public let isPressed: Bool
  /// Fn was combined with another key (Fn+Delete, Fn+arrow…), so the Fn press
  /// that started dictation was not meant as a dictation shortcut.
  public let isFunctionChord: Bool
  /// The key that was chorded with Fn, when `isFunctionChord`.
  public let chordKeyCode: UInt32?

  public init(
    action: GlobalHotkeyAction,
    isPressed: Bool,
    isFunctionChord: Bool = false,
    chordKeyCode: UInt32? = nil
  ) {
    self.action = action
    self.isPressed = isPressed
    self.isFunctionChord = isFunctionChord
    self.chordKeyCode = chordKeyCode
  }
}

public protocol NativeHotkeyBackend: Sendable {
  func register(
    identifier: UInt32,
    keyCode: UInt32,
    carbonModifiers: UInt32
  ) async -> NativeHotkeyRegistrationStatus
  func unregister(identifier: UInt32) async
  func events() async -> AsyncStream<NativeHotkeyEvent>
  func setEscapeMonitoringEnabled(_ enabled: Bool) async
}


public actor NativeGlobalHotkeyProvider: GlobalHotkeyPort {
  private let backend: any NativeHotkeyBackend

  public init(backend: any NativeHotkeyBackend) {
    self.backend = backend
  }

  public func register(
    action: GlobalHotkeyAction,
    binding: GlobalHotkeyBinding
  ) async -> GlobalHotkeyRegistrationResult {
    guard action != .cancel,
      binding.keyCode <= UInt32(UInt16.max),
      !binding.modifiers.isEmpty
    else { return .unavailable(code: "invalid-binding") }
    let status = await backend.register(
      identifier: action.rawValue,
      keyCode: binding.keyCode,
      carbonModifiers: Self.carbonModifiers(binding.modifiers)
    )
    switch status {
    case .registered:
      hotkeyLogger.info("provider registered action \(action.rawValue, privacy: .public)")
      return .registered
    case .conflict: return .conflict
    case .unavailable(let status):
      return .unavailable(code: "carbon-status-\(status)")
    }
  }

  public func unregister(action: GlobalHotkeyAction) async {
    guard action != .cancel else { return }
    await backend.unregister(identifier: action.rawValue)
  }

  public func actions() async -> AsyncStream<GlobalHotkeyAction> {
    let nativeEvents = await backend.events()
    return AsyncStream { continuation in
      let task = Task {
        for await event in nativeEvents {
          switch event {
          case .identifier(let identifier):
            if let action = GlobalHotkeyAction(rawValue: identifier) {
              hotkeyLogger.info(
                "provider delivered action \(action.rawValue, privacy: .public)"
              )
              continuation.yield(action)
            }
          case .identifierReleased, .functionChord:
            break
          case .escape:
            continuation.yield(.cancel)
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func transitions() async -> AsyncStream<NativeHotkeyTransition> {
    let nativeEvents = await backend.events()
    return AsyncStream { continuation in
      let task = Task {
        for await event in nativeEvents {
          switch event {
          case .identifier(let identifier):
            if let action = GlobalHotkeyAction(rawValue: identifier) {
              continuation.yield(
                NativeHotkeyTransition(action: action, isPressed: true)
              )
            }
          case .identifierReleased(let identifier):
            if let action = GlobalHotkeyAction(rawValue: identifier) {
              continuation.yield(
                NativeHotkeyTransition(action: action, isPressed: false)
              )
            }
          case .escape:
            continuation.yield(
              NativeHotkeyTransition(action: .cancel, isPressed: true)
            )
          case .functionChord(let keyCode):
            continuation.yield(
              NativeHotkeyTransition(
                action: .startOrEnd, isPressed: false, isFunctionChord: true,
                chordKeyCode: keyCode)
            )
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func setCancellationEnabled(_ enabled: Bool) async {
    hotkeyLogger.info(
      "provider set cancellation enabled=\(enabled, privacy: .public)"
    )
    await backend.setEscapeMonitoringEnabled(enabled)
  }

  private nonisolated static func carbonModifiers(
    _ modifiers: GlobalHotkeyModifiers
  ) -> UInt32 {
    var value: UInt32 = 0
    if modifiers.contains(.command) { value |= UInt32(cmdKey) }
    if modifiers.contains(.option) { value |= UInt32(optionKey) }
    if modifiers.contains(.control) { value |= UInt32(controlKey) }
    if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
    if modifiers.contains(.function) {
      value |= CarbonHotkeyBackend.functionModifierSentinel
    }
    return value
  }
}

@MainActor
public final class CarbonHotkeyBackend: NativeHotkeyBackend, @unchecked Sendable {
  public typealias PreflightHandler = @MainActor (UInt32) -> Void

  private static let signature: OSType = 0x4241_5352  // BASR
  public nonisolated static let functionModifierSentinel: UInt32 = 1 << 31

  private var references: [UInt32: EventHotKeyRef] = [:]
  private var bindings: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
  private var eventHandler: EventHandlerRef?
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var eventContinuations: [UUID: AsyncStream<NativeHotkeyEvent>.Continuation] = [:]
  private var globalEscapeMonitor: Any?
  private var localEscapeMonitor: Any?
  private var escapeMonitoringEnabled = false
  private var functionKeyDown = false
  private var functionShortcutHeld = false
  private var pressedIdentifiers = Set<UInt32>()
  private var preflightHandler: PreflightHandler?

  public init() {}

  /// Runs synchronously at the event-tap boundary before the registered key is
  /// consumed. Callers may capture bounded, in-memory focus context here; the
  /// handler must not perform unbounded work or mutate the foreground app.
  public func setPreflightHandler(_ handler: PreflightHandler?) {
    preflightHandler = handler
  }

  public func register(
    identifier: UInt32,
    keyCode: UInt32,
    carbonModifiers: UInt32
  ) async -> NativeHotkeyRegistrationStatus {
    if carbonModifiers & Self.functionModifierSentinel != 0 {
      guard AXIsProcessTrusted() else {
        return .unavailable(OSStatus(AXError.apiDisabled.rawValue))
      }
      if bindings.contains(where: {
        $0.key != identifier && $0.value.keyCode == keyCode
          && $0.value.modifiers == carbonModifiers
      }) {
        return .conflict
      }
      bindings[identifier] = (keyCode, carbonModifiers)
      installEventTapIfPossible()
      guard eventTap != nil else {
        bindings[identifier] = nil
        return .unavailable(OSStatus(eventInternalErr))
      }
      return .registered
    }
    guard installHandlerIfNeeded() else {
      return .unavailable(OSStatus(eventInternalErr))
    }
    if references[identifier] != nil { unregister(identifier: identifier) }
    var reference: EventHotKeyRef?
    let hotkeyID = EventHotKeyID(
      signature: Self.signature,
      id: identifier
    )
    let status = RegisterEventHotKey(
      keyCode,
      carbonModifiers,
      hotkeyID,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard status == noErr, let reference else {
      return status == eventHotKeyExistsErr ? .conflict : .unavailable(status)
    }
    references[identifier] = reference
    bindings[identifier] = (keyCode, carbonModifiers)
    installEventTapIfPossible()
    hotkeyLogger.info(
      "carbon registered action \(identifier, privacy: .public)"
    )
    return .registered
  }

  public func unregister(identifier: UInt32) {
    if let reference = references.removeValue(forKey: identifier) {
      UnregisterEventHotKey(reference)
    }
    pressedIdentifiers.remove(identifier)
    bindings[identifier] = nil
    if bindings.isEmpty, let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
      removeEventTap()
    }
  }

  public func events() async -> AsyncStream<NativeHotkeyEvent> {
    _ = installHandlerIfNeeded()
    let subscriberID = UUID()
    return AsyncStream { continuation in
      eventContinuations[subscriberID] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.eventContinuations[subscriberID] = nil
        }
      }
    }
  }

  public func setEscapeMonitoringEnabled(_ enabled: Bool) {
    escapeMonitoringEnabled = enabled
    hotkeyLogger.info(
      "backend set escape enabled=\(enabled, privacy: .public) tap=\(self.eventTap != nil, privacy: .public)"
    )
    if enabled, eventTap == nil {
      installFallbackEscapeMonitors()
    } else {
      removeFallbackEscapeMonitors()
    }
  }

  func emit(identifier: UInt32) {
    emit(.identifier(identifier))
  }

  func emitCarbon(identifier: UInt32, isPressed: Bool) {
    if isPressed {
      guard pressedIdentifiers.insert(identifier).inserted else { return }
      preflightHandler?(identifier)
      emit(.identifier(identifier))
    } else {
      guard pressedIdentifiers.remove(identifier) != nil else { return }
      emit(.identifierReleased(identifier))
    }
  }

  /// Returns true when the event matches a registered binding and must not be
  /// delivered to the foreground app. The event tap is the primary path when
  /// Accessibility is granted; Carbon remains registered as a fail-safe.
  func handleKeyDown(keyCode: UInt32, flags: CGEventFlags) -> Bool {
    if functionShortcutHeld, keyCode != 63 {
      // The two chords this app owns stay armed, so pressing Space or Shift
      // again while the key is still held means something again — that is how
      // Shift moves to the next translation language. Every other Fn chord
      // belongs to macOS (Fn Delete, Fn arrows): it is reported once, still
      // delivered, and disarms so the dictation is not cancelled twice.
      let mine = keyCode == Self.spaceKeyCode
      if !mine { functionShortcutHeld = false }
      emit(.functionChord(keyCode: keyCode))
      return mine
    }
    if keyCode == 53 {
      hotkeyLogger.info(
        "event tap observed escape enabled=\(self.escapeMonitoringEnabled, privacy: .public)"
      )
    }
    if escapeMonitoringEnabled, keyCode == 53,
      Self.carbonModifiers(from: flags) == 0
    {
      emit(.escape)
      return true
    }
    guard
      let identifier = bindings.first(where: {
        Self.matches(
          keyCode: keyCode,
          flags: flags,
          registeredKeyCode: $0.value.keyCode,
          carbonModifiers: $0.value.modifiers
        )
      })?.key
    else { return false }
    guard !pressedIdentifiers.contains(identifier) else {
      // Suppress hardware key-repeat from toggling a session more than once
      // while the shortcut remains physically held.
      return true
    }
    preflightHandler?(identifier)
    pressedIdentifiers.insert(identifier)
    emit(identifier: identifier)
    return true
  }

  func handleKeyUp(keyCode: UInt32, flags: CGEventFlags) -> Bool {
    guard
      let identifier = pressedIdentifiers.first(where: {
        bindings[$0]?.keyCode == keyCode
      })
    else { return false }
    pressedIdentifiers.remove(identifier)
    emit(.identifierReleased(identifier))
    return true
  }

  /// Globe/Fn alone does not generate a normal key-down event. Emit its
  /// binding on the modifier down edge while leaving the flags-changed event
  /// visible to macOS so system Globe behavior is not left in a stuck state.
  /// The two chords that mean something to this app rather than to macOS.
  public nonisolated static let spaceKeyCode: UInt32 = 49
  public nonisolated static let leftShiftKeyCode: UInt32 = 56
  public nonisolated static let rightShiftKeyCode: UInt32 = 60

  func handleFlagsChanged(keyCode: UInt32, flags: CGEventFlags) {
    // Shift produces no key-down, so an Fn Shift chord is only visible here.
    if functionShortcutHeld, flags.contains(.maskShift),
      keyCode == Self.leftShiftKeyCode || keyCode == Self.rightShiftKeyCode
    {
      emit(.functionChord(keyCode: keyCode))
      return
    }
    guard keyCode == 63 else { return }
    let isDown = flags.contains(.maskSecondaryFn)
    defer { functionKeyDown = isDown }
    let modifiers = Self.carbonModifiers(from: flags)
    if isDown, !functionKeyDown {
      guard
        let identifier = bindings.first(where: {
          $0.value.keyCode == keyCode && $0.value.modifiers == modifiers
        })?.key
      else { return }
      preflightHandler?(identifier)
      pressedIdentifiers.insert(identifier)
      functionShortcutHeld = true
      emit(identifier: identifier)
    } else if !isDown, functionKeyDown {
      functionShortcutHeld = false
      // Release whichever Fn press is actually outstanding, the same way
      // `handleKeyUp` does. Re-deriving the binding from the flags instead
      // silently dropped the release whenever the press had been matched
      // under a different modifier combination than bare Fn, leaving a
      // push-to-talk dictation recording after the user let go.
      guard
        let identifier = pressedIdentifiers.first(where: {
          bindings[$0]?.keyCode == keyCode
        })
      else { return }
      pressedIdentifiers.remove(identifier)
      emit(.identifierReleased(identifier))
    }
  }

  private func emit(_ event: NativeHotkeyEvent) {
    hotkeyLogger.info(
      "backend emitted event to \(self.eventContinuations.count, privacy: .public) subscriber(s)"
    )
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  func setBindingForTesting(
    identifier: UInt32,
    keyCode: UInt32,
    carbonModifiers: UInt32
  ) {
    bindings[identifier] = (keyCode, carbonModifiers)
  }

  private func installHandlerIfNeeded() -> Bool {
    if eventHandler != nil { return true }
    let eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      ),
    ]
    let status = eventTypes.withUnsafeBufferPointer { buffer in
      InstallEventHandler(
        GetApplicationEventTarget(),
        carbonHotkeyEventHandler,
        buffer.count,
        buffer.baseAddress,
        Unmanaged.passUnretained(self).toOpaque(),
        &eventHandler
      )
    }
    return status == noErr
  }

  private func installEventTapIfPossible() {
    guard eventTap == nil else { return }
    guard AXIsProcessTrusted() else {
      hotkeyLogger.error("event tap skipped because accessibility is not trusted")
      return
    }
    let mask =
      (CGEventMask(1) << CGEventType.keyDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyUp.rawValue)
      | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: bestASRHotkeyEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      hotkeyLogger.error("event tap creation failed")
      return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    eventTap = tap
    eventTapSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    removeFallbackEscapeMonitors()
    hotkeyLogger.info("event tap enabled")
  }

  private func removeEventTap() {
    if let eventTapSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
      self.eventTapSource = nil
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      self.eventTap = nil
    }
    if escapeMonitoringEnabled { installFallbackEscapeMonitors() }
  }

  private func installFallbackEscapeMonitors() {
    guard globalEscapeMonitor == nil, localEscapeMonitor == nil else { return }
    globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: .keyDown
    ) { [weak self] event in
      guard event.keyCode == 53,
        event.modifierFlags.intersection(
          .deviceIndependentFlagsMask
        ).isEmpty
      else { return }
      Task { @MainActor in self?.emit(.escape) }
    }
    localEscapeMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { [weak self] event in
      guard event.keyCode == 53,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
      else { return event }
      self?.emit(.escape)
      return nil
    }
  }

  private func removeFallbackEscapeMonitors() {
    if let globalEscapeMonitor {
      NSEvent.removeMonitor(globalEscapeMonitor)
      self.globalEscapeMonitor = nil
    }
    if let localEscapeMonitor {
      NSEvent.removeMonitor(localEscapeMonitor)
      self.localEscapeMonitor = nil
    }
  }

  /// A tap can be disabled after a slow target application or a system input
  /// transition. Key-up may be lost at that boundary, so clear the physical
  /// press latch before re-enabling; otherwise every later press of the same
  /// shortcut is mistaken for hardware repeat and silently swallowed.
  func recoverDisabledEventTap() {
    let interruptedIdentifiers = pressedIdentifiers
    pressedIdentifiers.removeAll()
    functionKeyDown = false
    functionShortcutHeld = false
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    for identifier in interruptedIdentifiers {
      emit(.identifierReleased(identifier))
    }
    hotkeyLogger.notice(
      "event tap recovered; cleared \(interruptedIdentifiers.count, privacy: .public) interrupted press(es)"
    )
  }

  nonisolated static func matches(
    keyCode: UInt32,
    flags: CGEventFlags,
    registeredKeyCode: UInt32,
    carbonModifiers: UInt32
  ) -> Bool {
    keyCode == registeredKeyCode
      && Self.carbonModifiers(from: flags) == carbonModifiers
  }

  private nonisolated static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
    if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
    if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.maskSecondaryFn) {
      modifiers |= Self.functionModifierSentinel
    }
    return modifiers
  }
}

private func bestASRHotkeyEventTapCallback(
  _ proxy: CGEventTapProxy,
  _ type: CGEventType,
  _ event: CGEvent,
  _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let backend = Unmanaged<CarbonHotkeyBackend>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    MainActor.assumeIsolated {
      backend.recoverDisabledEventTap()
    }
    return Unmanaged.passUnretained(event)
  }
  if type == .flagsChanged {
    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    MainActor.assumeIsolated {
      backend.handleFlagsChanged(keyCode: keyCode, flags: flags)
    }
    return Unmanaged.passUnretained(event)
  }
  let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
  let flags = event.flags
  if type == .keyUp {
    let handled = MainActor.assumeIsolated {
      backend.handleKeyUp(keyCode: keyCode, flags: flags)
    }
    return handled ? nil : Unmanaged.passUnretained(event)
  }
  guard type == .keyDown else { return Unmanaged.passUnretained(event) }
  let handled = MainActor.assumeIsolated {
    backend.handleKeyDown(keyCode: keyCode, flags: flags)
  }
  if handled {
    hotkeyLogger.info("event tap consumed registered shortcut")
  }
  return handled ? nil : Unmanaged.passUnretained(event)
}

private func carbonHotkeyEventHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  var hotkeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotkeyID
  )
  guard status == noErr else { return status }
  let backend = Unmanaged<CarbonHotkeyBackend>
    .fromOpaque(userData)
    .takeUnretainedValue()
  let identifier = hotkeyID.id
  let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
  Task { @MainActor in
    backend.emitCarbon(identifier: identifier, isPressed: isPressed)
  }
  return noErr
}
