import Foundation

public struct DiarizationMetrics: Equatable, Sendable {
  public let diarizationErrorRate: Double
  public let jaccardErrorRate: Double
  public let missedSpeakerNanoseconds: Double
  public let falseAlarmSpeakerNanoseconds: Double
  public let confusedSpeakerNanoseconds: Double
  public let referenceSpeakerNanoseconds: Double
  public let hypothesisToReference: [String: String]

  public init(
    diarizationErrorRate: Double,
    jaccardErrorRate: Double,
    missedSpeakerNanoseconds: Double,
    falseAlarmSpeakerNanoseconds: Double,
    confusedSpeakerNanoseconds: Double,
    referenceSpeakerNanoseconds: Double,
    hypothesisToReference: [String: String]
  ) {
    self.diarizationErrorRate = diarizationErrorRate
    self.jaccardErrorRate = jaccardErrorRate
    self.missedSpeakerNanoseconds = missedSpeakerNanoseconds
    self.falseAlarmSpeakerNanoseconds = falseAlarmSpeakerNanoseconds
    self.confusedSpeakerNanoseconds = confusedSpeakerNanoseconds
    self.referenceSpeakerNanoseconds = referenceSpeakerNanoseconds
    self.hypothesisToReference = hypothesisToReference
  }
}

public struct IdentityErrorMetrics: Equatable, Sendable {
  public let falseMergeCount: Int
  public let falseSplitCount: Int
  public let falseRejectCount: Int
  public let falseMergeRate: Double
  public let falseSplitRate: Double
  public let falseRejectRate: Double

  public init(
    falseMergeCount: Int,
    falseSplitCount: Int,
    falseRejectCount: Int,
    falseMergeRate: Double,
    falseSplitRate: Double,
    falseRejectRate: Double
  ) {
    self.falseMergeCount = falseMergeCount
    self.falseSplitCount = falseSplitCount
    self.falseRejectCount = falseRejectCount
    self.falseMergeRate = falseMergeRate
    self.falseSplitRate = falseSplitRate
    self.falseRejectRate = falseRejectRate
  }
}

