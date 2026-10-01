import BestASRMemory
import SwiftUI

/// 事件 | 全部 and search; then the day, what needs doing (pills), the
/// matters moving on one time axis, and the other matters as rows.
struct HomePage: View {
  @Environment(\.zhiji) private var palette
  @Binding var navigation: MemoryNavigation
  let state: MemoryScreenState
  let actions: MemoryActions
  let morph: Namespace.ID
  let accessory: AnyView?
  let allItems: () -> AnyView
  let open: (MemoryRoute) -> Void
  /// How many rows Home shows before "显示更多"; each tap adds as many.
  static let pageSize = 24
  @State private var shownCards = HomePage.pageSize
  @State private var loomSpan: MemoryLoom.Span = .twoWeeks
  /// Upper-case ID of the person chosen in 「看某个人」.
  @State private var person: String?
  /// The question card, opened from its pill.
  @State private var showQuestion = false

  var body: some View {
    VStack(spacing: 0) {
      HomeHeader(navigation: $navigation)
      switch navigation.homeMode {
      case .events:
        ZhijiScroll { content }
      case .all:
        allItems()
      }
    }
    .background(navigation.homeMode == .events ? HomeTones(palette).page : .clear)
    .onAppear { actions.refresh() }
  }

  /// 「最近在动的事」 for the chosen span, else the other one when only that
  /// has two matters; nil when neither does, or while searching.
  private var loom: MemoryLoom? {
    guard !searching else { return nil }
    for span in [loomSpan, loomSpan == .twoWeeks ? .fiveWeeks : .twoWeeks] {
      if let loom = state.looms[span], loom.isShown { return loom }
    }
    return nil
  }

  /// Counts and dates for every Home matter (the same in either span).
  private var facts: MemoryLoom? { state.looms[.twoWeeks] ?? state.looms.values.first }

  /// The rows: every match while searching; otherwise the matters the time
  /// axis does not already show (「其他在进行的事」), of the chosen person.
  private var entries: [MemoryHomeEntry] {
    let shown = Set(loom?.lanes.map(\.eventID) ?? [])
    return state.home.filter { entry in
      guard entry.matches(navigation.search), !shown.contains(entry.eventID) else {
        return false
      }
      guard !searching, let person else { return true }
      return entry.people.contains { $0.personID.uppercased() == person }
    }
  }

  /// All matches while searching; otherwise the first rows in Home order.
  private var visibleEntries: [MemoryHomeEntry] {
    searching ? entries : Array(entries.prefix(shownCards))
  }

  private var searching: Bool {
    !navigation.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The named people 「看某个人」 offers.
  private var chipPeople: [MemoryPersonEntry] { state.featuredPeople.filter(\.isNamed) }

  private var content: some View {
    VStack(alignment: .leading, spacing: 24) {
      if let accessory { accessory }
      if !state.isLoaded {
        // Still loading: neither the first-run page nor "没有找到".
        EmptyView()
      } else if state.home.isEmpty, state.unfiled.isEmpty {
        dateTitle
        EmptyHome()
      } else {
        if !searching {
          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
              dateTitle
              Text(summary)
                .font(.zhiji(13))
                .foregroundStyle(palette.secondary)
            }
            pills
            if showQuestion, let question = state.bannerQuestion {
              QuestionBanner(question: question, state: state, actions: actions)
            }
            if !state.issues.isEmpty {
              IssueList(issues: state.issues, actions: actions)
            }
          }
        }
        if !searching {
          HomeLensBar(lens: $navigation.homeLens)
        }
        if !searching, navigation.homeLens != .time, let lenses = state.lenses {
          lensContent(lenses)
        } else {
          timeLens
        }
      }
    }
    .padding(.horizontal, 32)
    .padding(.top, 24)
    .padding(.bottom, 40)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 按绳 / 按截止 / 按人.
  @ViewBuilder
  private func lensContent(_ lenses: MemoryHomeLenses) -> some View {
    switch navigation.homeLens {
    case .ropes:
      RopeBandsView(
        lenses: lenses, state: state, actions: actions, open: { open(.event($0)) })
    case .deadlines:
      DeadlineLadderView(lenses: lenses, state: state, open: { open(.event($0)) })
    case .people:
      PeopleLensView(lenses: lenses, state: state, open: open)
    case .time:
      EmptyView()
    }
  }

