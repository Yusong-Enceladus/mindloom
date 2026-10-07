import BestASRDomain
import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: v12 people (ALIGNMENT 理3-1). Two sheets the person page and 原文
// open: 合并到… (this person is the same as someone else; like Photos, the
// other keeps their name) and 不是他 (some sentences of a recording are not
// this person's: they go to a new 「没起名」 voice). Both go through the undo
// window: 8 s to take it back.

public struct MergePersonSheetInput: Equatable, Sendable {
  public let personID: String
  /// A typed filter (still images; the field starts empty in the App).
  public let query: String

  public init(personID: String, query: String = "") {
    self.personID = personID
    self.query = query
  }
}

/// 合并到…: who this person is the same as.
public struct MergePersonSheet: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: MergePersonSheetInput
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var fieldFocused: Bool

  public init(context: MindloomPageContext, input: MergePersonSheetInput) {
    self.context = context
    self.input = input
    _query = State(initialValue: input.query)
  }

  public var body: some View {
    let state = context.state
    let person = state.person(input.personID)
    VStack(alignment: .leading, spacing: 0) {
      Text(person.map { "“\($0.name)”与谁是同一个人？" } ?? "与谁是同一个人？")
        .mlFont(\.title2, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .padding(.bottom, 6)
      if let person {
        Text(
          person.isNamed
            ? "合并后使用对方的姓名，“\(person.name)”也将作为对方的姓名。"
            : "合并后，此声音归入对方。"
        )
        .mlFont(\.callout, lineBox: true)
        .foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
        picker(person)
      } else {
        Text("此人已被删除或合并。")
          .mlFont(\.callout, lineBox: true)
          .foregroundStyle(MLColor.ink2)
      }
      HStack {
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
      }
      .padding(.top, 20)
    }
    .padding(.top, 22)
    .padding(.horizontal, 24)
    .padding(.bottom, 18)
    .frame(width: 440, alignment: .leading)
    .background(MLColor.surface)
  }

  @ViewBuilder
  private func picker(_ person: MemoryPersonEntry) -> some View {
    let shown = HomeDerivation.mergeTargets(context.state, excluding: person.personID)
      .filter { PersonPicker.matches($0, query) }
    let selected = min(selection, max(0, shown.count - 1))
    PersonSheetField(
      text: $query, placeholder: "搜索姓名", focused: $fieldFocused, snapshot: snapshot,
      onSubmit: { if shown.indices.contains(selected) { merge(person, into: shown[selected]) } },
      onMove: { down in
        selection = down ? min(shown.count - 1, selected + 1) : max(0, selected - 1)
      }
    )
    .onChange(of: query) { _, _ in selection = 0 }
    .padding(.top, 14)
    let list = VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(shown.enumerated()), id: \.element.personID) { index, other in
        PersonPickerOption(
          title: other.name, detail: PersonPicker.detail(other), secondary: !other.isNamed,
          selected: index == selected
        ) { merge(person, into: other) }
        .id(other.personID)
      }
      if shown.isEmpty {
        Text("无结果")
          .mlFont(\.control)
          .foregroundStyle(MLColor.ink3)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    let height = min(300, CGFloat(max(shown.count, 1)) * 29)
    Group {
      if snapshot {
        list.frame(height: height, alignment: .top).clipped()
      } else {
        ScrollViewReader { reader in
          ScrollView(.vertical) { list }
            .frame(height: height)
            .onChange(of: selection) { _, value in
              if shown.indices.contains(value) { reader.scrollTo(shown[value].personID) }
            }
        }
      }
    }
    .padding(.top, 12)
  }

  private func merge(_ person: MemoryPersonEntry, into other: MemoryPersonEntry) {
    context.navigator.present(nil)
    let stays =
      MemoryPersonMerge.outcome(
        person: person.personID, into: other.personID,
        persons: context.state.projection?.persons ?? []
      ).stays
    context.actions.correct(.mergePerson(personID: person.personID, into: other.personID))
    if context.navigation.top == .person(person.personID), stays != person.personID {
      context.navigator.replacePerson(person.personID, with: stays)
    }
  }
}

enum PersonPicker {
  /// The filter ignores spaces and case; it also finds a number
  /// (「没起名 3」 by 「3」).
  static func matches(_ person: MemoryPersonEntry, _ query: String) -> Bool {
    let q = query.lowercased().filter { !$0.isWhitespace }
    guard !q.isEmpty else { return true }
    return person.name.lowercased().filter { !$0.isWhitespace }.contains(q)
  }

  /// 「3 件事」 / 「录音里有这个声音」.
  static func detail(_ person: MemoryPersonEntry) -> String {
    if !person.events.isEmpty { return "\(person.events.count) 件事" }
    return person.hasVoice ? "录音中有此声音" : ""
  }
}

// MARK: - 不是他

public struct NotPersonSheetInput: Equatable, Sendable {
  public let subject: NotPersonSubject

  public init(subject: NotPersonSubject) { self.subject = subject }
}

