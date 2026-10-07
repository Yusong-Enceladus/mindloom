import BestASRDomain
import BestASRMemory
import MindloomDesign
import SwiftUI

@testable import BestASRMemoryUI

// OWNER: mac-matter. Scenes for S6–S8, S12 and the move / delete sheets
// (MAC-SPEC §1.2), plus `x-matter-*` extras (member view, empty and gone
// states, the delete sheet).

extension V11Scenes {
  @MainActor static var matter: [V11Scene] {
    func page(
      _ id: String, _ handle: String, tab: MatterTab = .progress, popover: MatterPopover? = nil,
      scroll: CGFloat = 0, state: ((V11Fixture.Loaded) -> MemoryScreenState)? = nil,
      overlay: AnyView? = nil
    ) -> V11Scene {
      V11Scene(id: id) { loaded in
        let window = V11Page.window(
          state?(loaded) ?? V11Fixture.state(loaded),
          V11Page.matter(loaded, handle, tab: tab, popover: popover), scroll: scroll)
        guard let overlay else { return window }
        return AnyView(window.overlay(alignment: .topLeading) { overlay })
      }
    }
    return [
      page("matter", "E6"),
      page("matter-popover", "E6", popover: .step("k8")),
      page("matter-due", "E6", popover: .step("st1")),
      page("matter-open", "E6", popover: .step("k5")),
      page("matter-fold", "E6", popover: .segment("s3")),
      page("matter-same-day", "E6", popover: .step("k6")),
      page("matter-text", "E6", tab: .text),
      page(
        "matter-text-menu", "E6", tab: .text, scroll: V11MatterFixture.menuScroll,
        state: { loaded in
          var state = V11Fixture.state(loaded)
          state.matterExtras.stillMenuRow = V11MatterFixture.menuRow(state, loaded)
          return state
        }),
      page("matter-dense", "E3"),
      page("matter-many", "E3", state: { V11MatterFixture.stressState($0) }),
      page("matter-offer", "E25"),
      page("matter-small", "E81"),
      page("matter-over", "E61"),
      page(
        "matter-menu", "E6",
        overlay: AnyView(
          V11StillMenu(
            rows: [
              .item("pin", "取消置顶"), .item("pencil", "重新命名"), .submenu("folder", "移到分组"),
              .item("person.2", "停止共享"), .separator, .item("doc.on.doc", "拷贝为文本", key: "⌘C"),
              .separator, .destructive("trash", "删除…"),
            ], width: 200
          )
          .offset(x: 1188 - 16 - 196 - 10 - 200, y: 52))),
      V11Scene(id: "rename") {
        var navigation = V11Page.matter($0, "E6")
        navigation.renaming = $0.handles["E6"]
        return V11Page.window(V11Fixture.state($0), navigation)
      },
      V11Scene(id: "move-item", size: CGSize(width: 560, height: 560)) { loaded in
        let context = MindloomPageContext(state: V11Fixture.state(loaded))
        return V11Page.surface {
          MoveSheet(
            context: context,
            input: MoveSheetInput(
              subject: .step(eventID: loaded.handles["E6"] ?? "", stepID: "k7")))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .mlShadow(.level3)
        }
      },
      V11Scene(id: "move-text", size: CGSize(width: 560, height: 560)) { loaded in
        let state = V11Fixture.state(loaded)
        let context = MindloomPageContext(state: state)
        let event = loaded.handles["E6"] ?? ""
        let entry = state.matterTexts(event).dropFirst(2).first
        return V11Page.surface {
          MoveSheet(
            context: context,
            input: MoveSheetInput(
              subject: .item(
                eventID: event, itemID: entry?.itemID ?? "", segID: entry?.segID)))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .mlShadow(.level3)
        }
      },
      page(
        "matter-long", "E3",
        state: { loaded in
          V11MatterFixture.renamed(
            loaded, "E3", to: "SkillKnit：用可组合技能做长程双臂操作的论文投稿与补充材料（NeurCon 2027）")
        }),
      // Extras (not prototype states).
      V11Scene(id: "x-matter-member") { loaded in
        V11Page.window(
          V11Fixture.state(loaded), V11Page.matter(loaded, "E2", from: .space("sp1")))
      },
      V11Scene(id: "x-matter-member-text") { loaded in
        V11Page.window(
          V11Fixture.state(loaded), V11Page.matter(loaded, "E2", tab: .text, from: .space("sp1")))
      },
      V11Scene(id: "x-matter-member-popover") { loaded in
        let matter = V11Fixture.state(loaded).matter(loaded.handles["E2"] ?? "")
        let step = matter?.steps.last { $0.evidence != nil }?.id
        return V11Page.window(
          V11Fixture.state(loaded),
          V11Page.matter(loaded, "E2", popover: step.map { .step($0) }, from: .space("sp1")))
      },
      V11Scene(id: "x-matter-gone") { loaded in
        var navigation = MemoryNavigation()
        navigation.path = [.matter("gone-matter")]
        return V11Page.window(V11Fixture.state(loaded), navigation)
      },
      V11Scene(id: "x-matter-text-reveal") { loaded in
        let state = V11Fixture.state(loaded)
        let event = loaded.handles["E6"] ?? ""
        let k8 = state.matter(event)?.step("k8")?.evidence?.rowID
        var navigation = V11Page.matter(loaded, "E6", tab: .text)
        navigation.revealRow = k8
        return V11Page.window(state, navigation, scroll: V11MatterFixture.revealScroll)
      },
      V11Scene(id: "x-matter-text-empty") { loaded in
        V11Page.window(
          V11MatterFixture.withoutItems(loaded, "E81"), V11Page.matter(loaded, "E81", tab: .text))
      },
      V11Scene(id: "x-matter-done") { loaded in
        // 标为完成 on st1 (交回复信): the mark becomes ● on today.
        let event = loaded.handles["E6"] ?? ""
        var user = V11Fixture.user(loaded)
        user.stepOverrides = [
          UserStepOverride(eventID: event, stepID: "st1", state: .done, createdAt: V11Fixture.now)
        ]
        return V11Page.window(V11Fixture.state(loaded, user: user), V11Page.matter(loaded, "E6"))
      },
      V11Scene(id: "x-delete", size: CGSize(width: 480, height: 240)) { loaded in
        let context = MindloomPageContext(state: V11Fixture.state(loaded))
        return V11Page.surface {
          DeleteMatterSheet(
            context: context, input: DeleteMatterSheetInput(eventID: loaded.handles["E6"] ?? ""))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .mlShadow(.level3)
        }
      },
      V11Scene(id: "x-move-filter", size: CGSize(width: 560, height: 420)) { loaded in
        let context = MindloomPageContext(state: V11Fixture.state(loaded))
        return V11Page.surface {
          MoveSheet(
            context: context,
            input: MoveSheetInput(
              subject: .step(eventID: loaded.handles["E6"] ?? "", stepID: "k7"), query: "Skill"))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .mlShadow(.level3)
        }
      },
    ]
  }
}

