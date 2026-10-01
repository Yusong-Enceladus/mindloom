import BestASRMemory
import SwiftUI

/// One event: title (editable in place), date span, where it stands, people,
/// then the original items by day, questions where they belong, and related
/// events. 复制为文本 is the one primary action.
struct EventPage: View {
  enum Display: Hashable {
    case summary
    case all
  }

  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  let eventID: String
  let state: MemoryScreenState
  let actions: MemoryActions
  let morph: Namespace.ID
  let back: () -> Void
  let open: (MemoryRoute) -> Void
  @Binding var expanded: Set<String>
  @State private var display = Display.summary

  var body: some View {
    VStack(spacing: 0) {
      BackBar(title: ZhijiCopy.back, action: back) { primaryAction }
      if let detail = state.projection?.event(id: eventID) {
        ZhijiScroll {
          HStack {
            Spacer(minLength: 24)
            content(detail).frame(maxWidth: ZhijiMetrics.column)
            Spacer(minLength: 24)
          }
        }
      } else {
        Spacer()
      }
    }
  }

  // MARK: - Header action

  private var primaryAction: some View {
    HStack(spacing: 8) {
      Button {
        actions.copyText(eventID)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "doc.on.doc").font(.system(size: 12, weight: .medium))
          Text(ZhijiCopy.copyAsText).font(.zhiji(13, .semibold))
        }
        .foregroundStyle(palette.onAccent)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .contextMenu { Button(ZhijiCopy.exportAsText) { actions.exportText(eventID) } }
      .accessibilityIdentifier("bestASR.memory.copyEvent")
      if snapshot {
        moreLabel
      } else {
        Menu {
          Button(ZhijiCopy.exportAsText) { actions.exportText(eventID) }
          if state.canPin, let entry = state.entry(eventID) {
            Divider()
            Button(entry.pinned ? ZhijiCopy.unpin : ZhijiCopy.pin) {
              actions.pin(eventID, !entry.pinned)
            }
            Button(ZhijiCopy.featureLess) { actions.featureLess(eventID) }
          }
        } label: {
          moreLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(ZhijiCopy.more)
        .accessibilityLabel(ZhijiCopy.more)
      }
    }
  }

  /// The "…" button: the same quiet 30 pt square in the App and a snapshot.
  private var moreLabel: some View {
    Image(systemName: "ellipsis")
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(palette.label)
      .frame(width: 30, height: 30)
      .background(palette.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
  }

  // MARK: - Content

  private func content(_ detail: MemoryEventDetail) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      EventHeader(detail: detail, state: state, morph: morph) { title in
        actions.renameEvent(eventID, title)
      }
      HStack(spacing: 10) {
        PeopleChips(people: detail.shownPeople, actions: actions, open: open)
        Spacer(minLength: 8)
        ZhijiSegmented(
          options: [(Display.summary, ZhijiCopy.summary), (.all, ZhijiCopy.showAll)],
          selection: $display, height: 24, fontSize: 12, horizontalPadding: 12)
      }
      Rectangle().fill(palette.separator.opacity(0.8)).frame(height: 1)
      if display == .summary, !detail.statusFacts.isEmpty {
        StatusFactList(facts: detail.statusFacts, state: state)
      }
      DayTimeline(
        detail: detail, state: state, actions: actions,
        isExpanded: { display == .all || expanded.contains($0) },
        toggle: { id in
          if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }, open: open)
      let related = state.projection?.related(to: eventID, home: state.home) ?? []
      if !related.isEmpty {
        RelatedEvents(entries: related, state: state, open: open)
      }
    }
    .padding(.top, 28)
    .padding(.bottom, 40)
  }
}

struct EventHeader: View {
  @Environment(\.zhiji) private var palette
  let detail: MemoryEventDetail
  let state: MemoryScreenState
  let morph: Namespace.ID
  let rename: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      InPlaceText(
        text: detail.title, font: .zhiji(ZhijiMetrics.eventTitle, .semibold), commit: rename
      )
      .zhijiMorph("title-\(detail.eventID)", in: morph, isSource: false)
      .accessibilityIdentifier("bestASR.memory.eventTitle")
      Text(metaLine)
        .metaStyle(palette)
      // Only a status someone wrote: an item excerpt would repeat the first
      // row of the timeline below.
      if !detail.statusLine.isEmpty, !detail.statusIsFallback {
        Text(detail.statusLine)
          .font(.zhiji(ZhijiMetrics.statusLine))
          .lineSpacing(4)
          .foregroundStyle(palette.label)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      }
    }
  }

  private var metaLine: String {
    let span = state.span(detail.span)
    let count = ZhijiCopy.itemCount(detail.items.count)
    return span.isEmpty ? count : "\(span) · \(count)"
  }
}

