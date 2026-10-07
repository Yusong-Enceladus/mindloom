import AppKit
import Foundation
import MindloomSpaces
import SwiftUI

/// Which library Home shows: 我的, one shared space, or 全部 (both overlaid,
/// the shared threads two-tone).
public enum SpaceScope: Hashable, Sendable {
  case mine
  case space(String)
  case all

  public var spaceID: String? {
    if case .space(let id) = self { return id }
    return nil
  }
}

/// The sheets of shared spaces.
public enum SpaceSheet: Identifiable, Equatable, Sendable {
  case newSpace
  case join
  case members(spaceID: String)
  case share(eventID: String)
  case items(spaceID: String, eventID: String)
  case review(spaceID: String)
  case audit(spaceID: String)
  case propose(spaceID: String, eventID: String)
  /// 交接: hand a matter's 负责人 to another member, with a handover pack.
  case handover(spaceID: String, eventID: String)
  /// 邀请到「{space}」 (v11).
  case invite(spaceID: String)

  public var id: String {
    switch self {
    case .newSpace: "new"
    case .join: "join"
    case .members(let s): "members-\(s)"
    case .share(let e): "share-\(e)"
    case .items(let s, let e): "items-\(s)-\(e)"
    case .review(let s): "review-\(s)"
    case .audit(let s): "audit-\(s)"
    case .propose(let s, let e): "propose-\(s)-\(e)"
    case .handover(let s, let e): "handover-\(s)-\(e)"
    case .invite(let s): "invite-\(s)"
    }
  }
}

/// "共享版更完整 · +N 条，来自 …" on one of my matters.
public struct SpaceBadgeInfo: Equatable, Sendable {
  public let spaceID: String
  public let spaceEventID: String
  public let text: String

  public init(spaceID: String, spaceEventID: String, text: String) {
    self.spaceID = spaceID
    self.spaceEventID = spaceEventID
    self.text = text
  }
}

/// One shared item as a row with what this member may do with it.
public struct SpaceItemRow: Identifiable, Equatable, Sendable {
  public let itemID: String
  public let title: String
  public let preview: String
  public let contributor: String
  public let isMine: Bool
  public let sharedAt: Date
  public let kindLabel: String
  public let actions: [SpaceRules.ItemAction]
  public let hidden: Bool
  public let forked: Bool
  /// Opens with the member's key (a file, a screenshot, a segment's audio).
  public let originals: [SpaceBlobRef]
  /// "还能撤回 5 小时" in an org space, or nil.
  public let windowNote: String?
  /// A meeting part's audio (members play it after checking its length).
  public let audio: SpaceBlobRef?
  /// A frozen summary: what it was made from.
  public let snapshotNote: String?

  public var id: String { itemID }

  public init(
    itemID: String, title: String, preview: String, contributor: String, isMine: Bool,
    sharedAt: Date, kindLabel: String, actions: [SpaceRules.ItemAction], hidden: Bool,
    forked: Bool, originals: [SpaceBlobRef], windowNote: String?, audio: SpaceBlobRef? = nil,
    snapshotNote: String? = nil
  ) {
    self.audio = audio
    self.snapshotNote = snapshotNote
    self.itemID = itemID
    self.title = title
    self.preview = preview
    self.contributor = contributor
    self.isMine = isMine
    self.sharedAt = sharedAt
    self.kindLabel = kindLabel
    self.actions = actions
    self.hidden = hidden
    self.forked = forked
    self.originals = originals
    self.windowNote = windowNote
  }
}

