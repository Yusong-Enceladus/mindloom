import MindloomLink
import MindloomPhoneKit
import SwiftUI

struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      HomeView()
    }
    .fullScreenCover(isPresented: $model.showsPairing) {
      PairingView(allowsLater: true)
    }
  }
}

/// Home: the connection, the big voice control, what is waiting to go to
/// the Mac, the keyboard guide and the privacy page.
struct HomeView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if model.voiceBanner, model.voice.isAlive { VoiceBackBanner() }
        VoiceCard()
        OutboxCard()
        KeyboardCard()
        linksCard
        Text("声音只在这台手机上转成文字。收进来的内容先在手机上锁好，只有你的 Mac 能打开。")
          .font(.loom(12))
          .foregroundStyle(Loom.tertiary)
          .padding(.horizontal, 4)
          .padding(.bottom, 24)
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
    }
    .background(Loom.page.ignoresSafeArea())
    // Content scrolls under a paper-coloured status bar, not through it.
    .safeAreaInset(edge: .top, spacing: 0) {
      Color.clear.frame(height: 0).background(Loom.page.opacity(0.96).ignoresSafeArea(edges: .top))
    }
    .toolbar(.hidden, for: .navigationBar)
    .refreshable {
      model.delivery.refresh()
      await model.delivery.deliver()
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("织机")
          .font(.loom(32, .semibold))
          .foregroundStyle(Loom.ink)
          .accessibilityAddTraits(.isHeader)
        ConnectionLabel()
      }
      Spacer()
      Image("Mark")
        .resizable()
        .interpolation(.high)
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }
    .padding(.top, 12)
  }

  private var linksCard: some View {
    LoomCard(padding: 0) {
      NavigationLink {
        PrivacyView()
      } label: {
        LinkRow(symbol: "lock.shield", title: "隐私", detail: "说的话去了哪里")
      }
      Divider().overlay(Loom.hairline).padding(.leading, 56)
      NavigationLink {
        PairingDetailView()
      } label: {
        LinkRow(
          symbol: "laptopcomputer.and.iphone", title: "连接的 Mac",
          detail: model.pairing.record?.label ?? "未连接")
      }
      Divider().overlay(Loom.hairline).padding(.leading, 56)
      NavigationLink {
        AcknowledgementsView()
      } label: {
        LinkRow(symbol: "doc.text", title: "开源许可", detail: nil)
      }
    }
  }
}

struct LinkRow: View {
  let symbol: String
  let title: String
  let detail: String?

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(Loom.accent)
        .frame(width: 26)
      Text(title).font(.loom(16)).foregroundStyle(Loom.ink)
      Spacer()
      if let detail {
        Text(detail).font(.loom(14)).foregroundStyle(Loom.secondary).lineLimit(1)
      }
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Loom.tertiary)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
  }
}

/// "已连接 · <Mac>" or "未连接 Mac", with the delivery state after it.
struct ConnectionLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(model.pairing.isPaired ? Loom.green : Loom.tertiary)
        .frame(width: 7, height: 7)
      if let record = model.pairing.record {
        Text("已连接 · \(record.label)")
          .font(.loom(14, .medium))
          .foregroundStyle(Loom.ink)
          .lineLimit(1)
      } else {
        Button("未连接 Mac · 去连接") { model.showsPairing = true }
          .font(.loom(14, .medium))
          .foregroundStyle(Loom.accent)
      }
    }
  }
}

