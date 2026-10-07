import Foundation

/// What a DGX Spark refusal code means to the person (MAC-SPEC §7.6 toasts).
/// One entry per code: a dictionary literal with a repeated key traps at run
/// time, which is how 「退出这个共享空间」 by the space's owner crashed the App
/// (finish-mac; `last_admin` was listed twice).
public enum SpaceRefusalWords {
  public static let words: [String: String] = [
    "window_passed": "已过撤回期限；删除将提交撤回申请",
    "rotation_pending": "有成员刚离开。请等待管理员更换密钥后重试",
    "host_key_mismatch": "邀请来自另一台 DGX Spark；未加入",
    "invite_used": "此邀请码已使用", "invite_expired": "此邀请码已过期",
    "invite_revoked": "此邀请码已撤销", "bad_invite_secret": "邀请码无效",
    "forks_not_allowed": "此空间不允许保存副本",
    "privacy_takedown": "共享者本人提出的隐私撤回申请无法拒绝",
    "too_many_takedowns": "你已有 3 条隐私撤回申请待处理。请等待维护者处理后再申请",
    "recording_share_limit": "同一段录音最多共享 15 分钟。可以选择其他片段，或先撤回已共享的片段",
    "member_id_taken": "此成员编号已被他人使用",
    "approve_mismatch": "申请中的设备与要同意的设备不一致；未同意",
    "join_request_unverified": "无法核对此申请（并非邀请码持有人发出），无法同意",
    "bad_wraps": "DGX Spark 列出的设备与成员签名的记录不一致，未更换密钥。请检查 DGX Spark",
    "no_masker": "无法隐藏号码，更改未发送",
    "originals_not_allowed": "此空间仅保存文字", "item_gone": "此条内容已不在空间中",
    "archived": "空间已归档，仅可查看", "forbidden": "你的角色无权执行此操作",
    "owner_cannot_leave": "所有者无法退出自己的空间",
    // The same code for a space and for a team.
    "last_admin": "至少需要保留一位管理员",
    "never_shared": "声纹、词典、个人识别习惯和整段录音不可共享",
    "audio_needs_segment": "录音须按片段共享", "segment_too_long": "一段录音最多 15 分钟",
    "whole_recording": "无法共享整段录音，请共享其中一段",
    "one_part_per_recording": "同一段录音最多附带一段原始录音",
    "audio_too_large": "此段录音过大", "audio_not_allowed": "此空间不接受录音",
    "snapshot_frozen": "摘要已固定，请另行共享一份", "quota_exceeded": "你在此空间中的储存空间已满",
    "escrow_required": "此团队要求更多管理员能够恢复空间。请在团队管理员的 Mac 上更换密钥",
    "no_escrow": "这台 Mac 没有此空间的托管密钥", "recovered_key_unverified": "接管时获得的密钥不一致，未接管",
    "device_member_conflict": "这台 Mac 已以他人身份登记", "device_revoked": "这台 Mac 已断开连接，无法再次加入",
    "unknown_member_device": "请选择此人正在使用的 Mac",
  ]

  public static func text(_ code: String) -> String {
    words[code] ?? "DGX Spark 未接受（\(code)）"
  }
}