/// People as capsules; "?" asks for a name in place. `people` comes most
/// involved first. A long cast never widens the page: at most
/// `maximumChips` chips, fewer when they do not fit the width offered, then
/// "+N" for the rest (named in its accessibility label; everyone is on the
/// people page).
struct PeopleChips: View {
  @Environment(\.zhiji) private var palette
  let people: [MemoryPersonRef]
  let actions: MemoryActions
  let open: (MemoryRoute) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(Self.counts(people.count), id: \.self) { shown in
        row(shown)
      }
    }
  }

  /// The most chips the row shows however wide the page is: people the
  /// organizer links because a text names them made casts of 15 and more
  /// common.
  static let maximumChips = 6

  /// Chip counts to try, most first: all up to `maximumChips`, then fewer
  /// down to none.
  static func counts(_ total: Int) -> [Int] {
    let most = min(total, maximumChips)
    var out = [most]
    for n in [5, 4, 3, 2, 1, 0] where n < most { out.append(n) }
    return out
  }

  private func row(_ shown: Int) -> some View {
    HStack(spacing: 10) {
      ForEach(people.prefix(shown), id: \.personID) { person in
        PersonChip(person: person, actions: actions) { open(.person(person.personID)) }
          .fixedSize()
      }
      if people.count > shown {
        Text("+\(people.count - shown)")
          .font(.zhiji(13))
          .foregroundStyle(palette.secondary)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .background(palette.surface, in: Capsule())
          .fixedSize()
          .accessibilityLabel(
            people.dropFirst(shown).map { $0.isNamed ? $0.name : ZhijiCopy.nameSomeone }
              .joined(separator: "、"))
      }
    }
    .fixedSize()
  }
}

private struct PersonChip: View {
  @Environment(\.zhiji) private var palette
  let person: MemoryPersonRef
  let actions: MemoryActions
  let open: () -> Void
  @State private var naming = false

  var body: some View {
    Button {
      if person.isNamed { open() } else { naming = true }
    } label: {
      HStack(spacing: 6) {
        Avatar(person, size: 22)
          .accessibilityHidden(true)
        Text(person.isNamed ? person.name : ZhijiCopy.nameSomeone)
          .font(.zhiji(13))
          .foregroundStyle(palette.label)
          .lineLimit(1)
      }
      .padding(.leading, 4)
      .padding(.trailing, 12)
      .frame(height: 30)
      .background(palette.surface, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .contextMenu { Button(ZhijiCopy.rename) { naming = true } }
    .popover(isPresented: $naming, arrowEdge: .bottom) {
      NamePopover(
        prompt: ZhijiCopy.namePrompt, initial: person.isNamed ? person.name : "",
        save: { name in
          naming = false
          actions.namePerson(person.personID, name)
        },
        cancel: { naming = false })
    }
  }
}

/// Where it stands, one fact per line, styled by state.
struct StatusFactList: View {
  @Environment(\.zhiji) private var palette
  let facts: [MemoryStatusFact]
  let state: MemoryScreenState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: symbol(fact.state))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fact.state == .done ? palette.accent : palette.secondary)
            .frame(width: 14)
            .accessibilityHidden(true)
          Text(fact.text)
            .font(.zhiji(13))
            .strikethrough(fact.state == .cancelled, color: palette.secondary)
            .foregroundStyle(
              fact.state == .info || fact.state == .cancelled ? palette.secondary : palette.label)
          // No chip when the text already says the day.
          if let day = fact.chipDay.flatMap({
            MemoryDateText.factDay($0, calendar: state.calendar, now: state.now)
          }) {
            Text(day).metaStyle(palette)
          }
        }
        // The words it rests on, on hover; the state in words for VoiceOver.
        .help(fact.quote.map { "「\($0)」" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(fact))
      }
    }
    .accessibilityIdentifier("bestASR.memory.statusFacts")
  }

  /// "已定：房租涨 200"; a plain fact is read as is.
  private func accessibilityLabel(_ fact: MemoryStatusFact) -> String {
    let word = ZhijiCopy.factState(fact.state.rawValue)
    let day = fact.chipDay.flatMap {
      MemoryDateText.factDay($0, calendar: state.calendar, now: state.now)
    }
    let text = [fact.text, day].compactMap { $0 }.joined(separator: " ")
    return word.isEmpty ? text : "\(word)：\(text)"
  }

  private func symbol(_ state: MemoryStatusFact.State) -> String {
    switch state {
    case .planned: "circle"
    case .inProgress: "circle.lefthalf.filled"
    case .done: "circle.fill"
    case .cancelled: "circle.slash"
    case .info: "minus"
    }
  }
}

/// Items grouped by day; each question sits in the day of its item.
struct DayTimeline: View {
  @Environment(\.zhiji) private var palette
  let detail: MemoryEventDetail
  let state: MemoryScreenState
  let actions: MemoryActions
  /// Keyed by row (`MemoryEventItem.id`): a record held in parts has a row
  /// per part.
  let isExpanded: (String) -> Bool
  let toggle: (String) -> Void
  var open: ((MemoryRoute) -> Void)? = nil

