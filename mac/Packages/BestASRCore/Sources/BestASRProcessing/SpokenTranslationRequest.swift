import Foundation

/// The language a spoken instruction asks for, when it asks for a translation.
///
/// 指令 mode is one prompt doing everything, and translation is the one thing
/// a general prompt is measurably bad at: "翻译成中文" on an English selection
/// came back as a half-translated mix of the two languages (a synthetic
/// illustration: "我们 will go over 这个方案 next week."). Translating is a
/// different job from editing, so an instruction that asks for it is handed
/// to the system's translation engine rather than re-derived by the model.
///
/// Recognition is a small explicit table rather than a model call: it costs
/// nothing, it is testable, and when it does not match, the instruction falls
/// through to the general path unchanged.
public enum SpokenTranslationRequest {
  /// Whether the instruction asks for a translation at all, named language
  /// or not. "翻译一下" is a translation request whose target the caller
  /// picks; it must not fall through to the general model.
  public static func asksToTranslate(_ instruction: String) -> Bool {
    let text = instruction.lowercased()
    return ["翻译", "translate", "译成", "译为", "翻成"].contains { text.contains($0) }
  }

  public static func language(in instruction: String) -> String? {
    guard asksToTranslate(instruction) else { return nil }
    let text = instruction.lowercased()
    for (language, aliases) in aliases {
      if aliases.contains(where: { text.contains($0) }) { return language }
    }
    return nil
  }

  /// Language names as the user says them, mapped to the name the app uses.
  /// Ordered so a longer name is tested before one it contains.
  static let aliases: [(String, [String])] = [
    ("繁体中文", ["繁体", "繁體", "traditional chinese"]),
    ("简体中文", ["简体", "中文", "汉语", "漢語", "普通话", "chinese", "mandarin"]),
    ("英语", ["英文", "英语", "english"]),
    ("日语", ["日文", "日语", "japanese"]),
    ("韩语", ["韩文", "韩语", "korean"]),
    ("法语", ["法文", "法语", "french"]),
    ("德语", ["德文", "德语", "german"]),
    ("西班牙语", ["西班牙", "spanish"]),
    ("俄语", ["俄文", "俄语", "russian"]),
    ("葡萄牙语", ["葡萄牙", "portuguese"]),
    ("意大利语", ["意大利", "italian"]),
    ("阿拉伯语", ["阿拉伯", "arabic"]),
  ]
}
