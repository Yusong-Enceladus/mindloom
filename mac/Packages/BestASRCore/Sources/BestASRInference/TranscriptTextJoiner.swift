import Foundation

/// Joins independently timestamped phrases without gluing English sentences
/// together or inserting spaces between Chinese phrases. Recognition, replay
/// and evaluation must use the same boundary rule.
public enum TranscriptTextJoiner {
  public static func join(_ pieces: [String]) -> String {
    var output = ""
    for rawPiece in pieces {
      let piece = rawPiece.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !piece.isEmpty else { continue }
      if let left = output.unicodeScalars.last,
        let right = piece.unicodeScalars.first,
        needsSpace(left: left, right: right)
      {
        output.append(" ")
      }
      output.append(piece)
    }
    return output
  }

  private static func needsSpace(left: Unicode.Scalar, right: Unicode.Scalar) -> Bool {
    let rightStartsWord = right.isASCII && CharacterSet.alphanumerics.contains(right)
    let leftEndsWord = left.isASCII && CharacterSet.alphanumerics.contains(left)
    let leftEndsPhrase = ".,!?;:)]\"'”’".unicodeScalars.contains(left)
    return rightStartsWord && (leftEndsWord || leftEndsPhrase)
  }
}
