import Foundation

/// Demo mode on screen (ALIGNMENT 根-10; review v12-B #7). The demo library
/// opens in the same App as the owner's own, so whoever is in front of it
/// must always be able to tell which one is showing: the sidebar says 「演示」
/// above 设置, the menu bar's menu starts with a grey line, and the dictation
/// HUD says when a take is not kept. A demo launch exists only through its
/// launch arguments, so anything that would open the App again (a permission
/// that asks for a relaunch) says to open it the demo way again.
public enum MindloomDemoMarker {
  /// The sidebar's word.
  public static let label = "演示"
  /// What it means, for the tooltip and VoiceOver.
  public static let detail = "正在使用演示资料库"
  public static let symbol = "theatermasks"
  /// The menu bar menu's first line.
  public static let menuHeader = "演示中 · 演示资料库"
  /// 屏幕与系统录音 was allowed and needs a relaunch, in demo mode.
  public static let relaunchForComputerSound = "以演示方式重新打开后可录制电脑声音"
}