/// A matter shown inside a space: whose items it holds and the rows.
public struct SpaceMatterInfo: Equatable, Sendable {
  /// The rows of a matter's items in a space, with what this member may do
  /// with each (by role, space type and the withdraw window).
  public static func make(
    state: SpaceLocalState, itemIDs: [String], contributionLine: String?, now: Date
  ) -> SpaceMatterInfo {
    var seen = Set<String>()
    let rows: [SpaceItemRow] = itemIDs.compactMap { raw in
      let id = raw.lowercased()
      guard seen.insert(id).inserted, let item = state.items[id], item.isActive else { return nil }
      let mine = item.contributor == state.memberID
      let context = SpaceRules.ItemContext(
        isMine: mine, role: state.role, policy: state.policy, firstShared: item.firstSharedAt,
        hidden: state.hidden.contains(id), forked: state.forks[id] != nil,
        archived: state.archived)
      var note: String?
      if mine,
        let left = SpaceRules.withdrawWindowRemaining(
          policy: state.policy, firstShared: item.firstSharedAt, now: now)
      {
        note = left > 0 ? "可在 \(max(1, Int(left / 3_600))) 小时内撤回" : nil
      }
      let fields = item.fields
      let originals = state.policy.originalsForMembers ? item.blobs : []
      let snapshot = item.snapshot.map { ref in
        "固定的摘要\(ref.cites.isEmpty ? "" : "，引用 \(ref.cites.count) 条原文；引用的原文撤回时，此条也将撤回")"
      }
      return SpaceItemRow(
        itemID: id, title: fields?.title ?? "共享的内容",
        preview: String((fields?.text ?? fields?.reading ?? "").prefix(80)),
        contributor: state.name(of: item.contributor), isMine: mine, sharedAt: item.firstSharedAt,
        kindLabel: SpaceWords.kind(item.kind),
        actions: state.archived ? [] : SpaceRules.actions(context, now: now),
        hidden: state.hidden.contains(id), forked: state.forks[id] != nil,
        originals: originals.filter { $0.role != "audio" }, windowNote: note,
        audio: originals.first { $0.role == "audio" }, snapshotNote: snapshot)
    }
    return SpaceMatterInfo(
      spaceID: state.spaceID, spaceName: state.name, contributionLine: contributionLine,
      items: rows, canPropose: state.can("propose"), canEdit: state.can("edit_matters"),
      canHandover: state.can("handover"))
  }

  public let spaceID: String
  public let spaceName: String
  /// "林知远 2 条 + 韩策 3 条".
  public let contributionLine: String?
  public let items: [SpaceItemRow]
  public let canPropose: Bool
  public let canEdit: Bool
  /// May hand the matter's 负责人 to another member (maintainers and admins).
  public let canHandover: Bool

  public init(
    spaceID: String, spaceName: String, contributionLine: String?, items: [SpaceItemRow],
    canPropose: Bool, canEdit: Bool, canHandover: Bool = false
  ) {
    self.spaceID = spaceID
    self.spaceName = spaceName
    self.contributionLine = contributionLine
    self.items = items
    self.canPropose = canPropose
    self.canEdit = canEdit
    self.canHandover = canHandover
  }
}

/// The share sheet's content for one of my matters.
public struct SpaceShareDraft: Equatable, Sendable {
  public let eventID: String
  public let title: String
  /// Spaces this member may share into.
  public let destinations: [SpaceLocalState]
  public var destination: String?
  /// The rope (领域) the matter is on, if any.
  public let rope: (id: String, title: String, matters: Int)?
  public var review: SpaceShareReview
  public var scale: SpaceShareScale
  /// For 只这一条: the one item picked.
  public var picked: String?
  /// The spaces this matter is already in (as a package).
  public let sharedIn: [String: SpaceRuleMode]
  /// 一份摘要 (review V8R-11): what it may be made of, and the exact text
  /// that goes (shown and editable before sharing).
  public var snapshotStatus: String?
  public var snapshotFacts: [SpaceSnapshotText.Fact] = []
  public var snapshotText: String = ""
  /// The member edited the text: ticking items no longer rewrites it.
  public var snapshotEdited = false
  /// v11 「查看会共享什么」: each candidate's kind (the App knows the items'
  /// sources; unknown ones are told by their wire kind).
  public var kindOf: [String: ShareKind] = [:]
  /// 「进展和接下来的事」's count: the matter's dated steps.
  public var progressCount = 0