/// After 织机键盘 opened the app: how to go back.
struct VoiceBackBanner: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "arrow.uturn.backward.circle.fill")
        .font(.system(size: 24))
        .foregroundStyle(Loom.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("语音已开启").font(.loom(15, .semibold)).foregroundStyle(Loom.ink)
        Text("点左上角的「◀︎」回到刚才的 App，按住麦克风说话").font(.loom(13))
          .foregroundStyle(Loom.secondary)
      }
      Spacer(minLength: 0)
      Button {
        model.voiceBanner = false
      } label: {
        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Loom.tertiary)
      }
      .accessibilityLabel("关闭")
    }
    .padding(14)
    .background(Loom.accentTint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - Voice

struct VoiceCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let voice = model.voice
    LoomCard(padding: 20) {
      switch voice.status {
      case .off, .starting:
        offState(starting: voice.status == .starting)
      case .preparingModel(let progress):
        preparing(progress)
      case .live:
        liveState
      case .unavailable(let problem):
        unavailable(problem)
      }
    }
    .animation(.easeInOut(duration: 0.25), value: voice.status)
  }

  private func offState(starting: Bool) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        MicBadge(active: false)
        VStack(alignment: .leading, spacing: 6) {
          Text("语音输入").font(.loom(20, .semibold)).foregroundStyle(Loom.ink)
          Text("开一次，接下来 10 分钟里，在微信、邮件或任何地方按住织机键盘的麦克风就能说话。")
            .font(.loom(14))
            .foregroundStyle(Loom.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Button {
        Task { await model.voice.start() }
      } label: {
        HStack(spacing: 8) {
          if starting { ProgressView().tint(Loom.onAccent) }
          Text(starting ? "正在开启…" : "开始语音")
        }
      }
      .buttonStyle(LoomPrimaryButtonStyle())
      .disabled(starting)
      Label("开着时，屏幕顶部会亮起麦克风指示。", systemImage: "info.circle")
        .font(.loom(12))
        .foregroundStyle(Loom.tertiary)
    }
  }

  private func preparing(_ progress: Double?) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        MicBadge(active: false)
        VStack(alignment: .leading, spacing: 4) {
          Text("正在准备中文语音").font(.loom(18, .semibold)).foregroundStyle(Loom.ink)
          Text("第一次使用需要下载系统自带的中文识别模型，之后不再联网。")
            .font(.loom(13)).foregroundStyle(Loom.secondary)
        }
      }
      if let progress {
        ProgressView(value: progress).tint(Loom.accent)
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    }
  }

  private var liveState: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 14) {
        MicBadge(active: true)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.voice.isListening ? "正在听" : "语音已开启")
            .font(.loom(20, .semibold))
            .foregroundStyle(Loom.ink)
          if let until = model.voice.aliveUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text("\(Self.remaining(until, now: context.date)) 后不用就自动关闭")
                .font(.loom(13).monospacedDigit())
                .foregroundStyle(Loom.secondary)
            }
          }
        }
      }
      LoomWaveform(
        level: model.voice.isListening ? 0.7 : 0.08, bars: 29,
        color: model.voice.isListening ? Loom.accent : Loom.accent.opacity(0.35)
      )
      .frame(height: 36)
      VStack(alignment: .leading, spacing: 8) {
        Label("回到任何 App，按住织机键盘的麦克风说话。", systemImage: "keyboard")
        Label("只有按住时才会转成文字，松开就写进去。", systemImage: "hand.tap")
        Label("开着时麦克风指示会一直亮着，这是正常的；没按住时说的话不会被转写。", systemImage: "mic")
      }
      .font(.loom(13))
      .foregroundStyle(Loom.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button("结束语音") { model.voice.end() }
        .buttonStyle(LoomSecondaryButtonStyle())
    }
  }

  private func unavailable(_ problem: VoiceProblem) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        MicBadge(active: false, warning: true)
        VStack(alignment: .leading, spacing: 4) {
          Text("语音暂时不能用").font(.loom(18, .semibold)).foregroundStyle(Loom.ink)
          Text(KeyboardCopy.problem(problem))
            .font(.loom(14))
            .foregroundStyle(Loom.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if problem == .microphoneDenied || problem == .speechDenied {
        Button("打开设置") {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
        .buttonStyle(LoomPrimaryButtonStyle())
      } else {
        Button("再试一次") { Task { await model.voice.start() } }
          .buttonStyle(LoomSecondaryButtonStyle())
      }
    }
  }

  static func remaining(_ until: Date, now: Date) -> String {
    let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

struct MicBadge: View {
  var active: Bool
  var warning = false

  var body: some View {
    ZStack {
      Circle()
        .fill(warning ? Loom.amberTint : (active ? Loom.accent : Loom.accentTint))
        .frame(width: 52, height: 52)
      Image(systemName: warning ? "mic.slash.fill" : "mic.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(warning ? Loom.amber : (active ? Loom.onAccent : Loom.accent))
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Outbox

struct OutboxCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let delivery = model.delivery
    LoomCard(padding: 20) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("送往 Mac").font(.loom(20, .semibold)).foregroundStyle(Loom.ink)
          // Re-read every minute: "上次送出 刚刚" must not stay "刚刚".
          TimelineView(.everyMinute) { context in
            Text(statusLine(now: context.date)).font(.loom(13)).foregroundStyle(Loom.secondary)
          }
        }
        HStack(spacing: 12) {
          StatTile(
            value: delivery.counts.queued, title: "待送出",
            tint: delivery.counts.queued > 0 ? Loom.amber : Loom.tertiary)
          StatTile(value: delivery.counts.sent, title: "已送出 · 等 Mac 取走", tint: Loom.green)
        }
        if delivery.recent.isEmpty {
          Text("用织机键盘说的话、从别的 App 分享给「收进织机」的东西，会先出现在这里。")
            .font(.loom(13))
            .foregroundStyle(Loom.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(delivery.recent.prefix(4).enumerated()), id: \.element.entryID) {
              index, entry in
              if index > 0 { Divider().overlay(Loom.hairline) }
              OutboxRow(entry: entry)
            }
          }
          if delivery.recent.count > 4 {
            NavigationLink {
              OutboxListView()
            } label: {
              Text("全部 \(delivery.recent.count) 条")
                .font(.loom(14, .medium))
                .foregroundStyle(Loom.accent)
            }
          }
        }
      }
    }
  }

  private func statusLine(now: Date) -> String {
    guard model.pairing.isPaired else { return "连接 Mac 之后，收进来的内容会锁好送过去" }
    switch model.delivery.status {
    case .idle: return "锁好之后经你的 Spark 交给 Mac"
    case .sending: return "正在送出…"
    case .sent(let date):
      return "上次送出 \(Self.relative(date, now: now))"
    case .waiting(let category): return Self.waiting(category)
    }
  }

  /// "刚刚" within a minute, then "3 分钟前" and so on, counted from `now`
  /// (the rows redraw from a minute timeline, so `now` must be honoured).
  static func relative(_ date: Date, now: Date = Date()) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "刚刚" }
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: date, relativeTo: now)
  }

  static func waiting(_ category: DeliveryErrorCategory) -> String {
    switch category {
    case .network, .timeout: return "连不上 Spark，有网络时会自动再送"
    case .protocolError: return "Spark 的回答不对，稍后会再试"
    case .hostKeyMismatch: return "Spark 的身份和配对时不一致，已停止送出。请在 Mac 上重新连接 iPhone"
    case .authentication: return "这台手机的钥匙已失效，请在 Mac 上重新连接 iPhone"
    case .relayRefused: return "中转机器拒绝转交，请在 Mac 上重新连接 iPhone"
    case .rejected: return "有一条内容被 Spark 拒收"
    case .notPaired: return "还没连接 Mac"
    }
  }
}

