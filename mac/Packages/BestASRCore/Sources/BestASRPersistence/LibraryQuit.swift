import Foundation
import os

/// The library the App has open, closed cleanly when the App quits
/// (REHEARSAL.md §8): the App registers its store once it is open, and its
/// termination waits for `close(within:)` before the process ends.
@MainActor
public enum LibraryQuit {
  public static weak var store: GRDBDictationStore?

  /// How long quitting waits for the library to close (review 10-5d R6):
  /// closing waits for every read and write in progress, and a long one (an
  /// import, organizing, an index build) must not hold up a quit, a log out
  /// or a shutdown. The App quits anyway after this; the WAL left behind is
  /// recovered by the next open.
  public nonisolated static let quitWaitSeconds: TimeInterval = 2.5

  /// Checkpoints and closes the registered store; true when there was none
  /// or it closed.
  @discardableResult
  public static func close() async -> Bool {
    guard let store else { return true }
    self.store = nil
    return await store.closeForQuit()
  }

  /// `close()`, waited for at most `seconds`: false when the library did not
  /// close in time (it goes on closing while the App quits).
  @discardableResult
  public static func close(within seconds: TimeInterval) async -> Bool {
    guard let store else { return true }
    self.store = nil
    let closing = Task { await store.closeForQuit() }
    return await withCheckedContinuation { continuation in
      let first = FirstAnswer(continuation)
      Task {
        first.give(await closing.value)
      }
      Task {
        try? await Task.sleep(for: .seconds(seconds))
        first.give(false)
      }
    }
  }
}

/// Resumes a continuation with the first answer given; later ones are
/// dropped.
private final class FirstAnswer: Sendable {
  private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = OSAllocatedUnfairLock(initialState: continuation)
  }

  func give(_ answer: Bool) {
    let waiting = continuation.withLock { current -> CheckedContinuation<Bool, Never>? in
      defer { current = nil }
      return current
    }
    waiting?.resume(returning: answer)
  }
}