  /// The snapshot text from the ticked items (unless the member edited it).
  public mutating func refreshSnapshot() {
    guard !snapshotEdited else { return }
    snapshotText = SpaceSnapshotText.make(
      title: title, statusLine: snapshotStatus, facts: snapshotFacts, review: review)
  }

  public init(
    eventID: String, title: String, destinations: [SpaceLocalState], destination: String?,
    rope: (id: String, title: String, matters: Int)?, review: SpaceShareReview,
    sharedIn: [String: SpaceRuleMode]
  ) {
    self.eventID = eventID
    self.title = title
    self.destinations = destinations
    self.destination = destination
    self.rope = rope
    self.review = review
    scale = .matter(rule: .ask)
    picked = review.candidates.last?.id
    self.sharedIn = sharedIn
  }

  public static func == (lhs: SpaceShareDraft, rhs: SpaceShareDraft) -> Bool {
    lhs.eventID == rhs.eventID && lhs.destination == rhs.destination
      && lhs.review == rhs.review && lhs.scale == rhs.scale && lhs.picked == rhs.picked
      && lhs.rope?.id == rhs.rope?.id && lhs.snapshotText == rhs.snapshotText
  }
}

/// What a shared matter carries, by kind (MAC-SPEC §7.4 「查看会共享什么」).
public enum ShareKind: String, CaseIterable, Hashable, Sendable {
  /// 进展和接下来的事 (the matter's steps; always part of a shared matter).
  case progress
  /// 相关的聊天和会议记录.
  case chats
  /// 相关的邮件.
  case mail
  /// 相关的文件和网页.
  case files
  /// 你的口述 — never shared.
  case dictation

  public var title: String {
    switch self {
    case .progress: "进展和接下来的事"
    case .chats: "相关的聊天和会议记录"
    case .mail: "相关的邮件"
    case .files: "相关的文件和网页"
    case .dictation: "你的口述"
    }
  }

  public var symbol: String {
    switch self {
    case .progress: "clock"
    case .chats: "bubble.left"
    case .mail: "envelope"
    case .files: "doc"
    case .dictation: "mic.slash"
    }
  }

  /// A candidate's kind from its wire kind when the App did not say.
  public static func of(wireKind: String) -> ShareKind {
    switch wireKind {
    case "dictation": .dictation
    case "audio_segment", "text", "meeting", "chat", "transcript": .chats
    case "mail", "email": .mail
    default: .files
    }
  }
}

/// The handover sheet: who leads the matter now, to whom it goes, and the
/// pack (written on the Spark, numbers put back on this Mac).
public struct SpaceHandoverDisplay: Equatable, Sendable {
  public let spaceID: String
  public let eventID: String
  public let matterTitle: String
  /// The current 负责人's name, if one was set.
  public let currentLead: String?
  /// Members it can go to: (member id, name), this member excluded.
  public let members: [SpaceHandoverMember]
  public var to: String?
  public var packID: String?
  public var status: String?
  public var markdown: String?
  public var sources: Int
  /// The pack shared as a snapshot item (given with the handover).
  public var packItemID: String?
  public var working = false
  public var done: String?

  public init(
    spaceID: String, eventID: String, matterTitle: String, currentLead: String?,
    members: [SpaceHandoverMember]
  ) {
    self.spaceID = spaceID
    self.eventID = eventID
    self.matterTitle = matterTitle
    self.currentLead = currentLead
    self.members = members
    to = members.first?.memberID
    sources = 0
  }
}

public struct SpaceHandoverMember: Equatable, Hashable, Sendable {
  public let memberID: String
  public let name: String

  public init(memberID: String, name: String) {
    self.memberID = memberID
    self.name = name
  }
}

