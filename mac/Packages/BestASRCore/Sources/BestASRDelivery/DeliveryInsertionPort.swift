import BestASRDictation
import Foundation

/// The dictation state machine's insertion port, on top of the deliverer.
///
/// Capturing a target is reading which application is in front; inserting
/// is one delivery. The state machine's request carries the target captured
/// when the key went down, and the deliverer refuses if a different
/// application is in front by the time the words are ready.
public final class DeliveryInsertionPort: DictationInsertionPort, @unchecked Sendable {
  public enum CaptureError: Error, Equatable, Sendable {
    /// Nothing is in front, or this app itself is and may not be aimed at.
    case noTarget
  }

  private let reader: TargetReader
  private let deliverer: TextDeliverer
  private let ownApplicationAllowed: @Sendable () -> Bool
  private let targetProvider: (@MainActor () -> DictationTargetSnapshot?)?

  /// `ownApplicationAllowed` says whether a dictation may be aimed at this
  /// app's own window — true only while the onboarding practice field is
  /// up, so that a stray press with the main window in front is not
  /// counted as a dictation into nowhere. `targetProvider` replaces the
  /// live read of the front application, for tests.
  @MainActor
  public init(
    reader: TargetReader,
    deliverer: TextDeliverer,
    ownApplicationAllowed: @escaping @Sendable () -> Bool,
    targetProvider: (@MainActor () -> DictationTargetSnapshot?)? = nil
  ) {
    self.reader = reader
    self.deliverer = deliverer
    self.ownApplicationAllowed = ownApplicationAllowed
    self.targetProvider = targetProvider
  }

  @MainActor
  private func currentTarget() -> DictationTargetSnapshot? {
    if let targetProvider { return targetProvider() }
    return try? captureTargetNow()
  }

  @MainActor
  public func captureTargetNow() throws -> DictationTargetSnapshot {
    guard let target = reader.frontmostApplication(ownApplicationAllowed: ownApplicationAllowed())
    else { throw CaptureError.noTarget }
    return DictationTargetSnapshot(
      processIdentifier: target.processIdentifier,
      bundleIdentifier: target.bundleIdentifier,
      isSecure: reader.secureInputActive())
  }

  public func captureTarget() async throws -> DictationTargetSnapshot {
    try await captureTargetNow()
  }

  /// Where the words go is where the keyboard is when they are ready, not
  /// where it was when the key went down. A dictation can begin anywhere —
  /// with nothing focused, or in another application — and end in the
  /// field the user clicked into while talking; the request's target is
  /// only the hint recorded at the start.
  public func insert(_ request: DictationInsertionRequest) async throws
    -> DictationInsertionResult
  {
    guard let target = await currentTarget() else {
      return Self.result(request.idempotencyKey, kept: .nowhere)
    }
    guard !target.isSecure else {
      return Self.result(request.idempotencyKey, kept: .secureInput)
    }
    let outcome = await deliver(request.text, to: target)
    switch outcome {
    case .delivered(let evidence, _):
      return DictationInsertionResult(
        idempotencyKey: request.idempotencyKey, method: .clipboardPaste, inserted: true,
        evidence: evidence.rawValue)
    case .kept(let reason):
      return Self.result(request.idempotencyKey, kept: reason)
    }
  }

  @MainActor
  private func deliver(_ text: String, to target: DictationTargetSnapshot) async -> DeliveryOutcome {
    let destination = DeliveryTarget(
      processIdentifier: target.processIdentifier, bundleIdentifier: target.bundleIdentifier)
    let before = reader.focusedText(in: target.processIdentifier)
    let spaced = BoundarySpacing.apply(text, before: before?.caret)
    return await deliverer.deliver(spaced, to: destination, observing: before)
  }

  static func result(
    _ key: DictationIdempotencyKey, kept reason: DeliveryKeptReason
  ) -> DictationInsertionResult {
    DictationInsertionResult(
      idempotencyKey: key, method: .retainedForCopy, inserted: false,
      failureReason: Self.failureReason(for: reason))
  }

  static func failureReason(for reason: DeliveryKeptReason) -> DictationInsertionFailureReason {
    switch reason {
    case .nowhere: .nowhere
    case .secureInput: .secureInput
    case .applicationChanged: .applicationChanged
    case .permissionDenied: .permissionDenied
    }
  }
}
