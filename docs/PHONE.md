# 手机入口：「分享到织机」和手机键盘

手机上看到的东西（一段聊天、一个链接、一张截图、一条备忘）也应该能进织机，但手机不直接连 Mac，也不经过任何云服务。
现在可用的是 iOS 快捷指令「分享到织机」：在任意 App 里点「分享」，内容经过**你自己的 SSH 密钥**送到**你自己的 Spark**，
在 Spark 的收件箱里等 Mac 取走。手机键盘（像 Typeless 那样按住说话、在任何 App 里出字）是路线图，设计写在本文后半部分。

**已做 / 未做**
- 已实现并有测试：Spark 上的收件箱（`POST/GET /v1/inbox`、`POST /v1/inbox/{id}/ack`，`spark/tests/test_inbox.py`）、
  命令行 `zhiji-inbox`（`add` / `status` / 给手机密钥用的 `gate`）、Mac 端拉取和确认（bestASR 的 `RemoteOrganizerRuntime`）。
- 快捷指令本身是下面的搭建步骤，**没有在真 iPhone 上跑过**。`gate` 的放行规则有单元测试（模拟 `SSH_ORIGINAL_COMMAND`），
  但写进 `authorized_keys` 的强制命令和经跳板机的转发没有端到端跑过；第一次搭好后先用电脑上的 `ssh` 按同样的命令试一次。
- 手机键盘：只有设计，没有代码。

## 数据怎么走

```
iPhone「分享」→ 快捷指令「分享到织机」
   └─ 通过 SSH 运行脚本（你的 Spark 地址 + 手机专用密钥）
        └─ zhiji-inbox add --source iPhone        文字从 stdin 读入；图片是 Base64（--image -）
             └─ 本机 Unix 套接字 + 链路令牌 → POST /v1/inbox      只在 Spark 上排队
Mac（已有的 SSH 隧道）
   └─ GET /v1/inbox?since=游标 → 收进本地库，作为用户素材：来源 App「iPhone」，时间 = 分享时刻 received_at
        └─ POST /v1/inbox/{id}/ack → Spark 立刻删掉正文，只留一条不含内容的记录用来去重
   └─ 之后和其他素材一样：POST /v1/items 送去整理（归事件、写简介）
```

- 没有第三方服务：快捷指令的「通过 SSH 运行脚本」由 iOS 自己执行，连接的是你的 Spark。
- Spark 上的收件箱**只是中转**：Mac 确认收到之前内容留在 Spark（数据目录 0700，与整理服务同一个用户），确认后正文删除。
  Spark 不会直接整理收件箱里的东西；整理只发生在 Mac 把它作为素材送回来之后，所以撤销、删除、导出都以 Mac 为准。
- 重复点了两次分享：每次分享有独立 id，同一 id 重试不会存两遍；内容相同但分享两次，会进来两条，由 Mac 端去重或由你删除。
- 手机要能用 SSH 连到 Spark：同一局域网、你自己的 VPN，或你自己的跳板机（Spark 只能经跳板机访问时，见下面「经跳板机」）。
  不要为此把 Spark 的 SSH 暴露到公网。

## 在 Spark 上准备

1. 整理服务已经按 `spark/ctl.sh start` 跑起来（数据目录默认 `~/hack/organizer-data`，令牌在里面的 `link_token`）。
2. 确认命令能用（用 Spark 上的绝对路径）：

   ```bash
   ~/hack/organizer/spark/zhiji-inbox status        # 输出「等待 Mac 取走：0 条」
   echo "测试一下" | ~/hack/organizer/spark/zhiji-inbox add --source iPhone
   ```

   `zhiji-inbox` 用整理服务的虚拟环境（`ORGANIZER_VENV`，默认 `~/hack/organizer-venv`）和数据目录（`ORGANIZER_DATA_DIR`），
   只和本机套接字说话，令牌不出现在命令行参数里。