/// A new space's settings as the sheet edits them.
public struct SpaceDraft: Equatable, Sendable {
  public var name = ""
  public var owner: SpaceOwnerKind = .person
  public var forksAllowed = true
  public var textOnly = false
  public var keepOnLeave = false
  public var withdrawWindowHours = 24

  public init() {}

  public var policy: SpacePolicy {
    var policy = owner == .org ? SpacePolicy.org : SpacePolicy.group
    policy.forksAllowed = owner == .org ? forksAllowed : forksAllowed
    policy.originals = textOnly ? "text_only" : "members"
    if owner == .org {
      policy.withdrawWindowHours = max(1, min(withdrawWindowHours, 720))
      policy.onLeave = "keep"
    } else {
      policy.onLeave = keepOnLeave ? "keep" : "contributor_choice"
    }
    return policy
  }
}

/// The invite an admin shows: the code and its QR image.
public struct SpaceInviteDisplay: Equatable {
  public let spaceID: String
  public let code: String
  public let role: SpaceRole
  public let expires: Date
  public let qr: NSImage?

  public init(spaceID: String, code: String, role: SpaceRole, expires: Date, qr: NSImage?) {
    self.spaceID = spaceID
    self.code = code
    self.role = role
    self.expires = expires
    self.qr = qr
  }

  public static func == (lhs: SpaceInviteDisplay, rhs: SpaceInviteDisplay) -> Bool {
    lhs.code == rhs.code
  }
}

/// Everything the space pages show, as values the App builds.
public struct SpacesScreenState {
  public var scope: SpaceScope = .mine
  public var spaces: [SpaceLocalState] = []
  /// The link to the organizing device is up (spaces sync through it).
  public var linkReady = false
  public var hostLabel = "你的 DGX Spark"
  public var status: String?
  public var busy = false
  public var myFingerprint = ""
  /// Personal matter id → its badge (in 我的).
  public var badges: [String: SpaceBadgeInfo] = [:]
  /// Matter id in the current scope → its space information.
  public var matters: [String: SpaceMatterInfo] = [:]
  /// Matter id → the spaces it is shared into (my matters).
  public var sharedMatters: [String: [String]] = [:]
  public var joinRequests: [String: [SpaceJoinRequestView]] = [:]
  public var invite: SpaceInviteDisplay?
  public var proposals: [String: SpaceProposals] = [:]
  public var takedowns: [String: [SpaceTakedownRecord]] = [:]
  public var audit: [String: [SpaceAuditRecord]] = [:]
  public var shareDraft: SpaceShareDraft?
  /// Matter titles in a space (for proposals), by event id.
  public var matterTitles: [String: [String: String]] = [:]
  /// This member is an admin of an organization (can create org spaces).
  public var orgAdmin = false
  /// The pasted invite, read (for the join sheet's preview).
  public var joinPreview: SpaceInviteCode?
  public var joinError: String?
  /// What waits to be delivered to each space, and what was refused (v8 C3).
  public var outbox: [String: SpaceOutboxContents] = [:]
  /// The handover sheet's content (v8 B3).
  public var handover: SpaceHandoverDisplay?
  /// The audio part playing now.
  public var playingItem: String?
  /// The name this Mac's user goes by in a space they join (the account's
  /// full name; editable in the join request).
  public var myName = ""

  public init() {}

  /// "2 条等联网后发出" for a space, or nil.
  public func outboxLine(_ spaceID: String) -> String? {
    guard let waiting = outbox[spaceID]?.entries.count, waiting > 0 else { return nil }
    return linkReady ? "\(waiting) 条正在发送" : "\(waiting) 条将在连接后发送"
  }

  public func space(_ id: String?) -> SpaceLocalState? {
    guard let id else { return nil }
    return spaces.first { $0.spaceID == id }
  }

  public var activeSpaces: [SpaceLocalState] { spaces.filter { $0.membership == .active } }
  public var pendingSpaces: [SpaceLocalState] { spaces.filter { $0.membership != .active } }
}

