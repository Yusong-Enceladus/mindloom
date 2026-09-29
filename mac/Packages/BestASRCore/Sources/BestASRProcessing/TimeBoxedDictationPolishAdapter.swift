import BestASRDictation
import Foundation

public struct DictationPolishDeadlineExceeded: Error, Equatable, Sendable {
  public init() {}
}

/// Bounds how long insertion waits for model polish.
///
/// When the budget expires first, `polish` throws so the processing
/// coordinator inserts its deterministic fallback immediately. The model call
/// is not cancelled: its eventual result is handed to `onLateResult` so the
/// polished text can still be kept in history without delaying insertion.
/// A zero budget never waits: every model result arrives through
/// `onLateResult`.
public struct TimeBoxedDictationPolishAdapter: DictationPolishPort {
  public typealias LateResultHandler =
    @Sendable (DictationPolishRequest, DictationPolishResult) async -> Void

  private let base: any DictationPolishPort
  private let budget: Duration
  private let onLateResult: LateResultHandler

  public init(
    base: any DictationPolishPort,
    budget: Duration,
    onLateResult: @escaping LateResultHandler
  ) {
    self.base = base
    self.budget = budget
    self.onLateResult = onLateResult
  }

  public func polish(
    _ request: DictationPolishRequest
  ) async throws -> DictationPolishResult {
    let base = base
    let budget = budget
    let onLateResult = onLateResult
    guard budget > .zero else {
      Task {
        guard let result = try? await base.polish(request) else { return }
        await onLateResult(request, result)
      }
      throw DictationPolishDeadlineExceeded()
    }
    return try await withCheckedThrowingContinuation { continuation in
      let gate = ResumeOnce(continuation)
      let deadline = Task {
        try? await Task.sleep(for: budget)
        guard !Task.isCancelled else { return }
        gate.resume(with: .failure(DictationPolishDeadlineExceeded()))
      }
      Task {
        do {
          let result = try await base.polish(request)
          if gate.resume(with: .success(result)) {
            deadline.cancel()
          } else {
            await onLateResult(request, result)
          }
        } catch {
          if gate.resume(with: .failure(error)) { deadline.cancel() }
        }
      }
    }
  }
}

/// Resumes a continuation exactly once; later outcomes report `false`.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<DictationPolishResult, Error>?

  init(_ continuation: CheckedContinuation<DictationPolishResult, Error>) {
    self.continuation = continuation
  }

  @discardableResult
  func resume(with result: Result<DictationPolishResult, Error>) -> Bool {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    guard let continuation else { return false }
    continuation.resume(with: result)
    return true
  }
}