3. 给手机单独一把 SSH 密钥，并把它**锁死在这一个命令上**。在快捷指令的「通过 SSH 运行脚本」动作里选「SSH 密钥」→ 生成
   ed25519 密钥 → 拷贝公钥，然后在 Spark 的 `~/.ssh/authorized_keys` 里加一行（路径换成你的绝对路径）：

   ```
   command="/home/你/hack/organizer/spark/zhiji-inbox gate",restrict ssh-ed25519 AAAA…（手机公钥） iphone-share
   ```

   整理服务不在默认位置（例如单独目录里的实例）时，在命令前写上它的数据目录和虚拟环境：
   `command="ORGANIZER_DATA_DIR=/home/你/hack/<实例>/data ORGANIZER_VENV=/home/你/hack/<实例>/venv /home/你/hack/<实例>/app/spark/zhiji-inbox gate",restrict …`。

   `gate` 只放行两种命令：`zhiji-inbox add [--source 名字] [--image -] [--json]` 和 `zhiji-inbox status`；图片只能从 stdin 来，
   不能指定文件路径。`restrict` 关掉端口转发、终端和代理转发。这把钥匙丢了，最多能往收件箱里塞东西，读不到任何数据；
   在 `authorized_keys` 里删掉这一行就吊销了。

### 经跳板机（Spark 只能从跳板机访问时）

快捷指令的「通过 SSH 运行脚本」只能连一台主机，没有 ProxyJump。所以手机连**跳板机**，由跳板机再 `ssh` 到 Spark，
标准输入原样传过去。要点是跳板机上用一把**只做这件事的转发密钥**：它在 Spark 上被 `gate` 锁住，
这样即使手机那一行命令被改写，到了 Spark 也只能执行 `zhiji-inbox add` / `status`。

1. 在跳板机上生成转发密钥（不设口令，只用于这一件事）：

   ```bash
   ssh-keygen -t ed25519 -N "" -C zhiji-relay -f ~/.ssh/zhiji_relay
   ```

   把 `~/.ssh/zhiji_relay.pub` 加进 **Spark** 的 `~/.ssh/authorized_keys`，同样锁在 `gate` 上：

   ```
   command="/home/你/hack/organizer/spark/zhiji-inbox gate",restrict ssh-ed25519 AAAA…（转发公钥） zhiji-relay
   ```

2. 在跳板机的 `~/.ssh/config` 里给 Spark 起个别名（`<spark 别名>`、`<Spark 地址>` 换成你自己的；这里不写真实主机名）：

   ```
   Host <spark 别名>-inbox
     HostName <Spark 地址>
     User <Spark 上的用户名>
     IdentityFile ~/.ssh/zhiji_relay
     IdentitiesOnly yes
     BatchMode yes
   ```

   `IdentitiesOnly yes` 保证这条路只用转发密钥，不会带上你在跳板机上的普通密钥（普通密钥在 Spark 上能开 shell）。

3. 把**手机公钥**加进**跳板机**的 `~/.ssh/authorized_keys`，锁在"转发到 Spark 的 gate"这一个动作上：

   ```
   command="ssh -T <spark 别名>-inbox \"$SSH_ORIGINAL_COMMAND\"",restrict ssh-ed25519 AAAA…（手机公钥） iphone-share
   ```

   手机发来的命令（例如 `zhiji-inbox add --source iPhone`）作为一个整体交给 Spark 上的 `gate` 检查，跳板机不解释它；
   不在允许范围内的命令在 Spark 上被拒绝。`restrict` 关掉手机这把钥匙在跳板机上的端口转发和终端。

4. 快捷指令里「通过 SSH 运行脚本」的主机填**跳板机**的地址和用户名，认证用手机密钥；脚本一栏照下面写
   （`zhiji-inbox add --source iPhone` 或 `zhiji-inbox add --source iPhone --image -`），不用写 Spark 的地址。

吊销：删掉跳板机上手机公钥那一行（只停手机），或删掉 Spark 上转发公钥那一行（停掉整条路）。

## 在 iPhone 上建快捷指令「分享到织机」

1. 快捷指令 App → 新建 → 名称「分享到织机」→ 详细信息里打开「在共享表单中显示」，接收：文本、URL、图像、Safari 网页、富文本。
2. 添加动作（按顺序）：
   - 「如果」：快捷指令输入 · 是 · 图像
     - 「Base64 编码」：快捷指令输入
     - 「通过 SSH 运行脚本」：主机 = 你的 Spark 地址（经跳板机时填跳板机地址，见上），端口 22，用户 = 你的用户名，认证 = 上一步的 SSH 密钥，
       **输入** = Base64 编码的结果，脚本 = `zhiji-inbox add --source iPhone --image -`
   - 「否则」
     - 「获取文本」：快捷指令输入（网页会变成标题和链接）
     - 「通过 SSH 运行脚本」：同上的主机和密钥，**输入** = 文本，脚本 = `zhiji-inbox add --source iPhone`
   - 「结束如果」
   - 「显示通知」：通过 SSH 运行脚本的结果（成功时是「已收进织机（等 Mac 取走后整理）」）
