import Foundation
import XCTest

@testable import MindloomPhoneKit

/// A settable clock for the voice tests.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ start: Date = baseDate) {
    current = start
  }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(_ seconds: TimeInterval) {
    lock.lock()
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }

  var function: @Sendable () -> Date { { [self] in self.now } }
}

struct FakeRecognizerError: Error {}

/// A recognizer whose utterances the test drives: `say` sends a partial,
/// `finalText` is what `finish()` returns, and `holdFinish` keeps `finish()`
/// waiting until `release()` so finishing order can be controlled.
@MainActor
final class FakeRecognizer: VoiceRecognizing {
  let kindName = "fake"
  var utterances: [FakeUtterance] = []
  var failNextBegin = false
  var nextFinalText: String? = "合成：明早九点站会"
  var holdFinishes = false

  func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
    -> any VoiceUtterance
  {
    if failNextBegin {
      failNextBegin = false
      throw FakeRecognizerError()
    }
    let utterance = FakeUtterance(
      onPartial: onPartial, finalText: nextFinalText, hold: holdFinishes)
    utterances.append(utterance)
    return utterance
  }
}

@MainActor
final class FakeUtterance: VoiceUtterance {
  let onPartial: @MainActor (String) -> Void
  var finalText: String?
  private(set) var cancelled = false
  private(set) var finished = false
  private var hold: Bool
  private var gate: CheckedContinuation<Void, Never>?

  init(onPartial: @escaping @MainActor (String) -> Void, finalText: String?, hold: Bool) {
    self.onPartial = onPartial
    self.finalText = finalText
    self.hold = hold
  }

  func say(_ text: String) { onPartial(text) }

  func finish() async -> String? {
    finished = true
    if hold {
      await withCheckedContinuation { gate = $0 }
    }
    return finalText
  }

  func release() {
    hold = false
    gate?.resume()
    gate = nil
  }

  func cancel() {
    cancelled = true
    release()
  }
}

/// Lets queued main-actor tasks run (the finishing tasks of the core).
@MainActor
func settle(_ rounds: Int = 20) async {
  for _ in 0..<rounds { await Task.yield() }
}
