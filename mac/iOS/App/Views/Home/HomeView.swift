import MindloomDesign
import MindloomPhoneKit
import MindloomWatchHandoff
import SwiftUI
import UIKit

/// Home (PHONE-SPEC §5.4): 「最近」 with the status line, what the user sent by day, the speak bar,
/// and the in-app listening moment over the whole screen.
struct HomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.openURL) private var openURL
  @State private var scrolled = false
  @State private var expanded: Set<String> = []
  @State private var viewer: ViewerTarget?
  @State private var tipVisible = false
  /// 「撤回」 came too late: the Mac already has (or is receiving) the item.
  @State private var withdrawRefused = false
  /// 「删除录音…」 asked for this item of a recording from Apple Watch.
  @State private var deletingRecording: HomeRow?

  /// DEBUG: a frozen moment of the listening animation (screenshots).
  var frozenTime: TimeInterval? = nil
  var reduceMotionOverride: Bool? = nil

  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let size = CGSize(
        width: proxy.size.width, height: proxy.size.height + insets.top + insets.bottom)
      content(size: size, top: insets.top, bottom: insets.bottom)
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .onAppear {
          updateLayout(size)
          #if DEBUG
            DebugLaunch.runAutoTalk(
              model.talk, bar: CGPoint(x: size.width / 2, y: size.height - 58))
          #endif
        }
        .onChange(of: size) { _, new in updateLayout(new) }
    }
    .background(MLColor.paper.dynamicColor.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .fullScreenCover(item: $viewer) { target in
      PhotoViewer(row: target.row, index: target.index)
    }
    .alert("未能撤回", isPresented: $withdrawRefused) {
      Button("好", role: .cancel) {}
    } message: {
      Text("Mac 已收到此内容。")
    }
    .alert(
      WatchRecordingInbox.BackupNotice.title,
      isPresented: Binding(
        get: { model.watchBackupNoticeShown },
        set: { if !$0 { model.watchBackupNoticeShown = false } })
    ) {
      Button(WatchRecordingInbox.BackupNotice.button, role: .cancel) {}
    } message: {
      Text(WatchRecordingInbox.BackupNotice.message)
    }
    .onChange(of: model.delivery.rows.count, initial: true) { _, _ in
      model.presentWatchBackupNoticeIfDue()
    }
    .alert(
      "删除这条录音？",
      isPresented: Binding(
        get: { deletingRecording != nil }, set: { if !$0 { deletingRecording = nil } }),
      presenting: deletingRecording
    ) { row in
      Button("删除录音", role: .destructive) {
        model.watchRecordings?.delete(id: row.id)
        deletingRecording = nil
      }
      Button("取消", role: .cancel) { deletingRecording = nil }
    } message: { _ in
      Text("这条录音和它的文字会从这台 iPhone 上删除，已发送到 Mac 的文字会保留。此操作无法撤销。")
    }
    .onAppear {
      #if DEBUG
        if let label = DebugLaunch.expandedLabel, let id = DebugLaunch.ids[label] {
          expanded.insert(id)
        }
        if let label = DebugLaunch.viewerLabel, let id = DebugLaunch.ids[label],
          let row = model.delivery.rows.first(where: { $0.id == id })
        {
          viewer = ViewerTarget(row: row, index: 0)
        }
      #endif
    }
    .onChange(of: model.showsBounceTip, initial: true) { _, shows in
      if shows {
        Task {
          try? await Task.sleep(for: .seconds(0.25))
          withAnimation(reduceMotion ? .easeOut(duration: 0.2) : MLMotion.springSmooth) {
            tipVisible = model.showsBounceTip
          }
        }
      } else {
        withAnimation(MLMotion.springSmooth) { tipVisible = false }
      }
    }
  }

  private func updateLayout(_ size: CGSize) {
    let layout = ListenerLayout.phoneNote(
      size: size, rest: CGPoint(x: size.width / 2 - 39, y: size.height - 58))
    if model.talk.listener.layout != layout { model.talk.listener.layout = layout }
  }

  @ViewBuilder
  private func content(size: CGSize, top: CGFloat, bottom: CGFloat) -> some View {
    let talk = model.talk
    let paused = frozenTime == nil && !talk.isActive
    TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
      let t = frozenTime ?? ListenerModel.now()
      let chrome = TalkChrome(talk: talk, time: t, reduceMotion: reduceMotion)
      ZStack(alignment: .topLeading) {
        HomeList(
          size: size, top: top, rows: model.delivery.rows, status: model.homeStatus,
          paired: model.pairing.isPaired, tipShift: tipVisible ? 34 : 0, expanded: $expanded,
          scrolled: $scrolled, lastSavedID: talk.lastSavedID,
          voiceEndsAt: voiceEndsAt,
          notice: model.dataInAppGroup ? HomeList.dataElsewhereNotice : nil,
          onAction: statusAction,
          onEndVoice: { model.voice.end() },
          onOpenPhoto: { row, index in viewer = ViewerTarget(row: row, index: index) },
          onOpenLink: { url in openURL(url) },
          onWithdraw: { row in
            if !model.delivery.withdraw(itemID: row.id) { withdrawRefused = true }
          },
          onRetryRecording: { row in model.watchRecordings?.retry(id: row.id) },
          onDeleteRecording: { row in deletingRecording = row }
        )
        .equatable()
        .opacity(chrome.list)
        .allowsHitTesting(chrome.list > 0.9)

        TopBar(size: size, top: top, scrolled: scrolled)
          .opacity(chrome.list)
          .allowsHitTesting(chrome.list > 0.9)

        if tipVisible {
          BounceTip()
            .padding(.leading, 12)
            .padding(.top, top + 6)
            .transition(
              .opacity.combined(with: .offset(y: reduceMotion ? 0 : -6)))
        }

        LiveWords(talk: talk, chrome: chrome, size: size)

        SpeakBar(
          size: size, chrome: chrome, microphone: model.voice.microphone,
          frozen: frozenTime != nil
        )

        if model.voice.microphone != .denied {
          ListenerView(
            model: talk.listener, time: t, reduceMotion: reduceMotion)
            .frame(width: size.width, height: size.height)
        }
      }
      .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
  }

  private func statusAction() {
    model.startPairing(fromFirstRun: false)
  }

  /// When the voice session ends by itself, shown on Home only while nothing else (the Live
  /// Activity) offers its 「结束」.
  private var voiceEndsAt: Date? {
    let voice = model.voice
    guard voice.isAlive, !voice.indicatorShown else { return nil }
    return voice.endsAt ?? voice.aliveUntil
  }
}

