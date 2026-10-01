# 织机的 Claude Desktop 扩展

`manifest.json` 是 Claude Desktop 扩展（MCP Bundle）的清单；`server/mindloom-mcp.sh` 找到织机自带的连接程序并用它替换自己运行，扩展里不带任何织机的数据。

打包成一键安装的文件（需要 Node.js）：

```sh
npx @anthropic-ai/mcpb pack integrations/claude-desktop mindloom.mcpb
```

双击 `mindloom.mcpb`，在 Claude Desktop 里安装。织机装在别处时，在扩展设置里填写 `织机.app/Contents/Helpers/mindloom-mcp` 的完整路径。完整说明见 `docs/AGENTS.md`。