/// What the space pages can ask for; the App runs each on the engine.
public struct SpacesActions {
  public var setScope: @MainActor (SpaceScope) -> Void
  public var present: @MainActor (SpaceSheet?) -> Void
  public var createSpace: @MainActor (SpaceDraft) -> Void
  public var readInvite: @MainActor (String) -> Void
  public var join: @MainActor (_ code: String, _ displayName: String) -> Void
  public var dropJoin: @MainActor (_ spaceID: String) -> Void
  public var makeInvite: @MainActor (_ spaceID: String, _ role: SpaceRole) -> Void
  public var copy: @MainActor (_ text: String) -> Void
  public var approve: @MainActor (_ spaceID: String, SpaceJoinRequestView, SpaceRole) -> Void
  public var reject: @MainActor (_ spaceID: String, _ requestID: String) -> Void
  public var setRole: @MainActor (_ spaceID: String, _ memberID: String, SpaceRole) -> Void
  public var removeMember: @MainActor (_ spaceID: String, _ memberID: String) -> Void
  public var leave: @MainActor (_ spaceID: String, _ withdrawContributions: Bool) -> Void
  public var setPolicy: @MainActor (_ spaceID: String, SpaceJSON) -> Void
  public var archive: @MainActor (_ spaceID: String, Bool) -> Void
  public var share: @MainActor (SpaceShareDraft) -> Void
  public var unshare: @MainActor (_ spaceID: String, _ eventID: String) -> Void
  public var itemAction:
    @MainActor (_ spaceID: String, _ itemID: String, SpaceRules.ItemAction, _ reason: String?) ->
      Void
  public var openOriginal: @MainActor (_ spaceID: String, _ itemID: String, SpaceBlobRef) -> Void
  public var openSpaceMatter: @MainActor (_ spaceID: String, _ eventID: String) -> Void
  public var resolveProposal: @MainActor (_ spaceID: String, _ proposalID: String, Bool) -> Void
  public var answerOrganizer: @MainActor (_ spaceID: String, _ proposalID: String, Bool) -> Void
  public var resolveTakedown: @MainActor (_ spaceID: String, _ takedownID: String, Bool) -> Void
  /// 不同意 someone else's privacy takedown, with the reason the requester sees.
  public var rejectTakedown:
    @MainActor (_ spaceID: String, _ takedownID: String, _ reason: String) -> Void
  public var propose:
    @MainActor (
      _ spaceID: String, _ eventID: String, _ kind: String, _ text: String,
      _ otherEventID: String?
    ) -> Void
  public var refresh: @MainActor (_ spaceID: String?) -> Void
  /// v8: play a meeting part's audio (after checking its length).
  public var playAudio: @MainActor (_ spaceID: String, _ itemID: String, SpaceBlobRef) -> Void
  /// v8: the handover sheet's steps.
  public var handoverStep: @MainActor (SpaceHandoverStep) -> Void
  /// v8: a plain member confirms an org admin's takeover after comparing the fingerprint.
  public var confirmRecovery: @MainActor (_ spaceID: String, _ deviceID: String) -> Void
  /// v8: forget the outbox's refused entries (after reading them).
  public var dismissOutbox: @MainActor (_ spaceID: String) -> Void
  /// Review V8R-04: take back something still waiting to go.
  public var cancelOutbox: @MainActor (_ spaceID: String, _ entryID: String) -> Void

