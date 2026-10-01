import AppKit
import BestASRDomain
import BestASRMemory
import MindloomSpaces
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// The shared-space pages: what each member may do with each item (by role,
/// space type and the withdraw window), and every space view drawn in light
/// and dark (written to `BESTASR_UI_SNAPSHOT_DIR` when it is set).
@MainActor
final class SpaceUITests: XCTestCase {
  static let now = Date(timeIntervalSince1970: 1_790_000_000)
  static let me = "11111111-0000-4000-8000-000000000001"
  static let mate = "22222222-0000-4000-8000-000000000002"

  static func space(
    _ kind: SpaceOwnerKind, role: SpaceRole, sharedHoursAgo: Double = 2, archived: Bool = false
  ) -> SpaceLocalState {
    var state = SpaceLocalState(
      spaceID: "33333333-0000-4000-8000-000000000003", memberID: me, name: "实验室",
      ownerKind: kind, orgID: nil, policy: kind == .org ? .org : .group, role: role,
      membership: .active, spark: nil)
    state.archived = archived
    state.knownNames = [me: "林知远", mate: "韩策"]
    let shared = now.addingTimeInterval(-sharedHoursAgo * 3_600)
    for (id, by, title) in [
      ("44444444-0000-4000-8000-000000000001", me, "租约草稿"),
      ("44444444-0000-4000-8000-000000000002", mate, "装修报价"),
    ] {
      state.items[id] = SpaceSharedItem(
        itemID: id, contributor: by, kind: "text", revision: 1, shareSeq: 2,
        firstSharedAt: shared, updatedAt: shared,
        fields: SpaceItemFields(kind: "text", title: title, text: "\(title)：周五前定。"),
        blobs: [SpaceBlobRef(blobID: "55555555-0000-4000-8000-000000000001", role: "original")],
        segment: nil, packageID: nil, status: .active, keyEpoch: 1)
    }
    let names = state.knownNames
    let member = { (id: String, role: SpaceRole) -> SpaceMember in
      let record: SpaceJSON = [
        "member_id": .string(id), "role": .string(role.rawValue),
        "effective_role": .string(role.rawValue), "outside": false, "status": "active",
        "owner": .bool(kind == .person && id == me), "org_admin": false, "devices": [],
      ]
      // swift-format-ignore: NeverUseForceTry
      return SpaceMember(
        record: try! record.decoded(as: SpaceMemberRecord.self), displayName: names[id])
    }
    state.members = [member(me, role), member(mate, .write)]
    return state
  }

  private var ids: [String] { Self.space(.org, role: .write).items.keys.sorted() }

  func testItemRowsFollowRoleSpaceTypeAndTheWithdrawWindow() {
    // Org space, my item within 24 h: withdraw and delete; theirs: hide and
    // a privacy takedown, no fork (org default).
    var info = SpaceMatterInfo.make(
      state: Self.space(.org, role: .write), itemIDs: ids, contributionLine: nil, now: Self.now)
    XCTAssertEqual(
      info.items.map(\.actions), [[.withdraw, .delete], [.hide, .requestPrivacyTakedown]])
    XCTAssertEqual(info.items.first?.windowNote, "还能撤回 22 小时")
    XCTAssertEqual(info.items.last?.contributor, "韩策")
    // Past the window my item can only be deleted (a takedown request).
    info = SpaceMatterInfo.make(
      state: Self.space(.org, role: .write, sharedHoursAgo: 30), itemIDs: ids,
      contributionLine: nil, now: Self.now)
    XCTAssertEqual(info.items.first?.actions, [.delete])
    // Group space: forks allowed; a maintainer may remove anyone's item.
    info = SpaceMatterInfo.make(
      state: Self.space(.person, role: .maintain), itemIDs: ids, contributionLine: nil,
      now: Self.now)
    XCTAssertEqual(info.items.last?.actions, [.hide, .requestPrivacyTakedown, .fork, .remove])
    XCTAssertTrue(info.canEdit)
    // An archived space is read-only.
    info = SpaceMatterInfo.make(
      state: Self.space(.org, role: .admin, archived: true), itemIDs: ids, contributionLine: nil,
      now: Self.now)
    XCTAssertTrue(info.items.allSatisfy(\.actions.isEmpty))
    // A text-only space shows no original to open.
    var textOnly = Self.space(.person, role: .write)
    textOnly.policy.originals = "text_only"
    info = SpaceMatterInfo.make(state: textOnly, itemIDs: ids, contributionLine: nil, now: Self.now)
    XCTAssertTrue(info.items.allSatisfy(\.originals.isEmpty))
  }

