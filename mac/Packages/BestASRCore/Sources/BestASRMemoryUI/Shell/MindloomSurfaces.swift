import Foundation

/// The Mac surfaces (MAC-SPEC §1.1) and the prototype's 76 demo states
/// (§1.2), with who builds each. The snapshot harness renders any state by
/// its ID; FOUNDATION.md maps the files.
public enum MindloomSurface: String, CaseIterable, Sendable {
  case s1 = "S1"  // Home · 按时间
  case s2 = "S2"  // Home · 按截止
  case s3 = "S3"  // Home · 按人
  case s4 = "S4"  // Home · empty
  case s5 = "S5"  // Person page
  case s6 = "S6"  // Matter · 进展
  case s7 = "S7"  // Matter · small page
  case s8 = "S8"  // Matter · 原文
  case s9 = "S9"  // Search
  case s10 = "S10"  // Group page
  case s11 = "S11"  // Shared space page
  case s12 = "S12"  // Popovers and tooltips
  case s13 = "S13"  // Menus in the window
  case s14 = "S14"  // Sheets
  case s15 = "S15"  // Toasts
  case s16 = "S16"  // Settings window
  case s17 = "S17"  // Welcome
  case s18 = "S18"  // Agent consent panel
  case s19 = "S19"  // fn HUD
  case s20 = "S20"  // Menu bar extra
  case s21 = "S21"  // App menus
  case s22 = "S22"  // Drop overlay

  public var owner: MindloomOwner {
    switch self {
    case .s1, .s2, .s3, .s4, .s5, .s9, .s10: .home
    case .s6, .s7, .s8, .s12: .matter
    case .s11, .s16, .s17, .s18, .s19, .s20, .s22: .capture
    case .s13, .s14: .home  // shared: matter menus/sheets are mac-matter's files
    case .s15, .s21: .foundation
    }
  }
}

/// One prototype state (`?s=<id>` in the prototype; `<id>-light.png` and
/// `<id>-dark.png` in `v10/prototype/mac/shots/`).
public struct MindloomStateID: Hashable, Sendable {
  public let id: String
  public let surface: MindloomSurface
  public let owner: MindloomOwner
  /// What it shows.
  public let summary: String

  /// The prototype's screenshot of this state.
  public func shot(dark: Bool) -> String {
    "/Users/Shared/mindloom-demo/v10/prototype/mac/shots/\(shotName)-\(dark ? "dark" : "light").png"
  }

  /// `dictation` is shot frozen at a moment (`dictation-listen`).
  public var shotName: String { id == "dictation" ? "dictation-listen" : id }

