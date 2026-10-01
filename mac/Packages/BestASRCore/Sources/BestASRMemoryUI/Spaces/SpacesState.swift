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

  public var id: String { itemID }

  public init(
    itemID: String, title: String, preview: String, contributor: String, isMine: Bool,
    sharedAt: Date, kindLabel: String, actions: [SpaceRules.ItemAction], hidden: Bool,
    forked: Bool, originals: [SpaceBlobRef], windowNote: String?
  ) {
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
        note = left > 0 ? "还能撤回 \(max(1, Int(left / 3_600))) 小时" : nil
      }
      let fields = item.fields
      return SpaceItemRow(
        itemID: id, title: fields?.title ?? "共享的素材",
        preview: String((fields?.text ?? fields?.reading ?? "").prefix(80)),
        contributor: state.name(of: item.contributor), isMine: mine, sharedAt: item.firstSharedAt,
        kindLabel: SpaceWords.kind(item.kind),
        actions: state.archived ? [] : SpaceRules.actions(context, now: now),
        hidden: state.hidden.contains(id), forked: state.forks[id] != nil,
        originals: state.policy.originalsForMembers ? item.blobs : [], windowNote: note)
    }
    return SpaceMatterInfo(
      spaceID: state.spaceID, spaceName: state.name, contributionLine: contributionLine,
      items: rows, canPropose: state.can("propose"), canEdit: state.can("edit_matters"))
  }

  public let spaceID: String
  public let spaceName: String
  /// "林知远 2 条 + 韩策 3 条".
  public let contributionLine: String?
  public let items: [SpaceItemRow]
  public let canPropose: Bool
  public let canEdit: Bool

  public init(
    spaceID: String, spaceName: String, contributionLine: String?, items: [SpaceItemRow],
    canPropose: Bool, canEdit: Bool
  ) {
    self.spaceID = spaceID
    self.spaceName = spaceName
    self.contributionLine = contributionLine
    self.items = items
    self.canPropose = canPropose
    self.canEdit = canEdit
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
      && lhs.rope?.id == rhs.rope?.id
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
  public var hostLabel = "你的整理设备"
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

  public init() {}

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
    refresh: @escaping @MainActor (String?) -> Void = { _ in }
  ) {
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

/// The plain words of shared spaces (user-facing copy is Chinese).
public enum SpaceWords {
  public static let mine = "我的"
  public static let all = "全部"
  public static let newSpace = "新建共享空间"
  public static let joinSpace = "用邀请码加入"
  public static let allNote = "你自己的事和共享空间里的事叠在一起看；别人的素材用另一种颜色画在线上。"
  public static let linkOff = "整理设备没有连上：共享空间会在连上后同步；你自己的记录不受影响。"
  public static let promise =
    "整理设备只看到遮住号码的文字；成员看到你勾选的原样内容。录音只共享归进这件事的片段，声纹、词典和个人识别习惯永远不离开这台 Mac。"
  public static let keysNote = "空间的钥匙只发给你同意了的成员的 Mac，并且锁在那台 Mac 上；邀请码本身打不开空间。"

  public static func action(_ action: SpaceRules.ItemAction) -> String {
    switch action {
    case .withdraw: "撤回"
    case .delete: "删除…"
    case .requestPrivacyTakedown: "因隐私申请下架…"
    case .remove: "移除"
    case .hide: "只对我隐藏"
    case .unhide: "取消隐藏"
    case .fork: "存一份到我的空间"
    case .unfork: "不再保留副本"
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
    case "snapshot": "摘要"
    default: "文字"
    }
  }

  /// An audit record's action in words (records hold ids and counts only).
  public static func audit(_ action: String) -> String {
    let words: [String: String] = [
      "space.create": "建了空间", "space.meta": "改了空间名", "space.policy": "改了空间设置",
      "space.archive": "归档设置", "invite.create": "发了邀请", "invite.revoke": "收回邀请",
      "join.request": "申请加入", "join.approve": "同意加入", "join.reject": "拒绝加入",
      "member.role": "改了角色", "member.remove": "移除成员", "member.leave": "离开空间",
      "epoch.rotate": "换了钥匙", "member.profile": "更新名字", "device.add": "添加设备",
      "device.remove": "移除设备", "item.share": "共享素材", "item.withdraw": "撤回素材",
      "item.delete": "删除素材", "item.remove": "移除素材", "item.hide": "隐藏素材",
      "item.fork": "存了副本", "item.unfork": "删了副本", "takedown.request": "申请下架",
      "takedown.resolve": "处理下架", "takedown.withdraw": "撤回下架申请",
      "matter.share": "共享一件事", "matter.unshare": "停止共享一件事",
      "share_rule.set": "设了共享规则", "share_rule.clear": "取消共享规则",
      "proposal.create": "提了修改", "proposal.resolve": "处理提议", "proposal.withdraw": "撤回提议",
      "matter.handover": "交接负责人", "agent.access": "Agent 读取", "organizer.lease": "开始整理",
      "organizer.lock": "整理上锁", "organizer.decisions": "直接修改", "organizer.answer": "回答整理提问",
      "item_keys.rewrap": "钥匙重新包装", "system.remove": "到期自动下架",
    ]
    return words[action] ?? action
  }
}