struct StatTile: View {
  let value: Int
  let title: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(value)")
        .font(.loom(28, .semibold).monospacedDigit())
        .foregroundStyle(Loom.ink)
        .contentTransition(.numericText())
      HStack(spacing: 5) {
        Circle().fill(tint).frame(width: 6, height: 6)
        Text(title).font(.loom(12)).foregroundStyle(Loom.secondary).lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Loom.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct OutboxRow: View {
  let entry: OutboxEntry

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Loom.accent)
        .frame(width: 30, height: 30)
        .background(Loom.accentTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.preview ?? "一张图片")
          .font(.loom(15))
          .foregroundStyle(Loom.ink)
          .lineLimit(1)
        // A row whose entry does not change is not redrawn by itself; the
        // timeline keeps "刚刚" from staying on screen for hours.
        TimelineView(.everyMinute) { context in
          Text("\(sourceName) · \(OutboxCard.relative(entry.createdAt, now: context.date))")
            .font(.loom(12))
            .foregroundStyle(Loom.tertiary)
        }
      }
      Spacer(minLength: 8)
      Text(entry.state == .sent ? "已送出" : "待送出")
        .font(.loom(12, .medium))
        .foregroundStyle(entry.state == .sent ? Loom.green : Loom.amber)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
          entry.state == .sent ? Loom.greenTint : Loom.amberTint, in: Capsule())
    }
    .padding(.vertical, 10)
  }

  private var symbol: String {
    switch entry.kind {
    case .text: entry.source == .keyboard ? "waveform" : "text.alignleft"
    case .link: "link"
    case .image: "photo"
    case .file: "doc"
    }
  }

  private var sourceName: String {
    entry.source == .keyboard ? "键盘" : "分享"
  }
}

struct OutboxListView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section {
        ForEach(model.delivery.recent, id: \.entryID) { entry in
          OutboxRow(entry: entry)
        }
      } footer: {
        Text("已送出的只在手机上留一行文字提示，7 天后自动删掉；图片不留。")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Loom.page)
    .navigationTitle("送往 Mac")
  }
}
