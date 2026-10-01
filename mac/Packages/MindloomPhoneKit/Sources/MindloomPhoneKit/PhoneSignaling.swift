import Foundation

/// Payload-free notifications between the app and its extensions
/// (`PhoneSignal` names). The real implementation is the Darwin notify
/// center; tests use `LocalSignaling`.
public protocol PhoneSignaling: AnyObject, Sendable {
  func post(_ name: String)
  /// `handler` runs on the main actor, some time after a matching `post` in
  /// any process. Notifications of one name may coalesce, so a handler reads
  /// the current state from the App Group files instead of counting calls.
  func observe(_ name: String, handler: @escaping @MainActor @Sendable () -> Void)
    -> PhoneSignalObservation
}

/// Keeps one `observe` registration alive; `cancel()` or deinit ends it.
public final class PhoneSignalObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelBody: (() -> Void)?

  init(cancel: @escaping () -> Void) {
    cancelBody = cancel
  }

  public func cancel() {
    lock.lock()
    let body = cancelBody
    cancelBody = nil
    lock.unlock()
    body?()
  }

  deinit { cancel() }
}

/// The Darwin notify center: the one channel iOS offers between an app and
/// its keyboard or share extension that needs no network and no open socket.
public final class DarwinSignaling: PhoneSignaling, @unchecked Sendable {
  public static let shared = DarwinSignaling()

  private let lock = NSLock()
  private var handlers: [String: [UUID: @MainActor @Sendable () -> Void]] = [:]
  private var registered: Set<String> = []

  private init() {}

  public func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil,
      true)
  }

  public func observe(_ name: String, handler: @escaping @MainActor @Sendable () -> Void)
    -> PhoneSignalObservation
  {
    let id = UUID()
    lock.lock()
    handlers[name, default: [:]][id] = handler
    let needsRegistration = registered.insert(name).inserted
    lock.unlock()
    if needsRegistration {
      // `shared` lives for the whole process, so an unretained pointer is safe.
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
        darwinCallback, name as CFString, nil, .deliverImmediately)
    }
    return PhoneSignalObservation { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.handlers[name]?[id] = nil
      self.lock.unlock()
    }
  }

  fileprivate func deliver(_ name: String) {
    lock.lock()
    let current = Array((handlers[name] ?? [:]).values)
    lock.unlock()
    guard !current.isEmpty else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        for handler in current { handler() }
      }
    }
  }
}

private let darwinCallback: CFNotificationCallback = { _, observer, name, _, _ in
  guard let observer, let name = name?.rawValue as String? else { return }
  Unmanaged<DarwinSignaling>.fromOpaque(observer).takeUnretainedValue().deliver(name)
}

/// In-process signaling for tests: posts are queued and delivered only when
/// the test calls `deliverPending()`, so every interleaving is explicit.
public final class LocalSignaling: PhoneSignaling, @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [String: [UUID: @MainActor @Sendable () -> Void]] = [:]
  private var pending: [String] = []
  private var log: [String] = []

  public init() {}

  /// Every name posted so far, in order.
  public var posted: [String] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  public func post(_ name: String) {
    lock.lock()
    log.append(name)
    pending.append(name)
    lock.unlock()
  }

  public func observe(_ name: String, handler: @escaping @MainActor @Sendable () -> Void)
    -> PhoneSignalObservation
  {
    let id = UUID()
    lock.lock()
    handlers[name, default: [:]][id] = handler
    lock.unlock()
    return PhoneSignalObservation { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.handlers[name]?[id] = nil
      self.lock.unlock()
    }
  }

  /// Delivers queued posts (and any they cause) in order. Returns how many.
  @MainActor @discardableResult
  public func deliverPending() -> Int {
    var delivered = 0
    while true {
      lock.lock()
      guard !pending.isEmpty else {
        lock.unlock()
        return delivered
      }
      let name = pending.removeFirst()
      let current = Array((handlers[name] ?? [:]).values)
      lock.unlock()
      for handler in current { handler() }
      delivered += 1
    }
  }

  public func clearLog() {
    lock.lock()
    log.removeAll()
    lock.unlock()
  }
}