public enum SpeakerScorer {
  public static func diarization(
    reference: [SpeakerSegment],
    hypothesis: [SpeakerSegment]
  ) throws -> DiarizationMetrics {
    try validate(reference + hypothesis)
    let referenceIDs = Array(Set(reference.map(\.speakerID))).sorted()
    let hypothesisIDs = Array(Set(hypothesis.map(\.speakerID))).sorted()
    let boundaries = Array(
      Set((reference + hypothesis).flatMap { [$0.startNanoseconds, $0.endNanoseconds] })
    ).sorted()

    var overlapWeights = Array(
      repeating: Array(repeating: 0.0, count: referenceIDs.count),
      count: hypothesisIDs.count
    )
    for interval in intervals(boundaries) {
      let duration = Double(interval.end - interval.start)
      let references = activeSpeakers(reference, in: interval)
      let hypotheses = activeSpeakers(hypothesis, in: interval)
      for hypothesisID in hypotheses {
        guard let hypothesisIndex = hypothesisIDs.firstIndex(of: hypothesisID) else {
          continue
        }
        for referenceID in references {
          guard let referenceIndex = referenceIDs.firstIndex(of: referenceID) else {
            continue
          }
          overlapWeights[hypothesisIndex][referenceIndex] += duration
        }
      }
    }

    let assignment = maximumWeightAssignment(overlapWeights)
    var mapping: [String: String] = [:]
    for (hypothesisIndex, referenceIndex) in assignment {
      guard hypothesisIndex < hypothesisIDs.count,
        referenceIndex < referenceIDs.count,
        overlapWeights[hypothesisIndex][referenceIndex] > 0
      else { continue }
      mapping[hypothesisIDs[hypothesisIndex]] = referenceIDs[referenceIndex]
    }

    var missed = 0.0
    var falseAlarm = 0.0
    var confused = 0.0
    var referenceSpeakerTime = 0.0
    for interval in intervals(boundaries) {
      let duration = Double(interval.end - interval.start)
      let references = activeSpeakers(reference, in: interval)
      let hypotheses = activeSpeakers(hypothesis, in: interval)
      referenceSpeakerTime += Double(references.count) * duration
      missed += Double(max(0, references.count - hypotheses.count)) * duration
      falseAlarm += Double(max(0, hypotheses.count - references.count)) * duration
      let correctlyMapped = hypotheses.filter {
        guard let mapped = mapping[$0] else { return false }
        return references.contains(mapped)
      }.count
      confused +=
        Double(min(references.count, hypotheses.count) - correctlyMapped)
        * duration
    }
    let diarizationErrorRate: Double
    if referenceSpeakerTime == 0 {
      diarizationErrorRate = falseAlarm == 0 ? 0 : 1
    } else {
      diarizationErrorRate = (missed + falseAlarm + confused) / referenceSpeakerTime
    }

    let referenceDurations = durationsBySpeaker(reference)
    let hypothesisDurations = durationsBySpeaker(hypothesis)
    var perSpeakerJaccardErrors: [Double] = []
    for referenceID in referenceIDs {
      guard
        let mappedHypothesis = mapping.first(where: { $0.value == referenceID })?.key
      else {
        perSpeakerJaccardErrors.append(1)
        continue
      }
      guard
        let hypothesisIndex = hypothesisIDs.firstIndex(of: mappedHypothesis),
        let referenceIndex = referenceIDs.firstIndex(of: referenceID)
      else {
        perSpeakerJaccardErrors.append(1)
        continue
      }
      let intersection = overlapWeights[hypothesisIndex][referenceIndex]
      let union =
        (referenceDurations[referenceID] ?? 0)
        + (hypothesisDurations[mappedHypothesis] ?? 0) - intersection
      perSpeakerJaccardErrors.append(union > 0 ? 1 - intersection / union : 0)
    }
    let jaccardErrorRate =
      perSpeakerJaccardErrors.isEmpty
      ? 0
      : perSpeakerJaccardErrors.reduce(0, +) / Double(perSpeakerJaccardErrors.count)

    return DiarizationMetrics(
      diarizationErrorRate: diarizationErrorRate,
      jaccardErrorRate: jaccardErrorRate,
      missedSpeakerNanoseconds: missed,
      falseAlarmSpeakerNanoseconds: falseAlarm,
      confusedSpeakerNanoseconds: confused,
      referenceSpeakerNanoseconds: referenceSpeakerTime,
      hypothesisToReference: mapping
    )
  }

  public static func identity(_ assignments: [IdentityAssignment]) -> IdentityErrorMetrics {
    var falseMergeCount = 0
    var falseSplitCount = 0
    var differentPersonPairCount = 0
    var samePersonPairCount = 0

    for leftIndex in assignments.indices {
      for rightIndex in assignments.indices where rightIndex > leftIndex {
        let left = assignments[leftIndex]
        let right = assignments[rightIndex]
        if left.expectedPersonID == right.expectedPersonID {
          samePersonPairCount += 1
          if let leftPrediction = left.predictedPersonID,
            let rightPrediction = right.predictedPersonID,
            leftPrediction != rightPrediction
          {
            falseSplitCount += 1
          }
        } else {
          differentPersonPairCount += 1
          if let leftPrediction = left.predictedPersonID,
            leftPrediction == right.predictedPersonID
          {
            falseMergeCount += 1
          }
        }
      }
    }

    let sufficientAssignments = assignments.filter(\.evidenceSufficient)
    let falseRejectCount = sufficientAssignments.filter {
      $0.predictedPersonID == nil
    }.count
    return IdentityErrorMetrics(
      falseMergeCount: falseMergeCount,
      falseSplitCount: falseSplitCount,
      falseRejectCount: falseRejectCount,
      falseMergeRate: ratio(falseMergeCount, differentPersonPairCount),
      falseSplitRate: ratio(falseSplitCount, samePersonPairCount),
      falseRejectRate: ratio(falseRejectCount, sufficientAssignments.count)
    )
  }