  public init(
    setScope: @escaping @MainActor (SpaceScope) -> Void = { _ in },
    present: @escaping @MainActor (SpaceSheet?) -> Void = { _ in },
    createSpace: @escaping @MainActor (SpaceDraft) -> Void = { _ in },
    readInvite: @escaping @MainActor (String) -> Void = { _ in },
    join: @escaping @MainActor (String, String) -> Void = { _, _ in },
    dropJoin: @escaping @MainActor (String) -> Void = { _ in },
    makeInvite: @escaping @MainActor (String, SpaceRole) -> Void = { _, _ in },
    copy: @escaping @MainActor (String) -> Void = { _ in },
    approve: @escaping @MainActor (String, SpaceJoinRequestView, SpaceRole) -> Void = { _, _, _ in
    },
    reject: @escaping @MainActor (String, String) -> Void = { _, _ in },
    setRole: @escaping @MainActor (String, String, SpaceRole) -> Void = { _, _, _ in },
    removeMember: @escaping @MainActor (String, String) -> Void = { _, _ in },
    leave: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
    setPolicy: @escaping @MainActor (String, SpaceJSON) -> Void = { _, _ in },
    archive: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
    share: @escaping @MainActor (SpaceShareDraft) -> Void = { _ in },
    unshare: @escaping @MainActor (String, String) -> Void = { _, _ in },
    itemAction: @escaping @MainActor (String, String, SpaceRules.ItemAction, String?) -> Void = {
      _, _, _, _ in
    },
    openOriginal: @escaping @MainActor (String, String, SpaceBlobRef) -> Void = { _, _, _ in },
    openSpaceMatter: @escaping @MainActor (String, String) -> Void = { _, _ in },
    resolveProposal: @escaping @MainActor (String, String, Bool) -> Void = { _, _, _ in },
    answerOrganizer: @escaping @MainActor (String, String, Bool) -> Void = { _, _, _ in },
    resolveTakedown: @escaping @MainActor (String, String, Bool) -> Void = { _, _, _ in },
    rejectTakedown: @escaping @MainActor (String, String, String) -> Void = { _, _, _ in },
    propose: @escaping @MainActor (String, String, String, String, String?) -> Void = {
      _, _, _, _, _ in
    },
    refresh: @escaping @MainActor (String?) -> Void = { _ in },
    playAudio: @escaping @MainActor (String, String, SpaceBlobRef) -> Void = { _, _, _ in },
    handoverStep: @escaping @MainActor (SpaceHandoverStep) -> Void = { _ in },
    confirmRecovery: @escaping @MainActor (String, String) -> Void = { _, _ in },
    dismissOutbox: @escaping @MainActor (String) -> Void = { _ in },
    cancelOutbox: @escaping @MainActor (String, String) -> Void = { _, _ in }
  ) {
    self.cancelOutbox = cancelOutbox
    self.playAudio = playAudio
    self.handoverStep = handoverStep
    self.confirmRecovery = confirmRecovery
    self.dismissOutbox = dismissOutbox
    self.setScope = setScope
    self.present = present
    self.createSpace = createSpace
    self.readInvite = readInvite
    self.join = join
    self.dropJoin = dropJoin
    self.makeInvite = makeInvite
    self.copy = copy
    self.approve = approve
    self.reject = reject
    self.setRole = setRole
    self.removeMember = removeMember
    self.leave = leave
    self.setPolicy = setPolicy
    self.archive = archive
    self.share = share
    self.unshare = unshare
    self.itemAction = itemAction
    self.openOriginal = openOriginal
    self.openSpaceMatter = openSpaceMatter
    self.resolveProposal = resolveProposal
    self.answerOrganizer = answerOrganizer
    self.resolveTakedown = resolveTakedown
    self.rejectTakedown = rejectTakedown
    self.propose = propose
    self.refresh = refresh
  }

  public static var inert: SpacesActions { SpacesActions() }
}

/// What the handover sheet asks for.
public enum SpaceHandoverStep: Equatable, Sendable {
  case choose(memberID: String)
  /// 生成交接包 (written by the Spark's model from the matter's items).
  case generate
  /// 作为快照分享到空间 (a new item by this member, citing the pack's sources).
  case shareSnapshot
  /// 导出 Markdown… (numbers as they are, to a file the member picks).
  case export
  /// 转交负责人 (with the shared pack, if there is one).
  case handOver
}

