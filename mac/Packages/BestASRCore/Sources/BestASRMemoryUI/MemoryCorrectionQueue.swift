import BestASRMemory
import Combine
import Foundation

/// The undo window for corrections (MAC-SPEC §5.7; v11 decision: held 8 s,
/// then sent; ⌘Z after that sends the inverse; pending ones are committed on
/// quit).
///
/// - A held correction (`MemoryCorrection.isHeld`) is shown applied at once
///   (`held`, which the App lays over the projection) but sent only after
///   `hold` seconds. Undo before that drops it: nothing leaves the Mac.
/// - A local correction (step mark, group, pin) is committed at once.
/// - There is one undo slot: the last undoable correction, held or sent.
///   Undo after it was sent commits its inverse; a correction with no
///   inverse (删除) leaves the slot when it is sent.
/// - `commitAll()` sends everything still held and waits (on quit).
///
/// The clock is injected (`schedule`) so tests drive it.
/// Where held corrections are written as they are made, so a crash, a force
/// quit or a power cut inside the undo window does not lose them (v11: held
/// corrections are committed on quit *or* crash). The App keeps it in the
/// library; `replay` sends what a previous run left behind.
@MainActor
public protocol MemoryCorrectionJournal: AnyObject {
  /// A held correction was made; it is due at `releaseAt`.
  func record(_ id: UUID, _ correction: MemoryCorrection, releaseAt: Date)
  /// It was undone, or its send is durable.
  func remove(_ id: UUID)
  /// What a previous run left: oldest first.
  func leftovers() -> [(id: UUID, correction: MemoryCorrection, releaseAt: Date)]
}

