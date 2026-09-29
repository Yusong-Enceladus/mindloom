import AppKit
import Foundation

/// Text offered to the pasteboard as a promise: the string exists only when
/// a consumer asks for it. The callback proves a read, but cannot identify
/// the consumer or prove that text reached the intended input field.
/// Listing types is not a read; a clipboard manager can read after ⌘V too.
///
/// The request is delivered on the main run loop and nowhere else (a
/// background run loop does not receive it; measured 2026-09-22). So the
/// wait must not block the main thread, and it must not make the main thread
/// call into the target: an accessibility query to an application that is
/// itself waiting on our pasteboard data is a mutual wait that ends only at
/// the 6-second accessibility timeout, and the application's read returns
/// nothing after 5 — which is exactly how two dictations were reported
/// inserted into Claude while nothing appeared. The wait here is a suspended
/// task; the main thread stays free for the request.
final class PromisedPasteboardText: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
  private let text: String
  private let lock = NSLock()
  private var lastRequest: Date?
  private var waiters: [UUID: RequestWaiter] = [:]

  /// Mutable fields are accessed only while holding the promise's lock.
  private final class RequestWaiter: @unchecked Sendable {
    let id = UUID()
    let after: Date
    var result: Bool?
    var continuation: CheckedContinuation<Bool, Never>?
    var timeoutTask: Task<Void, Never>?

    init(after instant: Date) { after = instant }
  }

  private struct Completion {
    let continuation: CheckedContinuation<Bool, Never>?
    let timeoutTask: Task<Void, Never>?
    let result: Bool

    func resume() {
      timeoutTask?.cancel()
      continuation?.resume(returning: result)
    }
  }

  init(_ text: String) {
    self.text = text
  }

  func write(to pasteboard: NSPasteboard) -> Bool {
    offer(to: pasteboard) != nil
  }

  /// Keep this item valid until a pending consumer has finished reading it.
  /// Replacing the pasteboard owner invalidates items already held by consumers.
  func offer(to pasteboard: NSPasteboard) -> NSPasteboardItem? {
    let item = NSPasteboardItem()
    item.setDataProvider(self, forTypes: [.string])
    pasteboard.clearContents()
    return pasteboard.writeObjects([item]) ? item : nil
  }

  /// Whether the text has been requested since `instant`.
  func requested(after instant: Date) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let lastRequest else { return false }
    return lastRequest >= instant
  }

  /// Suspends until the text is requested after `instant`, or `timeout`
  /// passes. Never blocks the calling thread.
  func awaitRequest(
    after instant: Date,
    timeout: TimeInterval,
    beforeInstallingWaiter: (@Sendable () -> Void)? = nil
  ) async -> Bool {
    let waiter = RequestWaiter(after: instant)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Internal seam for a deterministic request-before-registration regression.
        beforeInstallingWaiter?()
        guard install(continuation, for: waiter) else { return }
        let timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(timeout))
          } catch {
            return
          }
          self?.complete(waiter, with: false)
        }
        installTimeout(timeoutTask, for: waiter)
      }
    } onCancel: {
      self.complete(waiter, with: false)
    }
  }

  /// Checking prior requests and publishing the continuation are one atomic step.
  private func install(
    _ continuation: CheckedContinuation<Bool, Never>, for waiter: RequestWaiter
  ) -> Bool {
    lock.lock()
    if waiter.result == nil, let lastRequest, lastRequest >= waiter.after {
      waiter.result = true
    }
    if let result = waiter.result {
      lock.unlock()
      continuation.resume(returning: result)
      return false
    }
    waiter.continuation = continuation
    waiters[waiter.id] = waiter
    lock.unlock()
    return true
  }

  private func installTimeout(_ task: Task<Void, Never>, for waiter: RequestWaiter) {
    lock.lock()
    let alreadyCompleted = waiter.result != nil
    if !alreadyCompleted { waiter.timeoutTask = task }
    lock.unlock()
    if alreadyCompleted { task.cancel() }
  }

  private func complete(_ waiter: RequestWaiter, with result: Bool) {
    lock.lock()
    let completion = completeLocked(waiter, with: result)
    lock.unlock()
    completion?.resume()
  }

  private func completeLocked(_ waiter: RequestWaiter, with result: Bool) -> Completion? {
    guard waiter.result == nil else { return nil }
    waiter.result = result
    waiters.removeValue(forKey: waiter.id)
    let completion = Completion(
      continuation: waiter.continuation, timeoutTask: waiter.timeoutTask, result: result)
    waiter.continuation = nil
    waiter.timeoutTask = nil
    return completion
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    let now = Date()
    lock.lock()
    lastRequest = now
    let requestedWaiters = waiters.values.filter { now >= $0.after }
    let completions = requestedWaiters.compactMap { completeLocked($0, with: true) }
    lock.unlock()
    item.setString(text, forType: type)
    for completion in completions { completion.resume() }
  }
}

/// The user's clipboard, taken before the pasteboard is borrowed and put
/// back afterwards, item for item and type for type.
struct PasteboardSnapshot {
  let items: [[NSPasteboard.PasteboardType: Data]]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(
        uniqueKeysWithValues: item.types.compactMap { type in
          item.data(forType: type).map { (type, $0) }
        }
      )
    }
  }

  @discardableResult
  func restore(to pasteboard: NSPasteboard, ifOwnedBy changeCount: Int) -> Bool {
    guard pasteboard.changeCount == changeCount else { return false }
    return restore(to: pasteboard)
  }

  @discardableResult
  func restore(to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    let restoredItems = items.map { storedTypes -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in storedTypes {
        item.setData(data, forType: type)
      }
      return item
    }
    guard !restoredItems.isEmpty else { return true }
    return pasteboard.writeObjects(restoredItems)
  }
}