/// The plain words of shared spaces (user-facing copy is Chinese).
public enum SpaceWords {
  public static let mine = "我的"
  public static let all = "全部"
  public static let newSpace = "新建共享空间"
  public static let joinSpace = "用邀请码加入"
  public static let allNote = "你自己的事和共享空间中的事合并显示；他人的内容以另一种颜色显示。"
  public static let linkOff = "DGX Spark 未连接：共享空间将在连接后同步；你自己的记录保持不变。"
  public static let promise =
    "DGX Spark 接收隐藏号码后的文字；成员看到你选择的原始内容。录音以这件事中的片段共享；声纹、词典和个人识别习惯储存在这台 Mac 上。"
  public static let keysNote = "空间密钥发送到你同意的成员的 Mac，并加密储存在该 Mac 上；邀请码本身无法打开空间。"

  public static func action(_ action: SpaceRules.ItemAction) -> String {
    switch action {
    case .withdraw: "撤回"
    case .delete: "删除…"
    case .requestPrivacyTakedown: "因隐私申请撤回…"
    case .remove: "移除"
    case .hide: "对我隐藏"
    case .unhide: "取消隐藏"
    case .fork: "储存副本到我的空间"
    case .unfork: "移除副本"
    }
  }

  public static func kind(_ kind: String) -> String {
    switch kind {
    case "dictation": "口述"
    case "meeting_offline": "线下录音"
    case "meeting_online": "电脑内录"
    case "imported_media": "导入媒体"
    case "audio_segment": "录音片段"
    case "image": "截图"
    case "document": "文档"
    case "file": "文件"
    case "link": "链接"
    case "snapshot": "摘要（固定）"
    default: "文字"
    }
  }

  /// An audit record's action in words (records hold ids and counts only).
  public static func audit(_ action: String) -> String {
    let words: [String: String] = [
      "space.create": "新建空间", "space.meta": "更改空间名称", "space.policy": "更改空间设置",
      "space.archive": "归档设置", "invite.create": "发送邀请", "invite.revoke": "撤销邀请",
      "join.request": "申请加入", "join.approve": "同意加入", "join.reject": "拒绝加入",
      "member.role": "更改角色", "member.remove": "移除成员", "member.leave": "退出空间",
      "epoch.rotate": "更换密钥", "member.profile": "更新姓名", "device.add": "添加设备",
      "device.remove": "移除设备", "item.share": "共享内容", "item.withdraw": "撤回内容",
      "item.delete": "删除内容", "item.remove": "移除内容", "item.hide": "隐藏内容",
      "item.fork": "储存副本", "item.unfork": "删除副本", "takedown.request": "申请撤回",
      "takedown.resolve": "处理撤回", "takedown.withdraw": "撤回撤回申请",
      "matter.share": "共享一件事", "matter.unshare": "停止共享一件事",
      "share_rule.set": "设定共享规则", "share_rule.clear": "取消共享规则",
      "proposal.create": "提出修改", "proposal.resolve": "处理提议", "proposal.withdraw": "撤回提议",
      "matter.handover": "交接负责人", "agent.access": "Agent 读取", "organizer.lease": "开始整理",
      "organizer.lock": "整理上锁", "organizer.decisions": "直接修改", "organizer.answer": "回答整理提问",
      "item_keys.rewrap": "重新加密密钥", "system.remove": "到期自动撤回",
      "escrow.wrap": "补充密钥托管", "space.recover": "团队管理员接管", "space.backup": "导出备份",
      "space.restore": "从备份恢复", "org.create": "新建团队", "org.admin_add": "添加团队管理员",
      "org.admin_remove": "移出团队管理员", "org.device_add": "添加团队设备",
      "org.device_remove": "移除团队设备", "org.policy": "更改密钥托管规则",
      "access.ticket": "发送设备邀请", "access.enroll": "一台 Mac 加入", "access.revoke": "断开一台 Mac",
      "access.ticket_revoke": "撤销邀请", "access.ticket_expired": "邀请过期",
    ]
    return words[action] ?? action
  }
}
