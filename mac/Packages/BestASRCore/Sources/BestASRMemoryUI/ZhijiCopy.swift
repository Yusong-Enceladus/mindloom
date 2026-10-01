import Foundation

/// Every fixed string of the memory pages, in one place so the copy rules can
/// be checked: state the result, never the mechanism (no "AI", "本地", "模型",
/// "Spark", "GPU", "加密"); people are names or "?"; one yes/no at a time;
/// the fewest words that stay true, without exclamation marks.
public enum ZhijiCopy {
  // Sidebar
  public static let home = "首页"
  public static let people = "人物"
  public static let dictionary = "词典"
  public static let settings = "设置"
  public static let recording = "正在记录"
  public static let recordingPaused = "记录已暂停"
  public static let importing = "正在导入"
  public static let inPerson = "当面"

  // Home
  public static let segmentEvents = "事件"
  public static let segmentAll = "全部"
  public static let searchPrompt = "搜索说过的话、人、事"
  public static let homeTitle = "最近的事"
  public static let nameSomeone = "起个名"
  public static let show = "查看"
  public static let yes = "是"
  public static let no = "不是"
  public static func unfiledRow(_ count: Int) -> String { "\(count) 条还没归到事里" }
  public static let emptyTitle = "说过的话、收进来的东西，会在这里变成一件件事"
  public static let emptyDictation = "按 Fn 说话"
  public static let emptyPaste = "⌘V 收进来"
  public static let emptyDrop = "拖进窗口"
  public static let noMatches = "没有找到"
  /// Under the first cards when there are more events.
  public static let showMore = "显示更多"
  /// After the people row when more people are known than it shows.
  public static let allPeople = "全部人物"
  /// Under the Unfiled row while nothing is organized into an event yet.
  public static let noEventsYet = "归好的事会出现在这里"
  public static func fixesNotTaken(_ count: Int) -> String { "\(count) 处修改没有生效" }
  public static let retry = "重试"
  public static let confirmDelivery = "确认送达"
  public static let discard = "放弃"

  // Card menu
  public static let copyAsText = "复制为文本"
  public static let exportAsText = "导出为文本…"
  public static let pin = "置顶"
  public static let unpin = "取消置顶"
  public static let featureLess = "少推荐这类"
  public static let more = "更多"
  public static let open = "打开"

  // Event page
  public static let back = "首页"
  public static func itemCount(_ count: Int) -> String { "\(count) 条" }
  public static let summary = "摘要"
  public static let showAll = "全部"
  public static let related = "相关的事"
  public static let notThisEvent = "这不是这件事的"
  public static let moveTo = "移到…"
  public static let fileInto = "放进…"
  public static let ownEvent = "单独成一件事"
  public static let play = "播放"
  public static let stop = "停止"
  public static let dictationKind = "口述"
  public static let textKind = "文字"
  public static let imageKind = "截图"
  public static let documentKind = "文档"
  /// A frame taken from a video, shown under the recording.
  public static let keyframeKind = "视频画面"
  public static func keyframeAt(_ clock: String) -> String { "视频画面 \(clock)" }
  public static func videoFrames(_ count: Int) -> String { "视频画面 \(count) 张" }
  public static let showFullText = "展开全文"
  public static let hideFullText = "收起全文"
  /// A file the organizing device has not read yet.
  public static let fileNotReadYet = "整理设备还没读这个文件"
  public static func filesInside(_ count: Int) -> String { "里面有 \(count) 个文件" }
  public static func attachmentsCount(_ count: Int) -> String { "附件 \(count) 个" }
  /// A meeting App's exported transcript (腾讯会议, 飞书, Zoom).
  public static let transcriptKind = "会议记录"
  public static let importKind = "导入"
  public static func inApp(_ app: String) -> String { "在「\(app)」" }
  public static func fromApp(_ app: String) -> String { "来自 \(app)" }
  public static let removedItem = "这条已经删掉了"
  public static let noText = "没有文字"
  /// Under a collapsed conversation that has more turns than it shows.
  public static func moreTurns(_ count: Int) -> String { "…还有 \(count) 句" }
  public static let meetingWord = "会议"
  public static let noteWord = "笔记"
  /// Under a part of a record that other events hold parts of too.
  public static func sameRecordAlso(_ word: String, _ count: Int) -> String {
    "同一段\(word)还涉及 \(count) 件事"
  }
  /// The organizing device's one-line summary of a screenshot, shown apart
  /// from what it read (the export uses the same label).
  public static func readingSummary(_ text: String) -> String { "读图概要：\(text)" }
  public static let rename = "改名"
  public static let expanded = "已展开"
  public static let collapsed = "已收起"
  public static let findEvent = "找一件事"
  /// A status fact's state, for VoiceOver ("已定：房租涨 200").
  public static func factState(_ state: String) -> String {
    switch state {
    case "planned": "要做"
    case "in_progress": "在办"
    case "done": "已定"
    case "cancelled": "不做了"
    default: ""
    }
  }

