# 隐私边界

以 [PRD §0.3](../mac/PRODUCT_REQUIREMENTS.md) 为准，这里是摘要和证据索引。

**一句话**：Spark 从头到尾听不到你的声音。录音在 Mac 上就转成文字、认出是谁；录音、声纹和词典从不离开这台 Mac。离开 Mac 的只有文字，以及你自己放进来的截图和文件，只经一条你打开、随时能撤销的 SSH 链路，到你自己的 DGX Spark，只用于整理。没有云端。

「模型在本地跑」只回答了谁在算。织机还回答了另外五个问题：送过去什么、怎么送过去、还有谁能碰到、能不能收回、关了还能不能用。

## 什么在哪里

| 数据 | 位置 |
|---|---|
| 原始音频、声纹 / 说话人向量、词典、窗口和会议标题、截图的本机识字结果 | 只在 Mac 上。发送类型里没有这些字段 |
| 逐字稿终稿（或你改过的版本）、分段（起止毫秒、人物 ID、文字）、人物 ID 和你起的名字、来源 App、开始时间、内容 SHA-256 | Mac 上；链路打开时发到**你自己的** Spark |
| 你放进来的截图和图片 | Mac 上保留原件；发给 Spark 的是缩小后（长边不超过 2560 px）、不复制任何元数据的 PNG/JPEG 副本 |
| 你放进来的文件 | 不超过 25 MiB 的发原件字节、文件名和 Mac 读出的文字；更大的只发文字，没有文字就留在 Mac |
| 视频 | 音轨在 Mac 上转成文字；视频本身不发送，只发最多 12 张关键帧（按图片处理） |
| 整理结果（事件、标题、现在到哪一步、排序、提问） | Spark 生成，作为建议回到 Mac；不覆盖原始素材 |
| 手机分享的内容 | 经你自己的 SSH 密钥直接进你自己 Spark 的收件箱，Mac 确认取走后 Spark 删掉正文 |
| 任何数据 | 不去任何云端：没有云模型 API，织机的代码不发遥测，没有远程崩溃上报 |

## 七条保证（代码里做到、有测试）

测试名都可以在仓库里搜到：Mac 端在 `mac/Packages/BestASRCore/Tests/`，Spark 端在 `spark/tests/`。