struct ViewerTarget: Identifiable {
  let row: HomeRow
  let index: Int
  var id: String { row.id + "-\(index)" }
}

// MARK: - The moment's chrome

/// Everything around the cord at one moment (PHONE-SPEC §7.9 "Chrome tied to the frame").
struct TalkChrome {
  var frame: ListenerFrame
  /// The list, title and gear.
  var list: Double = 1
  /// The bar's glass.
  var glass: Double = 1
  var glassBrightness: Double = 1
  /// 「按住说话」.
  var speakLabel: Double = 1
  /// 「已收好」 and 「撤销」.
  var saved: Double = 0
  /// × and ✓.
  var cancel: Double = 0
  var done: Double = 0
  var words: Double = 0
  var undoActive = false
  var hot = false

  @MainActor
  init(talk: TalkController, time t: TimeInterval, reduceMotion: Bool) {
    let listener = talk.listener
    frame = listener.frame(at: t)
    let snap = { (v: Double) -> Double in reduceMotion ? (v > 0.5 ? 1 : 0) : v }
    guard let press = listener.pressedAt else { return }
    let ss = MLMotion.springStep
    let smooth = { (u: Double) -> Double in
      let x = min(1, max(0, u))
      return x * x * (3 - 2 * x)
    }
    let released = listener.releasedAt.map { t >= $0 } ?? false
    let tr = listener.releasedAt.map { t - $0 } ?? 0
    let cancelled = listener.isCancelled
    let u = talk.resetAt.map { smooth((t - $0) / 0.25) } ?? 0
    // the list leaves before the lift and returns only after the landing
    list = snap(released ? ss(tr - 0.70 - 0.42, 0.3, 1) : 1 - ss(t - press, 0.2, 1))
    let pressPhase = frame.phase == .press
    glass = pressPhase ? 1 : snap(frame.keys)
    glassBrightness = pressPhase ? 0.94 : 1
    var label: Double
    if released {
      label = cancelled ? frame.keys * smooth((tr - 0.75) / 0.25) : 0
    } else {
      label = 1 - smooth((t - press - 0.06) / 0.10)
    }
    if talk.resetAt != nil { label = max(label, u) }
    speakLabel = snap(label)
    saved = snap(frame.saved * frame.keys * (1 - u))
    undoActive = saved > 0.5 && talk.resetAt == nil && talk.savedItemID != nil
    cancel = snap(frame.listen)
    done = talk.latched ? snap(frame.listen) : 0
    hot = talk.hot
    if !released {
      words = smooth((t - press - 0.2) / 0.2)
    } else if cancelled {
      words = 1 - smooth(tr / 0.15)
    } else {
      words = 1 - smooth((tr - 0.55) / 0.25)
    }
    if listener.isCancelled, !released { words = 0 }
  }
}