  // Person page
  public static func appearsIn(_ count: Int) -> String { "出现在 \(count) 件事" }
  public static func lastSeen(_ day: String) -> String { "最近一次 \(day)" }
  public static let listen = "听一段声音"
  public static let reviewTitle = "帮我确认一下"
  public static let theirEvents = "有这个人的事"
  public static let theirWords = "说过的话"
  public static let peopleTitle = "人物"
  public static let noPeople = "有人说话之后，会出现在这里"

  // Unfiled
  public static let unfiledTitle = "还没归到事里"
  public static let unfiledEmpty = "都归好了"

  // Toast
  public static let changeSource = "改来源"
  public static let sourcePrompt = "来源"
  public static let save = "保存"
  public static let cancel = "取消"
  public static let namePrompt = "名字"

  // First-run setup above Home
  public static let setupFirstUse = "首次使用"
  public static func setupStep(_ step: Int, of total: Int, _ title: String) -> String {
    "第 \(step) 步，共 \(total) 步 · \(title)"
  }
  public static let setupStartupFailed = "资料库没有打开；重新打开织机再试"
  public static let setupResume = "继续首次设置"

  // 最近在动的事 (Home's time axis)
  public static let loomTitle = "最近在动的事"
  public static let otherEvents = "其他在进行的事"
  public static let byRecent = "按最近动过排序"
  public static let lookAtPerson = "看某个人"
  public static let everyone = "全部"
  public static let loomNextWeek = "接下来一周"
  public static let openThisDay = "打开这一天 →"
  /// Home's line under the date: "过去两周动过 11 件事，其中 5 件在这张图上".
  public static func homeSummary(weeks: Int, moved: Int, shown: Int) -> String {
    let span = weeks == 2 ? "两周" : (weeks == 5 ? "五周" : "\(weeks) 周")
    guard moved > 0 else { return "过去\(span)没有新动静" }
    let head = "过去\(span)动过 \(moved) 件事"
    return shown > 0 ? "\(head)，其中 \(shown) 件在这张图上" : head
  }
  public static func dueToday(_ count: Int) -> String { "今天到期 \(count) 件" }
  public static func dueTomorrow(_ count: Int) -> String { "明天 \(count) 件" }
  public static func questionsWaiting(_ count: Int) -> String { "\(count) 个问题等你确认" }
  public static let loomTwoWeeks = "2周"
  public static let loomFiveWeeks = "5周"
  public static let loomNext = "接下来"
  public static let loomToday = "今天"
  public static let loomTomorrow = "明天"
  public static let loomDayAfter = "后天"
  public static func loomItems(_ count: Int) -> String { "\(count) 条" }
  /// "一场会 · 3 件事": one item filed into several matters.
  public static func loomWeft(_ what: String, _ matters: Int) -> String {
    "\(what) · \(matters) 件事"
  }
  public static let loomMeeting = "一场会"
  public static let loomChat = "一段聊天"
  public static let loomPhone = "一条手机消息"
  public static let loomDictation = "一段口述"
  public static let loomImage = "一张截图"
  public static let loomFile = "一份文件"
  public static func loomLane(_ title: String, _ count: Int, _ last: String) -> String {
    "\(title)，\(count) 条，最近一次 \(last)"
  }
  public static func loomNextStep(_ day: String) -> String { "下一步 \(day)" }

