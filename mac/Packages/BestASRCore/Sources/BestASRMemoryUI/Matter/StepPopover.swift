import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S12 · The step popover (MAC-SPEC §7.1): source line,
// step, who · state, the quote in its two lines, 「同一场会还讲到 A · B」
// (`step.evidence?.alsoIn`), no-source text, 「这一天还有」, 打开原文 ·
// 标为完成 / 已经定了 · 移到别的事…. Corrections via `actions.correct`.

public struct StepPopoverInput: Equatable, Sendable {
  public let matter: MatterDigest
  public let stepID: String
  public let memberView: Bool
  /// The other steps sharing its mark (「这一天还有」 / 「同一天还有」).
  public let others: [MatterStep]
  /// The shared mark is a finished ● (「这一天还有」).
  public let othersFinished: Bool

  public init(
    matter: MatterDigest, stepID: String, memberView: Bool, others: [MatterStep] = [],
    othersFinished: Bool = true
  ) {
    self.matter = matter
    self.stepID = stepID
    self.memberView = memberView
    self.others = others
    self.othersFinished = othersFinished
  }
}

public struct StepPopover: View {
  @Environment(\.colorScheme) private var scheme
  let context: MindloomPageContext
  let input: StepPopoverInput

  public init(context: MindloomPageContext, input: StepPopoverInput) {
    self.context = context
    self.input = input
  }

  private var calendar: Calendar { context.state.calendar }
  private var today: Date { context.state.today }

  private func dayWord(_ date: Date) -> String {
    MemoryDigest.days(from: today, to: date, calendar: calendar) == 0
      ? "今天" : MindloomDates.monthDay(date, calendar: calendar)
  }

  public var body: some View {
    if let step = input.matter.step(input.stepID) {
      MatterPopoverChrome(label: MLAutospace.apply(step.text)) { content(step) }
    }
  }

  /// In a member's view the owner's own dictation stays theirs: its words,
  /// and the other matters it went into, are not shown.
  private func withheld(_ step: MatterStep) -> Bool {
    guard input.memberView, let word = step.evidence?.source.word else { return false }
    return word == "口述" || word == "键盘"
  }

