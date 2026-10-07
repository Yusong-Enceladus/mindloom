import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S12 · A part's 「经过」 popover (MAC-SPEC §7.2):
// 「{M月D日}起 · {n} 天收到过这部分的东西」, the part's name and summary, the
// folded steps (up to 12), 「更早的 {n} 条在「原文」里」, 打开原文.

public struct SegmentPopoverInput: Equatable, Sendable {
  public let matter: MatterDigest
  public let partID: String
  /// The steps folded into the part's segment, newest first.
  public let folded: [MatterStep]

  public init(matter: MatterDigest, partID: String, folded: [MatterStep] = []) {
    self.matter = matter
    self.partID = partID
    self.folded = folded
  }
}

public struct SegmentPopover: View {
  let context: MindloomPageContext
  let input: SegmentPopoverInput

  public init(context: MindloomPageContext, input: SegmentPopoverInput) {
    self.context = context
    self.input = input
  }

  private var calendar: Calendar { context.state.calendar }

  public var body: some View {
    let part = input.matter.parts.first { $0.id == input.partID }
    let name = part?.name ?? "其他"
    let days = (part?.days ?? []).filter { $0 <= context.state.today }
    MatterPopoverChrome(label: MLAutospace.apply(name)) {
      if let first = days.first {
        Text("\(MindloomDates.monthDay(first, calendar: calendar))起 · \(days.count) 天收到过这部分的内容")
          .mlFont(\.foot, lineBox: true)
          .monospacedDigit()
          .foregroundStyle(MLColor.ink2)
      }
      Text(MLAutospace.apply(name))
        .mlFont(\.headline, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, days.isEmpty ? 0 : 6)
      if let summary = part?.summary, !summary.isEmpty {
        Text(MLAutospace.apply(summary))
          .mlFont(\.body, lineBox: true)
          .foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
      }
      if !input.folded.isEmpty {
        VStack(alignment: .leading, spacing: 1) {
          Text("经过").mlFont(\.foot, lineBox: true).foregroundStyle(MLColor.ink2).padding(.bottom, 4)
          ForEach(input.folded.prefix(12)) { step in
            PopoverRow {
              context.navigator.openPopover(.step(step.id))
            } label: {
              Text(MindloomDates.monthDay(step.date, calendar: calendar))
                .monospacedDigit()
                .foregroundStyle(MLColor.ink2)
                .frame(width: 64, alignment: .leading)
              Text(MLAutospace.apply(step.text)).foregroundStyle(MLColor.ink)
            }
          }
          if input.folded.count > 12 {
            Text("更早的 \(input.folded.count - 12) 条在“原文”中")
              .mlFont(\.foot, lineBox: true)
              .foregroundStyle(MLColor.ink2)
              .padding(.top, 4)
          }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(MLColor.rule).frame(height: 0.5) }
        .padding(.top, 12)
      }
      HStack(spacing: 6) {
        Button("打开原文") { context.navigator.setTab(.text) }
          .buttonStyle(MLButtonStyle(.tinted, small: true))
      }
      .padding(.top, 14)
    }
  }
}