  // v7: a matter's lenses (线索 / 结构 / 网 / 文本)
  public static let lensStrands = "线索"
  public static let lensStructure = "结构"
  public static let lensNet = "网"
  public static let lensText = "文本"
  public static let lensStrandsCaption = "主线分出子线索，了结后并回来；点一个结看原话"
  public static let lensStructureCaption = "一眼看这件事里有什么，时间和进度在「线索」里"
  public static let lensNetCaption = "虚线是一起出现过，箭头是在等"
  public static let lensTextCaption = "和复制出去的文本一样。"
  public static let drafting = "正在整理线索…"
  public static let draftingDetail = "先把已经知道的进展放在一条线上。"
  public static let redrawing = "有内容删掉了，线索正在重画"
  public static let mainThread = "主线"
  public static let closedStrand = "已了结"
  public static func nowHeader(_ day: String) -> String { "现在 · \(day)" }
  public static let nowLabel = "现在"
  public static let healthOK = "顺利"
  public static let healthRisk = "有风险"
  public static let healthStuck = "卡住了"
  public static let dueTodayWord = "今天到期"
  public static let dueTomorrowWord = "明天到期"
  public static func dueIn(_ days: Int) -> String { "还有 \(days) 天" }
  public static func overdue(_ days: Int) -> String { "过期 \(days) 天" }
  public static func promises(_ count: Int) -> String { "答应的事 \(count) 件" }
  public static func openQuestions(_ count: Int) -> String { "还没解决 \(count) 个" }
  public static let waitsOn = "在等"
  public static let waitedBy = "被它等"
  public static let nextStep = "下一步"
  /// v8 (V8 contract A5): written only when clicked.
  public static let addNextStepToReminders = "把下一步加到提醒事项"
  public static let stillOpen = "还没解决"
  public static let decided = "定下来的"
  public static let promised = "答应的事"
  public static let pickAKnot = "点一个结，看它依据的原话"
  public static func evidenceCount(_ count: Int) -> String { "\(count) 条素材作证" }
  public static let theWords = "原话"
  public static let openSource = "打开原文"
  public static let dateFromEvidence = "日期按素材推算"
  public static func knotState(_ glyph: String) -> String {
    switch glyph {
    case "done": "完成"
    case "doing": "进行中"
    case "planned": "计划、截止"
    case "decision": "决定"
    default: "还没解决"
    }
  }
  public static func knotKind(_ kind: String) -> String {
    switch kind {
    case "decision": "决定"
    case "question": "问题"
    case "commitment": "答应"
    case "deadline": "截止"
    default: "进展"
    }
  }
  public static let legendDone = "完成"
  public static let legendDoing = "进行中"
  public static let legendPlanned = "计划、截止"
  public static let legendDecision = "决定"
  public static let legendQuestion = "还没解决"
  public static let legendSources = "来源：会议 聊天 手机 口述 截图 文件"
  public static func strandItems(_ count: Int) -> String { "\(count) 条" }
  public static func crossed(_ count: Int) -> String { "交叉 \(count) 次" }
  public static func crossedDetail(_ count: Int) -> String {
    "在同一场会或同一条消息里出现过 \(count) 次"
  }
  public static let touchingMatters = "接触到的事"
  public static let hideCrossing = "不相关，隐藏"
  public static let notWaiting = "不是在等它"
  public static let branchProgress = "进展"
  public static let branchProgressDetail = "按线索"
  public static let branchDecisions = "决定"
  public static let branchNext = "下一步"
  public static let branchQuestions = "问题"
  public static let branchPeople = "人"
  public static let branchPeopleDetail = "说到的人"
  public static let branchMaterials = "材料"
  public static let branchMaterialsDetail = "按来源"
  public static func strandCount(_ count: Int) -> String { "\(count) 条线索" }
  public static let noRelations = "还没有和别的事交叉、也没有在等别的事"
  public static let ropeWord = "绳"
  public static let sameRope = "同一根绳"
  public static let blocksLegend = "在等"
  public static let crossLegend = "一起出现过"

  // v7: Home lenses (按时间 / 按绳 / 按截止 / 按人)
  public static let byTime = "按时间"
  public static let byRope = "按绳"
  public static let byDeadline = "按截止"
  public static let byPerson = "按人"
  public static let ropesCaption = "一件事只在一根绳上，缩进的是绳里的绳"
  public static let noRopesYet = "还没有归好的绳，事多起来以后会拧成股"
  public static let ropeArea = "领域"
  public static let ropeProject = "项目"
  public static let proposedRope = "建议"
  public static let confirmRope = "确认"
  public static let rejectRope = "不对"
  public static let renameRope = "改名"
  public static let moveToRope = "移到另一根绳…"
  public static let offRope = "不放在任何绳上"
  public static let unroped = "还没归到绳上的事"
  public static func mattersCount(_ count: Int) -> String { "\(count) 件" }
  /// Steps on the 按截止 ladder (a matter can have several).
  public static func stepsCount(_ count: Int) -> String { "\(count) 项" }
  public static func moreMatters(_ count: Int) -> String { "还有 \(count) 件" }
  public static let collapse = "收起"
  public static let rungJustPassed = "刚过去"
  public static let rungToday = "今天"
  public static let rungTomorrow = "明天"
  public static let rungThisWeek = "这周"
  public static let rungLater = "以后"
  public static let notMarkedDone = "还没标成完成"
  public static let afterAWeek = "一周以后"
  public static let nothing = "没有"
  public static func personMatters(_ count: Int) -> String { "\(count) 件事" }
  public static let ropeBreadcrumb = "在绳上"
  public static func ropeLabel(_ title: String, proposed: Bool) -> String {
    proposed ? "\(title)（建议）" : title
  }

