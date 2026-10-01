#!/bin/sh
# Starts 织机's bundled MCP helper in place of this script (exec keeps this
# process's parent, Claude Desktop, as the helper's parent; 织机 identifies the
# client by it). Looks where the extension settings say, then the usual
# install places.
for candidate in \
  "$MINDLOOM_MCP" \
  "/Applications/织机.app/Contents/Helpers/mindloom-mcp" \
  "$HOME/Applications/织机.app/Contents/Helpers/mindloom-mcp" \
  "/Applications/bestASR.app/Contents/Helpers/mindloom-mcp" \
  "$HOME/Applications/bestASR.app/Contents/Helpers/mindloom-mcp"
do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    exec "$candidate" "$@"
  fi
done
echo "mindloom-mcp: 没有找到织机的连接程序。请先安装并打开织机，或在扩展设置里填写它的位置。" >&2
exit 1