  /// 按时间: the time axis and the other matters (the page as it was).
  @ViewBuilder
  private var timeLens: some View {
    if let loom {
      LoomPanel(
        loom: loom, span: $loomSpan, state: state, person: $person,
        people: Array(chipPeople.prefix(LoomPanel.peopleChips)),
        morePeople: max(chipPeople.count - LoomPanel.peopleChips, 0),
        showAllPeople: { navigation.tab = .people },
        morph: morph, open: openAt)
    }
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        if loom != nil {
          HStack(alignment: .firstTextBaseline) {
            Text(ZhijiCopy.otherEvents)
              .font(.zhiji(16, .semibold))
              .foregroundStyle(palette.label)
              .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(ZhijiCopy.byRecent)
              .font(.zhiji(12))
              .foregroundStyle(palette.tertiary)
          }
        }
        OtherMatters(
          entries: visibleEntries, facts: facts, state: state,
          open: { open(.event($0)) })
      }
      if !searching, entries.count > visibleEntries.count {
        ShowMoreButton(remaining: entries.count - visibleEntries.count) {
          shownCards += Self.pageSize
        }
      }
    } else if searching {
      Text(ZhijiCopy.noMatches)
        .font(.zhiji(13))
        .foregroundStyle(palette.secondary)
    } else if loom == nil {
      // Items wait in Unfiled and no event exists yet.
      Text(ZhijiCopy.noEventsYet)
        .font(.zhiji(13))
        .foregroundStyle(palette.tertiary)
    }
  }

  /// "9月20日 周日": the axis's today (the newest item's day).
  private var dateTitle: some View {
    let date = facts?.now ?? state.now
    let parts = state.calendar.dateComponents([.month, .day, .weekday], from: date)
    let weekday = MemoryDateText.weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
    return Text("\(parts.month ?? 0)月\(parts.day ?? 0)日 \(weekday)")
      .font(.zhiji(30, .bold))
      .foregroundStyle(palette.label)
      .accessibilityIdentifier("bestASR.home.headline")
  }

  private var summary: String {
    let shown = loom ?? facts
    return ZhijiCopy.homeSummary(
      weeks: (shown?.span.days ?? 14) / 7, moved: shown?.movedCount ?? 0,
      shown: loom?.lanes.count ?? 0)
  }

  /// 今天到期 · 明天 · questions · Unfiled; a pill with nothing to count is
  /// left out.
  private var pills: some View {
    let tones = HomeTones(palette)
    return HStack(spacing: 8) {
      if let due = facts?.dueToday, due > 0 {
        HomePill(title: ZhijiCopy.dueToday(due), tint: tones.red, dot: true)
      }
      if let due = facts?.dueTomorrow, due > 0 {
        HomePill(title: ZhijiCopy.dueTomorrow(due), tint: tones.amber, dot: true)
      }
      if state.questionCount > 0, state.bannerQuestion != nil {
        HomePill(
          title: ZhijiCopy.questionsWaiting(state.questionCount), tint: tones.blue,
          symbol: "questionmark"
        ) { showQuestion.toggle() }
        .accessibilityIdentifier("bestASR.memory.questionPill")
      }
      if !state.unfiled.isEmpty {
        HomePill(title: ZhijiCopy.unfiledRow(state.unfiled.count), tint: tones.gray) {
          open(.unfiled)
        }
        .accessibilityIdentifier("bestASR.memory.unfiled")
      }
    }
  }

  /// Opens a matter with the rows of a day or milestone expanded.
  private func openAt(_ eventID: String, _ rows: [String]) {
    navigation.expandedItems.formUnion(rows)
    open(.event(eventID))
  }
}

/// A rounded, tinted pill of Home's header; a button when it has an action.
struct HomePill: View {
  let title: String
  let tint: HomeTones.Tint
  var dot = false
  var symbol: String?
  var action: (() -> Void)?

  var body: some View {
    let label = HStack(spacing: 6) {
      if dot {
        Circle().fill(tint.mark).frame(width: 6, height: 6)
      }
      if let symbol {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
      }
      Text(title).font(.zhiji(13, .medium))
    }
    .foregroundStyle(tint.ink)
    .padding(.horizontal, 12)
    .frame(height: 30)
    .background(tint.fill, in: Capsule())
    .contentShape(Capsule())
    if let action {
      Button(action: action) { label }.buttonStyle(.plain)
    } else {
      label
    }
  }
}