/// Fixture changes the matter scenes need (all synthetic).
@MainActor
enum V11MatterFixture {
  static let menuScroll: CGFloat = 900
  static let revealScroll: CGFloat = 700

  /// The 原文 row whose menu `matter-text-menu` shows (the 9月18日 17:33
  /// meeting line, as the prototype's shot).
  static func menuRow(_ state: MemoryScreenState, _ loaded: V11Fixture.Loaded) -> String? {
    let entries = state.matterTexts(loaded.handles["E6"] ?? "")
    let calendar = V11Fixture.calendar
    return entries.first {
      let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: $0.time)
      return parts.month == 9 && parts.day == 18 && parts.hour == 17 && parts.minute == 33
    }?.id ?? entries.dropFirst(10).first?.id
  }

  /// The state with one matter renamed (`long`, `matter-long`).
  static func renamed(_ loaded: V11Fixture.Loaded, _ handle: String, to title: String)
    -> MemoryScreenState
  {
    guard let id = loaded.handles[handle] else { return V11Fixture.state(loaded) }
    let projection = loaded.projection.applying([.rename(eventID: id, from: "", to: title)])
    return V11Fixture.state(
      V11Fixture.Loaded(state: loaded.state, projection: projection, handles: loaded.handles))
  }

  /// The matter with none of its items on this Mac (the 原文 empty state).
  static func withoutItems(_ loaded: V11Fixture.Loaded, _ handle: String) -> MemoryScreenState {
    guard let id = loaded.handles[handle],
      let event = loaded.projection.events.first(where: { $0.eventID == id })
    else { return V11Fixture.state(loaded) }
    let moves = event.itemIDs.map { MemoryCorrection.takeOut(itemID: $0, segID: nil, from: id) }
    let projection = loaded.projection.applying(moves)
    return V11Fixture.state(
      V11Fixture.Loaded(state: loaded.state, projection: projection, handles: loaded.handles))
  }

  /// `matter-many`: SkillKnit (E3) with one extra finished step per item
  /// (the prototype's `stressSteps()`: the first clause of 4+ characters,
  /// on the part sharing the most bigrams).
  static func stressState(_ loaded: V11Fixture.Loaded) -> MemoryScreenState {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: V11Fixture.statePath)),
      var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var events = root["events"] as? [[String: Any]],
      let index = events.firstIndex(where: { $0["handle"] as? String == "E3" }),
      var map = events[index]["map"] as? [String: Any],
      var knots = map["knots"] as? [[String: Any]],
      let strands = map["strands"] as? [[String: Any]],
      let items = events[index]["item_ids"] as? [String]
    else { return V11Fixture.state(loaded) }
    let lanes = strands.map {
      (
        $0["id"] as? String ?? "",
        MemoryDisplayText.bigrams(($0["name"] as? String ?? "") + ($0["summary"] as? String ?? ""))
      )
    }
    var added = 0
    let day = DateFormatter()
    day.calendar = V11Fixture.calendar
    day.timeZone = V11Fixture.calendar.timeZone
    day.dateFormat = "yyyy-MM-dd"
    let newestFirst = items.sorted {
      (loaded.projection.records[$0.uppercased()]?.startedAt ?? .distantPast)
        > (loaded.projection.records[$1.uppercased()]?.startedAt ?? .distantPast)
    }
    for item in newestFirst {
      guard added < 46, let record = loaded.projection.records[item.uppercased()],
        let text = record.text, record.startedAt <= V11Fixture.now
      else { continue }
      let clause = text.split(whereSeparator: { "，。！？；,\n".contains($0) })
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " :：[]0123456789-")) }
        .first { $0.count >= 4 } ?? String(text.prefix(16))
      let grams = MemoryDisplayText.bigrams(text)
      let best = lanes.max { $0.1.intersection(grams).count < $1.1.intersection(grams).count }?.0
      knots.append([
        "id": "x\(added)", "strand": best ?? "s1", "kind": "progress", "state": "done",
        "text": String(clause.prefix(24)), "date": day.string(from: record.startedAt), "who": [],
        "evidence": [item], "quote": "", "quote_item_id": item,
      ])
      added += 1
    }
    map["knots"] = knots
    events[index]["map"] = map
    root["events"] = events
    guard let patched = try? JSONSerialization.data(withJSONObject: root),
      let state = try? JSONDecoder().decode(RemoteOrganizerState.self, from: patched)
    else { return V11Fixture.state(loaded) }
    let live = state.events.filter { !$0.deleted }
      .sorted { ($0.importance, $0.updatedAt ?? "") > ($1.importance, $1.updatedAt ?? "") }
    let projection = MemoryProjection(
      events: live.map(MemoryProjection.source), records: Array(loaded.projection.records.values),
      persons: state.persons, questions: state.questions, unfiled: state.unfiled ?? [],
      now: V11Fixture.now)
    return V11Fixture.state(
      V11Fixture.Loaded(state: state, projection: projection, handles: loaded.handles))
  }
}