  var body: some View {
    let groups = detail.dayGroups(calendar: state.calendar)
    let placed = placement(groups)
    VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        VStack(alignment: .leading, spacing: 2) {
          if let day = group.day {
            Text(state.dayHeader(day))
              .font(.zhiji(12, .semibold))
              .foregroundStyle(palette.secondary)
              .padding(.bottom, 6)
          }
          // Lazy: an event can hold hundreds of records.
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(group.items) { item in
              TimelineRow(
                item: item, state: state, expanded: isExpanded(item.id), people: detail.people,
                eventID: detail.eventID, actions: actions, toggle: { toggle(item.id) },
                open: open)
            }
          }
          ForEach(placed[index] ?? []) { question in
            InlineQuestion(question: question, answer: actions.answer)
          }
        }
      }
      ForEach(placed[-1] ?? []) { question in
        InlineQuestion(question: question, answer: actions.answer)
      }
    }
  }

  /// Day index per question; -1 for the end (merge questions, or an item of
  /// a day this event has no group for).
  private func placement(_ groups: [MemoryDayGroup]) -> [Int: [MemoryQuestion]] {
    var result: [Int: [MemoryQuestion]] = [:]
    for question in detail.questions {
      var index = -1
      if let itemID = question.itemID,
        let date = state.projection?.item(itemID).startedAt
      {
        let day = state.calendar.startOfDay(for: date)
        index = groups.firstIndex { $0.day == day } ?? -1
      }
      result[index, default: []].append(question)
    }
    return result
  }
}

/// 这不是这件事的 / 移到… / 单独成一件事. 移到… lists the first events in
/// Home order and ends with 找一件事, which opens a searchable list of all.
struct ItemMenu: View {
  static let quickTargets = 10

  let itemID: String
  /// Set on a row showing one part of a record: the corrections are about
  /// that part.
  var segID: String? = nil
  let eventID: String?
  let state: MemoryScreenState
  let actions: MemoryActions
  let pick: () -> Void

  static func targets(_ state: MemoryScreenState, excluding eventID: String?) -> [MemoryHomeEntry] {
    state.home.filter { $0.eventID != eventID }
  }

  var body: some View {
    let targets = Self.targets(state, excluding: eventID)
    if let eventID {
      Button(ZhijiCopy.notThisEvent) { actions.removeItem(eventID, itemID, segID) }
    }
    Menu(eventID == nil ? ZhijiCopy.fileInto : ZhijiCopy.moveTo) {
      ForEach(targets.prefix(Self.quickTargets)) { entry in
        Button(entry.title) { actions.moveItem(itemID, entry.eventID, eventID, segID) }
      }
      if targets.count > Self.quickTargets {
        Divider()
        Button(ZhijiCopy.findEvent, action: pick)
      }
    }
    .disabled(targets.isEmpty)
    // A new event takes a whole record; a part stays with its record.
    if segID == nil {
      Button(ZhijiCopy.ownEvent) { actions.fileItemNewEvent(itemID) }
    }
  }
}

/// The same corrections, plus play, as VoiceOver actions on a row.
struct ItemAccessibilityActions: ViewModifier {
  let item: MemoryEventItem
  let eventID: String?
  let state: MemoryScreenState
  let actions: MemoryActions
  let pick: () -> Void

  func body(content: Content) -> some View {
    let playing = state.playingItemID == item.itemID
    content
      .accessibilityAction(named: eventID == nil ? ZhijiCopy.fileInto : ZhijiCopy.moveTo, pick)
      .modifier(OwnEventAction(item: item, actions: actions))
      .modifier(RemoveAction(item: item, eventID: eventID, actions: actions))
      .modifier(
        PlayAction(
          available: item.playbackAvailable, playing: playing,
          play: { actions.play(item.itemID) }, stop: { actions.stop() }))
  }

  private struct RemoveAction: ViewModifier {
    let item: MemoryEventItem
    let eventID: String?
    let actions: MemoryActions

    func body(content: Content) -> some View {
      if let eventID {
        content.accessibilityAction(named: ZhijiCopy.notThisEvent) {
          actions.removeItem(eventID, item.itemID, item.segment?.segID)
        }
      } else {
        content
      }
    }
  }

  private struct OwnEventAction: ViewModifier {
    let item: MemoryEventItem
    let actions: MemoryActions

    func body(content: Content) -> some View {
      if item.segment == nil {
        content.accessibilityAction(named: ZhijiCopy.ownEvent) {
          actions.fileItemNewEvent(item.itemID)
        }
      } else {
        content
      }
    }
  }

  private struct PlayAction: ViewModifier {
    let available: Bool
    let playing: Bool
    let play: () -> Void
    let stop: () -> Void

    func body(content: Content) -> some View {
      if available {
        content.accessibilityAction(named: playing ? ZhijiCopy.stop : ZhijiCopy.play) {
          playing ? stop() : play()
        }
      } else {
        content
      }
    }
  }
}

struct RelatedEvents: View {
  @Environment(\.zhiji) private var palette
  let entries: [MemoryHomeEntry]
  let state: MemoryScreenState
  let open: (MemoryRoute) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ZhijiCopy.related)
        .font(.zhiji(13, .semibold))
        .foregroundStyle(palette.secondary)
      CompactEventGrid(entries: entries, state: state, open: open)
    }
    .padding(.top, 10)
  }
}
