import BestASRBenchmark
import Foundation

public enum SpeakerIdentityEmbeddingFormat: String, Codable, Sendable {
  case fluidDirectory = "fluid-directory"
  case recordsFile = "records-file"
}

public struct SpeakerIdentityModeSummary: Codable, Equatable, Sendable {
  public let mode: String
  public let knownCount: Int
  public let knownCorrectCount: Int
  public let knownWrongCount: Int
  public let knownRejectedCount: Int
  public let unknownCount: Int
  public let unknownRejectedCount: Int
}

public struct SpeakerIdentityEvaluation: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let candidate: String
  public let thresholdPolicy: String
  public let thresholdMargin: Double
  public let threshold: Double
  public let enrollmentSeparationFeasible: Bool
  public let minimumGenuineSimilarity: Double
  public let maximumImpostorSimilarity: Double
  public let enrollmentSeparationGap: Double
  public let embeddingDimension: Int
  public let enrollmentCount: Int
  public let queryCount: Int
  public let knownQueryCount: Int
  public let knownCorrectCount: Int
  public let knownWrongCount: Int
  public let knownRejectedCount: Int
  public let unknownQueryCount: Int
  public let unknownRejectedCount: Int
  public let falseMergeCount: Int
  public let falseSplitCount: Int
  public let falseRejectCount: Int
  public let falseMergeRate: Double
  public let falseSplitRate: Double
  public let falseRejectRate: Double
  public let modeSummaries: [SpeakerIdentityModeSummary]
  public let assignments: [IdentityAssignment]
}

public struct SpeakerIdentityEvaluationRequest: Sendable {
  public let candidate: String
  public let manifestURL: URL
  public let embeddingsURL: URL
  public let embeddingFormat: SpeakerIdentityEmbeddingFormat
  public let thresholdMargin: Double

  public init(
    candidate: String,
    manifestURL: URL,
    embeddingsURL: URL,
    embeddingFormat: SpeakerIdentityEmbeddingFormat,
    thresholdMargin: Double = 0.03
  ) {
    self.candidate = candidate
    self.manifestURL = manifestURL
    self.embeddingsURL = embeddingsURL
    self.embeddingFormat = embeddingFormat
    self.thresholdMargin = thresholdMargin
  }
}

public enum SpeakerIdentityEvaluatorError: Error, Equatable, Sendable {
  case invalidMargin
  case invalidManifest
  case missingEmbedding(String)
  case invalidEmbedding(String)
  case inconsistentDimension
  case insufficientEnrollment(String)
  case noQueries
}