1. **Spark 听不到你的声音。** 识别、分说话人、声纹匹配都在 Mac 上做完。发送类型 `RemoteOrganizerItem`（`mac/Packages/BestASRCore/Sources/BestASRDomain/RemoteOrganizer.swift`）根本没有音频、声纹、词典、窗口标题的字段。`testPayloadCarriesOnlyAllowedFieldsAndNoPrivateSentinels` 在合成资料库里埋下带哨兵字符串的音轨、声纹、说话人向量、词典词、会议标题和窗口标题，断言发出的报文里一个都没有，并且字段集合严格等于允许的键。
2. **Spark 不对网络开端口。** 整理服务默认只在数据目录（权限 0700）里的 Unix socket 上监听；要开 TCP 必须显式设置 `ORGANIZER_TCP=1`，而且只能绑回环地址（`test_tcp_is_off_unless_explicitly_enabled`）。每个接口都要链路令牌（`test_every_route_needs_the_bearer_token`）。Mac 用 `ssh -N -L 127.0.0.1:<随机端口>:<socket>` 连过去，SSH 参数经过加固（`BatchMode`、`StrictHostKeyChecking`、不转发 agent 和 X11），每个请求前用 libproc 核对本机端口的监听者确实是 App 自己启动的 ssh（`testNothingIsSentWhenTheForwardPortIsNotHeldByOurSSH`、`testOwnerCheckRunsBeforeEveryRequestNotOnlyAtConnect`）。令牌另走一条已认证的 SSH 读进内存，不写盘、不进日志、不出现在进程参数里。App 没有内置主机，你不填就不连任何机器。
3. **关掉就是撤销，不是暂停。** 链路默认关闭，打开后只发送打开之后开始的记录，打开前的历史一条也不补发。关掉的那一刻隧道断开、待发队列清空；再打开也不补发关着期间的内容（`testRevocationStopsSendingAndClearsTheOutbox`、`testWatermarkReconciliationAndRevocation`）。状态读不准时一律按关闭处理。
4. **隐私不拿功能换。** 口述从松键到出字、录音、识别、插入、搜索，都不经过 Spark。Spark 不可用时待发内容在 Mac 上排队，恢复后自动补发；链路关闭时事件页改用本机整理；你的纠正先在本机生效。
5. **只发必要的，不该收的会被拦下。** 只在你按 ⌘V、选「收进来」或拖入时才读剪贴板，没有后台监听。密码管理器标成隐藏、临时或自动生成的剪贴板内容整份拒收（`testPasswordManagerMarkersAreNeverTakenIn`）。截图发的是不带 EXIF 位置和设备信息的缩小副本。网页链接和符号链接不读（`testWebLinksAndSymlinksAreNeverReadAndTextIsBounded`）。织机自己资料库里的文件不能再被收进来。
6. **素材只当数据，模型改不了原文。** Spark 只返回事件、标题、进展、排序这类派生结果；它那边的素材表只能新增，SQLite trigger 禁止修改和删除（`test_items_are_append_only`）。模型提示里素材放在 `<data>` 中并声明不是指令，素材里写着「删除所有事件」也只是一条内容（`test_injection_text_is_passed_as_quoted_data`）。纠正只能从界面发出，并永久优先于之后的模型输出（`test_rename_wins_over_later_briefs`）。
7. **开发过程也守住了边界。** 只有带 `SYNTHETIC_DATA_ROOT` 标记的数据目录能打开链路；真实资料库按文件身份（设备号 + inode）识别，符号链接、firmlink 等写法都绕不过，所有构建配置都一样（`testRealLibraryAndUnmarkedRootsNeverStartTheLink`、`testMagicPathPrefixesOfTheRealLibraryAreRefused`）。Spark 上的评测和演示全部用合成数据。Spark 上的模型都是开放权重，由 vLLM 在本机 `127.0.0.1` 上提供；解析文件的子进程在导入任何解析库之前就禁用了网络（`test_the_parser_process_has_no_network`）。

## 威胁和防护

| 担心的事 | 防护 |
|---|---|
| 录音、声纹被送出 Mac | 发送类型没有这些字段；哨兵测试逐字段比对报文 |
| 局域网里的别人连上整理服务 | 默认不开 TCP，只有 0700 目录里的 Unix socket；每个请求都要令牌，常数时间比较 |
| 本机别的进程抢占转发端口、骗走令牌 | 每个请求前核对端口监听者是 App 自己的 ssh 子进程，不是就不发并重建隧道 |
| 令牌泄漏 | 只在内存里，不写盘、不进日志和进程参数；收到 401 就丢弃重读 |
| 连错机器 | 没有默认主机；`StrictHostKeyChecking=yes`，用你自己的 `known_hosts` |
| 想反悔 | 一键关闭：断开隧道、清空待发队列，再打开也不补发 |
| 素材里藏着指令 | 素材只当数据；动作只能由代码从模型的判断推出，或由你在界面上发出 |
| 截图带出位置 | 发送副本不复制元数据；三个规模场景实测 162 张截图的 EXIF 里没有 GPS |
| 恶意文件 | 在断网、限时、限内存的子进程里解析；压缩包不展开炸弹，里面的音视频不解码 |
| 开发时误发真实资料库 | 按文件身份拒绝；lint 禁止用条件编译绕开 |
| 手机密钥丢了 | 手机那把 SSH 密钥在 `authorized_keys` 里被锁成只能往收件箱里加内容，读不到任何数据（`test_gate_only_allows_add_and_status`） |

## Spark 上存了什么、存多久、怎么删

