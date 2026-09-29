import BestASRDictation
import BestASRDomain
import BestASRMLXRuntime
import BestASRProcessing
import Foundation

/// Produces cleaned-up dictation text. The App owns this seam so the policy
/// around the model can be tested without loading one.
protocol DictationCleanupGenerating: Sendable {
  func prepareModel() async throws
  func releaseModel() async
  func cleanUp(_ raw: String) async throws -> String
}

extension MLXLocalTextRuntime: DictationCleanupGenerating {
  func prepareModel() async throws { try await prepare() }

  func releaseModel() async { await release() }

  func cleanUp(_ raw: String) async throws -> String {
    try await cleanUpDictation(raw)
  }
}

/// The cleanup model trained on this user's own dictations and the final text
/// they kept. It is personal data, so it is never bundled, downloaded or
/// uploaded: it exists only if it was built on this Mac.
enum PersonalDictationCleanupModel {
  static let relativePath = "personal-models/cleanup/current"

  /// The model directory, if a complete one is installed.
  static func installedDirectory(applicationSupport: URL) -> URL? {
    let directory = applicationSupport.appendingPathComponent(relativePath, isDirectory: true)
      .resolvingSymlinksInPath()
    let manager = FileManager.default
    let contents = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
    guard contents.contains("config.json"), contents.contains("tokenizer.json"),
      contents.contains(where: { $0.hasSuffix(".safetensors") })
    else { return nil }
    return directory
  }

  /// Identifies the installed model in derived-text provenance. The directory
  /// name carries the training date, so history says which model wrote a line.
  static func revision(of directory: URL) -> String {
    "personal-cleanup:\(directory.lastPathComponent)"
  }
}

/// Runs the cleanup model at most once per distinct dictation and keeps the
/// results found during speech pauses, so at release the text is usually
/// already there.
actor PersonalDictationCleanupService {
  private let generator: any DictationCleanupGenerating
  /// Enough for the pause results of one long dictation; oldest go first.
  private let cacheLimit = 8
  private var finished: [(raw: String, text: String?)] = []
  private var running: [String: Task<String?, Never>] = [:]
  private var warmUpTask: Task<Void, Never>?

  init(generator: any DictationCleanupGenerating) {
    self.generator = generator
  }

  /// Loads the model while the user is still speaking. Loading it takes about
  /// a second, which would otherwise land on the first pause's cleanup.
  func warmUp() {
    guard warmUpTask == nil else { return }
    let generator = generator
    warmUpTask = Task { try? await generator.prepareModel() }
  }

  /// Drops the model and everything it produced for earlier dictations.
  func release() {
    warmUpTask?.cancel()
    warmUpTask = nil
    running.values.forEach { $0.cancel() }
    running = [:]
    finished = []
    let generator = generator
    Task { await generator.releaseModel() }
  }

  /// Starts cleanup for text recognized at a speech pause, without waiting.
  func precompute(_ raw: String) {
    _ = task(for: raw)
  }

  /// The cleaned-up text, or nil when the model added words the user did not
  /// say, produced nothing usable, or failed.
  ///
  /// `cachedOnly` returns whatever a speech pause already produced and never
  /// waits for the model: short dictations are not worth delaying, since on
  /// the evaluation set the model changed only 2 of 60 clips under 5 seconds
  /// but 57 of 120 over 15 seconds.
  func cleanUp(_ raw: String, cachedOnly: Bool = false) async -> String? {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    if let cached = finished.first(where: { $0.raw == key }) { return cached.text }
    guard !cachedOnly else { return nil }
    return await task(for: key).value
  }

  private func task(for raw: String) -> Task<String?, Never> {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let running = running[key] { return running }
    let generator = generator
    let task = Task<String?, Never> {
      let candidate = try? await generator.cleanUp(key)
      let accepted = candidate.flatMap { DictationCleanupGuard.accepted($0, raw: key) }
      await self.store(raw: key, text: accepted)
      return accepted
    }
    running[key] = task
    return task
  }

  private func store(raw: String, text: String?) {
    running[raw] = nil
    finished.removeAll { $0.raw == raw }
    finished.append((raw, text))
    if finished.count > cacheLimit { finished.removeFirst(finished.count - cacheLimit) }
  }
}

/// Inserts the personal cleanup model's text when it is faithful to what was
/// recognized, and the rule-cleaned transcript otherwise.
struct PersonalDictationCleanupAdapter: DictationPolishPort {
  /// Dictations shorter than this are inserted with the rule cleanup unless a
  /// speech pause already produced the model's text.
  ///
  /// Measured on the 240-item evaluation set, by input length: under 15
  /// characters the model changed 0 of 43 dictations, so waiting 114 ms for it
  /// buys nothing. From 15 characters it starts earning its cost — 7 of 36
  /// changed and character precision against the verified transcripts rose
  /// 96.98% to 97.35%, for 135 ms median and 150 ms at p90, inside the 250 ms
  /// budget. Generation time scales with length, so the budget, not this
  /// number, is what protects the tail.
  static let shortDictationCharacters = 15

  let service: PersonalDictationCleanupService
  let revision: String

  func polish(_ request: DictationPolishRequest) async throws -> DictationPolishResult {
    let source = request.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else {
      return DictationPolishResult(
        sourceRevisionID: request.transcript.revisionID,
        text: request.transcript.text,
        disposition: .rawTranscriptFallback,
        modelArtifactID: nil
      )
    }
    let cachedOnly = source.count < Self.shortDictationCharacters
    if let text = await service.cleanUp(source, cachedOnly: cachedOnly) {
      return DictationPolishResult(
        sourceRevisionID: request.transcript.revisionID,
        text: text,
        disposition: .model,
        modelArtifactID: revision
      )
    }
    return DictationPolishResult(
      sourceRevisionID: request.transcript.revisionID,
      text: DictationTextCleanup.apply(source),
      disposition: .punctuationOnlyFallback,
      modelArtifactID: nil
    )
  }
}
