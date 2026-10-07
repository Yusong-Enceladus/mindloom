import BestASRMemory
import MindloomDesign
import MindloomSpaces
import SwiftUI

// OWNER: mac-capture. The v11 spaces sheets (MAC-SPEC §7.4): 新建共享空间,
// 用邀请码加入, 邀请到「…」, 「…」的成员 — wired to the v8 spaces code
// (`SpacesActions`), with its real join requests and codes.

// MARK: - 新建共享空间

struct NewSpaceSheet: View {
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var name = ""
  @State private var error: String?

  var body: some View {
    MindloomSheetChrome(width: 380) {
      SheetTitle("新建共享空间")
      SheetText("新建后，邀请他人加入并共享事。")
      SheetField(placeholder: "名称，例如“读书会”", text: $name, accessibility: "共享空间名称") {
        create()
      }
      .padding(.top, 14)
      if let error {
        Text(error).mlFont(\.sub).foregroundStyle(MLColor.alert).padding(.top, 6)
      } else if !state.linkReady {
        Text("DGX Spark 未连接。连接后才能新建。").mlFont(\.sub).foregroundStyle(MLColor.ink2)
          .padding(.top, 6)
      }
      SheetActions {
        Button("取消") { actions.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("新建") { create() }
          .buttonStyle(MLButtonStyle(.primary))
          .disabled(state.busy || !state.linkReady)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func create() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !state.spaces.contains(where: { $0.name == trimmed }) else {
      error = "已有同名的共享空间。"
      return
    }
    var draft = SpaceDraft()
    draft.name = trimmed
    actions.createSpace(draft)
  }
}

// MARK: - 用邀请码加入

struct JoinSpaceSheet: View {
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var code: String
  @State private var name: String

  init(state: SpacesScreenState, actions: SpacesActions, code: String = "") {
    self.state = state
    self.actions = actions
    _code = State(initialValue: code)
    _name = State(initialValue: state.myName)
  }

  var body: some View {
    MindloomSheetChrome(width: 380) {
      SheetTitle("用邀请码加入")
      SheetText("输入他人发给你的邀请码。")
      SheetField(placeholder: "例如 4MQ7-K2XP", text: $code, accessibility: "邀请码", mono: true) {
        join()
      }
      .padding(.top, 14)
      .onChange(of: code) { _, value in actions.readInvite(value) }
      if let error = state.joinError, !code.isEmpty {
        Text(JoinWords.error(error)).mlFont(\.sub).foregroundStyle(MLColor.alert).padding(.top, 6)
      } else if let preview = state.joinPreview {
        Text("将加入“\(preview.spaceName)”。管理员同意后，你可以看到其中的事。")
          .mlFont(\.sub).foregroundStyle(MLColor.ink2).padding(.top, 6)
          .fixedSize(horizontal: false, vertical: true)
        if !state.myFingerprint.isEmpty {
          Text("对方同意前会与你核对：\(state.myFingerprint)")
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(MLColor.ink2)
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      SheetActions {
        Button("取消") { actions.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("加入") { join() }
          .buttonStyle(MLButtonStyle(.primary))
          .disabled(state.joinPreview == nil || state.busy || !state.linkReady)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func join() {
    guard state.joinPreview != nil else { return }
    let me = name.trimmingCharacters(in: .whitespacesAndNewlines)
    actions.join(code.trimmingCharacters(in: .whitespacesAndNewlines), me.isEmpty ? "我" : me)
  }
}

enum JoinWords {
  /// The v8 refusals in the sheet's words (an expired code says so).
  static func error(_ raw: String) -> String {
    if raw.contains("过期") || raw.contains("无法识别") { return "此邀请码已过期。请让对方重新邀请。" }
    return raw
  }
}

// MARK: - 邀请到「…」

struct SpaceInviteSheet: View {
  let spaceID: String
  let state: SpacesScreenState
  let actions: SpacesActions
  /// A still image's code.
  var snapshotCode: String?
  var snapshotSpaceName: String?

  var body: some View {
    let name = state.space(spaceID)?.name ?? snapshotSpaceName ?? ""
    let code = snapshotCode ?? (state.invite?.spaceID == spaceID ? state.invite?.code : nil)
    MindloomSheetChrome(width: 380) {
      SheetTitle("邀请到“\(name)”")
      SheetText("将邀请码发给对方。24 小时内有效。")
      InviteCodeBox(code: code).padding(.top, 16)
      SheetActions {
        Button {
          if let code { actions.copy(code) }
        } label: {
          Label("拷贝", systemImage: "doc.on.doc").labelStyle(.titleAndIcon)
        }
        .buttonStyle(MLButtonStyle(.standard))
        .disabled(code == nil)
        Button("完成") { actions.present(nil) }
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
      }
    }
    .onAppear {
      guard snapshotCode == nil, state.invite?.spaceID != spaceID else { return }
      actions.makeInvite(spaceID, .write)
    }
  }
}

/// The code box (`code` type, tracked 0.12 em, tabular, `paper2`, radius 12,
/// padding 14). A long v8 code is shown on one line in a smaller mono face,
/// cut in the middle; 复制 copies all of it.
struct InviteCodeBox: View {
  let code: String?

  var body: some View {
    Group {
      if let code, code.count <= 12 {
        Text(code)
          .font(.system(size: 26, weight: .medium)).monospacedDigit()
          .tracking(26 * 0.12)
      } else if let code {
        Text(code)
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .padding(.horizontal, 14)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .foregroundStyle(MLColor.ink)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(MLColor.paper2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityLabel("邀请码")
  }
}

// MARK: - 「…」的成员

/// The members sheet's content: 你 first, then the members; admins marked.
public struct SpaceMembersInput: Equatable {
  public struct Member: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let admin: Bool
    public let removable: Bool
  }

  public let spaceID: String
  public let spaceName: String
  public let youAreAdmin: Bool
  public let members: [Member]
  public let canInvite: Bool
  /// People asking to join (admins say yes or no).
  public let requests: [SpaceJoinRequestView]

  public init(
    spaceID: String, spaceName: String, youAreAdmin: Bool, members: [Member], canInvite: Bool,
    requests: [SpaceJoinRequestView] = []
  ) {
    self.spaceID = spaceID
    self.spaceName = spaceName
    self.youAreAdmin = youAreAdmin
    self.members = members
    self.canInvite = canInvite
    self.requests = requests
  }

  /// From the v8 spaces state.
  public init(spaceID: String, state: SpacesScreenState) {
    let space = state.space(spaceID)
    let me = space?.memberID
    let admin = { (m: SpaceMember) in m.role == .admin || m.owner || m.orgAdmin }
    let mine = space?.members.first { $0.memberID == me }
    self.init(
      spaceID: spaceID, spaceName: space?.name ?? "",
      youAreAdmin: mine.map(admin) ?? false,
      members: (space?.activeMembers ?? []).filter { $0.memberID != me }.map { m in
        Member(
          id: m.memberID, name: space?.name(of: m.memberID) ?? "", admin: admin(m),
          removable: (space?.can("remove_members") ?? false) && !m.owner)
      },
      canInvite: space?.can("invite") ?? false,
      requests: (space?.can("approve_joins") ?? false) ? state.joinRequests[spaceID] ?? [] : [])
  }

  /// From a sidebar row (still images).
  public init(space: MemorySidebarSpace) {
    self.init(
      spaceID: space.id, spaceName: space.name, youAreAdmin: space.youAreAdmin,
      members: space.memberNames.map {
        Member(id: $0, name: $0, admin: space.admins.contains($0), removable: false)
      },
      canInvite: true)
  }
}

struct SpaceMembersSheet: View {
  let input: SpaceMembersInput
  let actions: SpacesActions
  @State private var removing: SpaceMembersInput.Member?

  var body: some View {
    MindloomSheetChrome(width: 400) {
      SheetTitle("“\(input.spaceName)”的成员")
      VStack(spacing: 0) {
        row(name: "你", admin: input.youAreAdmin, removable: nil)
        ForEach(input.members) { member in
          row(name: member.name, admin: member.admin, removable: member.removable ? member : nil)
        }
      }
      .padding(.top, 10)
      if !input.requests.isEmpty {
        Text("申请加入的人").mlFont(\.section).foregroundStyle(MLColor.ink2).padding(.top, 16)
        ForEach(input.requests) { request in
          JoinRequestRow(spaceID: input.spaceID, request: request, actions: actions)
        }
      }
      SheetText("管理员可以邀请和移出成员。").padding(.top, 12)
      SheetActions {
        if input.canInvite {
          Button {
            actions.present(.invite(spaceID: input.spaceID))
          } label: {
            Label("邀请…", systemImage: "person.badge.plus").labelStyle(.titleAndIcon)
          }
          .buttonStyle(MLButtonStyle(.standard))
        }
      } trailing: {
        Button("完成") { actions.present(nil) }
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
      }
    }
    .confirmationDialog(
      "移出\(removing?.name ?? "")？", isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible
    ) {
      Button("移出", role: .destructive) {
        if let removing { actions.removeMember(input.spaceID, removing.id) }
        removing = nil
      }
      Button("取消", role: .cancel) { removing = nil }
    } message: {
      Text("移出后，此人将无法看到之后共享的事。此人共享过的事会保留在空间中。")
    }
  }

  private func row(name: String, admin: Bool, removable: SpaceMembersInput.Member?) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "person").font(.system(size: 14)).foregroundStyle(MLColor.ink2)
        .frame(width: 16)
      Text(name).mlFont(\.control).foregroundStyle(MLColor.ink)
      Spacer(minLength: 8)
      if admin { Text("管理员").mlFont(\.control).foregroundStyle(MLColor.ink2) }
      if let removable {
        Button("移出") { removing = removable }
          .buttonStyle(MLButtonStyle(.plain, small: true))
      }
    }
    .frame(minHeight: 34)
    .overlay(alignment: .bottom) { Rectangle().fill(MLColor.rule).frame(height: 0.5) }
    .accessibilityElement(children: .combine)
  }
}

/// A join request: the name, the fingerprint to compare, 同意 · 不同意.
struct JoinRequestRow: View {
  let spaceID: String
  let request: SpaceJoinRequestView
  let actions: SpacesActions

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(request.displayName ?? "申请加入的人").mlFont(\.control)
        Spacer(minLength: 8)
        Button("拒绝") { actions.reject(spaceID, request.requestID) }
          .buttonStyle(MLButtonStyle(.standard, small: true))
        Button("同意") { actions.approve(spaceID, request, request.role ?? .write) }
          .buttonStyle(MLButtonStyle(.primary, small: true))
          .disabled(request.blocked)
      }
      Text("请先与对方核对：\(request.fingerprint)")
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
      if let warning = request.warning {
        Text(warning).mlFont(\.foot).foregroundStyle(MLColor.alert)
      }
    }
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) { Rectangle().fill(MLColor.rule).frame(height: 0.5) }
  }
}
