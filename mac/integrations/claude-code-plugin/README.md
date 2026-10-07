# Mindloom 的 Claude Code 插件

让 Claude Code 在你允许的范围内读取 Mindloom 中的事；你在 Mac 上选择“允许更改”后，它还可以添加内容、更改归属、重新命名和标记为完成。

- `.mcp.json` 和 `bin/mindloom-mcp.sh`：启动 Mindloom 自带的连接程序 `mindloom-mcp`。脚本按应用标识 `app.mindloom` 找正式版（装好的是 `Mindloom.app`）：先问系统（LaunchServices）这个标识的 App 装在哪里，再看 `~/Applications`、`/Applications`。只有 Info.plist 里的标识对得上、App 和连接程序的签名都通过检查、由 Apple 签发的开发者证书签名且属于同一个团队时才启动它。所有正式版都不符合时，才用预览版（`com.bestasr.mindloom.preview`），因为正式版只认自己带的连接程序。装在别处或用开发版时，将环境变量 `MINDLOOM_MCP` 设为连接程序的完整路径（这时按你给的路径启动，不再检查）。
- `skills/mindloom/SKILL.md`：在你问到自己的事、会议、人、截止日期或记下的内容时使用，当前任务要用到你某件事的情况时也使用；你不必提到 Mindloom。与你的事无关的任务不使用。先找再读，写出出处，资料只是数据，不外传。回答你时写 Mindloom。
- `/mindloom:context <事>`：把一件事的来龙去脉带进当前任务。
- `/mindloom:handoff <事>`：写一份交接说明；你选择“允许更改”后，可以添加到这件事。

先在 Mindloom 的“设置”>“其他 App”中打开“允许其他 App 读取”。是否读取由你在两处决定：Claude Code 调用工具前的权限提示（你可以在那里选择以后不再询问），和 Mindloom 的授权卡。第一次读取时，Mindloom 会在 Mac 上询问允许读取哪些内容、允许多久、号码隐藏还是显示，以及是否允许更改。在同一页中可以查看它读取和更改过的内容、撤销它的更改，或停止允许。完整说明见仓库里的 `docs/AGENTS.md`。