  private func screens() -> [(String, SpacesScreenState, SpaceSheet?, MemoryNavigation)] {
    let space = Self.space(.org, role: .admin)
    var base = SpacesScreenState()
    base.spaces = [space]
    base.linkReady = true
    base.myFingerprint = "A1B2-C3D4-E5F6"
    base.badges["ev-rent"] = SpaceBadgeInfo(
      spaceID: space.spaceID, spaceEventID: "ev-1", text: "共享版更完整 · +2 条，来自 韩策")
    base.sharedMatters["ev-rent"] = [space.spaceID]
    base.joinRequests[space.spaceID] = [
      SpaceJoinRequestView(
        requestID: "66666666-0000-4000-8000-000000000001", memberID: Self.mate,
        displayName: "韩策", fingerprint: "9F3C-11AB-7E20", role: .write, outside: false,
        createdAt: Self.now,
        device: SpaceDevicePublic(deviceID: "d", signPub: "AAAA", sealPub: "AAAA"))
    ]
    let audit: SpaceJSON = [
      [
        "id": 1, "seq": 1, "at": "2026-09-30T10:00:00+08:00", "actor_member": .string(Self.me),
        "action": "space.create", "target": [:],
      ],
      [
        "id": 2, "seq": 5, "at": "2026-09-30T10:05:00+08:00", "actor_member": .string(Self.mate),
        "action": "item.share", "target": ["blobs": 1],
      ],
    ]
    let takedown: SpaceJSON = [
      "takedown_id": "77777777-0000-4000-8000-000000000001", "item_id": .string(ids[1]),
      "kind": "privacy", "requester": .string(Self.me), "status": "open",
      "due_at": "2026-10-03T10:00:00+08:00",
    ]
    // swift-format-ignore: NeverUseForceTry
    base.audit[space.spaceID] = try! audit.decoded(as: [SpaceAuditRecord].self)
    // swift-format-ignore: NeverUseForceTry
    base.takedowns[space.spaceID] = [try! takedown.decoded(as: SpaceTakedownRecord.self)]
    var inSpace = base
    inSpace.scope = .space(space.spaceID)
    inSpace.matters["ev-rent"] = SpaceMatterInfo.make(
      state: space, itemIDs: ids, contributionLine: "林知远 1 条 + 韩策 1 条", now: Self.now)
    var all = base
    all.scope = .all
    var share = base
    share.shareDraft = SpaceShareDraft(
      eventID: "ev-rent", title: "租房续约", destinations: [space], destination: space.spaceID,
      rope: (id: "rope-1", title: "生活", matters: 6),
      review: SpaceShareReview(candidates: [
        SpaceShareCandidate(
          id: "a", sourceItemID: "a", kind: .item, wireKind: "text", title: "房东说涨 200",
          preview: "那涨 200 我这边没问题", startedAt: nil, isPrivateDictation: false,
          numberLabels: [], hasOriginal: false),
        SpaceShareCandidate(
          id: "b", sourceItemID: "b", kind: .item, wireKind: "dictation", title: "给房东回微信",
          preview: "好的周五见", startedAt: nil, isPrivateDictation: true, numberLabels: [],
          hasOriginal: false),
        SpaceShareCandidate(
          id: "c", sourceItemID: "c", kind: .item, wireKind: "image", title: "合同截图",
          preview: "", startedAt: nil, isPrivateDictation: false, numberLabels: ["手机号", "身份证号"],
          hasOriginal: true),
        SpaceShareCandidate(
          id: "d", sourceItemID: "rec",
          kind: .segment(parentItemID: "rec", startMS: 60_000, endMS: 180_000),
          wireKind: "audio_segment", title: "看房录音（1:00–3:00）", preview: "王姐：押金一个月",
          startedAt: nil, isPrivateDictation: false, numberLabels: [], hasOriginal: false),
      ]), sharedIn: [:])
    return [
      ("space-home-mine", base, nil, MemoryNavigation()),
      ("space-home-space", inSpace, nil, MemoryNavigation()),
      ("space-home-all", all, nil, MemoryNavigation()),
      ("space-event-mine-badge", base, nil, MemoryNavigation(path: [.event("ev-rent")])),
      ("space-event-in-space", inSpace, nil, MemoryNavigation(path: [.event("ev-rent")])),
      ("space-sheet-share", share, .share(eventID: "ev-rent"), MemoryNavigation()),
      ("space-sheet-members", base, .members(spaceID: space.spaceID), MemoryNavigation()),
      (
        "space-sheet-items", inSpace, .items(spaceID: space.spaceID, eventID: "ev-rent"),
        MemoryNavigation()
      ),
      ("space-sheet-review", base, .review(spaceID: space.spaceID), MemoryNavigation()),
      ("space-sheet-audit", base, .audit(spaceID: space.spaceID), MemoryNavigation()),
      ("space-sheet-new", base, .newSpace, MemoryNavigation()),
      ("space-sheet-join", base, .join, MemoryNavigation()),
    ]
  }

