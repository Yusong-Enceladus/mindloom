import BestASRMemory
import Foundation

/// What the pages can ask for. Every correction happens in place and is one
/// of these calls; the App routes it to the organizing device's decisions or
/// to the local organizer. All run on the main actor.
public struct MemoryActions {
  public var answer: @MainActor (MemoryQuestion, Bool) -> Void
  public var answerReview: @MainActor (MemoryPersonReview, Bool) -> Void
  public var pin: @MainActor (_ eventID: String, _ pinned: Bool) -> Void
  public var featureLess: @MainActor (_ eventID: String) -> Void
  public var copyText: @MainActor (_ eventID: String) -> Void
  public var exportText: @MainActor (_ eventID: String) -> Void
  public var renameEvent: @MainActor (_ eventID: String, _ title: String) -> Void
  public var namePerson: @MainActor (_ personID: String, _ name: String) -> Void
  /// "这不是这件事的". `segID` is set on a row showing one part of a record
  /// (the correction is about that part).
  public var removeItem: @MainActor (_ eventID: String, _ itemID: String, _ segID: String?) -> Void
  /// "移到…" (from the event page the user is on) / "放进…" (from Unfiled,
  /// `fromEventID` nil); `segID` as for `removeItem`.
  public var moveItem:
    @MainActor (
      _ itemID: String, _ toEventID: String, _ fromEventID: String?, _ segID: String?
    ) -> Void
  /// "单独成一件事".
  public var fileItemNewEvent: @MainActor (_ itemID: String) -> Void
  public var play: @MainActor (_ itemID: String) -> Void
  /// Plays one stretch of a recording (monotonic nanoseconds) and stops at
  /// its end: the voice a yes/no question is about.
  public var playRange:
    @MainActor (_ itemID: String, _ startNanoseconds: UInt64, _ endNanoseconds: UInt64) -> Void
  public var stop: @MainActor () -> Void
  public var playPersonSample: @MainActor (_ personID: String) -> Void
  public var changeSource: @MainActor (_ itemID: String, _ name: String) -> Void
  /// Called when the Home or People page appears, to refresh the read model.
  public var refresh: @MainActor () -> Void
  /// A correction the organizing device did not take: send it again, or
  /// drop it (`MemoryIssue.id`).
  public var retryIssue: @MainActor (_ issueID: String) -> Void
  public var discardIssue: @MainActor (_ issueID: String) -> Void
  /// v7: confirm / reject / rename a rope, move a matter to another rope,
  /// reject a blocks edge, hide a crossing.
  public var relation: @MainActor (MemoryRelationDecision) -> Void
  /// v7: a matter page with no map yet asks for one (optional).
  public var requestMap: @MainActor (_ eventID: String) -> Void

  public init(
    answer: @escaping @MainActor (MemoryQuestion, Bool) -> Void = { _, _ in },
    answerReview: @escaping @MainActor (MemoryPersonReview, Bool) -> Void = { _, _ in },
    pin: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
    featureLess: @escaping @MainActor (String) -> Void = { _ in },
    copyText: @escaping @MainActor (String) -> Void = { _ in },
    exportText: @escaping @MainActor (String) -> Void = { _ in },
    renameEvent: @escaping @MainActor (String, String) -> Void = { _, _ in },
    namePerson: @escaping @MainActor (String, String) -> Void = { _, _ in },
    removeItem: @escaping @MainActor (String, String, String?) -> Void = { _, _, _ in },
    moveItem: @escaping @MainActor (String, String, String?, String?) -> Void = { _, _, _, _ in },
    fileItemNewEvent: @escaping @MainActor (String) -> Void = { _ in },
    play: @escaping @MainActor (String) -> Void = { _ in },
    playRange: @escaping @MainActor (String, UInt64, UInt64) -> Void = { _, _, _ in },
    stop: @escaping @MainActor () -> Void = {},
    playPersonSample: @escaping @MainActor (String) -> Void = { _ in },
    changeSource: @escaping @MainActor (String, String) -> Void = { _, _ in },
    refresh: @escaping @MainActor () -> Void = {},
    retryIssue: @escaping @MainActor (String) -> Void = { _ in },
    discardIssue: @escaping @MainActor (String) -> Void = { _ in },
    relation: @escaping @MainActor (MemoryRelationDecision) -> Void = { _ in },
    requestMap: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.answer = answer
    self.answerReview = answerReview
    self.pin = pin
    self.featureLess = featureLess
    self.copyText = copyText
    self.exportText = exportText
    self.renameEvent = renameEvent
    self.namePerson = namePerson
    self.removeItem = removeItem
    self.moveItem = moveItem
    self.fileItemNewEvent = fileItemNewEvent
    self.play = play
    self.playRange = playRange
    self.stop = stop
    self.playPersonSample = playPersonSample
    self.changeSource = changeSource
    self.refresh = refresh
    self.retryIssue = retryIssue
    self.discardIssue = discardIssue
    self.relation = relation
    self.requestMap = requestMap
  }

  /// Does nothing; for snapshots and previews.
  public static var inert: MemoryActions { MemoryActions() }
}
