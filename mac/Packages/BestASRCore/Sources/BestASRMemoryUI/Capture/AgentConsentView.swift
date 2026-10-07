import AppKit
import BestASRDomain
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. S18 · The consent card (MAC-SPEC §11; v12 phase B, B5
// appendix C F2–F4, F9, F11): the App's tile, 「让 {app} 读「{matter}」？」, who
// it is in plain words (who signed it, where it is) and a warning when an App
// of the same name was allowed before but this is another program; then, all
// on the card (no folded options, B7 设计 9): what it may read (the smallest
// by default: this matter; 全部 and each shared space are ticks, unticked),
// how long (这次对话 · 今天 · 一直), numbers (遮住 · 原样), and 也可以改
// (unticked); one sentence that says exactly what 允许 does; 不允许 · 允许.
// 一直, 全部 and 也可以改 need Touch ID or the login password (the App asks).
// Hosted by the App in a floating panel that does not take the keyboard.

public enum ConsentDuration: String, CaseIterable, Sendable {
  case once
  case today
  case always

  /// 「这一次」 was the connection all along: it says so now (F4).
  public var title: String {
    switch self {
    case .once: "此次对话"
    case .today: "今天"
    case .always: "始终"
    }
  }
}

public struct AgentConsentInput: Equatable, Sendable {
  public struct Option: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
      self.id = id
      self.title = title
    }
  }

  public var appName: String
  /// 「Anthropic PBC 签名的程序 · ~/.local/share/claude/versions/…/claude」.
  public var whoLine: String
  /// Set when an App of the same name was allowed before and this is another
  /// program: the place of the one allowed before.
  public var lookalikePath: String?
  /// The matter the first call named (empty: none).
  public var matterTitle: String
  /// The matter's group (「同一分组」 is offered only with one).
  public var groupName: String?
  /// Matters to tick when the first call named none (recent first).
  public var matterChoices: [Option]
  /// Shared spaces, each its own tick.
  public var spaces: [Option]
  /// The requesting App's bundle on disk, for its icon (nil: the 「>_」 tile).
  public var appBundlePath: String?
  /// The first call wants to change something.
  public var wantsToChange: Bool
  public var duration: ConsentDuration
  public var showNumbers: Bool

  public init(
    appName: String, whoLine: String = "", lookalikePath: String? = nil, matterTitle: String,
    groupName: String? = nil, matterChoices: [Option] = [], spaces: [Option] = [],
    appBundlePath: String? = nil, wantsToChange: Bool = false, duration: ConsentDuration = .once,
    showNumbers: Bool = false
  ) {
    self.appName = appName
    self.whoLine = whoLine
    self.lookalikePath = lookalikePath
    self.matterTitle = matterTitle
    self.groupName = groupName
    self.matterChoices = matterChoices
    self.spaces = spaces
    self.appBundlePath = appBundlePath
    self.wantsToChange = wantsToChange
    self.duration = duration
    self.showNumbers = showNumbers
  }

  public var namesAMatter: Bool { !matterTitle.isEmpty }
}

/// What the owner ticked. nil = 不允许.
public struct AgentConsentChoice: Equatable, Sendable {
  /// Matters ticked from the list (when the first call named none).
  public var matterIDs: Set<String>
  /// Also the named matter's group.
  public var group: Bool
  /// 全部的事 (of 我的).
  public var all: Bool
  /// Shared spaces ticked (their IDs).
  public var spaces: Set<String>
  public var duration: ConsentDuration
  public var showNumbers: Bool
  /// 也可以改.
  public var canChange: Bool

  public init(
    matterIDs: Set<String> = [], group: Bool = false, all: Bool = false, spaces: Set<String> = [],
    duration: ConsentDuration = .once, showNumbers: Bool = false, canChange: Bool = false
  ) {
    self.matterIDs = matterIDs
    self.group = group
    self.all = all
    self.spaces = spaces
    self.duration = duration
    self.showNumbers = showNumbers
    self.canChange = canChange
  }

  /// 一直, 全部 and 也可以改 need the owner, not a click (F9; AGENT-IO N3): a
  /// program that can click the screen cannot pass Touch ID or the password.
  public var needsOwnerCheck: Bool { duration == .always || all || canChange }

  /// Something to read: the named matter, a ticked one, or 全部.
  public func readsSomething(namedMatter: Bool) -> Bool {
    namedMatter || all || !matterIDs.isEmpty
  }

