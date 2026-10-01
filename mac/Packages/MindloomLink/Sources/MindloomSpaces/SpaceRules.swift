import Foundation

/// Who may do what in a space (SPACES-CONTRACT §1, GitHub model). The Spark
/// enforces every rule; the Mac mirrors them so it only offers what will be
/// accepted and can say why something is not offered.
public enum SpaceOwnerKind: String, Codable, Equatable, Sendable {
  /// A group space owned by a person: shared-album rules.
  case person
  /// An organization's space: contributions are the organization's assets.
  case org

  public var title: String { self == .org ? "组织空间" : "小组空间" }
}

public enum SpaceRules {
  /// The rights of a role in a space, exactly as the Spark lists them in
  /// `me.rights`.
  public static func rights(role: SpaceRole, policy: SpacePolicy) -> [String] {
    var rights = ["read", "hide", "leave", "agent_access", "profile", "takedown_privacy"]
    if policy.forksAllowed { rights.append("fork") }
    if role >= .write { rights += ["share", "withdraw_own", "propose", "lease_write", "rewrap"] }
    if role >= .maintain {
      rights += ["remove", "resolve_takedowns", "resolve_proposals", "edit_matters", "handover"]
    }
    if role >= .admin {
      rights += [
        "invite", "approve_joins", "set_roles", "remove_members", "rotate", "policy", "archive",
      ]
    }
    return rights
  }

  /// Whether the contributor may still withdraw an item first shared at
  /// `firstShared`: group spaces any time, org spaces within the window.
  public static func withdrawWindowOpen(policy: SpacePolicy, firstShared: Date, now: Date) -> Bool {
    guard let hours = policy.withdrawWindowHours else { return true }
    return now.timeIntervalSince(firstShared) <= TimeInterval(hours) * 3_600
  }

  /// Seconds left in the withdraw window; nil when there is no window.
  public static func withdrawWindowRemaining(policy: SpacePolicy, firstShared: Date, now: Date)
    -> TimeInterval?
  {
    guard let hours = policy.withdrawWindowHours else { return nil }
    return max(0, TimeInterval(hours) * 3_600 - now.timeIntervalSince(firstShared))
  }

  public enum DeleteOutcome: Equatable, Sendable {
    /// The item leaves the space (its data key is deleted on the Spark).
    case withdrawn
    /// Past the window of an org space: a takedown request maintainers decide.
    case takedownRequested
  }

  /// What 删除 does to your own shared item.
  public static func deleteOutcome(policy: SpacePolicy, firstShared: Date, now: Date)
    -> DeleteOutcome
  {
    withdrawWindowOpen(policy: policy, firstShared: firstShared, now: now)
      ? .withdrawn : .takedownRequested
  }

  /// What one member may do with one shared item.
  public enum ItemAction: String, CaseIterable, Sendable {
    /// 撤回: your own item, within the window (always in group spaces).
    case withdraw
    /// 删除: your own item; past an org space's window it becomes a takedown request.
    case delete
    /// 因隐私申请下架: anyone's item; maintainers must honour it within the
    /// policy's window, or the Spark removes it when the window ends.
    case requestPrivacyTakedown
    /// 移除: maintainers and admins, anyone's item (tombstone + purge).
    case remove
    /// 只对我隐藏 / 取消隐藏.
    case hide
    case unhide
    /// 存一份到我的空间 / 不再保留: only where the policy allows forks.
    case fork
    case unfork
  }

  public struct ItemContext: Sendable {
    public var isMine: Bool
    public var role: SpaceRole
    public var policy: SpacePolicy
    public var firstShared: Date
    public var hidden: Bool
    public var forked: Bool
    public var archived: Bool

    public init(
      isMine: Bool, role: SpaceRole, policy: SpacePolicy, firstShared: Date, hidden: Bool = false,
      forked: Bool = false, archived: Bool = false
    ) {
      self.isMine = isMine
      self.role = role
      self.policy = policy
      self.firstShared = firstShared
      self.hidden = hidden
      self.forked = forked
      self.archived = archived
    }
  }

  public static func actions(_ context: ItemContext, now: Date) -> [ItemAction] {
    var actions: [ItemAction] = []
    let windowOpen = withdrawWindowOpen(
      policy: context.policy, firstShared: context.firstShared, now: now)
    if context.isMine {
      if windowOpen { actions.append(.withdraw) }
      // Past an org space's window 删除 becomes a takedown request.
      actions.append(.delete)
    } else {
      actions.append(context.hidden ? .unhide : .hide)
      actions.append(.requestPrivacyTakedown)
      if context.policy.forksAllowed, !context.archived {
        actions.append(context.forked ? .unfork : .fork)
      }
    }
    if context.role >= .maintain { actions.append(.remove) }
    return actions
  }
}

