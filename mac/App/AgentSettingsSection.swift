import AppKit
import BestASRAgentAccess
import BestASRDomain
import SwiftUI

/// 设置 → Agent: how to connect, who may read what (撤销), the Agent 收件箱, and
/// 谁读过什么 (records only; AGENT-CONTRACT §2).
struct AgentSettingsSections: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject var access: AgentAccessModel
  @State private var expandedProposal: UUID?
  @State private var pendingRevoke: AgentAccessService.GrantSummary?

  init(model: DictationAppModel) {
    self.model = model
    access = model.agentAccess
  }

  var body: some View {
    Section("让 Agent 读取织机") {
      Text(
        "Claude Code、Claude Desktop、Codex、Cursor 这类 Agent 可以通过织机自带的连接程序读你允许的事，帮你写交接、查进度。第一次连接时织机会问你给它看哪些事、看多久；号码默认遮住。"
      )
      .font(.callout)
      Text(
        "要知道：Agent 读到的内容会交给它背后的服务处理，通常在做这个 Agent 的公司的服务器上，也就离开了这台 Mac。只给它需要的，用完可以随时撤销。"
      )
      .font(.callout)
      .foregroundStyle(.orange)
      .accessibilityIdentifier("bestASR.settings.agentHonestLimit")
      if let status = access.status {
        Text(status).font(.caption).foregroundStyle(.secondary)
      } else {
        Text(access.isRunning ? "可以连接" : "还没有开始接受连接")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      LabeledContent("连接程序") {
        Text(access.helperPath)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(2)
      }
      HStack {
        Button("复制 Claude Code 连接命令") { model.copyAgentInstallCommand() }
          .accessibilityIdentifier("bestASR.settings.agentCopyCommand")
        Spacer()
      }
      Text("也可以装织机的 Claude Code 插件或 Claude Desktop 扩展；步骤见随附的 AGENTS 说明。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("已允许的 Agent") {
      if access.grants.isEmpty {
        Text("还没有允许任何 Agent。").foregroundStyle(.secondary)
      }
      ForEach(access.grants) { grant in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text(grant.clientName).font(.headline)
            Text(AgentAccessModel.scopeSummary(grant.terms)).font(.caption)
            Text(AgentAccessModel.durationText(grant))
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(grant.clientPath)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          Button("撤销", role: .destructive) { pendingRevoke = grant }
            .accessibilityIdentifier("bestASR.settings.agentRevoke")
        }
      }
    }
    .confirmationDialog(
      "撤销「\(pendingRevoke?.clientName ?? "")」？",
      isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
      titleVisibility: .visible
    ) {
      Button("撤销", role: .destructive) {
        if let grant = pendingRevoke { access.revoke(grant.grantID) }
        pendingRevoke = nil
      }
      Button("取消", role: .cancel) { pendingRevoke = nil }
    } message: {
      Text("它下一次读取时就会被拒绝，要再读得重新问你。它已经读走的内容收不回来。")
    }

    Section("Agent 收件箱") {
      if access.proposals.isEmpty {
        Text("Agent 提的建议会先放在这里，你收下之前什么都不会归档。").foregroundStyle(.secondary)
      }
      ForEach(access.proposals) { proposal in
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(proposal.title.isEmpty ? "（没有标题）" : proposal.title).font(.headline)
              Text(
                "来自 \(proposal.clientName) · \(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Button("不要") { model.rejectAgentProposal(proposal) }
            Button("收下") { model.acceptAgentProposal(proposal) }
              .accessibilityIdentifier("bestASR.settings.agentAccept")
          }
          Text(proposal.text)
            .font(.callout)
            .lineLimit(expandedProposal == proposal.id ? nil : 3)
            .textSelection(.enabled)
          if !proposal.matterHint.isEmpty {
            Text("它说可能属于：\(proposal.matterHint)").font(.caption).foregroundStyle(.secondary)
          }
          Button(expandedProposal == proposal.id ? "收起" : "展开全文") {
            expandedProposal = expandedProposal == proposal.id ? nil : proposal.id
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
      Text("收下的建议会成为一条来源标为“agent:它的名字”的资料，不算你自己说的话，和其他资料一样整理。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("谁读过什么") {
      HStack {
        Picker("只看", selection: $access.auditClient) {
          Text("全部").tag(String?.none)
          ForEach(access.clients, id: \.key) { client in
            Text(client.name).tag(Optional(client.key))
          }
        }
        .frame(maxWidth: 260)
        Spacer()
        Button("导出…") { model.exportAgentAudit() }
          .disabled(access.audit.isEmpty)
      }
      if access.audit.isEmpty {
        Text("还没有记录。只记谁、什么时候、用了什么、读了哪几件事、多少字节，不记内容。")
          .foregroundStyle(.secondary)
      }
      ForEach(access.audit.prefix(200)) { row in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.at.formatted(date: .abbreviated, time: .standard))
            .font(.caption.monospacedDigit())
            .frame(width: 150, alignment: .leading)
          Text(row.clientName).font(.caption).frame(width: 110, alignment: .leading)
          Text(AgentAccessModel.toolName(row.tool)).font(.caption)
          Text(AgentAccessModel.outcomeName(row.outcome))
            .font(.caption)
            .foregroundStyle(row.outcome == .allowed ? Color.secondary : Color.orange)
          Spacer()
          Text(row.matterIDs.isEmpty ? "" : "\(row.matterIDs.count) 件事")
            .font(.caption)
            .help(row.matterIDs.joined(separator: "\n"))
          Text(ByteCountFormatter.string(fromByteCount: Int64(row.byteCount), countStyle: .file))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .task { await access.refresh() }
  }
}