/// 「其他在进行的事」: two columns of rows, each its title, status, and a
/// 今天 / 明天 chip when due, else the day it last moved.
struct OtherMatters: View {
  @Environment(\.zhiji) private var palette
  let entries: [MemoryHomeEntry]
  let facts: MemoryLoom?
  let state: MemoryScreenState
  let open: (String) -> Void

  var body: some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 32, alignment: .top),
        GridItem(.flexible(), spacing: 32, alignment: .top),
      ],
      alignment: .leading, spacing: 0
    ) {
      ForEach(entries) { entry in row(entry) }
    }
  }

  private func row(_ entry: MemoryHomeEntry) -> some View {
    let tones = HomeTones(palette)
    let status =
      entry.statusLine.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return Button {
      open(entry.eventID)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Text(entry.title)
          .font(.zhiji(13, .semibold))
          .foregroundStyle(palette.label)
          .lineLimit(1)
          .frame(maxWidth: 240, alignment: .leading)
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(1)
        Text(status)
          .font(.zhiji(13))
          .foregroundStyle(entry.statusIsFallback ? palette.tertiary : palette.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        trailing(entry, tones)
      }
      .padding(.vertical, 11)
      .overlay(alignment: .bottom) {
        Rectangle().fill(palette.separator.opacity(0.7)).frame(height: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("bestASR.memory.otherEvent")
  }

  @ViewBuilder
  private func trailing(_ entry: MemoryHomeEntry, _ tones: HomeTones) -> some View {
    if let due = facts?.dues[entry.eventID], due.daysAway <= 1 {
      Text(due.daysAway == 0 ? ZhijiCopy.loomToday : ZhijiCopy.loomTomorrow)
        .font(.zhiji(11, .semibold))
        .foregroundStyle(tones.red.ink)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(tones.red.fill, in: Capsule())
    } else if let last = facts?.lastActivity[entry.eventID] ?? entry.lastUpdate {
      let parts = state.calendar.dateComponents([.month, .day], from: last)
      Text("\(parts.month ?? 0)/\(parts.day ?? 0)")
        .font(.zhiji(12))
        .monospacedDigit()
        .foregroundStyle(palette.tertiary)
    }
  }
}

struct HomeHeader: View {
  @Environment(\.zhiji) private var palette
  @Binding var navigation: MemoryNavigation

  var body: some View {
    HStack {
      ZhijiSegmented(
        options: [(MemoryHomeMode.events, ZhijiCopy.segmentEvents), (.all, ZhijiCopy.segmentAll)],
        selection: $navigation.homeMode)
      Spacer()
      ZhijiSearchField(text: $navigation.search, prompt: ZhijiCopy.searchPrompt)
    }
    .pageHeader(palette, horizontalPadding: 32)
  }
}

/// "显示更多" under the cards Home shows first.
struct ShowMoreButton: View {
  @Environment(\.zhiji) private var palette
  let remaining: Int
  let action: () -> Void

  var body: some View {
    HStack {
      Spacer()
      Button(action: action) {
        Text(ZhijiCopy.showMore)
          .font(.zhiji(13))
          .foregroundStyle(palette.label)
          .padding(.horizontal, 16)
          .frame(height: 30)
          .background(palette.selectionFill, in: Capsule())
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityHint(ZhijiCopy.itemCount(remaining))
      .accessibilityIdentifier("bestASR.memory.showMore")
      Spacer()
    }
  }
}

/// The one question Home shows, with 是 / 不是. A question about one item
/// says which: its source tile, when and where it came from, and a play pill
/// for a recording.
struct QuestionBanner: View {
  @Environment(\.zhiji) private var palette
  let question: MemoryQuestion
  let state: MemoryScreenState
  let actions: MemoryActions

  private var item: MemoryEventItem? {
    guard let itemID = question.itemID, let item = state.projection?.item(itemID),
      item.record != nil
    else { return nil }
    return item
  }

  var body: some View {
    HStack(spacing: 16) {
      HStack(spacing: 12) {
        if let item {
          SourceTile(kind: ItemKind(item.record))
        } else {
          QuestionGlyph(question: question, state: state, ring: palette.surface)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(question.prompt)
            .font(.zhiji(13))
            .foregroundStyle(palette.label)
            .lineLimit(2)
          if let item {
            Text(itemMeta(item)).metaStyle(palette).lineLimit(1)
          }
        }
      }
      Spacer(minLength: 8)
      if let item, item.playbackAvailable {
        PlayButton(playing: state.playingItemID == item.itemID) {
          if state.playingItemID == item.itemID {
            actions.stop()
          } else {
            actions.play(item.itemID)
          }
        }
      }
      YesNoButtons { actions.answer(question, $0) }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 16)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityIdentifier("bestASR.memory.question")
  }

  /// "9月26日 16:12 · 来自 Safari".
  private func itemMeta(_ item: MemoryEventItem) -> String {
    var parts: [String] = []
    if let date = item.startedAt { parts.append("\(state.day(date)) \(state.time(date))") }
    if let record = item.record {
      switch record.inputMode {
      case .roomMicrophone: parts.append(ZhijiCopy.inPerson)
      case .userItem: parts.append(ZhijiCopy.fromApp(record.sourceLabel))
      default: parts.append(record.sourceLabel)
      }
    }
    return parts.joined(separator: " · ")
  }
}

/// Corrections the organizing device did not take, each with 重试 / 放弃
/// (确认送达 when it may already have arrived; that one cannot be dropped).
struct IssueList: View {
  @Environment(\.zhiji) private var palette
  let issues: [MemoryIssue]
  let actions: MemoryActions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(ZhijiCopy.fixesNotTaken(issues.count))
        .font(.zhiji(13, .semibold))
        .foregroundStyle(palette.label)
      ForEach(issues) { issue in
        HStack(spacing: 10) {
          Text(issue.title)
            .font(.zhiji(12))
            .foregroundStyle(palette.secondary)
            .lineLimit(2)
          Spacer(minLength: 8)
          CapsuleButton(
            title: issue.deliveryUnknown ? ZhijiCopy.confirmDelivery : ZhijiCopy.retry,
            height: 26, fontSize: 12
          ) { actions.retryIssue(issue.id) }
          if !issue.deliveryUnknown {
            CapsuleButton(title: ZhijiCopy.discard, height: 26, fontSize: 12) {
              actions.discardIssue(issue.id)
            }
          }
        }
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 16)
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(palette.separator.opacity(0.8))
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.issues")
  }
}

/// Two overlapping avatars for a people question, else the event's people.
struct QuestionGlyph: View {
  @Environment(\.zhiji) private var palette
  let question: MemoryQuestion
  let state: MemoryScreenState
  let ring: Color

  var body: some View {
    let people = glyphPeople
    if people.isEmpty {
      Image(systemName: "square.on.square")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.accent)
        .frame(width: 28, height: 28)
        .background(palette.accent.opacity(0.14), in: Circle())
    } else {
      HStack(spacing: -6) {
        ForEach(Array(people.prefix(2).enumerated()), id: \.offset) { _, person in
          Avatar(person, size: 28, ring: ring)
        }
      }
    }
  }

  private var glyphPeople: [MemoryPersonRef] {
    if question.kind == .samePerson {
      return question.personIDs.map { id in
        if let person = state.person(id) {
          return MemoryPersonRef(personID: id, name: person.name, isNamed: person.isNamed)
        }
        return MemoryPersonRef(personID: id, name: MemoryProjection.unnamed, isNamed: false)
      }
    }
    let ids = [question.a, question.b]
    return ids.compactMap { state.entry($0) }.flatMap(\.shownPeople)
      .reduce(into: [MemoryPersonRef]()) { result, person in
        if !result.contains(person) { result.append(person) }
      }
  }
}

/// First run: what will appear here and the three ways in.
struct EmptyHome: View {
  @Environment(\.zhiji) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        ForEach(0..<3) { _ in
          RoundedRectangle(cornerRadius: ZhijiMetrics.cardRadius, style: .continuous)
            .strokeBorder(palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: 180, height: 110)
        }
      }
      Text(ZhijiCopy.emptyTitle)
        .font(.zhiji(15))
        .foregroundStyle(palette.label)
      HStack(spacing: 10) {
        hint("mic", ZhijiCopy.emptyDictation)
        hint("doc.on.clipboard", ZhijiCopy.emptyPaste)
        hint("arrow.down.doc", ZhijiCopy.emptyDrop)
      }
    }
    .padding(.top, 8)
  }

  private func hint(_ symbol: String, _ title: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 12))
      Text(title).font(.zhiji(13))
    }
    .foregroundStyle(palette.label)
    .padding(.horizontal, 12)
    .frame(height: 30)
    .background(palette.surface, in: Capsule())
  }
}
