import BestASRDictation
import BestASRDomain
import Foundation

/// Prevents a clearly regressed batch result from replacing a substantially
/// more complete live revision. Both results remain model-produced source
/// evidence; this only chooses which one becomes the final presentation
/// revision before polish and insertion.
public enum FinalTranscriptReconciler {
  public static func reconcile(
    final: DictationTranscriptResult,
    liveCandidates: [DictationTranscriptResult],
    parentRevisionID: TranscriptRevisionID,
    dictionaryTerms: [String]
  ) -> DictationTranscriptResult {
    let finalInformation = informationCount(final.text)
    guard
      let candidate = preferredCandidate(
        from: liveCandidates,
        dictionaryTerms: dictionaryTerms
      )
    else { return final }

    let candidateInformation = informationCount(candidate.text)
    guard candidateInformation >= 8,
      candidateInformation >= finalInformation + 6,
      finalInformation * 2 < candidateInformation
    else { return final }

    let sourceProvenance = candidate.provenance
    let finalProvenance = final.provenance
    return DictationTranscriptResult(
      revisionID: final.revisionID,
      segmentIDs: candidate.segmentIDs,
      text: candidate.text,
      modelArtifactID: candidate.modelArtifactID,
      provenance: DictationTranscriptProvenance(
        parentRevisionID: parentRevisionID,
        kind: .final,
        languageHints: finalProvenance?.languageHints
          ?? sourceProvenance?.languageHints ?? [],
        audioRanges: finalProvenance?.audioRanges
          ?? sourceProvenance?.audioRanges ?? [],
        segments: sourceProvenance?.segments ?? []
      )
    )
  }

  private static func preferredCandidate(
    from candidates: [DictationTranscriptResult],
    dictionaryTerms: [String]
  ) -> DictationTranscriptResult? {
    var selected: DictationTranscriptResult?
    var selectedScore = Int.min
    for candidate in candidates {
      let information = informationCount(candidate.text)
      guard information > 0 else { continue }
      let matches = dictionaryTerms.reduce(into: 0) { total, term in
        total += occurrenceCount(of: term, in: candidate.text)
      }
      let score = information + min(8, matches) * 16
      if score >= selectedScore {
        selected = candidate
        selectedScore = score
      }
    }
    return selected
  }

  private static func informationCount(_ text: String) -> Int {
    text.unicodeScalars.reduce(into: 0) { count, scalar in
      if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
    }
  }

  private static func occurrenceCount(of term: String, in text: String) -> Int {
    guard !term.isEmpty else { return 0 }
    let options: String.CompareOptions = [
      .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]
    var count = 0
    var cursor = text.startIndex
    while cursor < text.endIndex,
      let range = text.range(
        of: term,
        options: options,
        range: cursor..<text.endIndex
      )
    {
      count += 1
      cursor = range.upperBound
    }
    return count
  }
}