  /// Everything above that is fixed text, for the copy-rule test.
  public static var allFixedText: [String] {
    [
      home, people, dictionary, settings, recording, recordingPaused, importing, inPerson,
      segmentEvents, segmentAll, searchPrompt, homeTitle, nameSomeone, show, yes, no, unfiledRow(3),
      emptyTitle, emptyDictation, emptyPaste, emptyDrop, noMatches, copyAsText, exportAsText,
      pin, unpin, featureLess, back, itemCount(6), summary, showAll, related, notThisEvent, moveTo,
      fileInto, ownEvent, play, stop, dictationKind, textKind, imageKind, documentKind,
      keyframeKind, keyframeAt("0:12"), videoFrames(4), showFullText, hideFullText,
      fileNotReadYet, filesInside(3), attachmentsCount(2),
      importKind, transcriptKind, inApp("备忘录"), fromApp("微信"), removedItem, noText, moreTurns(3),
      rename,
      readingSummary("姐姐约好了复查"), appearsIn(2),
      lastSeen("9月25日"), listen, reviewTitle, theirEvents, theirWords, peopleTitle, noPeople,
      unfiledTitle, unfiledEmpty, changeSource, sourcePrompt, save, cancel, namePrompt,
      noEventsYet, fixesNotTaken(2), retry, showMore, allPeople,
      sameRecordAlso(meetingWord, 2), sameRecordAlso(noteWord, 1), confirmDelivery, discard, more,
      open, expanded,
      collapsed, findEvent, factState("planned"), factState("in_progress"), factState("done"),
      factState("cancelled"), setupFirstUse, setupStep(1, of: 3, "允许录音与回写"),
      setupStartupFailed, setupResume,
      loomTitle, otherEvents, loomTwoWeeks, loomFiveWeeks, loomNext, loomToday, loomTomorrow,
      loomDayAfter, loomItems(3), loomWeft(loomMeeting, 3), loomChat, loomPhone, loomDictation,
      loomImage, loomFile, loomNextStep("10月2日"), byRecent, lookAtPerson, everyone,
      loomNextWeek, openThisDay, homeSummary(weeks: 2, moved: 11, shown: 5),
      homeSummary(weeks: 5, moved: 0, shown: 0), dueToday(3), dueTomorrow(2),
      questionsWaiting(1),
    ] + v7FixedText
  }

  static var v7FixedText: [String] {
    [
      lensStrands, lensStructure, lensNet, lensText, lensStrandsCaption, lensStructureCaption,
      lensNetCaption, lensTextCaption, drafting, draftingDetail, redrawing, mainThread,
      closedStrand, nowHeader("9月20日 周日"), nowLabel, healthOK, healthRisk, healthStuck,
      dueTodayWord, dueTomorrowWord, dueIn(3), overdue(1), promises(2), openQuestions(1),
      waitsOn, waitedBy, nextStep, addNextStepToReminders, stillOpen, decided, promised, pickAKnot,
      evidenceCount(3),
      theWords, openSource, dateFromEvidence, knotState("done"), knotState("doing"),
      knotState("planned"), knotState("decision"), knotState("question"), knotKind("progress"),
      knotKind("decision"), knotKind("question"), knotKind("commitment"), knotKind("deadline"),
      legendDone, legendDoing, legendPlanned, legendDecision, legendQuestion, legendSources,
      strandItems(4), crossed(3), crossedDetail(3), touchingMatters, hideCrossing, notWaiting,
      branchProgress, branchProgressDetail, branchDecisions, branchNext, branchQuestions,
      branchPeople, branchPeopleDetail, branchMaterials, branchMaterialsDetail, strandCount(2),
      noRelations, ropeWord, sameRope, blocksLegend, crossLegend, byTime, byRope, byDeadline,
      byPerson, ropesCaption, noRopesYet, ropeArea, ropeProject, proposedRope, confirmRope,
      rejectRope, renameRope, moveToRope, offRope, unroped, mattersCount(3), stepsCount(5),
      moreMatters(2),
      collapse, rungJustPassed, rungToday, rungTomorrow, rungThisWeek, rungLater, notMarkedDone,
      afterAWeek, nothing, personMatters(4), ropeBreadcrumb,
      ropeLabel("Twin-7真机实验", proposed: true),
    ]
  }

  /// Words the pages never show.
  public static let forbidden = ["AI", "本地", "模型", "Spark", "GPU", "加密", "说话人", "未命名"]
}