  /// Every space view draws (light and dark); with `BESTASR_UI_SNAPSHOT_DIR`
  /// set, the PNGs are written there.
  func testSpaceViewsDraw() throws {
    let output = ProcessInfo.processInfo.environment["BESTASR_UI_SNAPSHOT_DIR"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    if let output {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    let fixture = MemorySnapshotFixture.self
    for (name, spaces, sheet, navigation) in screens() {
      for scheme in [ColorScheme.light, .dark] {
        var memory = MemoryScreenState(
          mode: .spark, projection: fixture.sparkProjection(questions: false), now: fixture.now,
          calendar: fixture.calendar, thumbnail: fixture.thumbnail)
        if spaces.scope == .all {
          memory.sharedItemIDs = [fixture.item(2).uppercased(), fixture.item(4).uppercased()]
        }
        let content: AnyView
        let size: CGSize
        if let sheet {
          content = AnyView(SpaceSheetHost(sheet: sheet, state: spaces, actions: .inert))
          size = CGSize(width: 560, height: 900)
        } else {
          content = AnyView(
            ZhijiShell(
              navigation: .constant(navigation), state: memory, actions: .inert,
              slots: MemoryShellSlots(
                homeAccessory: { AnyView(SpaceSwitcherBar(state: spaces, actions: .inert)) },
                eventAccessory: { id in
                  SpaceMatterBar.shows(eventID: id, state: spaces)
                    ? AnyView(SpaceMatterBar(eventID: id, state: spaces, actions: .inert)) : nil
                })))
          size = CGSize(width: 1280, height: 900)
        }
        let view =
          content
          .frame(width: size.width, height: size.height)
          .environment(\.colorScheme, scheme)
          .environment(\.zhijiSnapshot, true)
          .environment(\.locale, Locale(identifier: "zh-Hans"))
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, name)
        XCTAssertEqual(image.width, Int(size.width), name)
        if let output {
          let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
          try png.write(
            to: output.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"),
            options: .atomic)
        }
      }
    }
  }
}