3. 「输入」一栏会作为标准输入交给脚本；有 `gate` 时脚本一栏的写法只要是上面两种之一即可。
4. 想区分来源（iPad、另一台手机），把 `--source iPhone` 换成对应的名字；Mac 上它就是这条素材的来源 App。

排错：通知里是「organizer socket not found」→ Spark 上整理服务没启动；「Permission denied」→ 公钥没加对；
「this key may only run …」→ 脚本一栏写成了别的命令；一直转圈 → 手机连不到 Spark。

## Mac 端要做的（接口约定）

- `GET /v1/inbox?since=<游标>&limit=20` → `{cursor, items:[{inbox_id, source, kind: text|image, text, image_b64, received_at, seq}], pending, more}`。
  只返回未确认的条目；`since=0` 总能取回全部未确认的，所以丢了游标也不会漏。
- 每条先写进本地库（用户素材，来源 App = `source`，captured_at = `received_at`，图片按截图素材处理），**写成功后**再
  `POST /v1/inbox/{inbox_id}/ack`；确认可重复调用，未知 id 返回 404。没写成功就不确认，下次再取。
- 之后按平常的路径 `POST /v1/items` 送去整理；这时它才会被归事件、写进简介。
- `/v1/health` 的 `inbox_pending` 是还在等 Mac 取走的条数，可以在设置页显示。

## 路线图：手机键盘（Typeless 式）

目标：在任何 App 的输入框里按住说话，松开就出字；说过的话同时（可选）作为素材进织机，补上"我在手机上说过什么"这一块。
这是设计，不是已实现的功能。

**采集什么**
- 只采集你在键盘上**主动按住麦克风**时说的话：音频在手机本机转写，**音频本身不离开手机**；转写后的文字插入输入框。
- 如果打开了「收进织机」，同一段文字、所在 App 的名字和时间，走和「分享到织机」一样的路（你的 SSH 密钥 → 你的 Spark 收件箱 → Mac）。
- 不采集：你打的字、剪贴板、别人发来的消息、输入框里原有的内容、任何后台声音。没有"一直在听"。

**每个 App 可以单独关**
- 设置里列出用过这个键盘的 App，每个都有「收进织机」开关；关掉后在那个 App 里仍然可以语音输入，只是不收进。
- 默认关闭的类别：银行和支付、密码管理、医疗健康、工作单位要求不外传的 App。

**看得见的录音指示**
- 录音时键盘顶部显示红点、波形和「正在听」，iOS 自带的橙色麦克风指示同时亮起；松手即停，没有后台录音、没有定时录音。
- 收进织机的那一刻，键盘上短暂显示「已收进」和目的地（你的 Spark 名字）。

**安全字段永远不碰**
- 密码框、一次性验证码、银行卡号、身份证号等安全或敏感类型的输入框（`isSecureTextEntry`、`oneTimeCode`、`creditCardNumber`、
  `password` / `newPassword` 等内容类型）：键盘不提供语音，也不收进。iOS 在密码框里本来就会换回系统键盘，这里再加一道判断。

**处理在哪里，写在明处**
- 键盘和设置里始终写清：「转写：本机」「整理：你的 Spark（SSH）」。没有云端选项，也没有"为了改进服务"的上传。
- 连不上 Spark 时只插入文字、不外发；恢复后按你的选择补发或丢弃，补发前能看到列表。
- iOS 键盘扩展要联网就必须打开「允许完全访问」。我们会说明它只用于连你自己的 Spark；不打开时键盘照样能语音输入，只是不能收进。

**一键暂停**
- 键盘上有「暂停收进」按钮（语音输入照常）；控制中心/锁屏小组件可以「暂停 1 小时 / 到明天 / 直到我打开」。
- 暂停期间键盘顶部持续显示「收进已暂停」。

**删除**
- App 里有「最近收进」列表，每条可以删除；还在 Spark 收件箱里没被 Mac 取走的，一起撤回（需要新增 `DELETE /v1/inbox/{id}`，属于路线图）；
  已经进了 Mac 的，按 Mac 端的删除（墓碑）处理，Spark 上的整理结果随之更新。
- 「全部删除」会清掉手机上的记录和 Spark 收件箱里未取走的条目。

**和 Typeless 的不同**：Typeless 的识别和润色在云端；这里转写在手机本机，整理在你自己的 Spark，两边都不经过第三方服务器。
