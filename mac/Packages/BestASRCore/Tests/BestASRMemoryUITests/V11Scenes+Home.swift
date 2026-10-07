import BestASRDomain
import BestASRMemory
import MindloomDesign
import SwiftUI

@testable import BestASRMemoryUI

// OWNER: mac-home. Scenes for S1–S5, S9, S10 and the matter menu / group
// sheets (MAC-SPEC §1.2). Each scene builds the fixture state the
// prototype's state shows.

extension V11Scenes {
  @MainActor static var home: [V11Scene] {
    [
      V11Scene(id: "home") { V11Page.window(V11Fixture.state($0)) },
      V11Scene(id: "home-earlier") {
        // 「更早」 open, scrolled so 「上周」 sits 84 pt below the top of the page.
        V11Page.window(
          V11Fixture.state($0), MemoryNavigation(earlierOpen: true),
          scroll: V11HomeFixture.lastWeekScroll(V11Fixture.state($0)))
      },
      V11Scene(id: "home-deadline") {
        V11Page.window(V11Fixture.state($0), MemoryNavigation(homeLens: .deadlines))
      },
      V11Scene(id: "home-people") {
        V11Page.window(V11Fixture.state($0), MemoryNavigation(homeLens: .people))
      },
      V11Scene(id: "home-menu") { loaded in
        var state = V11Fixture.state(loaded)
        let id = loaded.handles["E6"] ?? ""
        state.homeExtras.menuEventID = id
        return V11Page.overlay(V11Page.window(state), at: CGPoint(x: 500, y: 484)) {
          MatterMenuStill(state: state, eventID: id, submenu: false)
        }
      },
      V11Scene(id: "captured") {
        var state = V11Fixture.state($0)
        state.waitingCaptures = [V11HomeFixture.pasted]
        return V11Page.window(state)
      },
      V11Scene(id: "organized") {
        var state = V11Fixture.state($0)
        state.highlightedEventID = $0.handles["E6"]
        state.toast = MemoryToast(
          "已归进「TES 论文 RoboPrior 大修返修」", icon: .none,
          action: .view(eventID: $0.handles["E6"] ?? "", stepID: nil))
        return V11Page.window(state)
      },
      V11Scene(id: "offline") {
        var state = V11Fixture.state($0, link: MemoryLinkState(status: .notConnected, waiting: 3))
        state.waitingCaptures = V11HomeFixture.offline
        return V11Page.window(state)
      },
      V11Scene(id: "empty") { _ in V11Page.window(V11Fixture.emptyState) },
      V11Scene(id: "long") { loaded in
        V11Page.window(V11HomeFixture.renamed(loaded, "E6", to: V11HomeFixture.longTitle))
      },
      // v12 find: 历史 (search and history are one page).
      V11Scene(id: "search") { V11HistoryFixture.window($0, "回复信") },
      V11Scene(id: "search-person") { V11HistoryFixture.window($0, "宋雨桐") },
      V11Scene(id: "search-none") { V11HistoryFixture.window($0, "火星基地") },
      V11Scene(id: "search-empty") { V11HistoryFixture.window($0, "") },
      V11Scene(id: "x-history-chips") { V11HistoryFixture.window($0, "上周 微信 RoboPrior") },
      V11Scene(id: "x-history-typo") { V11HistoryFixture.window($0, "肉包 返修") },
      V11Scene(id: "x-history-dictionary", size: CGSize(width: 560, height: 520)) { loaded in
        let state = V11HistoryFixture.state(loaded, "")
        let row = state.history.rows.first { $0.fullText.count > 30 } ?? state.history.rows[0]
        return V11Page.surface {
          AddToDictionarySheet(
            context: MindloomPageContext(state: state),
            input: AddToDictionarySheetInput(itemID: row.itemID, heard: "肉包", written: "RoboPrior"))
        }
      },
      V11Scene(id: "people") {
        let state = V11Fixture.state($0)
        let person = state.people.first { $0.name == "宋雨桐" }?.personID ?? ""
        return V11Page.window(state, MemoryNavigation(path: [.person(person)], homeLens: .people))
      },
      V11Scene(id: "group") {
        V11Page.window(
          V11Fixture.state($0), MemoryNavigation(root: .group("00000000-0000-4000-8000-0000000000a1")))
      },
      V11Scene(id: "group-new") { loaded in
        let state = V11Fixture.state(loaded)
        return V11Page.sheet(V11Page.window(state)) {
          NewGroupSheet(
            context: MindloomPageContext(state: state),
            input: NewGroupSheetInput(moving: nil, draft: "课题组杂事"))
        }
      },
      V11Scene(id: "group-empty") { loaded in
        V11Page.window(
          V11HomeFixture.withEmptyGroup(loaded),
          MemoryNavigation(root: .group(V11HomeFixture.emptyGroup.uuidString.lowercased())))
      },
      V11Scene(id: "group-add") { loaded in
        let state = V11HomeFixture.withEmptyGroup(loaded)
        let id = V11HomeFixture.emptyGroup.uuidString.lowercased()
        return V11Page.sheet(V11Page.window(state, MemoryNavigation(root: .group(id)))) {
          AddToGroupSheet(
            context: MindloomPageContext(state: state), input: AddToGroupSheetInput(groupID: id))
        }
      },
      V11Scene(id: "matter-group-menu") { loaded in
        let state = V11Fixture.state(loaded)
        return V11Page.overlay(
          V11Page.window(state, V11Page.matter(loaded, "E225")), at: CGPoint(x: 767, y: 49)
        ) {
          MatterMenuStill(state: state, eventID: loaded.handles["E225"] ?? "", submenu: true)
        }
      },
    ]
  }
}