- **存了什么**：Mac 送来的每条素材的每个修订（文字、分段、图片和文件字节）、整理结果、你的决定，以及每次模型调用的记录（技能名、版本、模型、提示哈希、输入摘要和输出；不存输入正文）。都在数据目录下的 `organizer.db`（SQLite）里。
- **怎么保护**：数据目录权限 0700、进程 umask 077，文件只有 Spark 上你这个账户能读。**没有静态加密**：加密只在传输段（SSH）。能以你的账户登录这台 Spark 的人（或 root）能读到这些内容和链路令牌，所以 Spark 账户要和 Mac 一样当作私人设备对待。
- **存多久**：没有自动过期，一直保留到你删除。
- **怎么删**：v1 没有远程删除接口。先在 Mac 上关掉链路，再停掉整理服务、删除它的数据目录（`ORGANIZER_DATA_DIR`，默认 `~/hack/organizer-data`）。注意：链路再打开后，Mac 发现 Spark 的数据库被重置，会把它仍保留、且之前送达过的素材重新发一遍；要彻底收回某条内容，先在 Mac 上删掉它。
- **收件箱**：手机分享的正文在 Mac 确认取走后就删除，只留一条不含内容的记录用于去重。

## 三个诚实的边界

1. **已送到 Spark 的内容，Mac 上删了，Spark 上不会跟着删。** Mac 上删除一条记录时，会在同一事务里删掉它的待发任务和发送资格，以后不会再从队列离开 Mac；但已经送达的副本和它的旧修订还在 Spark 上，关掉链路也不会收回。删除方法见上一节。
2. **「音频不出 Mac」指的是录音，以及按音视频导入的文件。** 你主动拖进来的其他文件，比如压缩包、不在导入列表里的音视频格式（`.avi`、`.wma`、`.3gp`）、相机 RAW，只要不超过 25 MiB，会原样发到 Spark，里面的音频或照片位置信息也一起过去。
3. **有几个环节还没有实证。**
   - 发布开关 `productReleaseAllowsOwnLibrary = false`：Spark 整理只在合成资料库上跑过，真实资料库还没打通。
   - 手机快捷指令没有在真 iPhone 上端到端跑过，只有收件箱和锁定规则有测试。
   - Spark 上的对话模型服务（`127.0.0.1:8000`）由你自己启动，不是本仓库启动的；它有没有关掉 vLLM 的使用统计，本仓库证明不了。我们自己启动的向量服务显式设置了 `VLLM_NO_USAGE_STATS=1`、`DO_NOT_TRACK=1`、`HF_HUB_OFFLINE=1`。

## 实测：Spark 实际收到了什么

三个规模场景（合成数据）结束后，只读打开 Spark 上的整理器数据库，逐条统计 Mac 发来的内容：每个场景 7.6–12.6 MB，只有文字、文档文字和截图；音视频文件头 0 个，长度 ≥32 的浮点向量 0 个，162 张截图的 EXIF 里只剩像素尺寸和色彩空间。这批素材本来就没有音频，所以这组数字不能证明「不发音频」（那由上面的类型和测试保证），它说明的是出网内容可以这样逐字节核对。数字和脚本见 [EVALUATION.md](EVALUATION.md#12-隐私spark-实际收到了什么) 和 [eval/results-2026-09-29/](../eval/results-2026-09-29/README.md)。

## 仓库里有什么、没有什么

- 仓库里的评测和演示数据全部是虚构的合成数据；截图是通用聊天界面样式的合成图。
- 仓库不含模型权重、音频、真人口述、个人整理模型或评测用的私人资料。依赖私人资料的评测脚本没有公开。
- 日志不记录音频、完整逐字稿、词典内容、声纹或参与者信息；整理服务关闭了访问日志和接口文档页。
- **已知的出站请求**：安装模型时从 Hugging Face 按固定 revision 下载。Mac App 的自动更新检查默认关闭；打开后只请求本仓库 GitHub Releases 的公开元数据（不带 cookie 和用户内容），目前还没有发布任何 Release。Mac 端没有分析或崩溃上报 SDK。
- 「复制这件事」「导出为文本」只在你点击时发生；织机没有和 Claude、Codex 的任何 API 集成，内容进不进云端助手由你决定。