@MainActor
public final class MemoryCorrectionQueue: ObservableObject {
  public struct Entry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let correction: MemoryCorrection
    public let at: Date
    public var committed: Bool
    /// Its send is under way: still shown applied, no longer undoable by
    /// dropping it.
    public var sending = false
  }

  /// A scheduled call that can be called off.
  public struct Scheduled {
    public let cancel: () -> Void
    public init(cancel: @escaping () -> Void) { self.cancel = cancel }
  }

  public typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Scheduled

  /// Held corrections, oldest first, laid over the pages until their send
  /// is durable (so a page never flickers back to the old title or place).
  @Published public private(set) var pending: [Entry] = []
  /// The last undoable correction.
  @Published public private(set) var slot: Entry?
  /// Sends queued or under way (held and local ones).
  @Published public private(set) var inFlight = 0

  public let hold: TimeInterval
  private let commit: @MainActor (MemoryCorrection) async -> Void
  private let schedule: Schedule
  private let clock: () -> Date
  private let journal: MemoryCorrectionJournal?
  private var timers: [UUID: Scheduled] = [:]
  /// The last send in the chain: every send waits for the one before, so
  /// an undo's inverse never lands before the correction it undoes.
  private var tail: Task<Void, Never>?
  /// The held correction whose toast the pointer is over.
  private var paused: UUID?

  /// - Parameters:
  ///   - hold: seconds a held correction waits (8, the toast's lifetime).
  ///   - schedule: runs a closure after a delay (default: a main-actor task).
  ///   - journal: keeps held corrections across a crash (nil in tests).
  ///   - commit: sends one correction and returns once it is durable (the
  ///     App: an organizer decision recorded, the local organizer or the
  ///     user-organizing store written).
  public init(
    hold: TimeInterval = 8, clock: @escaping () -> Date = Date.init, schedule: Schedule? = nil,
    journal: MemoryCorrectionJournal? = nil,
    commit: @escaping @MainActor (MemoryCorrection) async -> Void
  ) {
    self.hold = hold
    self.clock = clock
    self.commit = commit
    self.journal = journal
    self.schedule =
      schedule ?? { delay, work in
        let task = Task { @MainActor in
          try? await Task.sleep(for: .seconds(delay))
          guard !Task.isCancelled else { return }
          work()
        }
        return Scheduled(cancel: { task.cancel() })
      }
  }

  /// The corrections the pages show applied before they are durable.
  public var held: [MemoryCorrection] { pending.map(\.correction) }

  /// Something is held or being sent (quit waits for it).
  public var hasWork: Bool { !pending.isEmpty || inFlight > 0 }

  /// The menus' view of the slot.
  public var undoState: MemoryUndoState? {
    slot.map { MemoryUndoState(label: $0.correction.undoLabel, pending: !$0.committed) }
  }

  /// Sends what a previous run held when it ended without committing it
  /// (a crash or a force quit), in order, before anything new.
  public func replayLeftovers() {
    guard let journal else { return }
    for leftover in journal.leftovers() {
      dispatch(leftover.correction, journaled: leftover.id)
    }
  }

  /// Applies a correction: held ones wait, local ones go at once.
  @discardableResult
  public func submit(_ correction: MemoryCorrection) -> Entry {
    var entry = Entry(id: UUID(), correction: correction, at: clock(), committed: false)
    if correction.isHeld {
      pending.append(entry)
      journal?.record(entry.id, correction, releaseAt: entry.at.addingTimeInterval(hold))
      arm(entry.id, after: hold)
    } else {
      entry.committed = true
      dispatch(correction)
    }
    if correction.isUndoable, !(entry.committed && correction.inverse == nil) {
      slot = entry
    }
    return entry
  }

  /// 撤销 / ⌘Z: drops the slot's correction while it is held; after it was
  /// sent (or while its send is under way), sends its inverse after it.
  /// Returns what was undone.
  @discardableResult
  public func undo() -> MemoryCorrection? {
    guard let entry = slot else { return nil }
    slot = nil
    if let index = pending.firstIndex(where: { $0.id == entry.id }), !pending[index].sending {
      timers.removeValue(forKey: entry.id)?.cancel()
      pending.remove(at: index)
      journal?.remove(entry.id)
      if paused == entry.id { paused = nil }
      return entry.correction
    }
    guard let inverse = entry.correction.inverse else { return nil }
    dispatch(inverse)
    return entry.correction
  }

  /// The toast is hovered: the held correction waits until it is left. A
  /// correction paused before (its toast replaced while hovered) goes on.
  public func pause(_ id: UUID) {
    if let previous = paused, previous != id { resume(previous) }
    guard pending.contains(where: { $0.id == id && !$0.sending }) else { return }
    paused = id
    timers.removeValue(forKey: id)?.cancel()
  }

  /// The pointer left the toast, or the toast went away: the held
  /// correction goes after `after` seconds (2.4, as the toast restarts).
  public func resume(_ id: UUID, after: TimeInterval = 2.4) {
    if paused == id { paused = nil }
    guard pending.contains(where: { $0.id == id && !$0.sending }), timers[id] == nil else { return }
    arm(id, after: after)
  }

  /// Sends everything still held now and waits until every send (also
  /// those already under way) is durable: on quit, or when the window that
  /// showed them closes.
  public func commitAll() async {
    for entry in pending where !entry.sending { send(entry.id) }
    paused = nil
    while let last = tail {
      await last.value
      if tail == last { break }
    }
  }

  private func arm(_ id: UUID, after delay: TimeInterval) {
    timers[id] = schedule(delay) { [weak self] in self?.send(id) }
  }

  private func send(_ id: UUID) {
    timers.removeValue(forKey: id)?.cancel()
    guard let index = pending.firstIndex(where: { $0.id == id }), !pending[index].sending else {
      return
    }
    pending[index].sending = true
    if paused == id { paused = nil }
    let entry = pending[index]
    if slot?.id == id {
      if entry.correction.inverse == nil { slot = nil } else { slot?.committed = true }
    }
    dispatch(entry.correction, entry: id, journaled: id)
  }

  /// Queues one send after the ones before it.
  private func dispatch(_ correction: MemoryCorrection, entry: UUID? = nil, journaled: UUID? = nil) {
    let commit = commit
    let previous = tail
    inFlight += 1
    tail = Task { @MainActor [weak self] in
      await previous?.value
      await commit(correction)
      self?.finished(entry: entry, journaled: journaled)
    }
  }

  private func finished(entry: UUID?, journaled: UUID?) {
    inFlight -= 1
    if let entry { pending.removeAll { $0.id == entry } }
    if let journaled { journal?.remove(journaled) }
  }
}