/// The fixture changes the prototype's Home states make.
enum V11HomeFixture {
  static let emptyGroup = UUID(uuidString: "00000000-0000-4000-8000-0000000000a4")!

  static var longTitle: String { "TES期刊论文RoboPrior大修返修：补实验、理论推导与回复信（第二轮，含审稿人3的全部意见与新增的仿真对照）" }

  static func at(_ hour: Int, _ minute: Int) -> Date {
    V11Fixture.calendar.date(
      from: DateComponents(year: 2026, month: 9, day: 20, hour: hour, minute: minute))!
  }

  /// `captured`: one paste with no destination.
  static var pasted: MemoryWaitingCapture {
    MemoryWaitingCapture(
      id: "CAP-PASTE", firstLine: "周五下午三点 B203 碰一下新夹爪的标定，叫上孟凡。", kind: "粘贴",
      symbol: "doc.on.clipboard", capturedAt: at(22, 44))
  }

  /// `offline`: three captures waiting for the DGX Spark.
  static var offline: [MemoryWaitingCapture] {
    [
      MemoryWaitingCapture(
        id: "CAP-1", firstLine: "表2重跑完了，结果稳定，回复信里那段明天改掉。", kind: "口述", symbol: "mic",
        capturedAt: at(22, 41)),
      MemoryWaitingCapture(
        id: "CAP-2", firstLine: "高原：cover letter 第一段我又删了两句，你看下", kind: "微信",
        symbol: "bubble.left", capturedAt: at(22, 20)),
      MemoryWaitingCapture(
        id: "CAP-3", firstLine: "顺丰速运 · 已发货 · 预计 9月23日 送达", kind: "截图", symbol: "photo",
        capturedAt: at(22, 10), thumbnail: .photo),
    ]
  }

  /// The prototype's state with one matter renamed (`long`).
  @MainActor
  static func renamed(_ loaded: V11Fixture.Loaded, _ handle: String, to title: String)
    -> MemoryScreenState
  {
    let id = loaded.handles[handle] ?? ""
    let from = V11Fixture.state(loaded).matter(id)?.title ?? ""
    let projection = loaded.projection.applying([.rename(eventID: id, from: from, to: title)])
    let user = V11Fixture.user(loaded)
    let model = MemoryReadModel(
      projection, user: user, now: V11Fixture.now, calendar: V11Fixture.calendar,
      ownerNames: V11Fixture.owner)
    var state = MemoryScreenState(
      mode: .spark, readModel: model, user: user, now: V11Fixture.now, calendar: V11Fixture.calendar)
    let (space, sharing) = V11Fixture.space(loaded)
    state.spaces = [space]
    state.sharing = sharing
    state.link = MemoryLinkState(status: .connected)
    return state
  }

  /// The prototype's groups plus an empty 「课题组杂事」.
  static func withEmptyGroup(_ loaded: V11Fixture.Loaded) -> MemoryScreenState {
    var user = V11Fixture.user(loaded)
    user.groups.append(
      UserGroup(
        id: emptyGroup, name: "课题组杂事", sortOrder: 3, createdAt: V11Fixture.now,
        updatedAt: V11Fixture.now))
    return V11Fixture.state(loaded, user: user)
  }

