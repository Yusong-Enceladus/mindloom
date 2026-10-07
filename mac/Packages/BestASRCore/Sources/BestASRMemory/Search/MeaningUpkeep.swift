import Foundation

// v12 search, review fixes: what keeps the meaning model out of dictation's
// way (HIST-009: no indexing while dictation, a recording or their
// recognition runs), and a query's vector that never holds the character
// results up for long.

/// Counts heavy work in progress that the meaning index must not run
/// alongside: recognizing a dictation, a recording, an import or a record
/// recognized again; speaker matching; 整理; loading a recognition model.
/// Read from any thread.
public final class BusyGauge: @unchecked Sendable {
  private let lock = NSLock()
  private var running = 0

  public init() {}

  public var isBusy: Bool { lock.withLock { running > 0 } }

  public func begin() {
    lock.withLock { running += 1 }
  }

  public func end() {
    lock.withLock { running = max(0, running - 1) }
  }
}

/// The pause the meaning index takes before each of its steps.
public enum MeaningPause {
  /// Returns once `isBusy` says no, checking every `poll`. `whenBusy` runs
  /// once, when a wait begins (the App drops the model from memory then:
  /// it would otherwise sit unused for the whole recording). Throws when
  /// the task is cancelled.
  public static func wait(
    poll: Duration, isBusy: @Sendable () async -> Bool,
    whenBusy: @Sendable () async -> Void = {}
  ) async throws {
    var waited = false
    while await isBusy() {
      if !waited {
        waited = true
        await whenBusy()
      }
      try await Task.sleep(for: poll)
    }
    try Task.checkCancellation()
  }
}

/// A query's vector for a search someone is typing. The character results
/// wait for it at most `deadline` (the model may be busy with a step of the
/// index); a vector that comes later is kept, and `whenLate` runs so the
/// search can be shown again with it. One text is embedded once, however
/// many searches ask for it at the same time.
public actor MeaningQueryVectors {
  public typealias Embed = @Sendable (String) async -> [Float]?

  private let embed: Embed
  private let keep: Int
  private var known: [String: [Float]] = [:]
  private var order: [String] = []
  private var running: [String: Task<[Float]?, Never>] = [:]
  private var late: [String: [@Sendable () -> Void]] = [:]
  /// Texts sent to the model (for tests).
  public private(set) var embedded = 0

  public init(keep: Int = 32, embed: @escaping Embed) {
    self.keep = max(1, keep)
    self.embed = embed
  }

  public func vector(
    for text: String, within deadline: Duration, whenLate: (@Sendable () -> Void)? = nil
  ) async -> [Float]? {
    if let hit = known[text] { return hit }
    let task = running[text] ?? start(text)
    if let finished = await Self.first(task, within: deadline) { return finished }
    // It may have come while this call was waiting.
    if let hit = known[text] { return hit }
    if let whenLate { late[text, default: []].append(whenLate) }
    return nil
  }

  /// Forgets the vectors kept (the model was released or changed).
  public func forget() {
    known = [:]
    order = []
  }

  private func start(_ text: String) -> Task<[Float]?, Never> {
    let embed = embed
    embedded += 1
    let task = Task { await embed(text) }
    running[text] = task
    Task {
      let vector = await task.value
      self.finish(text, vector)
    }
    return task
  }

  private func finish(_ text: String, _ vector: [Float]?) {
    running[text] = nil
    let waiting = late.removeValue(forKey: text) ?? []
    guard let vector else { return }
    if known[text] == nil {
      order.append(text)
      if order.count > keep { known[order.removeFirst()] = nil }
    }
    known[text] = vector
    for callback in waiting { callback() }
  }

  /// The task's value when it comes within `deadline`; nil when it does
  /// not (the task goes on).
  static func first(_ task: Task<[Float]?, Never>, within deadline: Duration) async
    -> [Float]??
  {
    await withCheckedContinuation { continuation in
      let once = Once()
      Task {
        let value = await task.value
        if once.claim() { continuation.resume(returning: .some(value)) }
      }
      Task {
        try? await Task.sleep(for: deadline)
        if once.claim() { continuation.resume(returning: .none) }
      }
    }
  }

  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
      lock.withLock {
        guard !claimed else { return false }
        claimed = true
        return true
      }
    }
  }
}
