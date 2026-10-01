import MindloomSpaces
import SwiftUI

/// 交接 (v8 B3): hand a matter's 负责人 to another member. The handover pack
/// is written by the organizing device's model from the matter's items (every
/// sentence cites them, numbers stay placeholders there) and shown here with
/// the numbers put back; it can be exported as Markdown, shared into the space
/// as a frozen snapshot, and given along with the handover.
struct HandoverSheet: View {
  @Environment(\.zhiji) private var palette
  let state: SpacesScreenState
  let actions: SpacesActions

  var body: some View {
    SpaceSheetFrame(title: "交接这件事", actions: actions) {
      if let display = state.handover {
        content(display)
      } else {
        Text("正在读这件事的成员…").font(.zhiji(13)).foregroundStyle(palette.secondary)
      }
    }
  }

  @ViewBuilder
  private func content(_ display: SpaceHandoverDisplay) -> some View {
    Text(display.matterTitle).font(.zhiji(15, .semibold))
    Text(display.currentLead.map { "现在的负责人：\($0)" } ?? "这件事还没有指定负责人")
      .font(.zhiji(12)).foregroundStyle(palette.secondary)
    SpaceSection(title: "交给") {
      if display.members.isEmpty {
        Text("空间里还没有别的成员。").font(.zhiji(12)).foregroundStyle(palette.secondary)
      } else {
        Picker(
          "交给",
          selection: Binding(
            get: { display.to ?? display.members[0].memberID },
            set: { actions.handoverStep(.choose(memberID: $0)) })
        ) {
          ForEach(display.members, id: \.memberID) { Text($0.name).tag($0.memberID) }
        }
        .labelsHidden()
        .frame(width: 220)
      }
    }
    SpaceSection(title: "交接包") {
      Text(
        "现在到哪了、谁还欠着什么、截止日、定下的事（带原话）、还没答案的问题、接手先做什么——每一句都标出处。由整理设备上的模型写，可能漏掉事情，接手前请和原负责人核对。"
      )
      .font(.zhiji(12)).foregroundStyle(palette.secondary)
      HStack {
        Button(display.markdown == nil ? "生成交接包" : "重新生成") { actions.handoverStep(.generate) }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: display.markdown == nil))
          .disabled(display.working || !state.linkReady)
          .accessibilityIdentifier("bestASR.spaces.handoverGenerate")
        if display.working { ProgressView().controlSize(.small) }
        if let status = display.status {
          Text(status).font(.zhiji(12)).foregroundStyle(palette.secondary)
        }
      }
      if let markdown = display.markdown {
        // The sheet scrolls as a whole; the pack reads as one block.
        Text(markdown).font(.system(size: 12)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        HStack {
          Button("导出 Markdown…") { actions.handoverStep(.export) }
            .buttonStyle(ZhijiCapsuleButtonStyle())
          Button(display.packItemID == nil ? "作为快照分享到空间" : "已分享到空间") {
            actions.handoverStep(.shareSnapshot)
          }
          .buttonStyle(ZhijiCapsuleButtonStyle())
          .disabled(display.packItemID != nil || display.working)
          Text("引用 \(display.sources) 条素材").font(.zhiji(11)).foregroundStyle(palette.secondary)
        }
      }
    }
    if let done = display.done {
      Text(done).font(.zhiji(12)).foregroundStyle(palette.accent)
    }
    HStack {
      Spacer()
      Button("取消") { actions.present(nil) }.buttonStyle(ZhijiCapsuleButtonStyle())
      Button(display.packItemID == nil ? "转交负责人" : "转交负责人（附交接包）") {
        actions.handoverStep(.handOver)
      }
      .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
      .disabled(display.to == nil || display.working || !state.linkReady)
      .accessibilityIdentifier("bestASR.spaces.handOver")
    }
  }
}

/// What a space's members sheet says first in v8: a takeover to confirm, what
/// waits in the outbox or was refused, and this member's storage.
struct SpaceV8Notices: View {
  @Environment(\.zhiji) private var palette
  let space: SpaceLocalState
  let state: SpacesScreenState
  let actions: SpacesActions

  var body: some View {
    ForEach(space.pendingRecoveries ?? []) { recovery in
      VStack(alignment: .leading, spacing: 6) {
        Text("「\(space.name(of: recovery.memberID))」以组织管理员身份接管了这个空间").font(.zhiji(13, .semibold))
        Text(
          "这台 Mac 看不到组织的签名记录，核对不了。请当面或打电话核对对方的设备指纹：\(recovery.fingerprint)。核对一致再点「承认接管」；在那之前，对方之后的操作这台 Mac 一概不认。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
        Button("承认接管") { actions.confirmRecovery(space.spaceID, recovery.device.deviceID) }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
      }
      .padding(10)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }
    if let line = state.outboxLine(space.spaceID) {
      Text(line + "：内容先锁好存在这台 Mac 上，连上后按原样发出，不会重复。不想发了可以取消。")
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      ForEach(state.outbox[space.spaceID]?.entries ?? []) { entry in
        HStack(spacing: 8) {
          Text("· \(entry.label)").font(.zhiji(12)).lineLimit(1)
          Spacer(minLength: 4)
          Button("取消") { actions.cancelOutbox(space.spaceID, entry.entryID) }
            .buttonStyle(ZhijiCapsuleButtonStyle())
            .accessibilityLabel("取消发出 \(entry.label)")
        }
      }
    }
    if let failures = state.outbox[space.spaceID]?.failures, !failures.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("没有发出去的：").font(.zhiji(12, .semibold))
        ForEach(failures) { failure in
          Text("· \(failure.label)（\(SpaceV8Notices.refusal(failure.code))）").font(.zhiji(12))
        }
        Button("知道了") { actions.dismissOutbox(space.spaceID) }
          .buttonStyle(ZhijiCapsuleButtonStyle())
      }
    }
    if let usage = space.usage {
      Text("你在这个空间里的存储：\(usage.text)").font(.zhiji(12)).foregroundStyle(palette.secondary)
    }
  }

  static func refusal(_ code: String) -> String {
    switch code {
    case "quota_exceeded": return "你在这个空间的存储满了"
    case "one_part_per_recording": return "同一段录音只能附一段原音"
    case "whole_recording": return "整段录音不能共享"
    case "audio_too_large": return "这段原音太大"
    case "audio_not_allowed": return "这个空间不收原音"
    case "snapshot_frozen": return "摘要是冻结的，请另分享一份"
    case "unknown_items": return "引用的素材已经不在空间里"
    case "never_shared": return "这类内容永远不共享"
    case "forbidden": return "你的角色不能这样做"
    case "item_gone": return "这条已经不在空间里"
    default: return code
    }
  }
}