  /// How far Home is scrolled when 「上周」's header is 84 pt below the top
  /// of the page: everything above it measured by the same layout rules as
  /// the page (title 10 + 32, axis 14 + 26, headers, 56 pt rows).
  static func lastWeekScroll(_ state: MemoryScreenState) -> CGFloat {
    let days = HomeDays(state)
    let groups = HomeDerivation.timeGroups(state.digest?.matters ?? [], days: days)
    var y: CGFloat = 56 + 10 + 32 + 14 + 26
    for (index, group) in groups.enumerated() {
      if group.kind == .lastWeek { return y - 84 + (index == 0 ? 12 : 24) - 30 }
      y += (index == 0 ? 12 : 24) + 14 + 6
      y += CGFloat(group.matters.count) * 56
    }
    return 0
  }
}

extension V11Page {
  /// A still menu laid over the window at a point (window coordinates).
  @MainActor
  static func overlay<Content: View>(
    _ window: AnyView, at point: CGPoint, @ViewBuilder _ content: () -> Content
  ) -> AnyView {
    AnyView(
      ZStack(alignment: .topLeading) {
        window
        content().offset(x: point.x, y: point.y)
      })
  }

  /// A window-modal sheet over the window: the scrim and the card 64 pt from
  /// the top, centred (§7.4).
  @MainActor
  static func sheet<Content: View>(_ window: AnyView, @ViewBuilder _ content: () -> Content)
    -> AnyView
  {
    AnyView(
      ZStack(alignment: .top) {
        window
        Rectangle().fill(MLColor.scrim)
        content().padding(.top, 64)
      })
  }
}

/// v12 find: the 历史 page's values from the v10 fixture's records, as the
/// App builds them from the store (the in-memory rules match the index's).
enum V11HistoryFixture {
  @MainActor
  static func window(_ loaded: V11Fixture.Loaded, _ query: String) -> AnyView {
    V11Page.window(state(loaded, query), MemoryNavigation(root: .search, search: query))
  }

  @MainActor
  static func state(_ loaded: V11Fixture.Loaded, _ query: String) -> MemoryScreenState {
    var state = V11Fixture.state(loaded)
    let people = (state.projection?.persons ?? []).compactMap { person -> SearchPerson? in
      guard let name = person.displayName, person.mergedInto == nil else { return nil }
      return SearchPerson(id: person.personID, name: name, aliases: person.aliases)
    }
    let context = SearchContext(
      people: people, ownerNames: Set(state.ownerNameSet),
      lexicon: [SearchLexiconEntry(canonical: "RoboPrior", spoken: ["肉包"])],
      sourceNames: ["微信", "腾讯会议", "邮件"], clock: SearchClock(now: V11Fixture.now))
    let parsed = SearchQueryParser.parse(query, context: context)
    let index = MemoryHistoryBuilder.matterIndex(state.digest)
    let records = (state.projection?.records.values.map { $0 } ?? [])
      .filter { record in
        let text = MemoryHistoryBuilder.shownText(record)
        if !parsed.units.isEmpty, !parsed.matches(SearchTokens(text)) { return false }
        if let interval = parsed.interval, !interval.contains(record.startedAt) { return false }
        if !parsed.sources.isEmpty,
          !parsed.sources.contains(where: {
            $0.matches(
              sourceName: record.sourceDisplayName, inputMode: record.inputMode.rawValue,
              itemKind: record.itemKind?.rawValue, sourceKind: nil,
              sourceIdentifier: record.sourceIdentifier)
          })
        {
          return false
        }
        for person in parsed.people
        where !person.spellings.contains(where: { text.contains($0) }) {
          return false
        }
        return true
      }
      .sorted { $0.startedAt > $1.startedAt }
    let rows = records.prefix(40).map { record in
      MemoryHistoryBuilder.row(
        record, query: parsed, matter: index[record.sessionID.rawValue.uuidString.uppercased()])
    }
    state.history = MemoryHistoryState(
      query: query, chips: parsed.chips, ordersByTime: parsed.ordersByTime,
      matters: MemoryHistoryBuilder.matters(parsed, digest: state.digest),
      personIDs: MemoryHistoryBuilder.people(parsed, people: state.people), rows: rows,
      total: records.count, hasMore: records.count > 40,
      highlights: parsed.units.isEmpty ? [] : parsed.highlights)
    return state
  }
}
