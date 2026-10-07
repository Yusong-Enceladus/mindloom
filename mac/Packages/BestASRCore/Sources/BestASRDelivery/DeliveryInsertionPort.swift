import BestASRDictation
import Foundation

/// The dictation state machine's insertion port, on top of the deliverer.
///
/// Capturing a target is reading which application is in front; inserting
/// is one delivery. The state machine's request carries the target captured
/// when the key went down, and the deliverer refuses if a different
/// application is in front by the time the words are ready. When this App
/// itself is in front with one of its own text fields focused, the words
/// are written into that field directly instead.
public final class DeliveryInsertionPort: DictationInsertionPort, @unchecked Sendable {
  public enum CaptureError: Error, Equatable, Sendable {
    /// Nothing is in front, or this app itself is and may not be aimed at.
    case noTarget
  }

  private let reader: TargetReader
  private let deliverer: TextDeliverer
  private let ownApplicationAllowed: @Sendable () -> Bool
  private let targetProvider: (@MainActor () -> DictationTargetSnapshot?)?
  private let ownTextInput: (@MainActor () -> OwnTextInput?)?

  /// `ownApplicationAllowed` says whether a dictation may be aimed at this
  /// app's own window — true only while the onboarding practice field is
  /// up, so that a stray press with the main window in front is not
  /// counted as a dictation into nowhere. `targetProvider` replaces the
  /// live read of the front application, for tests. `ownTextInput` returns
  /// this App's focused text field while this App is in front (nil
  /// otherwise); it is asked first, when the words are ready.
  @MainActor
  public init(
    reader: TargetReader,
    deliverer: TextDeliverer,
    ownApplicationAllowed: @escaping @Sendable () -> Bool,
    targetProvider: (@MainActor () -> DictationTargetSnapshot?)? = nil,
    ownTextInput: (@MainActor () -> OwnTextInput?)? = nil
  ) {
    self.reader = reader
    self.deliverer = deliverer
    self.ownApplicationAllowed = ownApplicationAllowed
    self.targetProvider = targetProvider
    self.ownTextInput = ownTextInput
  }

  @MainActor
  private func currentTarget() -> DictationTargetSnapshot? {
    if let targetProvider { return targetProvider() }
    return try? frontTarget()
  }

  /// Reads which application is in front when the dictation key goes down
  /// (or the one `targetProvider` names), and asks it to build its
  /// accessibility tree now (off the main thread) so that the field read
  /// when the words are ready is there to be read (DELIVERY.md 原因 2).
  @MainActor
  public func captureTargetNow() throws -> DictationTargetSnapshot {
    let target: DictationTargetSnapshot
    if let targetProvider {
      guard let pinned = targetProvider() else { throw CaptureError.noTarget }
      target = pinned
    } else {
      target = try frontTarget()
    }
    reader.prepareAccessibility(of: target.processIdentifier)
    return target
  }