  @ViewBuilder
  private func content(_ step: MatterStep) -> some View {
    let open = step.isOpenQuestion && !step.isDone
    let hidden = withheld(step)
    // 1. Where it was said.
    HStack(spacing: 5) {
      if let evidence = step.evidence {
        MLSymbol(evidence.source.symbol, size: 12, box: 13)
        Text(
          evidence.source.line + " · " + dayWord(evidence.time) + " "
            + MindloomDates.clock(evidence.time, calendar: calendar))
      } else {
        Image(systemName: "doc.text").font(.system(size: 12))
        Text("概况")
      }
    }
    .mlFont(\.foot, lineBox: true)
    .monospacedDigit()
    .foregroundStyle(MLColor.ink2)
    // 2. The step.
    Text(MLAutospace.apply(step.text))
      .mlFont(\.headline, lineBox: true)
      .foregroundStyle(MLColor.ink)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 6)
    // 3. Who · state.
    whoAndState(step, open: open)
      .mlFont(\.sub, lineBox: true)
      .foregroundStyle(MLColor.ink2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 1)
    if hidden {
      Text("此条来自\(context.state.sharing[input.matter.eventID]?.sharedBy ?? "对方")的口述，原文未共享。")
        .mlFont(\.sub, lineBox: true)
        .foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
    } else if let evidence = step.evidence {
      // 4. The words, the quoted span marked.
      if !evidence.lines.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          let markAt =
            evidence.lines.firstIndex {
              !evidence.quote.isEmpty && $0.words.contains(evidence.quote)
            }
            ?? 0
          ForEach(Array(evidence.lines.enumerated()), id: \.offset) { index, line in
            // Each speaker's words are their own paragraph with the 14/22
            // line box, 2 apart (prototype: 22 + 2), so paragraphs never sit
            // closer than lines.
            quoteLine(line, quote: index == markAt ? evidence.quote : nil, scheme: scheme)
              .mlFont(\.body, lineBox: true)
              .foregroundStyle(index == 0 ? MLColor.ink : MLColor.ink2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.top, 10)
        .textSelection(.enabled)
      }
      // 5. Only when the same capture was filed elsewhere too.
      let also = evidence.alsoIn.filter { context.state.matter($0.eventID) != nil }
      if !also.isEmpty {
        Text(alsoLine(lead: evidence.source.sameCaptureLead, also))
          .mlFont(\.sub, lineBox: true)
          .foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 10)
          .environment(
            \.openURL,
            OpenURLAction { url in
              guard url.scheme == "mindloom-matter",
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .first(where: { $0.name == "id" })?.value
              else { return .discarded }
              context.navigator.openMatter(id)
              return .handled
            })
      }
    } else {
      // 6. No source: say so; never invent one.
      Text(
        step.fromStatus
          ? "这个日期写在这件事的概况中（\(MindloomDates.monthDay(input.matter.lastDay ?? today, calendar: calendar))），原文中未找到相应的内容。"
          : "此条没有原文。"
      )
      .mlFont(\.sub, lineBox: true)
      .foregroundStyle(MLColor.ink2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 10)
    }
    // 7. The same mark.
    if !input.others.isEmpty {
      VStack(alignment: .leading, spacing: 1) {
        Text(input.othersFinished ? "这一天还有" : "同一天还有")
          .mlFont(\.foot, lineBox: true)
          .foregroundStyle(MLColor.ink2)
          .padding(.bottom, 4)
        ForEach(input.others) { other in
          PopoverRow {
            context.navigator.openPopover(.step(other.id))
          } label: {
            MLStatusCircle(other.isDone ? .done : .next).alignmentGuide(.firstTextBaseline) {
              $0[.bottom]
            }
            Text(MLAutospace.apply(other.text)).foregroundStyle(MLColor.ink)
          }
        }
      }
      .padding(.top, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .top) { Rectangle().fill(MLColor.rule).frame(height: 0.5) }
      .padding(.top, 12)
    }
    // 8. Actions.
    HStack(spacing: 6) {
      if let evidence = step.evidence, !hidden {
        Button("打开原文") {
          context.navigator.openMatter(
            input.matter.eventID, tab: .text, revealRow: evidence.rowID)
        }
        .buttonStyle(MLButtonStyle(.tinted, small: true))
      } else {
        Button("查看原文") { context.navigator.setTab(.text) }
          .buttonStyle(MLButtonStyle(.tinted, small: true))
      }
      if !step.isDone, !input.memberView {
        Button(open ? "已确定" : "标记为完成") {
          context.navigator.openPopover(nil)
          context.actions.correct(
            .markStep(
              eventID: input.matter.eventID, stepID: step.id, state: open ? .settled : .done,
              previous: step.override))
        }
        .buttonStyle(MLButtonStyle(.standard, small: true))
      }
      Spacer(minLength: 0)
      if !input.memberView, step.evidence != nil {
        Button("移到其他事…") {
          context.navigator.openPopover(nil)
          context.navigator.present(.move(.step(eventID: input.matter.eventID, stepID: step.id)))
        }
        .buttonStyle(MLButtonStyle(.plain, small: true))
      }
    }
    .padding(.top, 14)
  }

  /// 「同一场会还讲到 A · B」: each title a link to that matter; wraps,
  /// never cut.
  private func alsoLine(lead: String, _ also: [MatterRef]) -> AttributedString {
    var line = AttributedString(lead + " ")
    for (index, ref) in also.enumerated() {
      if index > 0 { line += AttributedString(" · ") }
      var title = AttributedString(MLAutospace.apply(ref.title))
      var link = URLComponents()
      link.scheme = "mindloom-matter"
      link.host = "open"
      link.queryItems = [URLQueryItem(name: "id", value: ref.eventID)]
      title.link = link.url
      title.foregroundColor = MLColor.accent.color(for: scheme)
      line += title
    }
    return line
  }

  private func whoAndState(_ step: MatterStep, open: Bool) -> Text {
    let who = step.who.filter { !$0.isEmpty && $0 != "我" }
    let lead = who.isEmpty ? Text("") : Text(who.joined(separator: "、") + " · ")
    let date = MindloomDates.monthDay(step.date, calendar: calendar)
    let full = MindloomDates.dayTitle(step.date, calendar: calendar)
    if open {
      let asked = step.evidence.map { " · " + dayWord($0.time) + "提出" } ?? ""
      return lead + Text("尚未确定" + asked)
    }
    if step.isDone {
      return lead + Text(date + (step.kind == "decision" ? "定下" : "完成"))
    }
    if step.over {
      return lead + Text(date + " 已过期").foregroundStyle(MLColor.alert)
    }
    if let word = MindloomDates.dueWord(step.date, today: today, calendar: calendar) {
      return lead + Text(word + "到期").foregroundStyle(MLColor.alert) + Text(" · " + full)
    }
    return lead + Text(full)
  }
}

/// A row inside a popover (这一天还有, 经过): padding 3 8, radius 6, hover
/// `--fill-2`, sub type.
struct PopoverRow<Label: View>: View {
  let action: () -> Void
  let label: Label
  @State private var hovering = false

  init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
    self.action = action
    self.label = label()
  }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 8) { label }
        .mlFont(\.sub, lineBox: true)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? MLColor.fill2 : MLColor.transparent)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, -8)
    .onHover { hovering = $0 }
  }
}