  /// MAC-SPEC §1.2, in order.
  public static let all: [MindloomStateID] = {
    let rows: [(String, MindloomSurface, MindloomOwner, String)] = [
      ("home", .s1, .home, "Home, 按时间 (default)"),
      ("home-earlier", .s1, .home, "Home, 更早 open, scrolled to 上周"),
      ("home-deadline", .s2, .home, "Home, 按截止"),
      ("home-people", .s3, .home, "Home, 按人"),
      ("home-menu", .s13, .home, "Home, right-click menu on the TES row"),
      ("captured", .s1, .home, "Home with one waiting capture under 刚收进来"),
      ("organized", .s1, .home, "Home after a dictation was filed: row lit, toast 已归进"),
      ("offline", .s1, .home, "DGX Spark not connected: Home line + 3 waiting captures"),
      ("empty", .s4, .home, "Home with nothing yet"),
      ("first-run", .s17, .capture, "Welcome step 0: title cinch, end state"),
      ("first-run-2", .s17, .capture, "Welcome step 1: permissions"),
      ("first-run-3", .s17, .capture, "Welcome step 2: 连接你的设备"),
      ("first-run-qr", .s17, .capture, "Welcome step 2: Spark connected, iPhone QR open"),
      ("matter", .s6, .matter, "Matter page (TES), 进展"),
      ("matter-popover", .s12, .matter, "Opened step k8 (meeting source, 同一场会还讲到)"),
      ("matter-due", .s12, .matter, "Opened status-line step st1 (原文里没找到)"),
      ("matter-open", .s12, .matter, "Opened 待定 question k5"),
      ("matter-fold", .s12, .matter, "Opened the segment of part s3 (经过)"),
      ("matter-same-day", .s12, .matter, "Opened k6, a mark shared with k7 (这一天还有)"),
      ("matter-text", .s8, .matter, "Matter page, 原文"),
      ("matter-text-menu", .s13, .matter, "原文 item ⋯ menu"),
      ("matter-dense", .s6, .matter, "Matter E3 SkillKnit (dense)"),
      ("matter-many", .s6, .matter, "Stress: E3 with 46 extra finished steps"),
      ("matter-offer", .s6, .matter, "Matter E25 (offer, due tomorrow)"),
      ("matter-small", .s7, .matter, "Matter E81 with no parts: 接下来 · 经过 · 原文"),
      ("matter-over", .s7, .matter, "Matter E61, overdue 截稿"),
      ("matter-menu", .s13, .matter, "Toolbar … matter menu"),
      ("matter-group-menu", .s13, .home, "Matter menu with 移到分组 submenu (E225)"),
      ("rename", .s6, .matter, "Inline rename of the matter title"),
      ("move-item", .s14, .matter, "Move picker for step k7 (移到哪件事？)"),
      ("move-text", .s14, .matter, "Move picker for a 原文 item"),
      ("long", .s1, .home, "Home with a very long title and status on the TES row"),
      ("matter-long", .s6, .matter, "Matter page with a very long title (E3)"),
      ("search", .s9, .home, "Search 回复信"),
      ("search-person", .s9, .home, "Search 雨桐 (人 first)"),
      ("search-none", .s9, .home, "Search with no results 火星基地"),
      ("search-empty", .s9, .home, "Sidebar 搜索 with nothing typed"),
      ("people", .s5, .home, "Person page 宋雨桐"),
      ("group", .s10, .home, "Group 论文"),
      ("group-new", .s14, .home, "新建分组 sheet with a typed name"),
      ("group-empty", .s10, .home, "Empty group 课题组杂事"),
      ("group-add", .s14, .home, "添加到「课题组杂事」 picker sheet"),
      ("space", .s11, .capture, "Shared space 实验室"),
      ("space-member", .s11, .capture, "A matter shared by someone else (E2, member view)"),
      ("space-members", .s14, .capture, "成员 sheet"),
      ("space-new", .s14, .capture, "新建共享空间 sheet"),
      ("invite", .s14, .capture, "邀请 sheet with code 4MQ7-K2XP"),
      ("error-code", .s14, .capture, "Join sheet with expired code"),
      ("share", .s14, .capture, "Share sheet (E25)"),
      ("share-look", .s14, .capture, "Share sheet with 查看会共享什么 open, 邮件 unticked"),
      ("share-shared", .s14, .capture, "Already shared (E6): 停止共享"),
      ("consent", .s18, .capture, "Claude Code asks to read TES"),
      ("consent-more", .s18, .capture, "Consent with 更多选项 open, 多久 = 今天"),
      ("settings-entries", .s16, .capture, "Settings › 入口"),
      ("settings-privacy", .s16, .capture, "Settings › 设备与隐私 (top)"),
      ("settings-privacy-more", .s16, .capture, "Settings › 设备与隐私 with 详细说明 open"),
      ("settings-devices", .s16, .capture, "Settings › 设备与隐私 scrolled to DGX Spark"),
      ("settings-iphone", .s16, .capture, "Settings › 连接 iPhone… QR open"),
      ("settings-offline", .s16, .capture, "Settings › 设备与隐私 with Spark not connected"),
      ("settings-apps", .s16, .capture, "Settings › 其他 App 的访问"),
      ("settings-about", .s16, .capture, "Settings › 关于"),
      ("dictation", .s19, .capture, "fn dictation (frozen at t)"),
      ("dictation-plain", .s19, .capture, "fn dictation with no text field: caption above HUD"),
      ("dictation-saved", .s19, .capture, "Dictation committed"),
      ("fn-tap", .s19, .capture, "Short fn tap hint"),
      ("error-mic", .s19, .capture, "Microphone permission off"),
      ("meeting-menu", .s20, .capture, "Menu bar extra menu (idle)"),
      ("meeting", .s20, .capture, "Recording 12:04 with the extra menu open"),
      ("meeting-bar", .s20, .capture, "Recording 12:04, menu closed"),
      ("meeting-discard", .s20, .capture, "放弃这次记录？ alert"),
      ("offline-menu", .s20, .capture, "Menu bar extra menu when Spark not connected"),
      ("drop", .s22, .capture, "Dragging a file over the window"),
      ("drop-video", .s22, .capture, "组会录像.mov dropped (toast + organized)"),
      ("drop-dup", .s22, .capture, "Same file dropped twice"),
      ("file-menu", .s21, .foundation, "文件 menu"),
      ("edit-menu", .s21, .foundation, "编辑 menu showing 撤销标为完成"),
    ]
    return rows.map { MindloomStateID(id: $0.0, surface: $0.1, owner: $0.2, summary: $0.3) }
  }()
}