// MARK: - List

/// The scrolling part: title, status line, the days, the end line.
struct HomeList: View, Equatable {
  let size: CGSize
  let top: CGFloat
  let rows: [HomeRow]
  let status: HomeStatus
  let paired: Bool
  let tipShift: CGFloat
  @Binding var expanded: Set<String>
  @Binding var scrolled: Bool
  let lastSavedID: String?
  /// The voice session is on with no Live Activity: its line and 「结束」 under the status.
  let voiceEndsAt: Date?
  /// A line under the status (a build without the App Group after one with it).
  var notice: String? = nil
  let onAction: () -> Void
  let onEndVoice: () -> Void
  let onOpenPhoto: (HomeRow, Int) -> Void
  let onOpenLink: (URL) -> Void
  let onWithdraw: (HomeRow) -> Void
  /// Items of a recording from Apple Watch: 「重新转写」 and 「删除录音…」.
  let onRetryRecording: (HomeRow) -> Void
  let onDeleteRecording: (HomeRow) -> Void
  @State private var position = ScrollPosition(edge: .top)

  nonisolated static func == (a: HomeList, b: HomeList) -> Bool {
    a.size == b.size && a.top == b.top && a.rows == b.rows && a.status == b.status
      && a.paired == b.paired && a.tipShift == b.tipShift && a.expanded == b.expanded
      && a.scrolled == b.scrolled && a.lastSavedID == b.lastSavedID
      && a.voiceEndsAt == b.voiceEndsAt && a.notice == b.notice
  }

  /// The pairing and items of a build with the App Group are out of this build's reach.
  static let dataElsewhereNotice = "之前的配对和内容保存在这台 iPhone 上，重新签名安装后会恢复。"

  private var width: CGFloat { size.width - 40 }

  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Color.clear.frame(height: 0).id("top")
          header
          if rows.isEmpty {
            EmptyHome()
              .frame(width: size.width)
              .padding(.top, max(0, size.height * 0.38 - 113))
          } else {
            days
            if paired {
              Text("更早的内容在 Mac 上")
                .font(.system(size: 13))
                .foregroundStyle(MLColor.ink2)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 8, leading: 40, bottom: 0, trailing: 40))
            }
          }
          Color.clear.frame(height: 132)
        }
        .frame(width: size.width, alignment: .leading)
        .animation(MLMotion.springSmooth, value: rows.map(\.id))
      }
      .scrollIndicators(.hidden)
      .scrollPosition($position)
      .contentMargins(.top, top, for: .scrollContent)
      .onAppear {
        #if DEBUG
          if let offset = DebugLaunch.scrollOffset {
            Task {
              try? await Task.sleep(for: .seconds(0.3))
              position.scrollTo(y: offset)
            }
          }
        #endif
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.contentInsets.top > 30
      } action: { _, now in
        withAnimation(.easeOut(duration: MLMotion.durFast)) { scrolled = now }
      }
      .onChange(of: lastSavedID) { _, id in
        if id != nil { withAnimation(MLMotion.springSmooth) { reader.scrollTo("top", anchor: .top) } }
      }
      .mask {
        // no text beside the bar: opaque until H − 132, 30 % at H − 64, clear at H − 34
        LinearGradient(
          stops: [
            .init(color: .black, location: (size.height - 132) / size.height),
            .init(color: .black.opacity(0.3), location: (size.height - 64) / size.height),
            .init(color: .black.opacity(0), location: (size.height - 34) / size.height),
          ], startPoint: .top, endPoint: .bottom)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("最近")
        .font(PhoneTitleFont.font(28))
        .foregroundStyle(MLColor.ink)
        .frame(height: 34)
      StatusLine(status: status, onAction: onAction)
        .padding(.top, 3)
      if let voiceEndsAt {
        VoiceSessionLine(endsAt: voiceEndsAt, onEnd: onEndVoice)
          .padding(.top, 4)
      }
      if let notice {
        Text(notice)
          .font(.system(size: 13))
          .foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      }
    }
    .padding(.top, 52 + tipShift)
    .padding(.horizontal, 20)
  }

  private var days: some View {
    let groups = Self.group(rows)
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
        Text(group.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(MLColor.ink2)
          .frame(height: 18)
          .padding(EdgeInsets(top: index == 0 ? 24 : 16, leading: 20, bottom: 10, trailing: 20))
        ForEach(group.rows) { row in
          ItemView(
            row: row, width: width, expanded: expanded.contains(row.id),
            onExpand: { expanded.insert(row.id) },
            onOpenPhoto: { onOpenPhoto(row, $0) }, onOpenLink: onOpenLink
          )
          .padding(.horizontal, 20)
          .padding(.bottom, 24)
          .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 24, style: .continuous))
          .contextMenu {
            ItemMenu(
              row: row, onWithdraw: { onWithdraw(row) },
              onRetryRecording: { onRetryRecording(row) },
              onDeleteRecording: { onDeleteRecording(row) })
          } preview: {
            ItemPreview(row: row, width: width, expanded: expanded.contains(row.id))
          }
          .transition(.opacity.combined(with: .offset(y: -6)))
        }
      }
    }
  }

  struct DayGroup {
    let title: String
    var rows: [HomeRow]
  }

  static func group(_ rows: [HomeRow], now: Date = Date()) -> [DayGroup] {
    var groups: [DayGroup] = []
    for row in rows {
      let title = PhoneFormat.dayHeader(row.item.createdAt, now: now)
      if groups.last?.title == title {
        groups[groups.count - 1].rows.append(row)
      } else {
        groups.append(DayGroup(title: title, rows: [row]))
      }
    }
    return groups
  }
}