  private static func validate(_ segments: [SpeakerSegment]) throws {
    for segment in segments
    where segment.speakerID.isEmpty
      || segment.endNanoseconds <= segment.startNanoseconds
    {
      throw BenchmarkError.invalidSegment
    }
  }

  private static func intervals(_ boundaries: [UInt64]) -> [(start: UInt64, end: UInt64)] {
    guard boundaries.count > 1 else { return [] }
    return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
      end > start ? (start, end) : nil
    }
  }

  private static func activeSpeakers(
    _ segments: [SpeakerSegment],
    in interval: (start: UInt64, end: UInt64)
  ) -> Set<String> {
    Set(
      segments.compactMap { segment in
        segment.startNanoseconds < interval.end && segment.endNanoseconds > interval.start
          ? segment.speakerID
          : nil
      }
    )
  }

  private static func durationsBySpeaker(_ segments: [SpeakerSegment]) -> [String: Double] {
    Dictionary(grouping: segments, by: \.speakerID).mapValues { speakerSegments in
      speakerSegments.reduce(0) {
        $0 + Double($1.endNanoseconds - $1.startNanoseconds)
      }
    }
  }

  /// Hungarian assignment on a padded square cost matrix. The returned keys are
  /// hypothesis row indices and values are reference column indices.
  private static func maximumWeightAssignment(_ weights: [[Double]]) -> [Int: Int] {
    let rowCount = weights.count
    let columnCount = weights.first?.count ?? 0
    let size = max(rowCount, columnCount)
    guard size > 0 else { return [:] }
    let maximumWeight = weights.flatMap { $0 }.max() ?? 0
    var costs = Array(
      repeating: Array(repeating: maximumWeight, count: size),
      count: size
    )
    for row in 0..<rowCount {
      for column in 0..<columnCount {
        costs[row][column] = maximumWeight - weights[row][column]
      }
    }

    var rowPotential = Array(repeating: 0.0, count: size + 1)
    var columnPotential = Array(repeating: 0.0, count: size + 1)
    var matchedRow = Array(repeating: 0, count: size + 1)
    var predecessor = Array(repeating: 0, count: size + 1)

    for row in 1...size {
      matchedRow[0] = row
      var currentColumn = 0
      var minimum = Array(repeating: Double.infinity, count: size + 1)
      var used = Array(repeating: false, count: size + 1)
      repeat {
        used[currentColumn] = true
        let currentRow = matchedRow[currentColumn]
        var delta = Double.infinity
        var nextColumn = 0
        for column in 1...size where !used[column] {
          let reducedCost =
            costs[currentRow - 1][column - 1]
            - rowPotential[currentRow] - columnPotential[column]
          if reducedCost < minimum[column] {
            minimum[column] = reducedCost
            predecessor[column] = currentColumn
          }
          if minimum[column] < delta {
            delta = minimum[column]
            nextColumn = column
          }
        }
        for column in 0...size {
          if used[column] {
            rowPotential[matchedRow[column]] += delta
            columnPotential[column] -= delta
          } else {
            minimum[column] -= delta
          }
        }
        currentColumn = nextColumn
      } while matchedRow[currentColumn] != 0

      repeat {
        let previousColumn = predecessor[currentColumn]
        matchedRow[currentColumn] = matchedRow[previousColumn]
        currentColumn = previousColumn
      } while currentColumn != 0
    }

    var assignment: [Int: Int] = [:]
    for column in 1...size {
      let row = matchedRow[column]
      if row > 0 {
        assignment[row - 1] = column - 1
      }
    }
    return assignment
  }

  private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
    denominator == 0 ? 0 : Double(numerator) / Double(denominator)
  }
}