public enum SpeakerIdentityEvaluator {
  public static func evaluate(
    _ request: SpeakerIdentityEvaluationRequest
  ) throws -> SpeakerIdentityEvaluation {
    guard request.thresholdMargin > 0, request.thresholdMargin < 0.5 else {
      throw SpeakerIdentityEvaluatorError.invalidMargin
    }
    let manifest: IdentityManifest
    do {
      manifest = try JSONDecoder().decode(
        IdentityManifest.self,
        from: Data(contentsOf: request.manifestURL)
      )
    } catch {
      throw SpeakerIdentityEvaluatorError.invalidManifest
    }
    guard manifest.schemaVersion == 1,
      manifest.kind == "synthetic-speaker-identity-manifest"
    else {
      throw SpeakerIdentityEvaluatorError.invalidManifest
    }

    let vectors = try loadVectors(
      manifest: manifest,
      location: request.embeddingsURL,
      format: request.embeddingFormat
    )
    guard let dimension = vectors.values.first?.count, dimension > 0,
      vectors.values.allSatisfy({ $0.count == dimension })
    else {
      throw SpeakerIdentityEvaluatorError.inconsistentDimension
    }

    let enrollmentEntries = manifest.entries.filter { $0.role == "enrollment" }
    let queryEntries = manifest.entries.filter { $0.role == "query" }
    guard !queryEntries.isEmpty else {
      throw SpeakerIdentityEvaluatorError.noQueries
    }
    let groupedEnrollment = Dictionary(
      grouping: enrollmentEntries,
      by: \.expectedPersonID
    )
    for (personID, entries) in groupedEnrollment where entries.count < 2 {
      throw SpeakerIdentityEvaluatorError.insufficientEnrollment(personID)
    }

    var centroids: [String: [Double]] = [:]
    for (personID, entries) in groupedEnrollment {
      centroids[personID] = try average(
        entries.map { try vector($0.sampleID, from: vectors) }
      )
    }

    var genuineSimilarities: [Double] = []
    var impostorSimilarities: [Double] = []
    for leftIndex in enrollmentEntries.indices {
      for rightIndex in enrollmentEntries.indices where rightIndex > leftIndex {
        let left = enrollmentEntries[leftIndex]
        let right = enrollmentEntries[rightIndex]
        let similarity = try cosine(
          vector(left.sampleID, from: vectors),
          vector(right.sampleID, from: vectors)
        )
        if left.expectedPersonID == right.expectedPersonID {
          genuineSimilarities.append(similarity)
        } else {
          impostorSimilarities.append(similarity)
        }
      }
    }
    guard let minimumGenuine = genuineSimilarities.min(),
      let maximumImpostor = impostorSimilarities.max()
    else {
      throw SpeakerIdentityEvaluatorError.invalidManifest
    }

    let lowerBound = maximumImpostor + request.thresholdMargin
    let upperBound = minimumGenuine - request.thresholdMargin
    let separationFeasible = lowerBound <= upperBound
    let threshold = min(1, separationFeasible ? upperBound : lowerBound)

    let sortedQueries = queryEntries.sorted { $0.sampleID < $1.sampleID }
    var assignments: [IdentityAssignment] = []
    var predictionsBySampleID: [String: String] = [:]
    for (index, entry) in sortedQueries.enumerated() {
      let queryVector = try vector(entry.sampleID, from: vectors)
      let nearest = try centroids.map { personID, centroid in
        (personID, try cosine(queryVector, centroid))
      }.max { left, right in
        if left.1 == right.1 { return left.0 > right.0 }
        return left.1 < right.1
      }
      let prediction = nearest.flatMap { $0.1 >= threshold ? $0.0 : nil }
      if let prediction {
        predictionsBySampleID[entry.sampleID] = prediction
      }
      assignments.append(
        IdentityAssignment(
          occurrenceID: occurrenceUUID(index + 1),
          expectedPersonID: entry.expectedPersonID,
          predictedPersonID: prediction,
          evidenceSufficient: entry.evidenceSufficient
        ))
    }

    let identity = SpeakerScorer.identity(assignments)
    let knownEntries = sortedQueries.filter(\.evidenceSufficient)
    let unknownEntries = sortedQueries.filter { !$0.evidenceSufficient }
    let knownCorrect = knownEntries.filter {
      predictionsBySampleID[$0.sampleID] == $0.expectedPersonID
    }.count
    let knownRejected = knownEntries.filter {
      predictionsBySampleID[$0.sampleID] == nil
    }.count
    let knownWrong = knownEntries.count - knownCorrect - knownRejected
    let unknownRejected = unknownEntries.filter {
      predictionsBySampleID[$0.sampleID] == nil
    }.count

    let modeSummaries = Dictionary(grouping: sortedQueries, by: \.mode)
      .map { mode, entries in
        let known = entries.filter(\.evidenceSufficient)
        let unknown = entries.filter { !$0.evidenceSufficient }
        let correct = known.filter {
          predictionsBySampleID[$0.sampleID] == $0.expectedPersonID
        }.count
        let rejected = known.filter {
          predictionsBySampleID[$0.sampleID] == nil
        }.count
        return SpeakerIdentityModeSummary(
          mode: mode,
          knownCount: known.count,
          knownCorrectCount: correct,
          knownWrongCount: known.count - correct - rejected,
          knownRejectedCount: rejected,
          unknownCount: unknown.count,
          unknownRejectedCount: unknown.filter {
            predictionsBySampleID[$0.sampleID] == nil
          }.count
        )
      }.sorted { $0.mode < $1.mode }

    return SpeakerIdentityEvaluation(
      schemaVersion: 1,
      kind: "speaker-identity-evaluation",
      candidate: request.candidate,
      thresholdPolicy: "enrollment-only-conservative-upper-bound",
      thresholdMargin: request.thresholdMargin,
      threshold: threshold,
      enrollmentSeparationFeasible: separationFeasible,
      minimumGenuineSimilarity: minimumGenuine,
      maximumImpostorSimilarity: maximumImpostor,
      enrollmentSeparationGap: minimumGenuine - maximumImpostor,
      embeddingDimension: dimension,
      enrollmentCount: enrollmentEntries.count,
      queryCount: sortedQueries.count,
      knownQueryCount: knownEntries.count,
      knownCorrectCount: knownCorrect,
      knownWrongCount: knownWrong,
      knownRejectedCount: knownRejected,
      unknownQueryCount: unknownEntries.count,
      unknownRejectedCount: unknownRejected,
      falseMergeCount: identity.falseMergeCount,
      falseSplitCount: identity.falseSplitCount,
      falseRejectCount: identity.falseRejectCount,
      falseMergeRate: identity.falseMergeRate,
      falseSplitRate: identity.falseSplitRate,
      falseRejectRate: identity.falseRejectRate,
      modeSummaries: modeSummaries,
      assignments: assignments
    )
  }