  /// The ticks as grant terms (F2). The smallest is the default and nothing
  /// is widened behind the owner's back: 全部 (or the group) reads exactly
  /// the shared spaces ticked on the card, never one only because the agent
  /// named a matter in it (review v12-B #3). Only a grant of single matters
  /// carries the spaces those matters live in, since it reads nothing else
  /// there. `requestedMatterID` is the matter the request named (a shared
  /// space's is `space:<id>:<event>`); `groupOfRequestedMatter` its group.
  public func terms(requestedMatterID: String?, groupOfRequestedMatter: String?)
    -> AgentGrantTerms
  {
    var granted: Set<String> = [AgentSpaceID.personal]
    granted.formUnion(spaces)
    let range: AgentScopeRange
    if all {
      range = .all
    } else if group, requestedMatterID != nil, let groupID = groupOfRequestedMatter {
      range = .groups([groupID])
    } else {
      var matters = matterIDs
      if let requestedMatterID { matters.insert(requestedMatterID) }
      granted.formUnion(matters.compactMap(Self.space(ofMatter:)))
      range = .matters(matters)
    }
    let length: AgentGrantDuration =
      switch duration {
      case .once: .once
      case .today: .today
      case .always: .always
      }
    return AgentGrantTerms(
      spaces: granted, range: range, canChange: canChange, duration: length,
      showNumbers: showNumbers, askForNewMatters: false)
  }

  /// The shared space a matter lives in (`space:<id>:<event>`), or nil for
  /// the owner's own.
  static func space(ofMatter id: String) -> String? {
    guard id.hasPrefix("space:") else { return nil }
    let parts = id.split(separator: ":")
    return parts.count >= 3 ? String(parts[1]) : nil
  }

  /// The one sentence under the options: what 允许 does, exactly (F4).
  public func sentence(_ input: AgentConsentInput) -> String {
    let until =
      switch duration {
      case .once: "此次对话结束前"
      case .today: "今天"
      case .always: "直到你停止允许"
      }
    var what: String
    if all {
      what = "你的所有事"
    } else if input.namesAMatter {
      what = group ? "这件事及同一分组中的事" : "这件事"
    } else if matterIDs.isEmpty {
      what = "你选择的事"
    } else {
      what = "选择的 \(matterIDs.count) 件事"
    }
    if !spaces.isEmpty { what += "，以及选择的共享空间" }
    var sentence = "\(until)，\(input.appName) 可以读取\(what)的进展和原文。"
    if canChange {
      sentence += "它还可以添加内容、更改归属、重新命名和标记为完成。每次更改都可以在“设置”>“其他 App”中撤销。"
    }
    sentence += showNumbers ? "手机号和证件号完整提供。" : "手机号和证件号将被隐藏。"
    sentence += "它读取的内容会发送到它使用的模型。"
    return sentence
  }
}

public struct AgentConsentView: View {
  let input: AgentConsentInput
  let answer: @MainActor (AgentConsentChoice?) -> Void
  @State private var choice: AgentConsentChoice

  public init(
    input: AgentConsentInput, initial: AgentConsentChoice? = nil,
    answer: @escaping @MainActor (AgentConsentChoice?) -> Void = { _ in }
  ) {
    self.input = input
    self.answer = answer
    _choice = State(
      initialValue: initial
        ?? AgentConsentChoice(duration: input.duration, showNumbers: input.showNumbers))
  }

  /// 「让 {app} 读「{matter}」？」, or without a matter 「让 {app} 读你的事？」.
  private var title: String {
    input.namesAMatter
      ? "允许“\(input.appName)”读取“\(MLAutospace.apply(input.matterTitle))”？"
      : "允许“\(input.appName)”读取你在 Mindloom 中的事？"
  }

  public var body: some View {
    MindloomSheetChrome(width: 440, drawsCard: true) {
      HStack(spacing: 10) {
        ConsentAppTile(path: input.appBundlePath)
        BalancedText(title, size: 17, weight: .semibold, maxWidth: 340)
          .mlFont(\.title2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
      }
      .padding(.bottom, 8)
      if !input.whoLine.isEmpty {
        Text(input.whoLine).mlFont(\.foot).foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let previous = input.lookalikePath {
        Text("此 \(input.appName) 与你之前允许的不是同一个程序：签名或位置不同。之前允许的程序位于 \(previous)。")
          .mlFont(\.foot).foregroundStyle(MLColor.alert)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      }
      options.padding(.top, 12)
      SheetText(choice.sentence(input)).padding(.top, 12)
      if choice.needsOwnerCheck {
        Text("允许前需要使用触控 ID 或登录密码确认。").mlFont(\.foot).foregroundStyle(MLColor.ink2)
          .padding(.top, 4)
      }
      SheetActions {
        // Esc hides the card and refuses nothing (F11); 不允许 is a click.
        Button("不允许") { answer(nil) }
          .buttonStyle(MLButtonStyle(.standard))
        Button("允许") { answer(choice) }
          .buttonStyle(MLButtonStyle(.primary))
          .disabled(!choice.readsSomething(namedMatter: input.namesAMatter))
        // No Return: an agent's own terminal must never grant it access
        // (fix-mac). 允许 is a click.
      }
    }
  }

  private var options: some View {
    VStack(alignment: .leading, spacing: 10) {
      section("可读取") {
        if input.namesAMatter {
          ConsentTick(
            title: "这件事“\(MLAutospace.apply(input.matterTitle))”", isOn: true, fixed: true)
          if let group = input.groupName {
            ConsentTick(
              title: "同时读取分组“\(MLAutospace.apply(group))”中的事", isOn: $choice.group)
          }
        } else {
          ForEach(input.matterChoices) { option in
            ConsentTick(
              title: MLAutospace.apply(option.title),
              isOn: Binding(
                get: { choice.matterIDs.contains(option.id) },
                set: { on in
                  if on {
                    choice.matterIDs.insert(option.id)
                  } else {
                    choice.matterIDs.remove(option.id)
                  }
                }))
          }
        }
        ConsentTick(title: "所有事", isOn: $choice.all)
        ForEach(input.spaces) { space in
          ConsentTick(
            title: "共享空间“\(MLAutospace.apply(space.title))”",
            isOn: Binding(
              get: { choice.spaces.contains(space.id) },
              set: { on in
                if on { choice.spaces.insert(space.id) } else { choice.spaces.remove(space.id) }
              }))
        }
      }
      HStack(spacing: 12) {
        Text("期限").mlFont(\.callout).foregroundStyle(MLColor.ink)
        Spacer(minLength: 8)
        ConsentSegments(
          options: ConsentDuration.allCases.map { ($0, $0.title) }, selection: $choice.duration)
      }
      HStack(spacing: 12) {
        Text("手机号和证件号").mlFont(\.callout).foregroundStyle(MLColor.ink)
        Spacer(minLength: 8)
        ConsentSegments(
          options: [(false, "隐藏"), (true, "显示")], selection: $choice.showNumbers)
      }
      ConsentTick(
        title: input.wantsToChange ? "允许更改（此次请求包含更改）" : "允许更改",
        detail: "可以添加内容、更改归属、重新命名和标记为完成。更改立即生效，可以在“设置”中查看和撤销。",
        isOn: $choice.canChange)
    }
    .padding(14)
    .background(MLColor.paper2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).mlFont(\.callout).foregroundStyle(MLColor.ink)
      content()
    }
  }
}

/// An older grant asking matter by matter: 「让 {app} 读「{matter}」？」 with who
/// it is, 不允许 · 允许.
public struct AgentApprovalCard: View {
  let appName: String
  let whoLine: String
  let matterTitle: String
  let answer: @MainActor (Bool) -> Void