/// 「已安全送出 · 9:41」 and its siblings, with the inline 「连接」 / 「重新连接」.
struct StatusLine: View {
  let status: HomeStatus
  let onAction: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      (Text(status.lead).foregroundStyle(status.leadIsAlert ? MLColor.alert : MLColor.ink2)
        + Text(status.tail ?? "").foregroundStyle(MLColor.ink2))
        .font(.system(size: 13).monospacedDigit())
        .lineLimit(1)
      if let action = status.action {
        Button(action: onAction) {
          Text(action)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MLColor.accent)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .padding(-6)
      }
    }
    .frame(height: 18)
    .accessibilityElement(children: .combine)
  }
}

/// 「语音已开启 · 还剩 N 分钟」 and 「结束」: the session's off switch when there is no Live
/// Activity to carry it (Live Activities off, or a build without the widget). The microphone is
/// never open without a visible way to close it.
struct VoiceSessionLine: View {
  let endsAt: Date
  let onEnd: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      let minutes = max(1, Int(endsAt.timeIntervalSince(context.date) / 60))
      HStack(spacing: 8) {
        Text("语音已开启 · 还剩 \(minutes) 分钟")
          .font(.system(size: 13).monospacedDigit())
          .foregroundStyle(MLColor.ink2)
          .lineLimit(1)
        Button(action: onEnd) {
          Text("结束")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MLColor.accent)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .padding(-6)
      }
      .frame(height: 18)
      .accessibilityElement(children: .combine)
    }
  }
}

/// 「还没有东西」.
struct EmptyHome: View {
  var body: some View {
    VStack(spacing: 10) {
      Text("尚无内容")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(MLColor.ink)
      BodyText(
        text: "按住下方按钮说话，\n或从其他 App 分享内容。", size: 15, lineHeight: 21, color: .ink2,
        alignment: .center)
    }
  }
}

/// The nav row: the gear on glass; after 30 pt of scroll a solid paper band and the inline 「最近」.
struct TopBar: View {
  let size: CGSize
  let top: CGFloat
  let scrolled: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(
        stops: [
          .init(color: MLColor.paper.dynamicColor, location: 0),
          .init(color: MLColor.paper.dynamicColor, location: (top + 46) / (top + 68)),
          .init(color: MLColor.paper.dynamicColor.opacity(0.8), location: (top + 56) / (top + 68)),
          .init(color: MLColor.paper.dynamicColor.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom
      )
      .frame(width: size.width, height: top + 68)
      .opacity(scrolled ? 1 : 0)
      .allowsHitTesting(false)

      Text("最近")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(MLColor.ink)
        .frame(width: size.width - 144, height: 44)
        .padding(.leading, 72)
        .padding(.top, top + 4)
        .opacity(scrolled ? 1 : 0)
        .allowsHitTesting(false)

      NavigationLink(value: SettingsRoute.settings) {
        Image(systemName: "gearshape")
          .font(.system(size: 21))
          .foregroundStyle(MLColor.ink)
          .frame(width: 44, height: 44)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: Circle())
      .accessibilityLabel("设置")
      .padding(.leading, size.width - 60)
      .padding(.top, top + 4)
    }
  }
}

