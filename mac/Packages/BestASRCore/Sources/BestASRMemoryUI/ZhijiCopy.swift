import Foundation

/// Words the shared building blocks use (item previews, controls, the setup
/// card the App still shows). Page words live with their pages; the v10
/// vocabulary (VOCABULARY.md) applies to all of them and
/// `VocabularyGuardTests` checks every string literal.
public enum ZhijiCopy {
  public static let settings = "设置"
  public static let recording = "正在记录会议"
  public static let recordingPaused = "已暂停"
  public static let importing = "正在添加"
  public static let inPerson = "当面"
  public static let nameSomeone = "添加姓名"
  public static let noMatches = "无结果"
  public static let yes = "是"
  public static let no = "不是"
  public static let play = "播放"
  public static let stop = "停止"
  public static let showFullText = "展开"
  public static let hideFullText = "折叠"
  /// A file the DGX Spark has not read yet: say nothing about the device.
  public static let fileNotReadYet = "尚未读取文字"
  public static func filesInside(_ count: Int) -> String { "包含 \(count) 个文件" }
  public static func attachmentsCount(_ count: Int) -> String { "附件 \(count) 个" }
  public static func videoFrames(_ count: Int) -> String { "视频画面 \(count) 张" }
  public static let removedItem = "此条内容已删除"
  public static let noText = "无文字"
  public static func moreTurns(_ count: Int) -> String { "…另有 \(count) 句" }
  public static func readingSummary(_ text: String) -> String { "截图中的文字：\(text)" }
  public static let rename = "重新命名"
  public static let findEvent = "搜索"
  public static let save = "保存"
  public static let cancel = "取消"

  // First-run setup cards (the App's own, until the Welcome window replaces them)
  public static let setupFirstUse = "首次使用"
  public static func setupStep(_ step: Int, of total: Int, _ title: String) -> String {
    "第 \(step) 步，共 \(total) 步 · \(title)"
  }
  public static let setupStartupFailed = "无法打开资料库。请重新打开 Mindloom 后重试。"
  public static let setupResume = "继续首次设置"
}