/// 不是他: tick the sentences of the recording this person did not say.
public struct NotPersonSheet: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: NotPersonSheetInput
  @State private var ticked: Set<UInt64>

  public init(context: MindloomPageContext, input: NotPersonSheetInput) {
    self.context = context
    self.input = input
    _ticked = State(initialValue: input.subject.start.map { [$0] } ?? [])
  }

  /// One sentence of theirs: where it starts (shown as 「0:42」), its words,
  /// its stretch.
  struct Sentence: Identifiable, Equatable {
    let start: UInt64
    let end: UInt64
    let offset: Int64
    let words: String
    var id: UInt64 { start }
  }

  /// This person's sentences in the recording, in time order.
  static func sentences(_ subject: NotPersonSubject, state: MemoryScreenState) -> [Sentence] {
    guard let record = state.projection?.records[subject.itemID] else { return [] }
    return record.segments.compactMap { segment in
      guard
        let id = segment.personID?.rawValue.uuidString,
        id.caseInsensitiveCompare(subject.personID) == .orderedSame,
        let start = segment.monotonicStartNanoseconds
      else { return nil }
      let words = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return nil }
      return Sentence(
        start: start, end: segment.monotonicEndNanoseconds ?? start,
        offset: segment.startMilliseconds, words: words)
    }
  }

  public var body: some View {
    let subject = input.subject
    let sentences = Self.sentences(subject, state: context.state)
    VStack(alignment: .leading, spacing: 0) {
      Text("哪些句子不是“\(subject.name)”说的？")
        .mlFont(\.title2, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .padding(.bottom, 6)
      Text("选中的句子将分给一个新的声音，标为“未命名”，之后可以命名或合并。")
        .mlFont(\.callout, lineBox: true)
        .foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
      let list = VStack(alignment: .leading, spacing: 2) {
        ForEach(sentences) { sentence in
          row(sentence, itemID: subject.itemID)
        }
        if sentences.isEmpty {
          Text("这段录音中没有此人说的话。")
            .mlFont(\.control)
            .foregroundStyle(MLColor.ink3)
            .padding(.vertical, 6)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Group {
        if snapshot {
          list.frame(maxHeight: 320, alignment: .top).clipped()
        } else {
          ScrollView(.vertical) { list }.frame(maxHeight: 320)
        }
      }
      .padding(.top, 14)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button(ticked.isEmpty ? "不是\(subject.name)" : "这 \(ticked.count) 句不是\(subject.name)") {
          split(subject, sentences: sentences)
        }
        .buttonStyle(MLButtonStyle(.tinted))
        .disabled(ticked.isEmpty)
        .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 20)
    }
    .padding(.top, 22)
    .padding(.horizontal, 24)
    .padding(.bottom, 18)
    .frame(width: 520, alignment: .leading)
    .background(MLColor.surface)
  }

  private func row(_ sentence: Sentence, itemID: String) -> some View {
    let on = ticked.contains(sentence.start)
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Button {
        if on { ticked.remove(sentence.start) } else { ticked.insert(sentence.start) }
      } label: {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .font(.system(size: 14))
          .foregroundStyle(on ? MLColor.accent : MLColor.ink3)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(sentence.words)
      .accessibilityValue(on ? "已选中" : "未选中")
      Text(Self.clock(sentence.offset))
        .mlFont(\.sub)
        .monospacedDigit()
        .foregroundStyle(MLColor.ink2)
        .frame(width: 44, alignment: .leading)
      Text(sentence.words)
        .mlFont(\.body)
        .foregroundStyle(MLColor.ink)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        context.actions.playRange(itemID, sentence.start, sentence.end)
      } label: {
        Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(MLColor.accent)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("播放此句")
      .accessibilityLabel("播放此句")
    }
    .padding(.vertical, 5)
  }

  /// 「0:42」, 「12:05」, 「1:02:03」.
  static func clock(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1_000)
    let (h, m, s) = (seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  private func split(_ subject: NotPersonSubject, sentences: [Sentence]) {
    let starts = sentences.map(\.start).filter { ticked.contains($0) }
    guard !starts.isEmpty else { return }
    context.navigator.present(nil)
    context.actions.correct(
      .notPerson(
        itemID: subject.itemID, personID: subject.personID, starts: starts,
        newPersonID: UUID().uuidString))
  }
}

// MARK: - Shared pieces

/// The sheets' search field (as 移到哪件事？'s).
struct PersonSheetField: View {
  @Binding var text: String
  let placeholder: String
  var focused: FocusState<Bool>.Binding
  let snapshot: Bool
  let onSubmit: () -> Void
  /// ↓ (true) or ↑.
  let onMove: (Bool) -> Void

  var body: some View {
    Group {
      if snapshot {
        Text(text.isEmpty ? placeholder : text)
          .foregroundStyle(text.isEmpty ? MLColor.ink3 : MLColor.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField(placeholder, text: $text)
          .textFieldStyle(.plain)
          .focused(focused)
          .onAppear { focused.wrappedValue = true }
          .onSubmit(onSubmit)
          .onKeyPress(.downArrow) {
            onMove(true)
            return .handled
          }
          .onKeyPress(.upArrow) {
            onMove(false)
            return .handled
          }
          .accessibilityLabel(placeholder)
      }
    }
    .mlFont(\.control)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
        MLColor.rule2, lineWidth: 0.5)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .inset(by: -1.5)
        .stroke(MLColor.focus, lineWidth: 3)
        .opacity(focused.wrappedValue ? 1 : 0)
    )
  }
}

/// One person in a picker: name (secondary when unnamed) and a short
/// detail; selected in the accent fill.
struct PersonPickerOption: View {
  let title: String
  let detail: String
  let secondary: Bool
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(title)
          .mlFont(\.control)
          .foregroundStyle(selected ? MLColor.onAccent : secondary ? MLColor.ink2 : MLColor.ink)
          .lineLimit(1)
        Spacer(minLength: 0)
        Text(detail)
          .mlFont(\.foot)
          .foregroundStyle(selected ? MLColor.onAccent : MLColor.ink3)
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(selected ? MLColor.accentFill : hovering ? MLColor.fill2 : MLColor.transparent)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
