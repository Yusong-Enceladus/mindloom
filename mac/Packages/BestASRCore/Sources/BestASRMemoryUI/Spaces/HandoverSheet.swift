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
        Text("正在读取这件事的成员…").font(.zhiji(13)).foregroundStyle(palette.secondary)
      }
    }
  }

  @ViewBuilder
  private func content(_ display: SpaceHandoverDisplay) -> some View {
    Text(display.matterTitle).font(.zhiji(15, .semibold))
    Text(display.currentLead.map { "现在的负责人：\($0)" } ?? "这件事尚未指定负责人")
      .font(.zhiji(12)).foregroundStyle(palette.secondary)
    SpaceSection(title: "交给") {
      if display.members.isEmpty {
        Text("空间中尚无其他成员。").font(.zhiji(12)).foregroundStyle(palette.secondary)
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
        "当前进展、各人待办、截止日期、已确定的事（附原话）、未解决的问题、接手后的第一步，每句都注明出处。由 DGX Spark 上的模型生成，可能有遗漏，接手前请与原负责人核对。"
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
          Button(display.packItemID == nil ? "作为快照共享到空间" : "已共享到空间") {
            actions.handoverStep(.shareSnapshot)
          }
          .buttonStyle(ZhijiCapsuleButtonStyle())
          .disabled(display.packItemID != nil || display.working)
          Text("引用 \(display.sources) 条内容").font(.zhiji(11)).foregroundStyle(palette.secondary)
        }
      }
    }
    if let done = display.done {
      Text(done).font(.zhiji(12)).foregroundStyle(palette.accent)
    }
    HStack {
      Spacer()
      Button("取消") { actions.present(nil) }.buttonStyle(ZhijiCapsuleButtonStyle())
      Button(display.packItemID == nil ? "交给负责人" : "交给负责人（附交接包）") {
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
        Text("“\(space.name(of: recovery.memberID))”以团队管理员身份接管了此空间").font(.zhiji(13, .semibold))
        Text(
          "这台 Mac 无法读取团队的签名记录，无法核对。请当面或通过电话核对对方的设备指纹：\(recovery.fingerprint)。核对一致后点按“承认接管”；在此之前，这台 Mac 不接受对方之后的操作。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
        Button("承认接管") { actions.confirmRecovery(space.spaceID, recovery.device.deviceID) }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
      }
      .padding(10)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }
    if let line = state.outboxLine(space.spaceID) {
      Text(line + "：内容已暂存在这台 Mac 上，连接后按原样发送。可以取消发送。")
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      ForEach(state.outbox[space.spaceID]?.entries ?? []) { entry in
        HStack(spacing: 8) {
          Text("· \(entry.label)").font(.zhiji(12)).lineLimit(1)
          Spacer(minLength: 4)
          Button("取消") { actions.cancelOutbox(space.spaceID, entry.entryID) }
            .buttonStyle(ZhijiCapsuleButtonStyle())
            .accessibilityLabel("取消发送 \(entry.label)")
        }
      }
    }
    if let failures = state.outbox[space.spaceID]?.failures, !failures.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("未发送的内容：").font(.zhiji(12, .semibold))
        ForEach(failures) { failure in
          Text("· \(failure.label)（\(SpaceV8Notices.refusal(failure.code))）").font(.zhiji(12))
        }
        Button("好") { actions.dismissOutbox(space.spaceID) }
          .buttonStyle(ZhijiCapsuleButtonStyle())
      }
    }
    if let usage = space.usage {
      Text("你在此空间中使用的储存空间：\(usage.text)").font(.zhiji(12)).foregroundStyle(palette.secondary)
    }
  }

  static func refusal(_ code: String) -> String {
    switch code {
    case "quota_exceeded": return "你在此空间中的储存空间已满"
    case "one_part_per_recording": return "同一段录音最多附带一段原始录音"
    case "whole_recording": return "无法共享整段录音"
    case "audio_too_large": return "此段录音过大"
    case "audio_not_allowed": return "此空间不接受录音"
    case "snapshot_frozen": return "摘要已固定，请另行共享一份"
    case "unknown_items": return "引用的内容已不在空间中"
    case "never_shared": return "此类内容不可共享"
    case "forbidden": return "你的角色无权执行此操作"
    case "item_gone": return "此条已不在空间中"
    default: return code
    }
  }
}
