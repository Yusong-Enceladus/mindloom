import AppKit
import BestASRDomain
import BestASRMemory
import Foundation

@testable import BestASRMemoryUI

/// The v10 prototype's own data, as the native pages read it: the synthetic
/// lab scenario's organizer state (`v7/map/state-sample.json`, a
/// `RemoteOrganizerState`: 243 events, 59 live, 27 maps) and the same run's
/// items (`scale/lab/score/spark-db-extract.json`: text, source App, capture
/// time). "Now" is the prototype's frozen 2026-09-20 22:46 in Asia/Shanghai.
/// The user's hand-made state is the prototype's `USER` overlay (pins E6
/// and E25; groups 论文 / TG-2 夹爪 / 生活; the space 实验室). All synthetic.
///
/// Loaded once per test process (about a second). Tests that need it skip
/// when the files are not on this Mac.
enum V11Fixture {
  static let statePath = "/Users/Shared/mindloom-demo/v7/map/state-sample.json"
  static let itemsPath = "/Users/Shared/mindloom-demo/scale/lab/score/spark-db-extract.json"
  static let owner = ["林知远", "知远"]

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.locale = Locale(identifier: "zh_CN")
    return calendar
  }

  /// 2026-09-20 22:46 +08:00 (a Sunday).
  static var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 22, minute: 46))!
  }

  static var isAvailable: Bool {
    FileManager.default.fileExists(atPath: statePath)
      && FileManager.default.fileExists(atPath: itemsPath)
  }

  struct Loaded: @unchecked Sendable {
    let state: RemoteOrganizerState
    let projection: MemoryProjection
    /// Handle (E6) → event ID.
    let handles: [String: String]
  }

  nonisolated(unsafe) private static var cache: Loaded?

  static func load() throws -> Loaded {
    if let cache { return cache }
    let state = try JSONDecoder().decode(
      RemoteOrganizerState.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: itemsPath)))
    guard let extract = raw as? [String: Any], let items = extract["items"] as? [[String: Any]],
      let jobs = extract["jobs"] as? [[String: Any]]
    else { throw CocoaError(.fileReadCorruptFile) }
    var started: [String: Double] = [:]
    for job in jobs {
      if let id = job["item_id"] as? String, let ts = job["started_ts"] as? Double {
        started[id.uppercased()] = ts
      }
    }
    let records: [MemoryItemRecord] = items.compactMap { item in
      guard let id = item["item_id"] as? String, let uuid = UUID(uuidString: id),
        let ts = started[id.uppercased()]
      else { return nil }
      var app: String?
      var bundle: String?
      if let source = item["source_app"] as? String,
        let json = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
      {
        app = json["name"] as? String
        bundle = json["bundle_id"] as? String
      }
      let kind: UserItemKind =
        switch item["kind"] as? String {
        case "image": .image
        case "document": .document
        default: .text
        }
      let date = Date(timeIntervalSince1970: ts)
      return MemoryItemRecord(
        sessionID: SessionID(uuid), inputMode: .userItem, itemKind: kind, title: "",
        startedAt: date, updatedAt: date, sourceBundleID: bundle, sourceDisplayName: app,
        sourceIdentifier: nil, text: item["text"] as? String)
    }
    let live = state.events.filter { !$0.deleted }
      .sorted { ($0.importance, $0.updatedAt ?? "") > ($1.importance, $1.updatedAt ?? "") }
    let projection = MemoryProjection(
      events: live.map(MemoryProjection.source), records: records, persons: state.persons,
      questions: state.questions, unfiled: state.unfiled ?? [], now: now)
    var handles: [String: String] = [:]
    for event in live { if let handle = event.handle { handles[handle] = event.eventID } }
    let loaded = Loaded(state: state, projection: projection, handles: handles)
    cache = loaded
    return loaded
  }

  /// The prototype's `USER`: pins E6 and E25; groups 论文 · TG-2 夹爪 · 生活.
  static func user(_ loaded: Loaded) -> UserOrganizingSnapshot {
    func ids(_ handles: [String]) -> [String] { handles.compactMap { loaded.handles[$0] } }
    let at = now.addingTimeInterval(-86_400 * 10)
    return UserOrganizingSnapshot(
      pins: ids(["E6", "E25"]).enumerated().map {
        UserPin(eventID: $1, pinnedAt: at.addingTimeInterval(Double($0)))
      },
      groups: [
        UserGroup(
          id: UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!, name: "论文", sortOrder: 0,
          createdAt: at, updatedAt: at, eventIDs: ids(["E6", "E3", "E10", "E29", "E208"])),
        UserGroup(
          id: UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!, name: "TG-2 夹爪",
          sortOrder: 1, createdAt: at, updatedAt: at, eventIDs: ids(["E15", "E52", "E95"])),
        UserGroup(
          id: UUID(uuidString: "00000000-0000-4000-8000-0000000000a3")!, name: "生活", sortOrder: 2,
          createdAt: at, updatedAt: at, eventIDs: ids(["E31", "E56", "E8"])),
      ])
  }

  /// The prototype's space 实验室 and who shared what.
  static func space(_ loaded: Loaded) -> (MemorySidebarSpace, [String: MemoryShareInfo]) {
    let space = MemorySidebarSpace(
      id: "sp1", name: "实验室", memberNames: ["周明澜", "宋雨桐", "高原", "韩策", "邓子墨"],
      admins: ["周明澜"])
    let shared: [(String, String?)] = [
      ("E6", nil), ("E3", nil), ("E11", "韩策"), ("E20", "邓子墨"), ("E7", "宋雨桐"), ("E2", "宋雨桐"),
    ]
    var sharing: [String: MemoryShareInfo] = [:]
    for (handle, by) in shared {
      guard let id = loaded.handles[handle] else { continue }
      sharing[id] = MemoryShareInfo(spaceID: "sp1", spaceName: "实验室", sharedBy: by)
    }
    return (space, sharing)
  }

  /// The full screen state of the prototype's default (`home`).
  static func state(
    _ loaded: Loaded, user: UserOrganizingSnapshot? = nil, link: MemoryLinkState? = nil
  ) -> MemoryScreenState {
    let user = user ?? Self.user(loaded)
    let model = MemoryReadModel(
      loaded.projection, user: user, now: now, calendar: calendar, ownerNames: owner)
    var state = MemoryScreenState(
      mode: .spark, readModel: model, user: user, now: now, calendar: calendar)
    let (space, sharing) = Self.space(loaded)
    state.spaces = [space]
    state.sharing = sharing
    state.link = link ?? MemoryLinkState(status: .connected, lastOrganizedAt: now.addingTimeInterval(-360))
    return state
  }

  /// An empty library (`empty`, first run done).
  static var emptyState: MemoryScreenState {
    MemoryScreenState(
      mode: .local, projection: MemoryProjection(events: [], records: [], now: now), now: now,
      calendar: calendar)
  }
}
