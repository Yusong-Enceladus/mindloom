import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S5 · Person page (MAC-SPEC §4.5; v12 理3-1): the name
// (click it to change it; 「起个名字」 for a voice nobody named), 「最近一次在
// …」 and 「听一段」, 「一起在做」 (up to 6 matters by urgency), 「一起定下的」
// (`state.digest.decided(withPersonNamed:)`, up to 6), 「说过的话」 (their
// sentences in recordings here, each played by ▶; right-click 「不是他」).
// The toolbar's 「⋯」: 改名… · 合并到… · 听一段. Every change has 8 s to undo.

public struct PersonPageInput: Equatable, Sendable {
  /// `MemoryPersonEntry.personID`.
  public let personID: String

  public init(personID: String) { self.personID = personID }
}

public struct PersonPage: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: PersonPageInput
  @State private var draft = ""
  @State private var finished = false
  @FocusState private var editing: Bool

  public init(context: MindloomPageContext, input: PersonPageInput) {
    self.context = context
    self.input = input
  }

  private var renaming: Bool {
    context.navigation.renaming?.caseInsensitiveCompare(input.personID) == .orderedSame
  }

  public var body: some View {
    let state = context.state
    let days = HomeDays(state)
    MindloomPageScroll(key: context.navigation.scrollKey, maxWidth: 760) {
      VStack(alignment: .leading, spacing: 0) {
        if let person = state.person(input.personID) {
          title(person)
            .padding(.top, 10)
          HStack(spacing: 12) {
            let subtitle = HomeDerivation.personSubtitle(person, state: state)
            if !subtitle.isEmpty {
              Text(subtitle)
                .mlFont(\.sub)
                .foregroundStyle(MLColor.ink2)
            }
            if person.hasVoice {
              PersonVoiceButton(context: context, personID: person.personID)
                .padding(.leading, subtitle.isEmpty ? -10 : 0)
            }
          }
          .padding(.top, 4)
          let together = HomeDerivation.together(person, state: state)
          if !together.isEmpty {
            HomeGroupHeader(title: "共同参与的事")
            ForEach(together) { matter in
              HomeMatterRow(
                context: context, matter: matter,
                second: HomeDerivation.secondLine(matter, days: days), track: nil)
            }
          }
          let decided = person.isNamed ? HomeDerivation.decided(person, state: state) : []
          if !decided.isEmpty {
            HomeGroupHeader(title: "共同确定的事")
            ForEach(decided, id: \.matter.eventID) { group in
              Button {
                context.navigator.openMatter(group.matter.eventID)
              } label: {
                Text(MLAutospace.apply(group.matter.title)).mlFont(\.sub)
              }
              .buttonStyle(HoverAccentStyle())
              .padding(.top, 10)
              .padding(.bottom, 2)
              ForEach(group.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Text(days.md(days.n(step.date)))
                    .mlFont(\.sub)
                    .monospacedDigit()
                    .foregroundStyle(MLColor.ink2)
                    .frame(width: 72, alignment: .leading)
                  Text(MLAutospace.apply(step.text))
                    .mlFont(\.body)
                    .foregroundStyle(MLColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
              }
            }
          }
          let lines = state.projection?.spokenLines(of: person.personID) ?? []
          if !lines.isEmpty {
            HomeGroupHeader(title: "说过的话")
            ForEach(lines) { line in
              PersonSpokenLine(context: context, person: person, line: line)
            }
          }
        } else {
          HomeEmptyMessage(title: "找不到此人", message: "此人可能已与其他人合并。").padding(.top, 140)
        }
      }
    }
  }

  // MARK: - Name

  @ViewBuilder
  private func title(_ person: MemoryPersonEntry) -> some View {
    if renaming, !snapshot {
      TextField(person.isNamed ? "姓名" : "添加姓名", text: $draft)
        .textFieldStyle(.plain)
        .mlFont(\.title, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .padding(.horizontal, 6)
        .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .inset(by: -1.5)
            .stroke(MLColor.focus, lineWidth: 3)
        )
        .padding(.horizontal, -6)
        .focused($editing)
        .onSubmit { save(person) }
        .onExitCommand {
          finished = true
          context.navigator.rename(nil)
        }
        .onChange(of: editing) { _, focused in if !focused { save(person) } }
        .onAppear {
          draft = person.isNamed ? person.name : ""
          finished = false
          editing = true
        }
        .accessibilityLabel(person.isNamed ? "重新命名" : "添加姓名")
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(person.isNamed ? MLAutospace.apply(person.name) : person.name)
          .mlFont(\.title, lineBox: true)
          .foregroundStyle(person.isNamed ? MLColor.ink : MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .contentShape(Rectangle())
          .onTapGesture { startRename(person) }
          .help(person.isNamed ? "点按以重新命名" : "点按以添加姓名")
          .accessibilityAddTraits([.isHeader, .isButton])
          .accessibilityHint(person.isNamed ? "重新命名" : "添加姓名")
          .accessibilityAction(named: person.isNamed ? "重新命名" : "添加姓名") { startRename(person) }
        if !person.isNamed {
          Button("添加姓名") { startRename(person) }
            .buttonStyle(MLButtonStyle(.tinted, small: true))
        }
      }
    }
  }

  private func startRename(_ person: MemoryPersonEntry) {
    guard !snapshot else { return }
    context.navigator.openPerson(person.personID, renaming: true)
  }

  /// Return or blur saves (whitespace collapsed); an unchanged or empty
  /// name does nothing.
  private func save(_ person: MemoryPersonEntry) {
    guard renaming, !finished else { return }
    finished = true
    context.navigator.rename(nil)
    let name = PersonName.clean(draft)
    guard !name.isEmpty, !(person.isNamed && name == person.name) else { return }
    context.actions.correct(
      .namePerson(personID: person.personID, from: person.isNamed ? person.name : "", to: name))
  }
}

/// A name as typed: runs of whitespace become one space, at most 64
/// characters.
enum PersonName {
  static func clean(_ text: String) -> String {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return String(collapsed.prefix(64))
  }
}

/// One of 「说过的话」: 「9月18日 14:05 · 会议录音」, the words, ▶ (plays just
/// this sentence); right-click 「不是{name}…」.
struct PersonSpokenLine: View {
  let context: MindloomPageContext
  let person: MemoryPersonEntry
  let line: MemoryPersonLine

  var body: some View {
    let state = context.state
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(
          MindloomDates.monthDay(line.startedAt, calendar: state.calendar) + " "
            + MindloomDates.clock(line.startedAt, calendar: state.calendar) + " · "
            + line.source.line
        )
        .mlFont(\.foot)
        .monospacedDigit()
        .foregroundStyle(MLColor.ink2)
        Text(line.words)
          .mlFont(\.body)
          .foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let voice = line.voice {
        Button {
          context.actions.playRange(voice.itemID, voice.start, voice.end)
        } label: {
          Image(systemName: "play.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MLColor.accent)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("播放此句")
        .accessibilityLabel("播放此句")
      }
    }
    .padding(.vertical, 6)
    .contextMenu {
      Button {
        context.navigator.present(
          .notPerson(
            NotPersonSubject(
              eventID: "", itemID: line.itemID, segID: nil, personID: line.speakerID,
              name: person.name, start: line.start)))
      } label: {
        Label("不是\(person.name)…", systemImage: "person.crop.circle.badge.xmark")
      }
    }
  }
}

/// `ink2` text that turns `accent` under the pointer (「一起定下的」 headers).
struct HoverAccentStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(hovering || configuration.isPressed ? MLColor.accent : MLColor.ink2)
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}