/// One line of the review list before sharing (SPACES-CONTRACT §2): every
/// item or segment that would go is listed; private dictations and items
/// containing numbers start unticked.
public struct SpaceShareCandidate: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// A whole item (a note, a screenshot, a file, a dictation).
    case item
    /// A part of a recording: only the part filed into the matter goes.
    case segment(parentItemID: String, startMS: Int, endMS: Int)
  }

  /// The id the item has in the space (a segment's derived id).
  public let id: String
  /// The local item it comes from.
  public let sourceItemID: String
  public let kind: Kind
  /// The wire kind (`dictation`, `text`, `image`, `audio_segment` …).
  public let wireKind: String
  public let title: String
  public let preview: String
  public let startedAt: Date?
  /// Dictation goes into other people's chats: private unless ticked.
  public let isPrivateDictation: Bool
  /// What the masking rules found ("手机号", "银行卡号" …); empty when none.
  public let numberLabels: [String]
  /// An original members could open (a file, a screenshot, the segment's audio).
  public let hasOriginal: Bool

  public init(
    id: String, sourceItemID: String, kind: Kind, wireKind: String, title: String,
    preview: String, startedAt: Date?, isPrivateDictation: Bool, numberLabels: [String],
    hasOriginal: Bool
  ) {
    self.id = id.lowercased()
    self.sourceItemID = sourceItemID
    self.kind = kind
    self.wireKind = wireKind
    self.title = title
    self.preview = preview
    self.startedAt = startedAt
    self.isPrivateDictation = isPrivateDictation
    self.numberLabels = numberLabels
    self.hasOriginal = hasOriginal
  }

  /// Ticked unless it is a private dictation, contains numbers, or is a part
  /// of a recording: a recording's part goes only when the user picks it,
  /// one per recording, and never by a rule (review V7-S5).
  public var tickedByDefault: Bool {
    !isPrivateDictation && numberLabels.isEmpty && recordingID == nil
  }

  /// The recording a part comes from, or nil for a whole item.
  public var recordingID: String? {
    if case .segment(let parent, _, _) = kind { return parent }
    return nil
  }

  /// Why it starts unticked (shown under the line), or nil.
  public var untickedReason: String? {
    if recordingID != nil {
      let numbers =
        numberLabels.isEmpty ? "" : "；含号码（\(numberLabels.joined(separator: "、"))），成员会看到原样号码"
      return "录音片段要你自己选：每段录音最多共享一段（不超过 15 分钟）\(numbers)"
    }
    if isPrivateDictation, !numberLabels.isEmpty {
      return "口述，含号码（\(numberLabels.joined(separator: "、"))），默认不共享"
    }
    if isPrivateDictation { return "口述内容默认不共享" }
    if !numberLabels.isEmpty {
      return "含号码（\(numberLabels.joined(separator: "、"))），默认不共享；成员会看到原样号码"
    }
    return nil
  }
}

/// The three scales of the share sheet.
public enum SpaceShareScale: Equatable, Sendable {
  /// 只这一条.
  case item
  /// 这件事: its items or segments, the sharer's title and pinned facts as
  /// hints, and optionally a rule for what is filed into it later.
  case matter(rule: SpaceRuleMode)
  /// 整根绳: everything on a rope, now and later.
  case rope(rule: SpaceRuleMode)
}

/// "以后新归进来的也共享": ask each time, automatic, or not at all.
public enum SpaceRuleMode: String, Codable, Equatable, Sendable {
  case ask, auto, off
}

public struct SpaceShareReview: Equatable, Sendable {
  public private(set) var candidates: [SpaceShareCandidate]
  public var ticked: Set<String>

  public init(candidates: [SpaceShareCandidate]) {
    self.candidates = candidates
    ticked = Set(candidates.filter(\.tickedByDefault).map(\.id))
  }

  public var selected: [SpaceShareCandidate] { candidates.filter { ticked.contains($0.id) } }

  /// Ticks or unticks a line. Ticking a part of a recording unticks any
  /// other part of the same recording: at most one part per recording goes.
  public mutating func toggle(_ id: String) {
    if ticked.contains(id) {
      ticked.remove(id)
      return
    }
    if let recording = candidates.first(where: { $0.id == id })?.recordingID {
      for other in candidates where other.recordingID == recording { ticked.remove(other.id) }
    }
    ticked.insert(id)
  }
}
