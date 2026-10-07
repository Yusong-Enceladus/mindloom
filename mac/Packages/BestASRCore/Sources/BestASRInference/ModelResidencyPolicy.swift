/// How long the dictation models stay in memory after the last dictation
/// (ALIGNMENT recommendation 8, adopted 2026-10-05).
///
/// The recognizer is what makes a dictation cold: on 2026-10-06 the installed
/// App reloaded it (`qwen-warmup` 1.8–2.6 s) for 11 of 76 dictations, and
/// those waited a median 1,110 ms from release to text against 591 ms warm —
/// about half a second each, because most of the reload runs while the user
/// is still speaking. All 9 gaps of ten minutes to an hour that day were
/// followed by a reload. It stays an hour. The cleanup model and the general
/// text model cost little when they are late, so they leave after ten
/// minutes. The aligner is not loaded during dictation at all: dictation's
/// word timings come later, with the aligner alone in memory
/// (`DeferredWordAlignment`, adopted 2026-10-06).
///
/// Memory pressure (recommendation 5, adopted 2026-10-06) keeps a buffer:
/// a warning releases the aligner and the cleanup and text models at once
/// and the recognizer only if the warning lasts `recognizerPressureGrace`;
/// critical pressure releases everything at once. See
/// `modelsToRelease(on:)`.
public struct ModelResidencyPolicy: Equatable, Sendable {
  public enum Model: String, CaseIterable, Hashable, Sendable {
    /// The final recognizer (Qwen3-ASR).
    case recognizer
    /// Word alignment, the personal cleanup model, the general text model.
    case secondary
  }

  /// One step of the idle release: `after` this long from when the timer was
  /// armed, `models` leave memory.
  public struct ReleaseStep: Equatable, Sendable {
    public let after: Duration
    public let models: Set<Model>

    public init(after: Duration, models: Set<Model>) {
      self.after = after
      self.models = models
    }
  }

  /// What the system reports (`DispatchSource.makeMemoryPressureSource`).
  public enum MemoryPressure: String, Equatable, Sendable {
    case normal
    case warning
    case critical
  }

  public var recognizer: Duration
  public var secondary: Duration
  /// How long a memory-pressure warning may last, after the other models
  /// have gone, before the recognizer goes too.
  public var recognizerPressureGrace: Duration

  public static let standard = ModelResidencyPolicy(
    recognizer: .seconds(60 * 60), secondary: .seconds(10 * 60),
    recognizerPressureGrace: .seconds(60))

  public init(
    recognizer: Duration, secondary: Duration, recognizerPressureGrace: Duration = .seconds(60)
  ) {
    self.recognizer = recognizer
    self.secondary = secondary
    self.recognizerPressureGrace = recognizerPressureGrace
  }

  /// How long `model` stays after the last dictation.
  public func residency(of model: Model) -> Duration {
    switch model {
    case .recognizer: recognizer
    case .secondary: secondary
    }
  }

  /// What the idle timer releases, and when, counted from when it is armed.
  /// After a dictation: the secondary models after `secondary`, the
  /// recognizer after `recognizer`. After a launch nobody has dictated into
  /// yet, the prewarm is all that loaded them: everything after `secondary`.
  /// The runtime arms the timer at the end of every dictation and at the end
  /// of the launch prewarm, and follows these steps (`LocalDictationRuntime
  /// .scheduleIdleModelRelease`).
  public func idleReleaseSchedule(afterDictation: Bool) -> [ReleaseStep] {
    let everything = Set(Model.allCases)
    guard afterDictation else { return [ReleaseStep(after: secondary, models: everything)] }
    guard secondary < recognizer else {
      return [ReleaseStep(after: recognizer, models: everything)]
    }
    return [
      ReleaseStep(after: secondary, models: [.secondary]),
      ReleaseStep(after: recognizer, models: [.recognizer]),
    ]
  }

  /// The models to release the moment the system reports `pressure`,
  /// whatever their timers say.
  ///
  /// A warning releases the secondary models only. On a 16 GB Mac loading
  /// the recognizer for a dictation can itself raise a warning; releasing
  /// it then would make the next dictation load it again (about half a
  /// second more each time, §15.2) and raise the same warning — every
  /// dictation cold. The secondary models (the aligner while it times
  /// sentences, 1.22 GB; the cleanup model; the text model) cost nothing on
  /// the way to the text, so they go first. Critical pressure releases
  /// everything: the system is about to take memory by force.
  public func modelsToRelease(on pressure: MemoryPressure) -> Set<Model> {
    switch pressure {
    case .normal: []
    case .warning: [.secondary]
    case .critical: Set(Model.allCases)
    }
  }

  /// The models to release once a warning has lasted `duration` without
  /// the system reporting normal again: the recognizer after
  /// `recognizerPressureGrace`. Sixty seconds, because a warning that the
  /// released secondary models relieved ends within seconds; one that
  /// outlasts every dictation the user is likely to be in (a minute) and
  /// the recognizer's own reload (1.8–2.6 s) is not about this App's next
  /// dictation, and the recognizer's 2.35 GB should go back.
  public func modelsToRelease(afterWarningLasting duration: Duration) -> Set<Model> {
    duration >= recognizerPressureGrace ? [.recognizer] : []
  }
}
