import BestASRDomain
import Foundation

/// Settings › 其他 App › an App's page: what each recorded call did, in plain
/// words (review v12-B #16). An unknown tool is never shown by its protocol
/// name (「tools/call」), and the record's footnote says what is recorded.
public enum AgentAuditWords {
  /// 「找」「读一件事」…; a call to a tool Mindloom does not have says so.
  public static func tool(_ tool: String) -> String {
    switch tool {
    case "today": "查看今天"
    case "search", "search_matters": "搜索"
    case "get_matter", "resources/read": "读取一件事"
    case "list_deadlines": "查看截止日期"
    case "list_recent": "查看最近内容"
    case "get_person": "查找人物"
    case "add_note": "添加内容"
    case "move_item": "更改归属"
    case "rename_matter": "重新命名"
    case "mark_step": "标记为完成"
    case "resources/list": "列出事"
    case "add_to_inbox": "提交待确认内容"
    default: unknownTool
    }
  }

  public static let unknownTool = "调用了 Mindloom 不支持的操作"

  public static func outcome(_ outcome: AgentAuditOutcome) -> String {
    switch outcome {
    case .allowed: "已提供"
    case .denied: "不允许"
    case .pending: "等待你的决定"
    case .notFound: "超出允许范围"
    case .invalid: "无法识别请求"
    case .failed: "未能读取"
    case .limited: "已达到每小时上限"
    }
  }

  /// The 它读过的 group's footnote when every call is listed.
  public static let recordsFooter = "每次访问都会记录时间、操作、结果和字数。"
}
