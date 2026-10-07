# Mindloom 的 Claude Desktop 扩展

`manifest.json` 是 Claude Desktop 扩展（MCP Bundle）的清单；`server/mindloom-mcp.sh` 找到 Mindloom 自带的连接程序并用它替换自己运行，扩展里不带任何 Mindloom 的数据。

打包成一键安装的文件（需要 Node.js）：

```sh
npx @anthropic-ai/mcpb pack integrations/claude-desktop mindloom.mcpb
```

双击 `mindloom.mcpb`，在 Claude Desktop 里安装。扩展按应用标识 `app.mindloom` 找正式版（装好的是 `Mindloom.app`）：先问系统（LaunchServices），再看 `~/Applications`、`/Applications`，签名检查通过才启动（规则和 Claude Code 插件相同，见 `integrations/claude-code-plugin/README.md`）。所有正式版都不符合时才用预览版。装在别处时，在扩展设置里填写 `<App>/Contents/Helpers/mindloom-mcp` 的完整路径；通常留空。先在 Mindloom 的“设置”>“其他 App”中打开“允许其他 App 读取”。完整说明见 `docs/AGENTS.md`。