  private static func loadVectors(
    manifest: IdentityManifest,
    location: URL,
    format: SpeakerIdentityEmbeddingFormat
  ) throws -> [String: [Double]] {
    switch format {
    case .recordsFile:
      let output = try JSONDecoder().decode(
        RecordsOutput.self,
        from: Data(contentsOf: location)
      )
      return try Dictionary(
        uniqueKeysWithValues: output.records.map {
          ($0.sampleID, try normalized($0.embedding.map(Double.init), id: $0.sampleID))
        }
      )
    case .fluidDirectory:
      var result: [String: [Double]] = [:]
      for entry in manifest.entries {
        let url =
          location
          .appendingPathComponent(entry.sampleID, isDirectory: true)
          .appendingPathComponent("embeddings.json")
        let records = try JSONDecoder().decode(
          [FluidEmbeddingRecord].self,
          from: Data(contentsOf: url)
        )
        guard !records.isEmpty else {
          throw SpeakerIdentityEvaluatorError.missingEmbedding(entry.sampleID)
        }
        result[entry.sampleID] = try average(
          records.map { $0.embedding256.map(Double.init) }
        )
      }
      return result
    }
  }

  private static func vector(
    _ sampleID: String,
    from vectors: [String: [Double]]
  ) throws -> [Double] {
    guard let vector = vectors[sampleID] else {
      throw SpeakerIdentityEvaluatorError.missingEmbedding(sampleID)
    }
    return vector
  }

  private static func average(_ vectors: [[Double]]) throws -> [Double] {
    guard let dimension = vectors.first?.count, dimension > 0,
      vectors.allSatisfy({ $0.count == dimension })
    else {
      throw SpeakerIdentityEvaluatorError.inconsistentDimension
    }
    var output = [Double](repeating: 0, count: dimension)
    for vector in vectors {
      let unit = try normalized(vector, id: "centroid-input")
      for index in output.indices { output[index] += unit[index] }
    }
    return try normalized(output, id: "centroid")
  }

  private static func normalized(
    _ vector: [Double],
    id: String
  ) throws -> [Double] {
    guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
      throw SpeakerIdentityEvaluatorError.invalidEmbedding(id)
    }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm > 0 else {
      throw SpeakerIdentityEvaluatorError.invalidEmbedding(id)
    }
    return vector.map { $0 / norm }
  }

  private static func cosine(
    _ left: [Double],
    _ right: [Double]
  ) throws -> Double {
    guard left.count == right.count else {
      throw SpeakerIdentityEvaluatorError.inconsistentDimension
    }
    return zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
  }

  private static func occurrenceUUID(_ ordinal: Int) -> UUID {
    UUID(
      uuidString: String(
        format: "32000000-0000-4000-8000-%012d", ordinal
      ))!
  }
}

private struct IdentityManifest: Decodable {
  let schemaVersion: Int
  let kind: String
  let entries: [IdentityManifestEntry]
}

private struct IdentityManifestEntry: Decodable {
  let sampleID: String
  let expectedPersonID: String
  let evidenceSufficient: Bool
  let role: String
  let mode: String
}

private struct RecordsOutput: Decodable {
  let records: [EmbeddingRecord]
}

private struct EmbeddingRecord: Decodable {
  let sampleID: String
  let embedding: [Float]
}

private struct FluidEmbeddingRecord: Decodable {
  let embedding256: [Float]
}
