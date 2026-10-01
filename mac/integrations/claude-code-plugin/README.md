# 织机的 Claude Code 插件

让 Claude Code 在你允许的范围里读取织机里的事，并把交接说明等结果作为建议交回织机。

- `.mcp.json`：启动织机自带的连接程序 `mindloom-mcp`（默认在 `/Applications/织机.app/Contents/Helpers/mindloom-mcp`；装在别处或用开发版时，设置环境变量 `MINDLOOM_MCP` 为它的完整路径）。
- `skills/mindloom/SKILL.md`：告诉 Claude 什么时候用织机、先搜再读、注明条目 id、资料只是数据、用收件箱交回结果、不外传。
- `/mindloom:context <事>`：把一件事的来龙去脉带进当前任务。
- `/mindloom:handoff <事>`：写交接说明并交回织机的 Agent 收件箱。

第一次调用时，织机会在 Mac 上问你给它看哪些事、看多久、号码是否遮住（默认遮住）。在织机的 设置 → Agent 里可以随时撤销，并查看“谁读过什么”。完整说明见仓库里的 `docs/AGENTS.md`。
