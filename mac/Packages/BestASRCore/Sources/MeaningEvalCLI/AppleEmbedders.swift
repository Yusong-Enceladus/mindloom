import BestASRMemory
import Foundation
import NaturalLanguage

/// The system's own text vectors, as candidates to measure against (B4 §6
/// question 2: a downloaded model only if it clearly beats what the system
/// has). Both run on this Mac; neither is shipped by this tool.
///
/// - `contextual`: `NLContextualEmbedding` for Simplified Chinese, its token
///   vectors averaged.
/// - `sentence`: `NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)`.
final class AppleMeaningEmbedder: MeaningEmbedding, @unchecked Sendable {
  enum Kind: String {
    case contextual
    case sentence
  }

  let kind: Kind
  let modelVersion: String
  let dimension: Int
  private let contextual: NLContextualEmbedding?
  private let sentence: NLEmbedding?
  private let lock = NSLock()

  init(_ kind: Kind) throws {
    self.kind = kind
    switch kind {
    case .contextual:
      guard let model = NLContextualEmbedding(language: .simplifiedChinese) else {
        throw AppleEmbedderError.unavailable
      }
      if !model.hasAvailableAssets {
        let semaphore = DispatchSemaphore(value: 0)
        model.requestAssets { _, _ in semaphore.signal() }
        semaphore.wait()
      }
      try model.load()
      contextual = model
      sentence = nil
      dimension = model.dimension
      modelVersion = "apple-contextual-\(model.modelIdentifier)-r\(model.revision)"
    case .sentence:
      guard let model = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) else {
        throw AppleEmbedderError.unavailable
      }
      contextual = nil
      sentence = model
      dimension = model.dimension
      modelVersion = "apple-sentence-zh-r\(model.revision)"
    }
  }

  func embed(_ texts: [String], role: MeaningTextRole) async throws -> [[Float]] {
    try lock.withLock {
      try texts.map { text in
        let clipped = String(text.prefix(500))
        switch kind {
        case .contextual:
          let result = try contextual!.embeddingResult(for: clipped, language: .simplifiedChinese)
          var sum = [Double](repeating: 0, count: dimension)
          var count = 0
          result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            for index in 0..<min(vector.count, sum.count) { sum[index] += vector[index] }
            count += 1
            return true
          }
          guard count > 0 else { return [Float](repeating: 0, count: dimension) }
          return MeaningMatrix.normalized(sum.map { Float($0 / Double(count)) })
        case .sentence:
          let vector = sentence!.vector(for: clipped) ?? []
          guard vector.count == dimension else { return [Float](repeating: 0, count: dimension) }
          return MeaningMatrix.normalized(vector.map(Float.init))
        }
      }
    }
  }

  func release() async {}
}

enum AppleEmbedderError: Error {
  case unavailable
}