/// 「语音已开启 / 回到信息，按住说话就行」, pointing up at the system's 「◀ 信息」.
struct BounceTip: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("语音已开启")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(MLColor.ink)
        .frame(height: 20)
      Text("返回“信息”，按住即可说话")
        .font(.system(size: 14))
        .foregroundStyle(MLColor.ink2)
        .frame(height: 19)
    }
    .padding(EdgeInsets(top: 9, leading: 16, bottom: 10, trailing: 16))
    .background {
      // The card and its notch are one shape: one fill, one 0.5 pt ring, one shadow.
      TipShape()
        .fill(MLColor.surface)
        .shadow(color: Color(red: 0.16, green: 0.12, blue: 0.06).opacity(0.10), radius: 10, y: 6)
        .overlay(TipShape().stroke(MLColor.rule2, lineWidth: 0.5))
    }
    .accessibilityElement(children: .combine)
  }
}

/// The tip's card (radius 18) with its notch (an 11 pt square turned 45°, at left 22, top −5).
struct TipShape: Shape {
  func path(in rect: CGRect) -> Path {
    let card = Path(roundedRect: rect, cornerRadius: 18, style: .continuous)
    let side: CGFloat = 11
    let centre = CGPoint(x: rect.minX + 22 + side / 2, y: rect.minY - 5 + side / 2)
    let half = side / 2 * sqrt(2)
    var notch = Path()
    notch.move(to: CGPoint(x: centre.x, y: centre.y - half))
    notch.addLine(to: CGPoint(x: centre.x + half, y: centre.y))
    notch.addLine(to: CGPoint(x: centre.x, y: centre.y + half))
    notch.addLine(to: CGPoint(x: centre.x - half, y: centre.y))
    notch.closeSubpath()
    return card.union(notch)
  }
}

// MARK: - Long press

struct ItemMenu: View {
  let row: HomeRow
  let onWithdraw: () -> Void
  var onRetryRecording: () -> Void = {}
  var onDeleteRecording: () -> Void = {}

  var body: some View {
    Button {
      copy()
    } label: {
      Label("拷贝", systemImage: "doc.on.doc")
    }
    if let share = shareItem {
      ShareLink(item: share) {
        Label("分享", systemImage: "square.and.arrow.up")
      }
    } else if let image = shareImage {
      ShareLink(item: image, preview: SharePreview("照片", image: image)) {
        Label("分享", systemImage: "square.and.arrow.up")
      }
    }
    if row.item.recordingID != nil {
      // The item of a kept recording (Apple Watch) goes only with its recording.
      if row.item.text == nil, row.item.awaitingTranscription != true, !row.item.awaitingPairing,
        row.item.entryIDs.isEmpty
      {
        Button(action: onRetryRecording) {
          Label("重新转写", systemImage: "arrow.clockwise")
        }
      }
      Divider()
      Button(role: .destructive, action: onDeleteRecording) {
        Label("删除录音…", systemImage: "trash")
      }
    } else if row.onPhone || row.notSent {
      Divider()
      Button(role: .destructive, action: onWithdraw) {
        Label("撤回", systemImage: "arrow.counterclockwise")
      }
    }
  }

  private var shareItem: String? {
    switch row.item.kind {
    case .text: row.item.text.map(PhoneText.plain)
    case .link: row.item.link?.url
    case .file: row.item.fileTitle
    case .photos: nil
    }
  }

  private var shareImage: Image? {
    guard row.item.kind == .photos, let url = row.previews.first,
      let image = UIImage(contentsOfFile: url.path)
    else { return nil }
    return Image(uiImage: image)
  }

  private func copy() {
    switch row.item.kind {
    case .text: UIPasteboard.general.string = row.item.text.map(PhoneText.plain)
    case .link: UIPasteboard.general.string = row.item.link?.url
    case .file: UIPasteboard.general.string = row.item.fileTitle
    case .photos:
      if let url = row.previews.first, let image = UIImage(contentsOfFile: url.path) {
        UIPasteboard.general.image = image
      }
    }
  }
}

/// The lifted item: itself on `surface`, 386 wide (inset 8), radius 24, padding 14 12 12, at the
/// list's text measure.
struct ItemPreview: View {
  let row: HomeRow
  let width: CGFloat
  let expanded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ItemBody(row: row, width: width, expanded: true)
      MetaRow(row: row).padding(.top, 6)
    }
    .frame(width: width, alignment: .leading)
    .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
    .background(MLColor.surface)
  }
}