  public init(
    appName: String, whoLine: String, matterTitle: String,
    answer: @escaping @MainActor (Bool) -> Void
  ) {
    self.appName = appName
    self.whoLine = whoLine
    self.matterTitle = matterTitle
    self.answer = answer
  }

  public var body: some View {
    MindloomSheetChrome(width: 420, drawsCard: true) {
      BalancedText(
        "允许“\(appName)”读取“\(MLAutospace.apply(matterTitle))”？", size: 17, weight: .semibold,
        maxWidth: 360
      )
      .mlFont(\.title2)
      .accessibilityAddTraits(.isHeader)
      Text(whoLine).mlFont(\.foot).foregroundStyle(MLColor.ink2).padding(.top, 6)
      SheetActions {
        Button("不允许") { answer(false) }.buttonStyle(MLButtonStyle(.standard))
        Button("允许") { answer(true) }.buttonStyle(MLButtonStyle(.primary))
      }
    }
  }
}

/// One tick: a checkbox and its words (and a quiet line under them).
struct ConsentTick: View {
  let title: String
  var detail: String?
  @Binding var isOn: Bool
  var fixed = false

  init(title: String, detail: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.detail = detail
    _isOn = isOn
  }

  init(title: String, isOn: Bool, fixed: Bool) {
    self.title = title
    _isOn = .constant(isOn)
    self.fixed = fixed
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).mlFont(\.control).foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail).mlFont(\.foot).foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .toggleStyle(.checkbox)
    .disabled(fixed)
  }
}

/// The requesting App's icon, or a 40 pt tile with 「>_」 for a command-line
/// agent.
struct ConsentAppTile: View {
  let path: String?

  var body: some View {
    Group {
      if let path, FileManager.default.fileExists(atPath: path) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(red: 0x1F / 255, green: 0x1D / 255, blue: 0x19 / 255))
          .overlay(
            Text(">_").font(.system(size: 15, weight: .semibold, design: .monospaced))
              .foregroundStyle(Color(red: 0xF2 / 255, green: 0xEF / 255, blue: 0xE8 / 255)))
      }
    }
    .frame(width: 40, height: 40)
    .accessibilityHidden(true)
  }
}

/// A 24 pt segmented control (segments padding 0 10, `controlSmall`).
struct ConsentSegments<Value: Hashable>: View {
  let options: [(Value, String)]
  @Binding var selection: Value
  var disabled: Set<Value> = []

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options.indices, id: \.self) { i in
        let (value, title) = options[i]
        let on = value == selection
        Button {
          withAnimation(MLSpring.snappy.animation) { selection = value }
        } label: {
          Text(title)
            .font(.system(size: 12, weight: on ? .medium : .regular))
            .foregroundStyle(disabled.contains(value) ? MLColor.ink3 : MLColor.ink)
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background {
              if on {
                Capsule().fill(MLColor.surface2)
                  .overlay(Capsule().strokeBorder(MLColor.rule, lineWidth: 0.5))
                  .mlShadow(.thumb)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled.contains(value))
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
    .padding(2)
    .frame(height: 24)
    .background(Capsule().fill(MLColor.fill))
  }
}