  @MainActor
  private func frontTarget() throws -> DictationTargetSnapshot {
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
    if let written = await writeIntoOwnField(request) { return written }
    guard let target = await currentTarget() else {
      return Self.result(request.idempotencyKey, kept: .nowhere)
    }
    guard !target.isSecure else {
      return Self.result(request.idempotencyKey, kept: .secureInput)
    }
    let outcome = await deliver(request.text, to: target, key: request.idempotencyKey)
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
  private func deliver(
    _ text: String, to target: DictationTargetSnapshot, key: DictationIdempotencyKey
  ) async -> DeliveryOutcome {
    let destination = DeliveryTarget(
      processIdentifier: target.processIdentifier, bundleIdentifier: target.bundleIdentifier)
    let before = await reader.focusedTextWaitingForTree(in: target.processIdentifier)
    let spaced = BoundarySpacing.apply(text, before: before?.caret)
    let outcome = await deliverer.deliver(spaced, to: destination, observing: before)
    record(deliverer.lastLease, for: key)
    // A field that shows its text is watched, so a word the user corrects in
    // the dictation can be learned (收1-8). Apps that show none (Claude's
    // composer reports no value; WeChat names no field) are not.
    if case .delivered(.field, _) = outcome, let before, before.value != nil {
      correctionWatch = CorrectionWatch(
        key: key, inserted: spaced, field: before, bundleIdentifier: target.bundleIdentifier,
        armedAt: Date())
    } else {
      correctionWatch = nil
    }
    return outcome
  }

  // MARK: Watching a dictation for the user's corrections (收1-8)

  struct CorrectionWatch {
    let key: DictationIdempotencyKey
    let inserted: String
    let field: FocusedText
    let bundleIdentifier: String?
    let armedAt: Date
  }

  @MainActor private var correctionWatch: CorrectionWatch?

  /// What the user has made of the last dictation typed into a field that
  /// shows its text: the dictation and the field's text now (nil when the
  /// field is gone or empty — a chat App empties it when the message is
  /// sent). Called when the next dictation starts or after a while; ends the
  /// watch. Nil when nothing is watched.
  @MainActor
  public func settleCorrectionWatch() -> (
    key: DictationIdempotencyKey, inserted: String, fieldContents: String?
  )? {
    guard let watch = correctionWatch else { return nil }
    correctionWatch = nil
    return (watch.key, watch.inserted, read(watch))
  }

  /// The watched field's text now, without ending the watch: read every
  /// second or two while it lasts, so a word fixed just before the message
  /// is sent is seen before the field is emptied (review 10-6 S10). One
  /// accessibility read of one element, bounded by the reader's timeout.
  @MainActor
  public func peekCorrectionWatch() -> (
    key: DictationIdempotencyKey, inserted: String, fieldContents: String?
  )? {
    guard let watch = correctionWatch else { return nil }
    return (watch.key, watch.inserted, read(watch))
  }

  @MainActor
  private func read(_ watch: CorrectionWatch) -> String? {
    guard let now = reader.currentValue(of: watch.field), !now.isEmpty else { return nil }
    return now
  }

  /// When the last watch began (nil without one).
  @MainActor public var correctionWatchArmedAt: Date? { correctionWatch?.armedAt }

  // MARK: The clipboard a delivery left the words on

  @MainActor private var leases: [(key: DictationIdempotencyKey, lease: ClipboardLease)] = []

  @MainActor
  func record(_ lease: ClipboardLease?, for key: DictationIdempotencyKey) {
    leases.removeAll { $0.key == key }
    guard let lease else { return }
    leases.append((key, lease))
    if leases.count > 8 { leases.removeFirst(leases.count - 8) }
  }

  /// True when the delivery of `key` left its words on the clipboard and the
  /// clipboard has changed since (its change count is now
  /// `currentChangeCount`): the user copied something else, and the App must
  /// not copy the dictation over it (review 10-5c S5). False when that
  /// delivery did not borrow the clipboard, or the words are still there.
  @MainActor
  public func clipboardTakenSinceDelivery(
    _ key: DictationIdempotencyKey, currentChangeCount: Int
  ) -> Bool {
    guard let lease = leases.last(where: { $0.key == key })?.lease else { return false }
    return lease.userCopiedSince(currentChangeCount: currentChangeCount)
  }

  /// This App's own focused field, when it is in front: the words go in
  /// directly, with the boundary space English after English needs, and
  /// without a final 「。」 in a one-line field (a search runs on the words).
  @MainActor
  private func writeIntoOwnField(
    _ request: DictationInsertionRequest
  ) -> DictationInsertionResult? {
    guard let field = ownTextInput?(), !reader.secureInputActive() else { return nil }
    guard let text = Self.ownFieldText(request.text, into: field) else { return nil }
    field.insert(text)
    return DictationInsertionResult(
      idempotencyKey: request.idempotencyKey, method: .directWrite, inserted: true,
      evidence: DeliveryEvidence.ownField.rawValue)
  }

  /// What goes into one of this App's own fields: nil when nothing would.
  @MainActor
  public static func ownFieldText(_ text: String, into field: OwnTextInput) -> String? {
    var words = text
    if field.isSingleLine {
      words = words.trimmingCharacters(in: .whitespacesAndNewlines)
      while let last = words.last, "。.".contains(last) { words.removeLast() }
    }
    guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let selection = field.selection
    let caret = CaretContext(
      value: field.text, selectionLocation: selection.location, selectionLength: selection.length)
    return BoundarySpacing.apply(words, before: caret)
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
    case .unconfirmed: .unconfirmed
    }
  }
}