/// A still image of an in-window menu (§7.5) for snapshots: the real menus
/// are AppKit's, which `ImageRenderer` does not draw.
struct V11StillMenu: View {
  enum Row {
    case item(String, String, key: String? = nil)
    case submenu(String, String)
    case destructive(String, String)
    case separator
  }

  let rows: [Row]
  let width: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        switch row {
        case .separator:
          Rectangle().fill(MLColor.rule2).frame(height: 0.5).padding(.vertical, 5).padding(
            .horizontal, 10)
        case .item(let symbol, let title, let key):
          line(symbol, title, color: MLColor.ink, icon: MLColor.ink2, trailing: key)
        case .submenu(let symbol, let title):
          line(symbol, title, color: MLColor.ink, icon: MLColor.ink2, trailing: "›")
        case .destructive(let symbol, let title):
          line(symbol, title, color: MLColor.alert, icon: MLColor.alert, trailing: nil)
        }
      }
    }
    .padding(6)
    .frame(width: width, alignment: .leading)
    .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func line(_ symbol: String, _ title: String, color: MLColor, icon: MLColor, trailing: String?)
    -> some View
  {
    HStack(spacing: 8) {
      Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(icon).frame(width: 14)
      Text(title).mlFont(\.control).foregroundStyle(color)
      Spacer(minLength: 0)
      if let trailing { Text(trailing).mlFont(\.control).foregroundStyle(MLColor.ink3) }
    }
    .padding(.horizontal, 10)
    .frame(height: 24)
  }
}
