import Foundation

/// Whether an instruction about highlighted text asks for something to read,
/// rather than something to write over the highlight.
///
/// "改短一点" wants the selection replaced. "这是什么意思" wants an answer
/// beside it, and replacing the paragraph with its explanation would destroy
/// the thing the question was about. Typeless draws the same line: rewrites
/// replace, questions get a panel.
public enum SpokenInstructionIntent {
  public static func showsAnswer(for instruction: String) -> Bool {
    let text = instruction.lowercased()
    return readingVerbs.contains { text.contains($0) }
  }

  static let readingVerbs = [
    "解释", "什么意思", "啥意思", "是什么", "总结", "概括", "翻译", "译成", "译为", "翻成",
    "explain", "what does", "what is", "summarize", "summarise", "translate",
  ]
}
