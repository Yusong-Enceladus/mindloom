import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S3 · Home 按人 (MAC-SPEC §4.3; v12 理3-1, B7 U13): everyone
// once, not one matter per person: people in several matters or heard on
// this Mac first, then 「只在一件事里」, then 「没起名」 (voices nobody named,
// numbered the same on every page) with 「听一段」. Rows are drawn as they
// scroll in; a row opens the person page; right-click: 改名… · 合并到… ·
// 听一段.

public struct HomePeopleView: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  @FocusState private var focused: String?
  @State private var keyboard = false

  public init(context: MindloomPageContext) {
    self.context = context
  }

  public var body: some View {
    let groups = HomeDerivation.peopleGroups(context.state)
    let order = groups.flatMap(\.rows).map(\.id)
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(groups) { group in
        if let title = group.title {
          HomeGroupHeader(title: title)
        }
        ForEach(group.rows) { row in
          HomePersonRow(
            context: context, row: row,
            focusRing: keyboard && focused == row.id && !snapshot
          )
          .focusable(!snapshot)
          .focusEffectDisabled()
          .focused($focused, equals: row.id)
          .onKeyPress(.return) {
            context.navigator.openPerson(row.person.personID)
            return .handled
          }
        }
      }
      if groups.isEmpty {
        HomeEmptyMessage(title: "尚无人物", message: "说过话或发过消息的人会显示在这里。").padding(.top, 140)
      }
    }
    .padding(.top, 14)
    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
      guard let current = focused, let at = order.firstIndex(of: current) else { return .ignored }
      keyboard = true
      focused = order[press.key == .downArrow ? min(at + 1, order.count - 1) : max(at - 1, 0)]
      return .handled
    }
  }
}

/// One 按人 row: the name (「没起名 N」 in secondary), the most urgent matter
/// or how often the voice was heard, 「听一段」 for a voice, the last day.
struct HomePersonRow: View {
  let context: MindloomPageContext
  let row: HomeDerivation.PersonRow
  let focusRing: Bool

  private var person: MemoryPersonEntry { row.person }

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      FadingText(Text(person.name), fade: 37.5)
        .mlFont(\.headline)
        .foregroundStyle(person.isNamed ? MLColor.ink : MLColor.ink2)
        .frame(width: 120, alignment: .leading)
      FadingText(Text(HomeDerivation.personSecondLine(row)), fade: 32.5)
        .mlFont(\.sub)
        .foregroundStyle(MLColor.ink2)
        .mlLineBox(\.sub)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 10) {
        if person.hasVoice {
          PersonVoiceButton(context: context, personID: person.personID, compact: true)
        }
        Text(row.last).mlFont(\.sub).monospacedDigit().foregroundStyle(MLColor.ink2)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(MLColor.ink3)
      }
      .fixedSize()
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .frame(minHeight: 56)
    .modifier(HomeRowChrome())
    .modifier(HomeFocusRing(on: focusRing))
    .padding(.horizontal, -12)
    .contentShape(Rectangle())
    .onTapGesture { context.navigator.openPerson(person.personID) }
    .contextMenu { PersonMenuItems(context: context, person: person) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isLink)
    .accessibilityAction { context.navigator.openPerson(person.personID) }
  }
}

/// A person's menu (按人 right-click, the person page's 「⋯」).
struct PersonMenuItems: View {
  let context: MindloomPageContext
  let person: MemoryPersonEntry

  var body: some View {
    Button {
      context.navigator.openPerson(person.personID, renaming: true)
    } label: {
      Label(person.isNamed ? "重新命名…" : "命名…", systemImage: "pencil")
    }
    Button {
      context.navigator.present(.mergePerson(person.personID))
    } label: {
      Label("合并到…", systemImage: "person.2")
    }
    if person.hasVoice {
      Divider()
      Button {
        context.actions.home.playVoice(person.personID)
      } label: {
        Label("试听", systemImage: "play")
      }
    }
  }
}

/// 「听一段」: about three seconds of their own voice; the glyph shows it
/// playing.
struct PersonVoiceButton: View {
  let context: MindloomPageContext
  let personID: String
  var compact = false

  private var playing: Bool {
    context.state.homeExtras.playingVoice?.caseInsensitiveCompare(personID) == .orderedSame
  }

  var body: some View {
    Button {
      if playing {
        context.actions.stop()
      } else {
        context.actions.home.playVoice(personID)
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: playing ? "stop.fill" : "play.fill")
          .font(.system(size: compact ? 10 : 11, weight: .semibold))
        if !compact { Text(playing ? "停止" : "试听").mlFont(\.control) }
      }
      .foregroundStyle(MLColor.accent)
      .frame(minWidth: compact ? 22 : nil, minHeight: 22)
      .padding(.horizontal, compact ? 0 : 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(playing ? "停止" : "试听此声音 3 秒")
    .accessibilityLabel(playing ? "停止" : "试听此声音")
  }
}
