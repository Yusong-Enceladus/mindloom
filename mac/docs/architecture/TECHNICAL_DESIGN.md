# bestASR macOS V1 技术方案

> 版本：0.6（本地音频记忆、任务型产品投影与分层推理）
> 日期：2026-09-26
> 状态：可进入风险验证；尚不可冻结模型、加密实现与发布配置  
> 产品依据：[PRODUCT_REQUIREMENTS.md](../../PRODUCT_REQUIREMENTS.md) V1.7，范围以 §0.1–§0.3 用户裁决为准

## 2026-09-26 远程整理器：用户自有 DGX Spark（Remote organizer on the user's own DGX Spark）

依据 PRD §0.3。本节优先于下文 §12、§14 中与之冲突的“只有模型/App 更新可以联网”“内容不离开本机”的表述。状态：接口 v1 已冻结；Mac 端桥接代码与 Spark 端服务已通过合成数据联调，产品验收状态见 `IMPLEMENTATION_STATUS.md`。

**职责划分。**
- Mac 负责收集、识别、插入、搜索和人物声纹匹配，并始终是源事实：原始音频、逐字稿修订、用户条目和用户决定都先在本机提交。
- Spark 上的整理服务只产出派生结果：事件归类、标题与“现在到哪一步”、首页排序、截图读取。这些结果分别由 event-assign、event-brief、home-rank、screenshot-read 四个 skill 生成；可选的 recall 供其他 agent 只读调用。
- 整理结果不是同步：Spark 不写回 Mac 的源记录，Mac 也不把 Spark 当作源事实；`SyncAdapter` 与 `.bestasrarchive` 两条出口不变。

**离开 Mac 的数据。**
- 可以发送：
  - 最终逐字稿及其分段（时间、人物 ID、用户起的名字）。
  - 用户粘贴或拖入的文字、截图字节，以及从文档提取的文字。
  - 来源 App 的 bundle ID 与名称，以及起止时间。
  - 用户的纠正决定与二选一问题的回答。
- 永不发送：音频、声纹/说话人 embedding、词典、窗口标题、会议标题与参会者上下文。
- 日志只记录 item/事件 ID、数量、状态码和耗时，不记录正文、标题、人名或链路令牌。

**开关与撤销（按资料库保存）。**
- 链路默认关闭。开启时间作为“水位线”写入当前资料库的 `remote_organizer_meta.link_enabled_at`，不写 App 偏好设置。
- 可发送资格在采集开始时显式授予：`GRDBDictationStore.create` 本身从不授予资格（历史导入等批量写入也走它）；只有实时采集路径在建会话后调用 `markLiveCaptureRemoteEligible(sessionID:)`（`DictationCaptureCoordinator` 经 `LiveCaptureRemoteEligibilityPort`，以及 App 内用户发起的媒体导入），链路开启时写入 `remote_organizer_eligible`；这一步失败只让该会话留在本机，不影响录音。收进来的条目在 `createUserItem` 的同一事务里授予。不再按 `created_at` 与水位线比较推断。归档导入的会话、Typeless 历史导入的会话、链路关闭时开始的会话永远没有资格；`TypelessImportCLI` 遇到链路开启的资料库直接拒绝运行。
- 开启期间：只有有资格且已完成的会话会被自动发送（设置页文案为“开启后开始的记录”）。已被跟踪的会话在链路开启时发生逐字稿修改、版本恢复、重新识别、说话人更正、人物改名或退役、来源 App 字段变化时，发送新版本。
- 关闭（撤销）在界面边界是同步的：开关的回调先调用控制器的 `revokeNow()`（删除“开启标记”、停止运行时——取消 worker 与 HTTP、终止 ssh 子进程并等待退出——并显示已关闭），之后才异步写资料库：删除水位线并清空待发队列。从未送达的条目任务及其资格被删除；已送达条目的待发更新被取消；排队的决定标为“未发送”（`cancelled/revoked`），正在发送或已尝试过的决定标为“可能已送达”（`cancelled/in_flight`）。
- 开启标记按数据根保存在资料库之外（`~/Library/Application Support/bestASR-organizer-link/link-on-<hash>`，hash 取数据根的内核规范路径 `F_GETPATH`，符号链接、`/tmp` 与 `/private/tmp`、大小写不同的写法得到同一个标记）。资料库的开启提交之后才创建标记；启动时只有标记与水位线同时存在才恢复链路。关闭只需删除标记（磁盘满也能删除），删除失败时状态显示“存储不可用”而不是“已关闭”。只有水位线没有标记（撤销的资料库写入失败，或开启没做完）时，下次启动先重试撤销，成功前不启动任何运行时（fail closed）；只有标记没有水位线时保持关闭并删除标记。链路配置无效或状态目录不可用时同样撤销。旧版本的 `link-off-<hash>` 文件不再使用：升级后没有开启标记的资料库按关闭处理，需要重新开启一次。
- 重新开启只写新的水位线，不补发任何东西：关闭前未发出的内容与修改、关闭期间的记录与修改都不会因重新开启而发送。重新开启后某条已送达记录再次变化时，发送它当时的完整内容（其中自然包含之前的修改）。
- 已送达 Spark 的内容仍保留在 Spark 上；v1 没有远程删除接口。显式删除 Mac 会话会同时删除该会话的条目任务与资格。
- 归档导入：导入在同一事务里先撤销链路；导入的会话没有资格；恢复的决定以“从归档导入，未发送”（`cancelled/imported`）列出，只有用户重试才会发送。开发阶段 App 拒绝向带合成标记的数据根导入归档。

**开发阶段的数据来源护栏。**
- 在所有构建配置下（不再依赖 `#if DEBUG`；`script/lint.sh` 拒绝该模块与 App 胶水代码中的条件编译），只有当前数据根目录含有标记文件 `SYNTHETIC_DATA_ROOT` 时，App 才会启动远程整理。标记只由 `script/make_synthetic_data_root.sh` 放在它新建的空目录上（已存在的目录一律拒绝），或由测试创建。
- 真实资料库一律拒绝，即使其中被放了标记。真实资料库路径取自账户数据库（`getpwuid(getuid())->pw_dir`），不受 `HOME`/`CFFIXED_USER_HOME` 影响；比较按文件身份（候选路径及其每个已存在祖先的设备号与 inode），不存在的部分按内核规范路径（`F_GETPATH`）大小写不敏感比较，因此符号链接、firmlink、`/.nofollow`、`/.resolve/N`、`/.vol` 等写法都会被识别。启动时若资料库已开启链路但标记已不存在，App 撤销链路并显示原因（fail closed）。
- 带标记的数据根里，`history.sqlite`（含 `-wal`/`-shm`）与 `assets` 必须是该目录自己的文件：不能是符号链接，数据库文件不能有其他硬链接，也不能与真实资料库对应条目是同一文件，否则拒绝发送。
- 演示用独立数据根：`bestASR -BestASRDataRoot <绝对路径>`。只从本次启动参数读取，不写入偏好设置；路径不能是、包含或位于真实资料库之内，也不能以 `/.` 开头。只要参数中出现该选项的任何写法（大小写不同、`--`、`=`、缺值、空值、重复），而不是恰好一个 `-BestASRDataRoot <绝对路径>`，启动就失败，绝不回退到真实资料库。
- 唯一的发布开关是 `RemoteOrganizerDataProvenance.productReleaseAllowsOwnLibrary`（当前为 `false`），由通过产品验收的发布流程改动，开发期间不改。

**隧道与链路令牌。**
- 服务只绑定 `<spark-host>` 上的 `127.0.0.1:8765`，不监听任何外部网卡；另外在 `<data_dir>/organizer.sock`（`ORGANIZER_UDS`，`spark/ctl.sh` 默认开启）上提供同一接口。套接字目录必须属于服务用户且权限为 0700，否则服务拒绝启动。
- Mac 转发到这个 Unix 套接字，而不是 TCP 8765：Spark 上任何本机进程都能在整理服务停机（重启、崩溃、systemd 重启间隔）时抢占一个众所周知的回环端口，从而收到令牌和逐字稿；0700 目录中的套接字只有服务用户本人能创建。
- 每次建立隧道时，Mac 由内核随机分配一个空闲回环端口 P。套接字路径含 `~` 时，先用一条独立的已认证 SSH 命令 `cd <目录> && pwd -P` 解析为绝对路径（每个运行时一次），再启动 `/usr/bin/ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=15 … -L 127.0.0.1:P:<套接字绝对路径> -- <spark-host>`。
- 发出任何 HTTP 请求之前（每个请求，包括 `/v1/health`），App 通过 libproc 确认 127.0.0.1:P 上的监听套接字属于自己这个 ssh 子进程；否则不发送并重建隧道。这防止 Mac 上其他进程抢占端口后收到逐字稿。
- 已接受的剩余风险：所有权检查与 URLSession 随后建立 TCP 连接之间不是原子的。若自己的 ssh 恰好在这约一毫秒内退出，且另一个本机进程抢先绑定了同一随机端口，这一个请求会到达该进程。内核规则使并发重复绑定不可能，这是唯一剩余窗口；不另做连接后按四元组核对 `proc_pidfdinfo`。
- 链路令牌：Spark 首次启动时在 `<data_dir>/link_token` 生成 64 位十六进制随机令牌（权限 0600）。令牌文件存在且未设置 `ORGANIZER_REQUIRE_TOKEN=0` 时，所有 `/v1/*`（含 `/v1/debug/*`）都要求 `Authorization: Bearer <token>`，否则返回 401（常数时间比较）。Mac 只通过另一条已认证的 SSH 命令 `ssh <spark-host> cat <远端令牌路径>` 读取令牌，从 stdout 读入内存；令牌不经隧道、不写日志、不落盘，也不出现在其他进程的参数或环境变量中。收到 401 时丢弃令牌并在重连时重新读取。
- 主机、套接字路径与令牌路径没有设置界面，通过 `defaults write` 写入偏好键 `preferences.spark-organizer-host`（没有内置默认值：未设置或为空时链路视为未配置，按配置无效同样处理——开关保持关闭、撤销资料库链路、不发送任何内容，并提示用户写入主机；`<spark-host>` 指用户自己 Spark 的 ssh 主机名或别名，例如 `defaults write com.bestasr.app preferences.spark-organizer-host <spark-host>`）、`preferences.spark-organizer-socket-path`（默认 `~/hack/organizer-data/organizer.sock`）与 `preferences.spark-organizer-token-path`（默认 `~/hack/organizer-data/link_token`）；值只能含 `[A-Za-z0-9._/~-]`，不能以 `-` 开头或含 `..`。
- 每个 ssh 子进程在 `~/Library/Application Support/bestASR-organizer-link/`（不属于任何资料库）写一条记录（ssh PID、App PID 与可执行路径、主机、本地端口、转发目标）。App 启动时（`applicationDidFinishLaunching`，与资料库能否打开、偏好是否有效无关）、开启（在数据来源检查之前）和关闭链路时清理遗留隧道：仅当记录的 ssh 进程仍存活、其实时命令行与该记录对应的 ssh 签名完全一致，且记录所属的 App 实例已不在运行时，才终止它。撤销与退出都执行 SIGTERM、限时等待、SIGKILL 兜底。
- HTTP 传输在同一把锁下创建任务和作废会话：`cancelAll()` 之后的发送直接抛错，不会在已作废的 URLSession 上创建任务（那会触发 Objective-C 异常使 App 退出）。
- 加密和主机/用户认证由 SSH 承担，使用用户已有的密钥和 `known_hosts`；App 不保存 SSH 私钥或口令。HTTP 客户端只访问回环地址，不带 cookie、缓存、代理，不跟随重定向。
- 运行时一次性使用且带代次保护：`stop()` 返回后，旧 worker 迟到的状态或投影都不会再送达界面。

**接口 v1（JSON，UTF-8）。**
- 所有请求带 `Authorization: Bearer <link_token>`。
- `GET /v1/health` → `{ok, store_id, model, skills:[{name, version}], items, events}`。`store_id` 是服务端数据库首次创建时生成的 UUID。
- `POST /v1/items`，请求体 `{items:[Item]}`，返回 `{accepted, duplicates}`。`Item` 的字段：
  - `item_id`：UUID 字符串，即 Mac 的 SessionID，同一会话始终不变。
  - `revision`：整数，同一 `item_id` 单调递增。
  - `kind`：`dictation`、`meeting_online`、`meeting_offline`、`imported_media`、`text`、`image`、`document` 之一。
  - `source_app`：`{bundle_id?, name}`。
  - `started_at`、可选的 `ended_at`：带时区偏移的 ISO 8601 时间。
  - `text?`：最终逐字稿或提取的文字。
  - `segments?`：`[{start_ms, end_ms, person_id?, text}]`。
  - `persons?`：`[{person_id, display_name?}]`。
  - `image_b64?`：`kind=image` 时为 PNG/JPEG，在 Spark 上由 screenshot-read 读取。
  - `sha256`：条目内容摘要。
- `POST /v1/decisions`，请求体 `{decisions:[Decision]}`，返回 `{applied, rejected:[{index, reason}]}`。`Decision` 的种类：
  - `rename_event{event_id, title}`（标题 1–80 个字符，Mac 在保存前校验）、`remove_item{event_id, item_id}`、`move_item{item_id, to_event_id}`。
  - `same_event{a, b, answer: bool}`、`same_person{a, b, answer: bool}`、`name_person{person_id, display_name}`。
  - `pin_event{event_id, pinned}`、`feature_less{event_id}`、`delete_event{event_id}`。
  - Mac 发送的每个决定另有稳定 `decision_id`；Spark 以 ID 与内容摘要保存回执，同一决定重放返回原结果，ID 被不同内容复用则拒绝。
- `GET /v1/state?since=<cursor>` → `{cursor, store_id, events, questions, persons}`：
  - `events`：`[{event_id, title, title_user_edited, status_line, status_facts:[{text, item_ids}], importance, started_at, updated_at, item_ids, person_ids, pinned, deleted}]`。
  - `questions`：`[{question_id, kind: "same_event"|"same_person", a, b, prompt_zh, created_at}]`。
  - `persons`：`[{person_id, display_name, aliases, origin, merged_into}]`。
- `POST /v1/questions/{id}/answer`，请求体 `{answer: bool}`。

**来源与决定的语义。**
- 模型写出的每个字段都带 skill 名称与版本、模型 ID 和 prompt hash；源条目永不修改。
- 决定是永久约束。例如被 `remove_item` 移出的条目不会再被自动归回该事件；`title_user_edited` 的标题不被后续 event-brief 覆盖；`same_*` 的否定答案阻止之后的自动合并。
- `same_person` 合并时语音来源的人物保留为主人物，否则保留 `a`；Mac 的本地叠加使用同一规则并沿 `merged_into` 追到主人物，不会形成环。
- 条目内容一律按数据处理。skill 的 prompt 把正文作为被引用的材料，条目中任何类似指令的文字都不能改变约束、删除内容或调用接口；约束只能来自 `/v1/decisions` 和问题回答。
- 二选一问题由服务端限频，Mac 只展示，不自行生成。

**幂等与顺序。**
- 条目：同一 `(item_id, revision)` 重复发送只计入 `duplicates`；同一 `item_id` 的更高 `revision` 替换已存内容（文字、分段、人物、来源元数据），标记为已变化并重新归类、重写相关事件的标题与进度，重试同样幂等；更低的 `revision` 视为过期，计入 `duplicates`。
- Mac 端条目待发队列按会话一行（`remote_organizer_item_jobs`），记录目标版本、已尝试版本与内容摘要、已送达版本与内容摘要、状态、重试次数、错误类别和时间戳。发送内容在认领时由会话当前的最新终稿、分段、人物归属与显示名现场生成，不在入队时冻结，所以同一会话的多次修改合并为一次发送。
- 版本规则：若某版本号已经尝试发送过且当前内容摘要不同，就改用更大的版本号，保证 Spark 不会把新内容当作重复丢弃；当前内容与已送达内容一致时不发送。暂时无法发送的会话（文字为空、超长等）的任务不删除，而是以 `failed/unsendable` 停放并保留已用过的版本号，下一次变化再排队；只有显式删除会话才删除任务。每次认领最多检查 32 个未变化或无法发送的任务，避免长时间占用唯一的写连接。
- 人物来自会话已接受的说话人归属（`speaker_occurrences` 中 `anonymousIdentity`/`automaticMatch`/`userConfirmed`），不依赖分段，所以整段修改（没有分段）仍带着人物。显示名与来源名按服务端限制以 Unicode 标量截断（128/256），过长的 bundle ID 省略。
- 逐字稿终稿/用户修改的写入、说话人出现与人物归属的变化、人物改名或退役、来源 App 字段变化，都由 SQLite trigger 在同一事务里把已跟踪的会话标记为待发（仅在链路开启时）。
- 对账：运行时每次连接及轮询时，把有资格、已完成但没有任务的会话（崩溃恢复、退出打断记账、模型就绪后才完成等）补入队列；关闭期间开始的会话和导入的会话没有资格。
- 决定严格按本地提交顺序发送：最早的未送达决定仍在发送或退避时，后面的决定等待；运行时启动时把遗留的租约放回队列。被 Spark 永久拒绝的决定保留、在本地继续生效，并在事件页以“Spark 未接受”列出原因，用户可重试或放弃；问题回答遇到 404/409（问题已过期、未知或其决定未能应用）时改以等价的普通决定发送；旧服务对重放回复“already answered”而不带 `applied: true` 时同样视为未确认。无法解析的本地决定被隔离为失败项，不会中断恢复。
- 重试：Spark 按决定 ID 保存回执（包括拒绝），同一 ID 重放只会得到原结果，所以“重试”把被拒绝或未发送的决定以新 ID、普通决定（不再回答问题）重新提交，排在本地提交顺序的末尾并删除旧行，本地叠加顺序因此与发送顺序一致。“可能已送达”的决定不能放弃，只能“确认送达”：它和其他重试一样以新 ID 排到提交顺序末尾，而不是以原 ID 在原位置重放——否则 Spark 会在其后已送达的决定之后应用它（例如之后已送达的“取消置顶”被重新应用的“置顶”覆盖），而本地叠加仍按原位置重放，两边永久不一致。若 Spark 当时其实已应用，末尾这份是一次重复；所有决定都是设定状态（置顶、标题、归属、合并、降低重要度），重复应用结果不变，Spark 与本地叠加都以它结束。
- Spark 端：问题回答的决定未能应用时，问题记为 `failed` 并保存原因，不再记为 `answered`；同一回答重放返回保存的结果（未应用则 409）。
- 接收只做校验、入库和入队；整理由后台 worker 按 `started_at` 顺序执行，所以 `accepted` 不表示已经整理完成。只有收到 `accepted`/`duplicates` 或 `applied` 才标记已送达；失败按退避重试。
- Mac 保存最后一个 `cursor` 和 `store_id`，增量拉取 `/v1/state`，把结果写入与源记录分开的派生投影。本地决定优先于拉回的状态。

**Spark 重置。**
- `/v1/health` 或 `/v1/state` 返回的 `store_id` 与本机保存的不同（或旧服务的 `cursor` 倒退）时，Mac 视 Spark 为已重置：清空投影与 cursor，从 0 重新拉取，并把之前已送达的每个条目的最新版本重新排队发送。
- 每个决定任务记录做出时对应的 `store_id`。重置时，关于人物的决定（`name_person`、`same_person`，其 ID 在任何库中都相同）按原顺序以普通决定重新发送给新库；关于旧库事件、条目或问题的决定标为 `store_reset`：不再在本地叠加，待发的取消并以“Spark 已重置”列出，用户可放弃。

**故障行为。**
- 以下情况都视为远程整理不可用：隧道未建立或端口不属于自己的 ssh、令牌不可用、`/v1/health` 非 `ok`、超时或 5xx。此时 Mac 继续捕获、落盘、识别、插入和搜索，待发条目在本机累积。
- 链路关闭时，事件页回到本机 `LocalEventOrganizer`（Apple NaturalLanguage 端上 embedding 与词法回退）。链路开启时，事件页只显示 Spark 的整理结果，不再并列本机整理的列表。
- 链路恢复后按会话创建时间补发。远程结果不替换任何用户决定。
- Spark 端服务默认只监听数据目录（0700）里的私有 Unix 套接字，回环 TCP 端口只有显式设置 `ORGANIZER_TCP=1` 才开：TCP 端口在服务停机时可被本机其他用户占用，向它发令牌就等于交出令牌。`spark/ctl.sh`（`curl --unix-socket`，且只在服务运行时检查）、`ops/spark_demo.sh status`（httpx UDS）、`eval/smoke_api.py --uds` 与 `skills/recall/scripts/recall.py --uds` 都只经套接字发送从文件读取的令牌；README 的客户端示例也转发到套接字。
- 远程请求不进入口述热路径：条目在最终稿提交后才入队，发送失败不影响已插入的文字、历史记录或原始音频。

## 2026-09-27 收进来：粘贴与拖入的条目、来源标签与事件导出

依据 PRD §0.3.2、§0.3.5、§0.3.6、§0.3.8。状态：数据层、Spark 待发、导出与投影已实现并有包测试；Home/事件/人物页面重做在后续任务中，本节只加了最小界面挂钩。

**持久化选择：条目是 `userItem` 会话，不是新的条目表。**
- 链路上的 `item_id` 本来就是 SessionID；待发队列、资格、变化 trigger、`event_sessions`、`history_search_fts`、带墓碑的显式删除和 `.bestasrarchive` 都按会话工作。单独建表就要把这些全部复制一遍。
- 映射：正文是一条 `kind=final` 的 `transcript_revisions`（粘贴的文字或本机提取的文字；`model_artifact_id` 为空，`config_hash` = 提取器名的 SHA-256，如 `pdfkit-v1`）。纠正走已有的 `saveUserTranscriptEdit`，生成 `userEdit` 子版本，原文不被覆盖。来源写在 `session_metadata.source_bundle_id`/`source_display_name`，文件名写在 `source_identifier`。原始文件是 `session_source_assets` 的 `userProvidedOriginal`，图片的缩小副本是 `normalizedImage`，两者都带 SHA-256。`dictation_snapshots` 有一行 `phase=completed`、`is_ephemeral=0`，所以历史与整理查询无需改动。
- 迁移 `v22-user-items`（`currentUserVersion = 22`）新增 `user_item_details`（`item_kind` text/image/document、`captured_at`、`source_origin` previousFrontmost/dragSource/finder/user/unknown、`extractor`、页数、原图像素尺寸、两个资产 ID）。它是可移植用户数据：排在 `portableTableOrder` 最后；v12–v21 的归档导入时补一张空表。显式删除先删这一行再删 `sessions`。
- 条目没有音频：`create(_:inputMode:)` 与说话人任务拒绝 `.userItem`；“只删除原音”对条目不可用（原始文件只随整条删除）；原音索引修复与压缩不看条目。

**收进来（`BestASRIntake` 包模块，只用 AppKit、PDFKit、ImageIO、UniformTypeIdentifiers、Vision；不联网、不下载模型）。**
- 入口：主窗口内没有文字输入焦点时按 ⌘V（窗口级按键监视：第一响应者是 `NSText` 时照常粘贴）；菜单“收进来”（⇧⌘V，有输入焦点时也可用）；拖到主窗口任意位置（导入页的拖放区也走同一路由）。
- 按住 ⌘V 的自动重复不再收进来；同一份剪贴板内容（`changeCount` 相同）只收一次。剪贴板带 nspasteboard.org 的 `ConcealedType`/`TransientType`/`AutoGeneratedType`（密码管理器的密码与验证码）时整份拒绝（“剪贴板内容被标记为隐私或临时，未收进来”）。bestASR 自己写入剪贴板的内容（未能插入的口述、指令回答、历史复制、“复制这件事”）都带 `com.bestasr.origin` 标记，⌘V 时拒绝（“这是 bestASR 自己复制的内容，未重复收进来”），不会被当成上一个 App 的新条目再次收进来并排入 Spark。
- 剪贴板读取顺序：文件 URL；然后每个剪贴板项按纯文字、PNG/TIFF/JPEG/HEIC、PDF、RTF、HTML。拖放用同一个纯函数 `IntakeRepresentations.candidate(origin:)`，两条路径不会分叉。纯文字优先于图片/PDF：Word、Pages 等复制文字时会附带渲染图，用户复制的是文字；只有“只是一条链接的文字 + 图片”时取图片。HTML 用 `XMLDocument` 的 tidy 解析（先按 UTF-8/GB18030 等解码），去掉 script/style/head 等，从不使用会加载远程资源的 WebKit 富文本导入。
- 文件：先拒绝不是本机文件的 URL（从浏览器拖来的链接，“只收本机文件，链接未收进来”——媒体导入会联网去取），再拒绝资料库里的文件（见下），再拒绝文件夹、未知类型、符号链接和非普通文件，之后才分类路由（媒体也在这些检查之后）。`.txt/.md` 以及系统声明为文本的其他类型（csv、json、log、yaml、diff/patch、源代码等；图片、RTF、HTML 除外）按 UTF-8、BOM、GB18030、Windows-1252 依次解码；`.rtf/.docx` 用 `NSAttributedString`；`.html` 同上；`.pdf` 用 PDFKit 逐页取文字层，没有文字层的扫描件保存为空文字（标题用文件名，页数与原件照存，导出显示“[扫描件，没有可读的文字层]”），停放不发送（OCR 以后再做），旧版本存成 `[无文字层]` 的行仍按扫描件处理；图片见下；`wav/m4a/mp3/aac/mp4/mov/flac` 进入已有导入管线；其他类型提示“不支持 .xyz，未收进来”。外部文件只读，不移动、不删除。原件上限 200 MB；文字上限 16 MB（`UserItemLimits.maximumStoredTextBytes`），粘贴、拖入的文字和提取出的文字超过时在复制任何文件前拒绝（“文字超过 16 MB，未收进来”）。
- 资料库里的文件永不收进来：`IntakePathPolicy` 按文件身份（`BestASRDataRootSelection.path(_:isWithinOrEqualTo:)`）拒绝位于账户真实资料库或当前数据根之内的文件（包括 `.m4a` 等媒体）；拿不到真实资料库路径时拒绝所有文件。否则一份复制会得到新摘要、通过数据根护栏，开发中的合成数据根就能把真实资料送到 Spark。
- 图片：保留原始字节；另生成缩小副本（长边 ≤2560 px、不放大、应用方向），有透明通道用 PNG，否则 JPEG 0.85，按固定步骤降低质量/尺寸直到 ≤12 MB。副本不复制 EXIF，所以位置等元数据只留在原件里。
- 截图的本机读图：`VisionImageTextReader`（Apple Vision 文字识别，简体中文与英文，在本机运行，不下载模型）读缩小副本，结果作为该条目的派生文字版本写入 `derived_text_revisions`（`model_artifact_id = local-item-reading`，`config_hash` = 读图器名 `vision-text-v1` 的 SHA-256），与条目行在同一事务提交；条目自身的文字仍为空，原件与原文不被覆盖。它进入本机搜索（已有的派生文字索引）、历史列表显示与本机回退整理，并由 `memoryItemRecords` 作为 `localReading` 提供给导出；之后用户改写条目文字不会让它失效。读图失败或没有文字时条目照常保存。读图结果不发送：Spark 用自己的读图技能读图片本身。
- 文件落盘顺序：新建 `sessions/<id>/`（已存在则拒绝）并先写 `.intake-staging` 标记 → 复制到 `source/`、fsync、算 SHA-256 → 提交数据库行 → 删标记。提交失败则删除仍带标记的目录；启动时清理带标记且没有会话行的目录，已提交的只去掉标记。每次收进来都先等启动清理结束（`intakeReady`），清理因此不会删掉正在提交的条目的文件。
- 多个文件或多个剪贴板项各成一条，按输入顺序给出递增的收集时间。音视频按顺序排队，逐个交给导入管线（`startImport` 同时只处理一个）；被拒绝时清空队列并提示原因。这个队列只在本次运行的内存里：提示写明“已开始导入”与“另 N 个等待中（退出 App 会取消等待，需重新拖入）”，不承诺持久排队；用户的文件不受影响。
- 条目提交后立即刷新历史并运行本机回退整理（与录音完成相同）；改来源后也重新整理（本机整理的相似度用到来源 bundle ID）。
- 历史列表每行只带条目文字的前 20,000 个字符（`UserItemLimits.historyPreviewCharacters`，`DictationHistoryItem.textIsPreview` 标明）；详情、复制与单条导出读取完整文字。
- 条目内容永远只是数据：没有任何路径解析或执行条目里的文字；纠正只能从界面发起。

**来源标签。**
- `WorkspaceSourceApplicationTracker` 只在内存里保存 `NSWorkspace` 激活通知中最近一个非 bestASR 的 App（bundle ID、显示名、时间），不写日志。核心是可测试的纯状态 `SourceApplicationTrackerState`。
- 只记录普通 App（`activationPolicy == .regular`）：启动器、密码管理器面板、截图界面等辅助 App 激活时不改变来源。
- 粘贴和“收进来”：用 bestASR 变为活动前的那个普通 App（`previousFrontmost`）。拖放时 bestASR 未激活：当前最前的普通 App 就是拖动来源（`dragSource`；从访达拖文件记为 `finder`）；bestASR 已激活时拖入的文件记为访达（它们来自后台的访达窗口或桌面），其他内容用之前的 App。
- 用户可改来源（历史列表中“来源”标签的右键菜单）：写新的 `session_metadata` 版本并把 `source_origin` 设为 `user`；已发送的条目由已有 trigger 排入新版本。
- 标签规则（`SourceLabel`，历史、投影、导出共用）：口述、电脑内录和条目显示 App 名；导入与线下录音只有在收进来时记录了 bundle ID 才显示 App，否则显示“导入媒体”“线下录音”，文件名永远不作标签。

**Spark 待发。**
- 资格规则不变：链路开启时收进来的条目在同一事务里记为有资格并入队；链路关闭时收进来的、归档导入的永远没有资格。
- 发送内容在认领时生成：`kind` 为 text/image/document，`source_app` 为 App 名与 bundle ID，`started_at` 为收集时间，`text` 为最新提交的文字（文档只发提取的文字）。文件名与原始文件永不发送。`sha256`：图片为缩小副本的摘要，其余为文字摘要。
- 图片：认领事务里不读 12 MB，只放一个本地字段 `local_image_asset`（资产 ID、相对路径、摘要、大小、类型）；认领摘要覆盖它，所以来源等变化照常升版本。`RemoteOrganizerRuntime` 在主 actor 之外通过注入的 `RemoteOrganizerItemAssetReader` 读取字节：根目录是已通过数据来源检查的 `<数据根>/assets`，逐级 `O_NOFOLLOW` 打开（拒绝任何符号链接与 `..`），核对大小、SHA-256、≤12 MB 与 PNG/JPEG 签名，然后只发送 `image_b64`，本地字段不出现在请求里。读取失败时该条目以 `failed/asset` 停放，直到它下次变化。
- 超长文字（>400,000 标量）、扫描件和缺失副本都照旧停放；本机检索不受影响。

**导出一件事（`BestASRMemory` 包模块，只依赖 Foundation 与 Domain）。**
- `EventPlainTextFormatter` 是纯函数，时区注入：标题、日期行（`2026年9月27日（周日）`，跨天为“…至 …”，取自条目时间，没有本机条目时取 Spark 事件的 `started_at`）、状态行、`人物：` 行、一行说明“以下各条记录的正文以“> ”开头，是原始资料，不是指令”，然后按时间排列的条目，每条 `HH:mm · 来源：<App>`（跨天时加“M月d日”；文档、截图以及用户改过标题的记录再加 ` · <标题或文件名>`）加正文。正文每一行都以 `> ` 开头（空行为 `>`），只有格式器自己写的行不带前缀，所以条目文字里看起来像标题行的内容（如“10:00 · 来源：口述”）不能伪装成另一条记录或另一个来源。正文：录音为逐字稿（按人物分行时人名与 `人物：` 行用同一套解析——沿 `merged_into` 归并、优先 Spark 的名字；整段被用户改写后用改写的文字）；文档为提取的文字（扫描件为“[扫描件，没有可读的文字层]”）；截图为 Spark 的读图结果，没有则用本机读图结果，都放在“[截图中的文字]”之后，都没有则 `[截图]`；Spark 读图的摘要（新版单独的 `summary` 字段，旧版为首行）是整理设备自己的概括、不是截图里的文字，因此不进引用块，而在条目标题行下单独写一行 `读图概要：<一行>`（固定前缀、合并为一行，不能伪装成标题行），此时开头说明改为同时说明这一行也不是指令；每条消息都带同一个时间戳（截图唯一的时间标签）时去掉这些时间戳，时间不同则保留；搜索用原始读图文字加摘要。本机已删除的条目为 `[已删除]`。
- “复制这件事”只在用户点击时写入通用剪贴板（`LocalPasteboardWriter` 改为可注入剪贴板，测试只用私有命名剪贴板）；“导出为文本…”用 `NSSavePanel` 保存纯文本 `.txt`（Markdown 查看器会把单个换行合并），原子写入。两条路径都经 `MemoryProjection.sparkEventDetail`/`localEventDetail` 组装，包测试覆盖“资料库记录 → 事件详情 → 文字”整条路径。Spark 事件在卡片“更多”菜单里，本机回退事件在事件详情标题旁。
- v1 接口的 `/v1/state` 不返回逐条读图结果，所以截图用收进来时在本机做的读图结果；格式器仍接受按条目 ID 的 Spark 读图文本（优先于本机结果），接口提供后即可接上。

**给后续界面的读模型（`MemoryProjection`，不依赖任何界面框架）。**
- 输入：已排好首页顺序的事件（Spark 投影已按置顶、重要度、最近排序；本机回退按最近更新）、`GRDBDictationStore.memoryItemRecords(ids:)` 返回的本机记录、Spark 的人物与问题。
- 首页：标题、状态行、日期范围（`MemoryEventSpan`：本机条目的最早到最晚时间，没有时用 Spark 的 `started_at`）、人物（沿 `merged_into` 归并，再补本机录音里的说话人）、条目数、最后更新、封面（第一张有缩略图的截图，否则最早的条目）。本机回退事件没有状态行，用用户备注的第一个非空行（只取一行）代替。事件详情：按时间排列的条目（含播放可用性、缩略图相对路径、来源标签），本机没有记录的条目排在最后，以及该事件的待确认问题。人物：每个主人物及其事件和待确认问题。
- App 通过 `loadMemoryProjection()` 取得，链路开启且有投影时用 Spark 的事件，否则用本机回退。

## 2026-09-27 记忆页（首页、事件、人物、未归入）与整理设备接口更新

依据 PRD §0.3.5–§0.3.8。状态：已实现并有包测试与快照；未在安装版中验收。

**接口更新（整理设备 organizer-quality，全部为新增字段）。**
- 条目的 `started_at` 带本机 UTC 偏移（`GRDBDictationStore(remoteItemTimeZone:)`，默认 `.autoupdatingCurrent`，长时间运行时跟随时区变化）；只有之后变化的条目会以新版本发出，不会因此自动重发。
- 决定新增 `unfile_item{item_id}` 与 `file_item_new_event{item_id, new_event_id?}`；`new_event_id` 由 Mac 生成（小写 UUID），本地叠加与整理设备用同一个 ID。`move_item` 也可把未归入的条目放进事件。
- `/v1/state` 的 `unfiled[]` 是每次拉取的完整集合：存在 `remote_organizer_meta.unfiled_json`（无迁移），每次拉取整体替换，旧服务缺省视为空，`store_id` 变化时清空。本地叠加：`remove_item` 与“条目已在 b 中”的 `same_event` 否定答案把条目放进未归入（`removed_by_user`）；`unfile_item` 把条目移出所有事件（`user`）；`file_item_new_event` 在整理设备返回同 ID 事件前显示一个以条目首行为标题的临时事件；`move_item` 与肯定答案把条目移出未归入；最后任何仍在事件中的条目都不算未归入。放置类决定（`move_item`、`file_item_new_event`、条目形态 `same_event` 的肯定答案）只在它是该条目的最后一个位置决定时重放；之后若有 `remove_item`/`unfile_item`/否定答案，以拉取到的位置为准，不把条目拖回旧事件。被用户纠正清空的事件不再显示（整理设备随后会撤掉它）。
- `/v1/state` 可附加 `readings`（按条目 ID 的对象，或带 `item_id` 的列表；每项含整数 `revision` 与 `text`，也接受 `derived_text`/`reading`）：整理设备对截图等条目读出的文字及其所读的条目修订号。字段缺失、整体或单项格式不对时忽略，不让整次拉取失败。Mac 把它合并进 `remote_organizer_meta.readings_json`（无迁移；每个条目保留修订号最高的一条，只收本机已送达且仍在的条目），只在其修订号等于该条目最近一次送达的修订号时交给读模型；显式删除条目时一并删掉，`store_id` 变化时清空。事件页的条目行与“复制为文本/导出为文本”据此显示 `[截图中的文字]`。每项还可带 `summary`（整理设备自己的一行概要，不是截图里的文字；`""` 或 `null` 表示没有）：带了这个字段时 `text` 只有读出的文字（每条消息一行 `发送者：内容`，各条时间不同时才带 `[时:分] ` 前缀），摘要按一行保存在同一条读图记录里，经读模型的 `readingSummaries` 交给条目行、导出与搜索；`text` 为空但有摘要也算一条读图。旧版 Spark 不发 `summary`，其 `text` 是一行摘要再加每条消息一行 `[时:分] 发送者：内容`（时间前可带日期），此时首行（两行以上且不带时间戳时）当作摘要；条目行对截图不显示摘要、去掉重复的时间戳后按发言轮次显示（展开时摘要单独显示为“读图概要：…”），其余字段（`source`/`messages`/`run_id`）不解码。粘贴的文字或读图只有一行“名字：内容”且名字是该事件的人物时也按一个发言轮次显示。
- 事件新增 `handle`、`anchor`；`status_facts[]` 新增 `state`（planned/in_progress/done/cancelled/info）、`date`、`quote`，均按可选解码。`/v1/health` 的 `clock` 不是 `wall` 时，设置页显示“整理设备在测试配置下运行”。
- `MemoryProjection` 按 a、b 判断 `same_event` 的三种形态（条目进事件、条目留在事件、两事件合并），问题提出 72 小时后不再显示（注入的 `now`），并提供按天分组、状态事实、相关事件、未归入条目、人物颜色与“名字或 ?”。人物颜色默认是人物 ID 的 FNV-1a 取模 6；首页人物行前 6 个有名字的人按首次出现先后分配，各自优先用自己 ID 的颜色，已被更早出现的人占用时顺延到下一个空闲颜色，保证可见的人不撞色；其余人保持 ID 颜色；事件卡、人物页与发言轮次用同一结果，输入相同则结果相同。首页卡片没有截图时用最新一条粘贴文字/文档（没有则任一有文字的条目）的来源与前几行做文字封面；截图封面从顶部裁切，若画框底边落在截图内，则在画框下部 40% 内找最低的一段无文字横带（按灰度跳变次数与间距判断）结束裁切并把该行向下延伸，找不到则底部 22% 渐隐，不缩小截图。

**界面模块 `BestASRMemoryUI`（只依赖 SwiftUI、AppKit、`BestASRMemory`、`BestASRDomain`）。**
- 页面只读值状态 `MemoryScreenState`，纠正通过 `MemoryActions` 回调；App 的 `MemoryScreenModel` 从现有模型组装状态，`DictationAppModel+Memory` 把回调路由到整理设备决定（`MemoryDecisions`）或本机事件/人物接口。
- 主窗口：212 pt 侧栏（首页、人物、词典、正在记录、设置）与一个详情列，事件、人物、未归入与录制页压栈显示；人物页不论从哪里打开都高亮“人物”。首页的“全部”沿用原历史列表与详情（其可见文案也遵守文案规则，由源码扫描测试检查）。只有卡片到事件的变形有动画（0.35 s 弹簧：首页淡出、事件页从上方放大淡入、标题滑入页眉）；减少动态效果时不做 `matchedGeometryEffect`，只淡入淡出。
- 卡片、条目行和改名可用键盘（Tab、Return/空格）与旁白操作；条目纠正（这不是这件事的、移到…、单独成一件事、播放）也是旁白动作；移到…/放进… 打开可搜索的全部事件列表。强调色上的文字用 `onAccent`（浅色为白，深色为 #1E1E1E）。
- 本机用户（`localSelfPersonID`，或名字为 我/自己/本人 的人）不算事件的人物：不进首页人物行、卡片头像、人物标签与相关事件，逐字稿里用中性色。首页搜索也匹配条目文字与截图读出的文字。条目问题在首页显示条目的来源、时间与播放按钮；本机问题按整理设备的句式点名条目（“这条「…」和「…」是同一件事吗？”）。首页在第一次加载完成前不画空状态；有未归入而无事件时不显示“没有找到”。整理设备未接受的修改在首页列出，带重试/放弃（可能已送达的只能确认送达）。
- 人物页“这段声音是…吗？”与“听一段声音”只播放那个人的那一段（`MemoryItemRecord.Segment` 新增单调时钟起止，`PlaybackModel.stopAt` 到点暂停）。
- 链路关闭时首页外观不变：状态行取备注首行；没有写好的状态行时卡片不显示条目摘录，改在日期后显示条数，事件页也不重复它；问题来自本机候选；未归入为近 14 天未入事件的条目与录音，取自事件记忆加载的不筛选全集（最多 5000 条）加当前历史页，而不是“全部”当前筛选的 60 条；置顶与“少推荐这类”隐藏。本机“移到…”从用户所在的事件页移出。
- 文案集中在 `ZhijiCopy`，测试禁止 “AI、本地、模型、Spark、GPU、加密、说话人、未命名” 与感叹号；没有名字的人显示 “?”。
- 快照：`MemorySnapshotTests` 用 `ImageRenderer` 渲染真实页面（合成数据），`BESTASR_UI_SNAPSHOT_DIR` 未设置时跳过；快照模式下由 AppKit 绘制的输入框、滚动视图与下拉菜单以静态外观代替。
- 端到端（选择性开启）：`BestASRSparkEndToEndTests` 只在设置 `BESTASR_E2E_SPARK_HOST`、`BESTASR_E2E_SPARK_SOCKET_PATH`、`BESTASR_E2E_SPARK_TOKEN_PATH` 时运行。它用 `script/make_synthetic_data_root.sh` 在临时目录建新的合成数据根，经真实的剪贴板读取、`IntakeProcessor`、`createUserItem` 收进 14 条虚构的一周资料（聊天文字、两张聊天截图、一份带文字层的 PDF、备忘），打开受保护链路直到整理设备处理完每一条，再用真实投影构建首页/事件/人物/未归入页面快照（浅色与深色）和前两件事的导出文本，写出不含条目正文的 JSON 摘要（`BESTASR_E2E_OUTPUT_DIR`），最后关闭链路并核对待发队列已清空。截图不在 Mac 上读字（不做本机推理），由整理设备读。

## 2026-09-28 会议转写、拆分条目、手机入口与规模（Mac 侧）

依据 PRD §0.3（黑客松范围）与整理设备接口的新增约定。状态：包测试、快照与 App Debug 构建通过；整理设备侧（item-split、`/v1/inbox`、并发）由服务分支实现，端到端尚未与之联跑。全部为新增字段，旧服务照常工作。

**会议转写文本（两端同一规则，`MemoryTranscriptText`）。** 粘贴或拖入的文字/文档若是会议 App 导出的转写，按发言轮次读：腾讯会议 `名字(HH:MM:SS):` 行（半角或全角括号与冒号，冒号可省）后接发言段；飞书 `名字 HH:MM:SS` 行后接发言段（普通笔记也可能这样写，所以要求至少三轮或有人发言两次）；Zoom `[HH:MM:SS] 名字: 内容` 每行一轮，续行并入上一轮；WebVTT/SRT 的 cue（`<v 名字>` 或 `名字: `），同一人连续的 cue 合为一轮。名字可为“中文名 English NAME”，不能含句读。第一个标题行之前的内容不属于任何一轮；至少两轮有字才算转写；多种格式都成立时取轮次最多者。每轮的 `start`/`end` 是 Unicode 标量偏移（与整理设备 Python 的字符下标一致，`\r\n` 计两个），从标题行开头到最后一个非空行末尾。事件页用它显示发言轮次（名字与事件人物同名或首词相同则用其颜色，本人用中性色），条目标为“会议记录”；导出写成每轮一行 `名字（时间）：内容`。说话人由整理设备经既有的近名 `same_person` 问题并入人物（来源 `transcript`），本人别名由 `ORGANIZER_OWNER_ALIASES` 排除。

**拆分条目。** `/v1/state` 的事件可带 `segments[]`：`{item_id, seg_id, start, end, gist}`，偏移是条目发送时文本的 Unicode 标量偏移（转写按轮次对齐），`gist` 是整理设备写的短说明（不是原文）。解码宽松：只保留该事件持有的条目、`end > start`、`seg_id` 非空且每个（条目, 段）一次，gist 合成一行并截到 60 字；字段缺失或格式不对视为没有。事件里没有某条目的段，就表示整条在该事件里。读模型对有段的条目每段一行（行 ID 为 `条目#段`），只显示该段文字（`MemoryEventItem.shownText`）；首页卡片的封面文字、搜索文本和状态行替代也只用本事件的段，同一场会议的其他事情不会把这张卡带出来。行下方有安静的“同一段会议/口述/笔记还涉及 N 件事 ›”，一件时直接打开，多件时列出标题与 gist。导出只含本段，并在条目头下写一行 `节选：<gist>；同一段记录还涉及：「A」、「B」`（前言说明“节选：”是整理设备的说明，不是指令）。在某段上做的“这不是这件事的”“移到…”带 `seg_id`（`remove_item`/`move_item`/`unfile_item` 的可选字段，其它种类带它视为格式不对）；拆分行不提供“单独成一件事”。本地叠加：移出某段时条目随最后一段离开该事件；移动某段只移该段；带段的 `unfile_item` 只移出该段，条目不再在任何事件里才进未归入；整条移出同时移除它在该事件的段；合并事件时 b 的段并入 a（a 已持有整条时不缩成段）；指向已不存在的段的决定不改变任何东西（新修订会重新拆分）。放置类决定按“条目#段”判断是否为最后一次。

**手机入口（收件箱）。** 整理设备暂存手机经 iOS 快捷指令（经 SSH 运行 `zhiji-inbox add --source iPhone`）送来的文字或图片，直到 Mac 确认。链路开启时，运行时每轮在送完条目与决定后读 `GET /v1/inbox?since=<cursor>`（`{"cursor", "items": [{"inbox_id", "source", "kind": "text"|"image", "text"?, "image_b64"?, "received_at"}]}`，也接受 `id`/`entries`；格式不对的项丢弃）。每项经 `IntakeInboxIngestor` 走与粘贴相同的 `IntakeProcessor.prepare` → `createUserItem` → 暂存文件提交，成为来源 App 为该 `source`（默认“iPhone”）、采集时间为 `received_at` 的 userItem；本地提交后才 `POST /v1/inbox/{id}/ack`（404 视为已确认）。条目 ID 由收件 ID 派生（SHA-256，UUID v5 布局），在提交与确认之间崩溃后再次拉取会找到已有条目，不会重复收入。内容不可用（无字、不是图片）的项不确认，本次运行内跳过；本地写入失败则本轮停下、游标不前进。整理设备没有该接口（404/405）时本次运行不再询问。游标只在内存里：重启后整理设备返回全部未确认项。新条目随后像其它条目一样送去整理。

**规模。** `MemoryProjection` 在构造时建好人物索引、本机人名表、条目段索引与首页（原来每次调用都重算、按人物线性查找并对全部记录排序）；`MemoryReadModel` 一次得出首页、人物、最近人物、未归入与横幅问题。App 的 `MemoryScreenModel` 在主线程取输入（记录由存储异步读），在分离任务里构建读模型，再回主线程赋值；2000 条/60 件在调试构建下约 30 ms（`testReadModelFor2000ItemsAnd60Events`）。首页仍是按排序的卡片网格，先显示 24 张，“显示更多”每次再加 24（搜索时显示全部匹配）；人物行显示最近的 8 人，其后“全部人物 ›”打开人物页；事件页每天的条目与未归入页用 `LazyVStack`。

**端到端场景目录。** `ScenarioEndToEndTests` 在设置 `BESTASR_E2E_SCENARIO_DIR`（加上整理设备三项变量）时运行，此时原合成一周测试跳过。它读 `scenario.json`（`items[]` 的 `ref/t/kind/format/source_app/text/segments/event_segments/image/filename/file/asset/events`，以及 `people[]`）与 `assets/`，按时间顺序、以 `BESTASR_E2E_PACE_SECONDS` 的间隔经真实收入：文字按来源 App 粘贴（口述没有音频，也按文字粘贴；`chat_paste`、`email` 等 `format` 不改变种类）；转写（`kind` 为 transcript、会议导出格式如 `tencent_transcript`/`feishu_transcript`/`zoom_vtt`/`zoom_txt`、`.vtt`/`.srt` 文件）与 `meeting_*` 的分段（写成腾讯会议导出格式）作为文件拖入；截图用附带图片或按 `image.messages` 绘制后粘贴；文档拖入附带的文件，没有文件时 `.txt`/`.md` 按该文本文件拖入，其它生成带文字层的 PDF（扩展名改为 .pdf）。`BESTASR_E2E_LIMIT` 只取前 N 条。等待阶段另开一条与链路同样方式建立的转发（令牌只在内存），每 `BESTASR_E2E_PROBE_SECONDS`（默认 10 秒）读 `/v1/health` 与 `/v1/debug/jobs`：只有本机把每条都送出、整理设备报告每条已送条目的最新修订都已结束（done/failed/superseded）且队列为 0、每条都已放进事件或未归入、页面再静止 `BESTASR_E2E_QUIET_SECONDS`（默认 40 秒）后才结束；整理设备连续 5 次问不到时退回只等静止并记入错误；总时长受 `BESTASR_E2E_TIMEOUT_SECONDS`（默认 1800 秒）限制。之后渲染首页、前 3 件事、一件含拆分转写的事（展开各段）、一个人物页与未归入（浅色/深色），导出前 3 件事；`BESTASR_E2E_RENDER_EVENTS`（逗号分隔的场景真值事件）把每个真值事件对应到持有其多数条目的整理事件（拆分条目按场景给出的各段引文与整理段的重叠计票，找不到引文时平分，平票取首页排名靠前者），渲染该事件页为 `threads/thread-<id>-{light,dark}.png`（高 `BESTASR_E2E_THREAD_HEIGHT`，默认 1600），持有拆分段时再渲染展开一段的 `thread-<id>-part-*.png`，并把与“复制为文本”相同的文本写到 `threads/export-<id>.md`。`scenario-summary.json` 记录条数、按场景种类/收入方式/来源的计数、多于一段的条目数、正文总字数、从首条粘贴到最后一条归入的时长与每分钟条数、粘贴到归入延迟 P50/P90、出现过的问题数与结束时的未答问题数、未归入数、整理事件数、整理设备的任务状态计数与排队到完成的 P50/P90、真值事件的对应（排名、份额、持有事件数、文件名）；不含正文。设置 `BESTASR_E2E_WORK_DIR` 时合成数据根与 `ledger.jsonl`（只记 ref、本机条目 ID 与时间）保留在该目录，重跑时只收入尚未收入的条目，已在整理设备上的条目不再重复发送（链路未撤销的中断运行保留全部；正常结束撤销后只保留已送达的，其余重新收入）。最后撤销链路并核对。并行多跑时直接用 `xcrun xctest` 运行测试包（`swift test --skip-build` 会等待同一构建目录的锁）。

## 2026-09-28 所有文件类型（Mac 侧，`claude/files`）

依据 PRD §0.3.2（收进来）与 §0.3（只把文档类内容送到用户自己的 Spark，音频永不离开 Mac）。状态：Mac 侧已实现并有包测试与界面快照；整理设备读文件的一侧在服务分支上按同一合同实现。

**收进来的路由（`IntakeFileClass` + `IntakeProcessor`，都在本机、无模型、不联网）。**
- 本机能读全的仍是 `document`（只发文字）：txt/md/日志/源代码/JSON/YAML/XML、RTF、HTML、`.webarchive`（只读存档 plist 里主页面的 HTML，经 `XMLDocument` 去掉 script）、`.webloc`/`.url`（只取保存的地址，从不打开）、每页都有文字层的 PDF。
- 新条目类型 `file`：原文件逐字节保存，本机能读出的文字作为 `local_text`（可以为空）。docx/odt/doc 用 `NSAttributedString` 读文字（`docx|odt|doc-attributed-v1`）但仍以文件发送，让整理设备读表格和内嵌图片；csv/tsv/ics/vcf/eml/mbox/msg 的文字作为本机文字；有扫描页或需要密码的 PDF、xlsx/xls/ods、pptx/ppt/odp、epub、zip、Pages/Numbers/Keynote 和任何未知类型都作为文件。Pages/Numbers/Keynote 若是文件夹形式的包，取包内自带的 `QuickLook/Preview.pdf`（或 `preview.jpg`）作为文件，命名为 `<名>.<扩展名>-preview.pdf`。其他文件夹仍拒绝。
- 图片：png/jpg/heic/heif/webp/gif/tiff/bmp 统一规范化为 ≤2560 px 的 PNG/JPEG。SVG 只有在不引用任何外部资源（无外部 href/src/url()、无 `@import`、无实体声明）时才在本机绘制，否则作为文件发送源码。GIF 在第一帧之外，最多再取 3 个“明显不同”的帧（16×16 灰度图平均差 > 0.06），存为 `animationFrame1…3` 资产。
- 音频（m4a/mp3/wav/aac/flac/ogg/opus/amr/caf/aiff）与视频（mp4/mov/m4v/mkv/webm）走原有导入管线；先用 `AVURLAsset.audiovisualTypes()` 判断这台 Mac 能否解码，不能（如本机的 mkv/webm）就当场拒绝并说明。视频在保留原文件后，用 `VideoKeyframeExtractor` 取关键帧：每秒（长视频按最多 240 次采样）取一帧缩成 16×16 灰度，与上一帧差 > 0.12 视为换场；保留第一帧与相隔 ≥2 s 的换场（过近时取变化更大的），超过 12 张时保留变化最大的，按时间顺序存为 `image` 条目，`parent_session_id` = 录音会话，`frame_ms` = 位置。音轨仍只在本机转写。
- 大小：原文件 >200 MB 在复制前拒绝（不变）。≤25 MiB 的文件随条目发送字节；更大的文件若本机读出了文字，就以 `kind: "text"` 发送这些文字和文件信息，否则不发送，页面写明“超过 25 MB，只留在这台 Mac”。

**持久化：迁移 `v23-user-item-files`（`currentUserVersion = 23`）。** SQLite 不能放宽 CHECK，所以重建 `user_item_details`：`item_kind` 增加 `file`，末尾新增 `uniform_type`、`parent_session_id`（无外键，删除录音不会因关键帧失败）、`frame_ms`，原有行逐行复制，并加 `parent_session_id` 的部分索引。可移植归档：v22 归档导入时在这三列补 NULL（v12–v21 先补空表再补列）。`session_source_assets.kind` 新增 `animationFrame1…3`。`memoryItemRecords` 给出文件的 UTI、媒体类型、大小，关键帧的父录音与位置，以及录音的关键帧列表；缩略图优先取 `normalized_asset_id` 指向的那一张。

**发送合同（增量、向后兼容，旧服务忽略未知字段）。** 文件条目：`{kind:"file", filename, uti, mime, size, sha256(文件), bytes_b64, local_text?, captured_at, source_app, …}`；字节在发送时由 `RemoteOrganizerItemAssetReader.fileData` 按与图片相同的路径/链接/大小/摘要校验读取（上限 25 MiB），本地引用 `local_file_asset` 永不发送。关键帧：`kind:"image"` 加 `parent_item_id`、`frame_ms`。GIF：`image_b64` 之外加 `extra_images_b64`（最多 3 张，PNG/JPEG），它们的摘要参与条目摘要。上传超时按正文大小放宽（30 s + 每 500 KB 1 s，会话资源上限 180 s）。

**读回。** `readings[item_id]` 的 `type`（text|document|spreadsheet|slides|pdf|scanned_pdf|email|calendar|contact|ebook|archive|web|code|data|image）、`fields`、`counts`、`attachments`、`error`（encrypted|unsupported|too_large|corrupt）、`source` 逐项宽松解码，未知值丢弃，保存在 `RemoteOrganizerItemReading.facts`；只有 error 的读取也保留。读取正文上限提高到 60,000 字。投影把它们作为 `readingFacts` 交给记忆页。

**记忆页与导出。** 文件行：按读取类型（没有时按扩展名）选图标和“表格/邮件/…”标签；显示文件名、大小与计数、整理设备的概要；展开后显示关键字段（发件人、日程时间、联系人等）、读到的正文（表格按 Markdown 表绘制，默认 8 行，“展开全文”）和内含文件/附件；无法读取、超过 25 MB 或尚未读取时说明原因。录音行下显示关键帧条；关键帧只在其录音不在同一列表时才单独成行。事件导出：文件先写“文件：表格 · 47 KB · 2 个工作表”和“文件概要：…”两行格式化器自己的说明，读到的字段、正文与附件全部以“> ”引用；录音后附“[视频画面 N 张：0:00、…]”。

## 2026-09-22 交互查询边界修正

历史列表查询与首页统计、来源全集、旧音频补索引分开调度。筛选只读取有界的当前页；列表与分页请求持有可取消任务及相同查询身份，取消与版本校验共同阻止旧结果覆盖或混入。库内容变更更新概览，启动/显式刷新执行维护，维护不占用首屏发布的等待链。

阶段候选在 SQL 分页之前筛选，界面再做需要运行时状态的精化；分页游标按实际读取候选推进。异步打开记录必须等待当前查询成功发布，不能在防抖或失败时打开旧列表。App 替换与运行时缓存迁移分别执行，替换不隐式修改用户缓存链接。

历史筛选使用当前条件摘要和页内侧栏，不在默认首屏展开所有选择、不使用弹出菜单。词典页拥有自身选择/编辑状态并直接观察词典模型，未选/单选/多选复用同一工具栏尺寸，不能靠插入条件视图推移内容。扩展能力使用明确导航入口；入口调整不代表其用户旅程已验收。以上优先于下文冲突的旧布局描述。

无语音判定不构成删除原音的授权。自动清理仅作用于已验证没有已提交、暂存、隔离或其他来源资产的空录音；缺失或损坏日志、检查失败以及曾经隔离的音频都保留恢复入口。仅清理实际成功的记录才从启动恢复列表移除。

## 1. 结论与就绪边界

现有领域、持久化和捕获基础可以继续使用，但当前安装候选尚未达到产品可用门槛。V1.5 的主缺口不是继续增加页面或协议，而是把既有能力投影为连续用户任务，并在同一真实语料上重新冻结分层推理组合。任何“实现存在”状态都必须与正式安装包的端到端产品验收分开记录。

| 门槛 | 当前判断 | 进入下一阶段的条件 |
|---|---|---|
| 产品边界 | 通过 | 16 GB、原始音频永久保留、三类数据出口、四入口统一人物语义与口述优先 MVP 边界已冻结 |
| 架构边界 | 通过 | 模块、数据语义、失败恢复与未来同步边界已定义 |
| 捕获可行性 | conditional | Process Tap 已解锁实机矩阵 8/8 通过，包括 selected/nonselected、helper、重启、静音、真实 HDMI 输出切换与恢复、真实 TCC 拒绝和 HAL 零泄漏；2 小时合成双轨耐久及安装版 selected-App + 麦克风同采也通过。综合音频裁决仍因 Zoom、真实会议生命周期、采样率/输入设备变化和 16 GB 资源门禁保持 conditional。 |
| 模型可用性 | conditional | 三套固定版本 ASR runtime/model 已在 48 GB 推荐内存机器完成断网真实音频冒烟；仍须完成 16 GB、完整 ASR release corpus、说话人/声纹与热/长会话矩阵 |
| 隐私与存储 | 待实测 | 加密数据库/资产、密钥恢复、搜索性能和删除语义 Spike 通过 |
| 构建与发布 | conditional | Xcode 27.0 的预检、Debug/Release 构建、160 项 App 测试、严格签名校验、包清单校验和本地 DMG 烟测已通过；`script/check.sh` 仍被既有 Swift 格式问题阻断，Developer ID 签名与公证尚未完成。详见 `IMPLEMENTATION_STATUS.md`。 |

因此，下一步应先完成 [SPIKE_PLAN.md](../spikes/SPIKE_PLAN.md)，再依据证据冻结依赖与实现 ADR。

## 2. 架构驱动因素

1. 录音不能因 ASR、说话人或 LLM 变慢而丢失。
2. 指定 App 系统音频、麦克风和派生混音必须保持来源边界与统一时间轴。
3. 口述、线下录音、系统音频和导入媒体都使用同一套会话说话人、出现记录与全局人物管线；来源只影响捕获和计算调度，不能改变人物实体、匹配空间、置信语义或纠错行为。
4. 流式草稿、句末结果、最终逐字稿和润色/摘要都是不同修订，不能互相覆盖证据。
5. 具体模型必须可替换，并由本地基准选择，不能渗透到领域层。
6. V1 完全本地且无账号；持久化模型必须能在未来增加历史迁移与 iPhone↔Mac 同步。
7. 人物误合并比暂时不识别更危险；所有自动归属必须可解释、可撤销、可重建。
8. 所有模式的原始音频默认永久保留；离线完整迁移、单条音频导出与未来云同步必须是不同协议。
9. 人物、事件、时间和来源是同一份音频证据上的四个可交叉检索维度；事件模型输出必须可追溯、可撤销，不能成为新的 source of truth。

MVP 先交付口述用户闭环，但不是独立架构分支。首个可运行切片即使用 V1 的 `SessionDomain`、`AudioJournal`、版本化修订、`SpeakerCore`、`Person`/`SpeakerOccurrence`、持久化仓库、durable jobs、模型 artifact 和未来 `SyncAdapter` 边界；后续开放线下录音、系统音频与导入界面时只增加来源适配器和流程编排，不替换核心领域或数据结构。

## 3. 总体架构

```mermaid
flowchart LR
    UI["SwiftUI / AppKit UI"] --> Session["SessionCoordinator\n状态机与命令"]
    Hotkey["全局快捷键与 AX 插入"] --> Session
    Session --> Capture["CaptureEngine\n麦克风 / Process Tap / 文件"]
    Capture --> Journal["AudioJournal\n分轨、单调时间、增量落盘"]
    Journal --> Jobs["DurableJobQueue"]
    Jobs --> Worker["InferenceWorker\nASR / VAD / Diarization / LLM"]
    Worker --> Store["Repository / SQLite / FTS5"]
    Store --> Memory["MemoryGraph\n人物 / 事件 / 时间 / 来源"]
    Journal --> Store
    Store --> UI
    Store --> Export["Export / Backup Bundle"]
    Store -. "未来、显式启用" .-> Sync["SyncAdapter\nCKSyncEngine 或产品后端"]
    Models["ModelManager\n清单、校验、回滚"] --> Worker
```

### 3.1 目标模块

| 模块 | 职责 | 不得承担 |
|---|---|---|
| `AppShell` | 菜单栏、窗口、导航、设置、权限状态 | 音频处理、数据库 SQL、模型 SDK 调用 |
| `SessionDomain` | 会话状态机、命令、事件、暂停/结束/取消语义 | UI 控件和具体音频 API |
| `AudioCore` | 设备发现、麦克风、Process Tap、重采样、时间轴 | ASR、说话人身份判断 |
| `AudioJournal` | 分轨块、清单、校验、恢复、最终封装 | 长期业务查询 |
| `SpeechCore` | 流式/句末/最终 ASR 接口和修订合并 | 具体供应商类型泄漏到领域层 |
| `SpeakerCore` | VAD、会话内分段、嵌入、全局人物匹配 | 将声纹作为安全认证 |
| `TextIntelligence` | 润色、摘要、章节、结论、待办与引用 | 修改源逐字稿 |
| `MemoryCore` | 事件候选、事件操作、人物/事件/会话关系和本地语义检索 | 覆盖逐字稿、猜测人物或强制合并事件 |
| `Persistence` | 事务、迁移、FTS、作业队列、审计历史 | 网络同步策略 |
| `Insertion` | AX 目标验证、安全插入与剪贴板兜底 | 自动发送消息 |
| `ModelManager` | 设备档位、下载、摘要校验、许可、回滚 | 根据厂商宣传直接选默认模型 |
| `SyncCore` | 稳定变更模型与未来同步协议 | 让 V1 本地读写依赖网络 |
| `BenchCLI` | 可重复的捕获、模型、恢复和性能基准 | 产品 UI 逻辑 |

建议把纯领域模块和基准工具放进本地 Swift Packages；macOS App、XPC Service、UI Tests、签名与资源保留在 Xcode workspace。所有 target 使用 Swift 6 严格并发检查。

### 3.2 任务型产品投影

领域模型继续保持 `Session`、`TranscriptRevision`、`Person`、`Event` 和 durable job 的严格边界；UI 不直接投影这些表或作业，而由只读 presentation stores 形成五个用户任务：

| 用户任务 | UI 投影 | 领域写入入口 |
|---|---|---|
| 立即记录 | 菜单栏、非激活口述条、今天页主入口 | `SessionCommand` |
| 看懂当前进度 | 统一记录工作区、来源/电平/计时/实时稿/人物暂定状态 | `SessionSnapshot` / revision stream |
| 找回事实 | 资料库列表、混合搜索、固定播放器、同步逐字稿 | 查询 repository + playback coordinator |
| 修正记忆 | 逐字稿内联纠错、说话人修正、人物/事件候选确认与撤销 | 版本化 correction/operation command |
| 使用结果 | 复制、来源引用、整理、导出与迁移 | 派生文档和 export protocols |

`AppShell` 必须拆分主窗口导航、菜单栏、非激活口述 panel 和独立设置 scene。悬浮条不得成为 key window，不持有文本输入控件，不直接读写数据库；它只订阅有界 `CapturePresentationState` 并发送开始、暂停、结束、取消命令。资料库详情用单一 `RecordWorkspacePresentation` 聚合播放器、逐字稿、人物、事件、来源和派生文档，避免每个能力各自维护选择状态和加载流程。完成/需处理 handoff 只引用仍存在的 session；显式删除对应资料库记录后必须同时清除 handoff 并恢复首页入口，异步打开时发现记录已不存在也不得保留死链接。

资料库的主任务是阅读与回放，不重复堆叠导航栏标题、页面大标题和说明。搜索、常用筛选与刷新使用同一紧凑行；人物/事件/来源筛选渐进展开并在应用后收起。列表宽度有界，固定播放器下面的正文滚动区在普通最小窗口中仍应保留有效阅读高度；此布局同时覆盖逐字稿、整理、人物关系和来源页，不移动播放器或改动音频/文档选择状态。

本轮资料库修正的 P0 合同：默认阅读标题，主动重命名才进入编辑；保存有即时状态，失败保留草稿，切换记录不应用旧回调。人物、资料库与事件共享基于身份创建时间的待命名显示名称，不因再次出现而改名；名称不是身份键，同名、含逗号或同一时刻创建的人物仍按完整 ID 分别保留。会话内使用简短 A/B/C 标签并明确候选状态。普通搜索不匹配人物内部 UUID；修正仅重建可再生全文索引，不改写源记录、声纹或人物关系。验收覆盖真实 SQLite 查询、重命名保存/失败以及正式安装版的阅读与人物操作。

原音时长修正的 P0 合同：四种入口均从已提交源块登记 `tracks/audio_chunks`，不依赖 ASR 成功、语音长度或录音墙钟时间。密封/恢复边界事务性补齐元数据，重复同步不得覆盖既有来源证据；既有记录只补索引，不改原音、会话修订或用户内容。时长按源块时间区间并集计算，排除暂停和缺口，同时录制的音轨不重复计时，换设备产生的接续音轨也不能漏算。资料库、首页统计和时长筛选使用同一结果，未知时长不冒充短录音。逐字稿定位只显示已执行的定位动作，持续播放/暂停/完成状态由固定播放器负责。

Finder「打开方式」通过已有主窗口的 external-event preference 接收导入 URL，不能再创建一份共享同一 capture/selection 状态的主窗口。文件选择使用当前主窗口的非阻塞 sheet，同一时刻只允许一份导入选择器；取消不创建记录。没有可用主窗口时才使用独立的异步 panel。

## 4. 进程、并发与资源所有权

### 4.1 进程边界

- **主 App 进程**：UI、权限、会话状态机、音频捕获、AudioJournal 和持久化提交。录音持久性不能依赖推理进程存活。
- **InferenceWorker XPC 候选**：ASR、说话人和本地 LLM。模型崩溃或内存压力退出后，主进程继续落盘，重启 worker 后从持久化作业继续。
- `SPIKE-XPC-001` 的版本协商、取消/超时、强制退出/重启、重放与幂等矩阵为 pass；同进程 actor / XPC 的 32 MiB 相同 workload 比较四项均通过，但因尚未覆盖真实模型、16 GB 压力、Developer ID 与公证，`ADR-0001` 对 XPC 的结论保持 Conditional。
- 在上述发布门槛通过前不得把 XPC 标为冻结。若门槛失败，scheduler adapter 回退到同进程 actor；`InferenceService` 协议、持久化作业、取消/超时与幂等结果语义保持不变。

### 4.2 Actor 所有权

- `SessionActor` 是会话状态的唯一写入者。
- 每条采集流由独立 `CaptureActor` 管理，音频回调只做无阻塞复制/入队，不做模型推理或数据库查询。
- `JournalActor` 按会话串行写清单和块，并在提交点执行 `fsync` 策略。
- `JobSchedulerActor` 按优先级调度：捕获与落盘 > 口述实时 ASR > 会议实时 ASR > 会后 ASR/说话人 > LLM 整理 > 索引重建。
- 禁止没有持久化 job ID、取消语义和结果幂等键的 `Task.detached` 长任务。

### 4.3 资源策略

- 记录物理内存、可用磁盘、热状态和低电量模式；不得记录用户内容。
- 录音期间限制并发重模型，禁止因为会后 LLM 导致实时 ASR 积压。
- 中间张量与完整音频不得随会议时长常驻内存；只保留滑动窗口和有界队列。
- 推理结果的幂等键为 `jobType + inputRevision + modelArtifactID + configHash`。
- `ResourcePolicyController` 固定按 capture > journal > live ASR > final ASR > speaker/local text 排序。memory warning 先节流 live ASR 并卸载重模型；critical memory、critical thermal 或 backlog 满时把推理持久化延后，但 capture/journal 仍继续运行。
- 每次降级决策携带稳定 reason code，并显式产生 entered/remained/recovered transition，供 UI 与诊断显示；backlog 超出容量的输入 fail closed，不能隐式扩容。
- `SPIKE-RES-001` 对 normal、memory warning/critical、thermal serious/critical、backlog full、组合压力与恢复执行确定性注入；8 个场景均通过，16 个压力窗口音频块全部提交并重新打开恢复，gap 为 0。该 probe 验证调度 contract，不替代 16 GB 真机模型资源矩阵。

## 5. 会话状态机

```mermaid
stateDiagram-v2
    [*] --> Preparing
    Preparing --> Recording: 权限、音源和 journal 就绪
    Preparing --> FailedRecoverable: 初始化失败
    Recording --> Paused: 用户暂停
    Paused --> Recording: 用户继续
    Recording --> Finalizing: 用户结束
    Paused --> Finalizing: 暂停时结束
    Recording --> Cancelled: 仅短口述取消
    Paused --> Cancelled: 仅短口述取消
    Finalizing --> Completed: 音轨封存，必要作业已入队
    Finalizing --> FailedRecoverable: 可重试封存失败
    FailedRecoverable --> Finalizing: 恢复/重试
    Completed --> [*]
    Cancelled --> [*]
```

- `Completed` 表示捕获已不可继续，不表示所有派生处理都成功；会后作业有独立状态。
- 崩溃恢复的是未封存会话，不是把用户已结束的会话重新打开。
- 暂停使用同一会话 UUID；时间轴保存墙钟区间、媒体区间和 `pause/gap/sourceChanged/deviceChanged` 事件。
- 导入的暂停是处理任务暂停，不修改或切割源文件。准备期间收到的暂停意图必须保留，并在 journal 进入 recording 后先写入同一会话的暂停标记再开始解码；恢复时先持久化 `resumed` 标记和会话快照，再释放解码 gate，避免音频越过尚未落盘的时间线边界。源音频封存后不再显示无法兑现的“暂停并删除进度”：用户停止后保留原文件、已提取音频和可恢复作业到资料库，只有新导入在封存前经确认的取消才删除本次临时进度；从资料库恢复既有导入时任何阶段的停止都不得删除已有记录或来源证据。所有选择保留证据的中断路径都必须立即把仍活跃的 snapshot 加入本次运行的恢复集合，不能依赖下次启动扫描才能重试或删除；容器级可访问性属性不得覆盖暂停、继续和停止控件自身的语义与标识。

## 6. 音频捕获、时间轴与落盘

### 6.1 来源

- 麦克风使用 Core Audio/AVAudioEngine 的原生 PCM 回调，保存实际设备 UID、格式和切换点。
- 口述 alpha 已在当前 Mac 默认内置麦克风上以拒绝全部出站网络的 sandbox 跑通 start、pause、resume、end 和 cancel：44.1 kHz 单声道，暂停窗口新增块为 0，结束路径获得 8 块/35,280 帧，取消路径获得 2 块/8,820 帧。探针全程只在内存消费 PCM，证据不保存音频、设备 UID 或用户内容；`validate_builtin_microphone_evidence.sh` 对结构与隐私字段 fail closed。安装版腾讯会议合成语音已通过真实麦克风与 Process Tap 分轨同采，Process Tap 探针也通过真实 HDMI 默认输出切换与恢复；录制中权限撤销、采样率/输入设备物理变化和 16 GB 完整资源矩阵仍属更广的实机任务。
- 系统/指定 App 音频首选 macOS 14.2 的 Core Audio Process Tap。Apple 官方样例表明 tap 可捕获一个或一组进程的输出，并通过 aggregate device 作为输入，同时要求 `NSAudioCaptureUsageDescription` 和系统音频录制权限。
- 麦克风、辅助功能和“屏幕与系统音频录制”统一由 `MacDictationPermissionService` 读取、申请、轮询和打开恢复设置；主窗口、设置、预听和正式捕获使用同一状态源。服务只持久化“曾请求/曾允许”布尔证据，不复制或替代 TCC 的当前裁决；每次显示仍以系统实时状态为准，并结合历史区分首次未决定、拒绝和授权后撤销，避免重启后把拒绝误报为首次请求。macOS 已接受系统音频授权但当前进程尚未观察到时显示“重新打开 App 后生效”，不得误报为拒绝。首次流程只在麦克风获准后提供设备选择和不落盘的实时电平检查；系统音频权限仍延迟到用户进入电脑内录时申请。录制中撤销任一正在使用的捕获权限会立即暂停并保留已提交音轨。
- 真实拒绝必须按数据边界失败关闭，不能只依赖 `AudioDeviceStart` 返回码；macOS 26.5.2 的实测拒绝路径会继续交付正常节奏的回调，但把选中来源替换为精确数字零。捕获层必须禁止发布/落盘该轨并清理临时 tap/aggregate 对象。
- ScreenCaptureKit 只作为兼容性/故障对照，不作为首选，因为产品不需要视频且 Process Tap 更贴合进程音频边界。
- Chrome 等多进程 App 使用“用户选择的应用身份 + 已验证的进程集合”建模；helper 的发现、退出和新 PID 加入必须由 Spike 证明，不能只比较一个静态 PID。
- 来源选择按稳定应用身份保存“同时记录我的麦克风”覆盖值：已知会议 App 默认开启，纯输出媒体与整个 Mac 默认关闭；Chrome 等浏览器只在本机可见窗口标题明确命中会议页面时调整可逆默认值，捕获边界仍是整个浏览器 App。用户显式选择始终优先，并随加密归档迁移。
- 可选 `LocalSourceContextAdapterRegistry` 在基础录音之外读取本机可见窗口信息；腾讯会议适配器使用有界 Accessibility 遍历获取会议标题、参与者和当前发言状态，通用适配器只记录可见窗口标题。适配器失败、权限不足或字段不可靠时必须返回空并继续原始音频、匿名分段和人物处理，绝不调用会议云 API、改变捕获边界或猜测姓名。
- 平台姓名只使用 `reliable` 的“当前发言人”时间区间，并且只能对齐到非重叠的远端系统音轨出现片段；单次重叠至少 500 ms、覆盖率至少 60%，同一会话说话人累计至少 1 s。参与者名单、标题或语义内容不能单独成为姓名映射。冲突姓名保持匿名，用户确认高于平台证据，平台证据高于纯声纹自动匹配；证据及来源 context/occurrence ID 持久化，重算不得覆盖人工拆分或复活已删除人物。

### 6.2 分轨原则

- 在线会议同时保存 `systemRemote` 与 `microphoneLocal` 两条源轨，不在捕获阶段不可逆混合。
- 麦克风轨可由来源直接标记“本机发言者候选”，系统轨仍可能包含多个远端说话人，需要分段。
- 线下会议的共享麦克风轨对全部人执行分段。
- ASR 产生独立的 16 kHz mono 派生流；源轨保持原格式或无损规范化格式。
- 多轨 ASR 派生必须按 `trackID` 独立维护重采样器和有界窗口，不能因系统输出与麦克风回调交错而把每个回调切成独立窗口。每条轨内的窗口和来源映射严格单调且禁止重叠；不同轨允许共享同一单调时间区间，识别上下文只沿同一轨传递，最终片段再按共享单调时间轴稳定合并。

### 6.3 单调时间模型

每个音频块至少保存：

- `sessionID`、`trackID`、连续块序号；
- `hostTime`/转换后的单调纳秒；
- 源采样率、帧数、媒体起止时间；
- 墙钟时间仅用于展示，不参与音频对齐；
- 不连续原因、设备/进程身份和块摘要。

跨轨对齐以单调 host time 和帧计数为准。任何采样率变化先形成新的 track segment，不能静默改变同一段的时间换算。

### 6.4 Crash-safe AudioJournal

- 会话开始即原子创建 manifest 与数据库会话记录。
- 以短块写临时资产，块完成后先落盘再用原子 rename 提交，随后事务性登记摘要和时间范围。
- 块时长暂定不超过 2 秒；编码使用 PCM、ALAC 或其他可恢复方案由 Spike 决定，不能在没有 kill-test 的情况下锁定 M4A 容器。
- 原生麦克风和 Process Tap 的高频回调先在捕获边界内合并为最多 500 ms 的连续 PCM 块；暂停、结束和格式/时间不连续会立即冲刷尾块。块文件原子 rename 后，摘要与范围以本地 `commits.jsonl` 逐条追加并 `fsync`，录制中的实时 ASR 只读取已提交内存快照并在派生时逐块校验；完整 recover 与 manifest 快照仅在密封、启动恢复或显式恢复边界执行。启动时只重放完整换行结尾的提交记录，尾部半条记录会先耐久截断再允许续录。禁止每个 40 ms 回调或每次实时识别都重写随会话增长的完整 manifest。
- 安装版 revision `75d22ffd5617` 的 selected-App 实测在 Finder 前台通过全局暂停/继续后连续采集 7,244.085 秒：14,490 条提交序号连续、14,490 个块的长度与 SHA-256 全部匹配，实时识别期间 manifest 始终为 304 bytes，峰值 physical footprint 2.3 GiB，且无 App error/fault 或 thermal warning。该 48 GB M4 Pro 证据只关闭真实安装包的长时 capture/journal 回归，不替代 16 GB、真实语音 ASR/XPC、生产说话人模型或物理设备事件门禁。
- App 来源归并使用“宿主可执行文件 + 已知音频 helper”关系，而不是把全部 WebKit helper 按显示名混为一个来源。安装版 revision `b6f139459f23` 已把 Tencent Meeting 及其宿主命名的 `Graphics and Media` 音频 helper 收敛成唯一 `bundle:com.tencent.meeting` 来源；正常 UI 捕获 Tencent 本地扬声器测试音时生成 167 个连续 journal 块，暂停边界冲刷后稳定在 83 块，恢复后继续同一会话。并行非选中进程的 19.1 kHz 水印峰值仅 `0.00002227`，低于 `0.003` 门槛。该非语音 fixture 只证明来源发现、selected-App 捕获/排除、来源元数据和暂停恢复；真实会议语音、生命周期/进程重启、可选麦克风同采、说话人和人物链路仍须单独验收。
- 安装版 revision `a2bf3af6c794` 又以 Tencent 本地音频测试控件完成受控合成语音、selected-App 与可选麦克风两条生产音轨的封存和重处理。156 个源块按轨独立派生，最终稿允许远端与本地同时段分段并稳定落库；统一说话人管线保留两名会话说话人和四次按轨出现，麦克风轨正确匹配本地人物，远端轨保持匿名且未误认成本人。Qwen 随后生成摘要、章节、结论和待办四类本地文档，48 条来源引用均指向该最终稿的有效片段。此证据关闭受控 Tencent 语音、麦克风同采、最终 ASR、说话人/人物和本地整理链路；未加入真实会议，因此生命周期/进程重启、参会者上下文和 Zoom 仍属开放矩阵。
- 最终化只生成新的逻辑资产/索引，不覆盖已提交块；失败时原块仍可恢复。
- 启动时扫描 manifest 与数据库差异：孤立有效块可重新挂接，摘要错误块隔离并显示缺口。
- 磁盘空间采用软/硬水位：软水位提示并暂停重模型，硬水位安全停止捕获、封存已有块且不显示伪成功。

## 7. 三阶段语音识别

### 7.1 统一接口

```swift
protocol StreamingASRBackend: Sendable { /* bounded incremental audio -> revisions */ }
protocol FinalASRBackend: Sendable { /* immutable audio ranges -> timestamped result */ }
protocol ForcedAlignmentBackend: Sendable { /* transcript + audio -> word/character timing */ }
```

领域层只接收版本化 `TranscriptRevision`，包含来源范围、父修订、稳定性、语言、模型 artifact ID 和 token/segment 置信信息。`inputRevision` 是同一会话内推理输入的幂等序号，不是 UI 的“当前稿”排序键：新的终稿必须在所有已持久化 live 输入之后分配序号，恢复或重试已经存在的终稿则必须复用原序号。读取当前逐字稿时先按 `final`/`userEdit` 终态与创建时间选择，只有不存在任何终态修订时才能回退到 live；时间轴优先使用当前终态的 segments，必要时才回退到最近一份带时间戳的终态证据。任何 History、导出、整理、事件、人物、重处理或编辑入口都不得用数值最大的 live revision 覆盖已完成终稿。

### 7.2 流程

1. **流式草稿**：VAD/端点检测后提交有界音频窗口，允许局部回改；UI 只替换相同 revision range。
2. **句末重算**：对已结束语句使用完整音频、最近上下文和词典，以精确批处理能力重新识别，形成父链可追溯的新修订并替换同一段流式草稿，不允许仅把流式结果改标签或追加重复句。暂停边界使用同一精确句末路径，但不封存会话；结束边界先取消并落定尚未提交的草稿任务，再以 `max(lifecycle revision, persisted live input revision + 1)` 分配新终稿输入序号。恢复已存在终稿时保持其原始输入序号，避免改变 durable-job 幂等键。若全局终稿的有效信息量不到最佳 live 候选的一半且至少少 6 个字母/数字/汉字，则判定为明确退化：以词典命中和信息量选择更可信的 live 来源生成 final 修订，继续保留终稿父链、完整封存音频范围、原 live segment 与实际模型来源；正常的句末纠正仍以终稿为准。
3. **会后全局重算**：对长会话按重叠窗口离线解码并统一标点、时间戳和分段；导入直接进入此路径。
4. **润色/整理**：输入是已冻结逐字稿修订，只产生派生文档和可追溯引用。

### 7.3 模型候选，不是最终选型

| 候选 | 适合验证的能力 | 主要风险 |
|---|---|---|
| FluidAudio | 原生 Swift/Core ML/ANE、中文模型、在线/离线说话人、嵌入 | 中英文句内混输与各模型组合必须实测；模型许可逐项核验 |
| Argmax OSS / WhisperKit | macOS 14+、Swift/Core ML、Whisper 多语种、时间戳 | 开源实时说话人边界与中文低延迟需实测 |
| sherpa-onnx | Swift、macOS/iOS、流式/离线 ASR、VAD、说话人识别 | Apple Silicon 能效、包体和 Swift 封装复杂度 |
| Qwen3-ASR 0.6B/1.7B | 普通话、英语、方言和混输高质量对照；存在兼容 macOS 14 的原生 MLX Swift 实现 | 原生端口须通过相同本机语料、时间对齐和产品集成验收，不能直接采用供应商结果 |

默认后端只能由 [EVALUATION_PLAN.md](../quality/EVALUATION_PLAN.md) 的本机结果决定。模型供应商的公开 WER、RTF 或演示只能用于入围，不能用于发布结论。

Qwen3-ASR 的下一轮对照限定为开发者 `AlphaASREvalCLI`：固定 MLX Audio Swift `cae704f53bc32a3d0b606823828fbc5bedaaf388`（MIT，Swift 6.2 / macOS 14）与 `mlx-community/Qwen3-ASR-1.7B-8bit` 的 `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`（Apache-2.0）。沿用当前精确 MLX 依赖，不提高 App 最低系统版本；模型只能从外置评测存储的已验证文件加载。上游 loader 会在模型目录生成 `tokenizer.json`，故评测适配层在内存中构造 tokenizer，保持受校验模型目录不可变。不开启 Hub 自动下载，不改变 App 生产路由，也不能把构建或单条推理成功当作质量通过。

该原生候选已完成相同 64 条语料的断网推理。24 条真人英语 WER 为 4.15%（现用 Parakeet 7.64%，Whisper 8.30%）；24 条真人普通话原始 CER 16.16%（Paraformer 10.73%），统一去标点的补充内容 CER 7.81%（Paraformer 10.42%），原始混合单位错误率 4.90%（Paraformer 7.65%）。这些口径必须并列保留，不得用归一化值冒充原始 gate。两条合成混输的归一化内容无误，两条静音/低噪声不产生文字。严格危险 token gate 的唯一标记经逐条复核是同一日期的英语年份等价写法不在冻结 fixture 表中，不是日期改变；原始 failed decision 仍完整保留，组合 WER 和 5.125 GB RSS 也未通过原门槛。该小型调优集只支持继续验证候选，不能宣布发布胜出或静默替换生产路由。生产接入前还必须落实可取消执行、逐字时间对齐、来源范围与持久作业语义；本轮不进入用户明确后置的 16 GB 优化。

2026-08-30 补充固定 `Qwen3-ForcedAligner-0.6B-8bit`（revision `0e1a68e91d815300c7c9754b2a7639378b23db15`，Apache-2.0）的本机断网对齐检查，沿用同一原生 SDK。16 条 AMI tuning / 349 词相对参考的边界偏差中位数 30 ms、P95 590 ms；AMI 原始文档明确其逐字时间由自动强制对齐生成，不能称为人工语音边界真值。另对 6 条真人中文、6 条真人英语和 2 条合成混输加入准确一秒前置静音，306 词的平移偏差中位数/P95 均为 40 ms、最大 440 ms，符合 80 ms 量化存在半格平移偏差的预期，但不证明绝对边界精度。保留原始缺陷计数：AMI 有 22 个零时长词，平移对照有 10 个零时长预测及一个超出原音末尾 7.4375 ms 的词。生产句段装配必须覆盖原文、不丢标点和零时长词；仅容纳一个已声明模型量化步长内的边缘舍入，超界、逆序或文本对应失败必须拒绝对齐并保留原有 VAD 来源范围。不得直接把逐词输出变成逐行 UI，也不得把这些 tuning 结果当成 release holdout。

接入合同（实现中，不代表已安装版本）：P0 是四入口共享的最终稿、可取消原生解码、自然句段与原音范围映射，以及模型不可用/异常时保留原有已验证终稿路径。`BestASRQwenRuntime` 独占持有 MLX 模型；使用 SDK 的公开前向接口实现有界贪心 token 循环，每次模型阶段和 token 间检查调用任务取消，不使用 SDK 隐藏的 detached streaming 任务，也不在取消后并发复用尚未结束的实例。保留现有实时草稿路径；Qwen 最终识别及对齐均成功才采用该结果，异常不写入不完整新修订，取消不触发降级重算。P1 包含同一推荐组件安装/升级、两份模型的固定版本与 provenance、词典实际影响、无内容错误信息、回归覆盖及正式 App 回放/跳转/取消验收。原始语料 gate 不修改；此次模型/解码变更必须复验受影响的本机语料，独立发布集与最低设备仍单独列为未完成。

原生接入的 64 条实测发现旧 RMS/peak 活动阈值误拦截 15 条轻声真人英语，故最终稿仅跳过全零数字静音；其余有界音频保持原幅度与完整上下文交给 Qwen，不靠音量猜测“无人说话”。仅复测受影响的 15 条与两条非语音对照后，15 条均恢复、对照均无幻觉；保留初次失败结果，不把组合质量统计当成另一次全量计时。自然句段在口述正文、评测和持久化片段修改中共用 `TranscriptTextJoiner`，避免英文句末标点后的空格丢失；原始片段、时间和不可变修订仍保留。已通过真实模型取消后复用与 48 项相关 hosted App 测试，正式安装包交互尚待验收。

候选 adapter 统一实现 `ASREngine`，把 runtime SDK 隔离在 `CandidateASRRuntime` bridge 后，并在进入 runtime 前校验协议版本、artifact ID、离线网络策略、能力、音频范围与有界上下文；runtime 返回后再次校验 segment 时间范围和唯一 ID。FluidAudio/SenseVoice、Argmax OSS/WhisperKit 与 sherpa-onnx 的 contract probe 使用同一套 `ASR-001..010` 合成 fixtures，并把草稿→终稿表示为同一音频范围上的 `replaceAudioRange` 修订，避免重复追加。

`SPIKE-ASR-001/adapter-contract-smoke.json` 只证明可替换接口和失败关闭语义，contract fixture digest 不得冒充真实模型 digest。另行固定的 FluidAudio 0.15.5、Argmax OSS/WhisperKit 1.0.0 与 sherpa-onnx 1.13.2 已在 Apple M4 Pro / 48 GB 机器上，以三个本地合成中英/混说样本完成断网真实推理；`recommended-memory-smoke-summary.json` 将 runtime commit、模型树 digest、语料 manifest 和无原文聚合结果串联。SenseVoice 权重已固定为 `LicenseRef-FunASR-Model-1.1`，完整中英文协议、上游提交、归属要求和每个文件的尺寸/摘要由 `config/model-artifacts.json` 与 `Legal/` 快照约束。生产 bridge 只能接收 ModelManager 原子安装并验摘要后的本地路径，不能调用候选 SDK 的自动下载功能。

生产实现把精确提交的 FluidAudio 放在独立 `BestASRFluidRuntime` target，领域/口述模块不导入 SDK。`LocalModelManager` 只接收用户或分发层显式提供的本地 staging 目录，拒绝符号链接、额外/缺失文件、尺寸或 SHA-256 不符、健康检查失败、重放和降级；验证后原子切换 active pointer、保留 last-known-good，并在启动时重新验摘要和恢复损坏 pointer。启动发现会逐文件复核注册表尺寸与摘要，随后只由运行时构造执行一次 Core ML 模型加载，避免“健康检查一次、运行时再加载一次”的重复冷启动。App 先注册全局快捷键和捕获路径，再异步预热已安装模型；SenseVoice 和普通组件发现完成后，Mandarin/English 两个终稿 runtime 并行预热，各个 `LazyManagedASREngine` 用 actor 持有唯一 in-flight factory task，因此预热与用户提前结束口述会加入同一次加载而不会重复创建 runtime。加载失败会清除该 in-flight task，使实际终稿请求仍可重试；重新配置模型会取消并重建预热所有权。预热期间仍可开始录音，提前结束时也先封存音频并留下可恢复任务。安装 revision `d18ce553b7f8` 的冷启动实测在捕获路径可用后 3.685/3.718 秒完成 English/Mandarin 预热，首个真实外部目标普通话口述在 End 后 3.544 秒完成识别与一次性插入。修复/回滚只隔离模型目录，绝不删除来源音频、历史或排队作业。

封存后的 AudioJournal 依据不可变来源范围生成 content-addressed 的 16 kHz 单声道 Float32 推理资产；每个窗口默认最多 30 秒，遇到 track/格式变化或不连续即切窗，派生 manifest 与摘要支持同一进程内幂等复用而不修改原块。每个 ASR/说话人消费者为派生目录持有显式 lease，成功、失败、超时或取消后都释放；最后一个 lease 释放即删除可重建窗口，App 重启时只清除上次进程遗留的无 lease `inference/` scratch，绝不删除 journal 原块。这样 900 ms 流式修订不会把每轮累计窗口永久留在历史资产中。SenseVoice 与单语终稿路径共用有界 20 ms 能量帧、静音/低噪声抑制和带 padding 的短句边界，保留短句时间定位。显式词典只允许最多 64 项、每项 128 字符的确定性标准拼写或唯一近音/近形纠正，不允许凭空补出未识别事实。识别 adapter 对字典、上下文、语言、输出尺寸、超时和取消设硬边界，将分段 runtime 时间戳映射回连续的单调来源范围；跨短块的 segment 由范围并集验证，重采样舍入只允许两帧容差且不能跨越真实 gap。静音的流式窗口不落空修订；终稿没有任何可识别 segment 时进入保留原音的可恢复识别失败，不能继续润色、插入或标记完成。非空流式草稿和父链终稿作为替换修订提交。GRDB V5 分表保存 segment、来源音频范围与恢复标记，同时保留模型 artifact、config hash、语言提示和父修订。

2026-08-29 的真实导入失败被进一步定位到固定 Core ML 前处理的 CPU-only 执行路径：同一合成原音从 83,200 样本增加到 83,520 样本时，前 4.8 秒中数千个原本应保持不变的特征发生大幅变化；文件直接读取与 SDK 重采样的样本逐点相同。FP32 `cpuAndGPU` 前处理保持这些共同前缀一致，而编码器仍必须使用 `cpuAndNeuralEngine`，不能把整个 FP16 模型移到 CPU/GPU。`FluidASRModelLoader` 因此只从已验证本地目录加载同一固定权重，为 SenseVoice/Paraformer 分别指定 FP32 CPU/GPU 前处理（禁止 GPU 低精度累加）与 ANE 推理；健康检查使用相同策略，不调用下载入口。取消上一候选合并整段上下文的绕行，不添加依赖合成错误文本的语言规则。该变更由可选真实模型的输入长度不变性、中文识别和短句时间戳回归约束，仍需正式安装包与受影响真实语料复验。

任务 5.5 已用 `product-synthetic-alpha-asr-v1` 1.1.0 的 16 条中英/混说/专名/危险数字与否定/快慢语速/长停顿/自我修正/静音低噪声样本完成真实断网推理。Fluid SenseVoice int8 的聚合结果为 CER 5.59%、WER 12.90%、MER 9.19%、危险 token 错误 0、P95 2.40 秒、RTF 0.21、峰值 RSS 560,807,936 字节；全部 gate 通过，因此 `config/inference-candidates.json` 将它选为口述 alpha 默认。该结论不等于发布选型：独立内置麦克风控制流虽已通过，16 GB 等效、真实麦克风直接进入已安装模型的整链、release holdout、热降级、长会话和流式 revision churn 仍未完成，所有候选继续保持 `releaseEligible: false`。SenseVoice 模型协议的精确版本、摘要和归属快照已登记，但产品分发条款仍须进入发布法律接受流程；sherpa 模型/数据许可仍未放行。sherpa 固定运行时的 Core ML provider 探针明确回退 CPU，设计不得宣称其具备本次实测的 Core ML 加速。

V1.5 重新用固定 revision 的公开 FLEURS 真人 `cmn_hans_cn` 与 `en_us` dev 音频建立调优集：普通话和英语各 24 条，分别在性别与短/中/长时长上平衡，并与原有 16 条产品合成危险语义/静音样本组成 64 条本地运行。内容、逐字参考和逐条诊断只留在 `/Volumes/BestASRBuild/bestASR/corpora` 与本地 evaluation root；Git 只保存无内容 manifest、许可、固定下载文件摘要和聚合结果。SenseVoice 在组合 profile 上 CER 47.36%、WER 83.79%、MER 35.12%，明确失败，不能再作为所有语言的终稿默认。固定 Paraformer 中文 int8 在 32 条普通话 profile 上以 CER 14.96%、危险 token 错误 0、P95 428 ms、RTF 0.0281、峰值 RSS 906,035,200 B 通过；固定 Parakeet Unified 英文 int8 的热运行在 32 条英语 profile 上以 WER 7.80%、危险 token 错误 0、P95 190 ms、RTF 0.0175、峰值 RSS 684,720,128 B 通过。首次冷运行中健康检查与 runtime 重复加载造成的峰值超门槛没有被修改门槛掩盖，产品路径通过只在安装激活时执行完整健康检查、正常发现只验文件集并延迟持有一个 runtime 消除重复常驻。

产品候选因此采用自动阶段路由，而不是把模型选择交给用户：SenseVoice 继续产生低延迟实时/句末证据并承担同一句中英混输；明确普通话终稿交给 Paraformer，明确英语终稿交给 Parakeet。runtime 在清除可见文本的特殊 token 前保留模型语言标签，并通过 candidate/ASR result 和 revision provenance 传到路由；清晰混输文字优先于单一主语言标签，否则真实检测标签优先于可能已经误识别的文字形态。路由优先使用已持久化实时证据，证据不足时才先跑多语终稿分类；用户从原音重新识别时必须独立重判，不沿用旧终稿的错误语言证据。SenseVoice 无任何可用证据且返回空结果时仍按真实评测记录先尝试英文终稿，再尝试中文终稿，因此该兜底不应被视为可靠语言识别器。三个 runtime 都先经过同一有界 VAD、词典归一化、`CandidateASRRuntime` 网络策略与 request/result contract；专用模型缺失、输出文字系统不相符或普通 runtime 失败时安全回退，取消必须立即传播。真正混输不得被强制拆给单语模型。每份最终 revision 保存实际产出模型 artifact ID，config hash 同时包含路由版本和本次可用模型集合。该 tuning 决策只推进 final-ASR 阶段选择，不替代独立 release holdout、真实安装包连续断网、alignment、流式、人物、语义检索或本地文本阶段的统一验收。

高质量多语种复核不能把早期 Whisper `tiny` 三样本 smoke 当作整个 Whisper 系列的结果。开发期 `AlphaASREvalCLI` 增加精确固定的 Argmax OSS / WhisperKit 1.0.0（`25c62997041c134b03ca82731ce2f6fd2cae1eb9`）依赖，仅评测 target 链接 `WhisperKit`/`ArgmaxCore`，不链接 App、不启用 Pro、服务器、TTS 或 SpeakerKit。上游 SDK 为 MIT、最低 macOS 13，评测仍在 bestASR 的 Apple Silicon/macOS 14.2 边界内运行，不引入用户端 Python 或命令行依赖。指定的 Core ML `large-v3-v20240930_626MB` 与分词器分别按公开仓库提交固定，并通过同一个 `LocalModelManager` 验证；下载、构建、原文诊断全部留在专属外置路径。关闭 SDK 自动下载并先显式解析本地分词器，整个推理进程再由父 sandbox 拒绝网络，避免 SDK 的 tokenizer-fallback 下载路径越界。先单条真实推理，成功后复用现有 FLEURS/合成危险词语料及原指标；比较尚未完成前保留当前生产路由，不改变安装模型或用户数据。

FP32 CPU/GPU 前处理修复后的同一 32 条普通话 profile 断网复测为 CER 9.17%、危险 token 错误 0、P95 434 ms、RTF 0.0286，通过原有门槛；此前 CPU-only 的 14.96% 结果保留作为旧路径，不冒充新实现证据。SenseVoice 的同一组合 profile 仍未通过总体质量门槛，不能据此前处理修复升级为通用终稿默认。两套复测聚合及逐条本地诊断分别保存在外置 `evaluations/asr/fluid-paraformer-fp32-gpu-v1` 和 `fluid-sensevoice-fp32-gpu-v1`。SenseVoice CTC 宿主解码改为按实际 strides 读取原生 Float16/Float32，避免对每个 token 构造 NSNumber 数组；带填充行、重复 token、blank 分隔和有效帧上限有独立回归。

`installed-model-dictation-summary.json` 的 schema 5 进一步在父进程拒绝全部网络的 sandbox 中，以 Release 优化构建跑通两个精确已安装模型、五个模拟采集短块、AudioJournal 封存、词典上下文、真实 SenseVoice ASR、真实 Qwen 润色、零容忍事实门、GRDB 历史、保留待复制插入、一个会话说话人/五个出现记录和 queued 人物任务；本次 Qwen 结果通过事实门并以 `model` disposition 成为插入修订，五个来源音频范围仍全部可恢复。9 秒样本的整链处理为 2.488 秒，其中 ASR 为 1.532 秒、润色/事实保护/落库/插入为 0.956 秒、其余管线开销为 0.285 毫秒，峰值 RSS 为 3,266,953,216 字节。这个单点说明 Release 路径可以进入 PRD 的 2.5 秒边界，但不能代替任务 8.4 的 P95 和推荐/16 GB 设备矩阵。新进程无 Core ML 缓存时的模型准备为 101.865 秒，App 仍必须在捕获前后台预热并允许捕获优先于推理。证据不含音频路径、逐字稿、词典正文或目标内容。

说话人候选另以 `config/speaker-candidates.json` 固定 FluidAudio、Argmax SpeakerKit 与 sherpa-onnx 的 runtime revision、模型树 digest、许可状态和无默认选择状态。三者已在同一 Apple M4 Pro / 48 GB 主机上，以九个本地合成 diarization 样本和 22 个 identity enrollment/query 样本完成断网真实推理；自动人数与 oracle 人数共六份聚合 benchmark，oracle 只作诊断。自动模式下 sherpa 的 DER/JER 较低且已知人接受为 9/12，但 P95 为 6.89 秒；Fluid/Argmax 更快但各保守拒绝 6/12 个已知 query。三者均无已知错认并拒绝 4/4 陌生人。这些结果只属于推荐内存合成 smoke，不是发布门槛或默认选择。

`validate_inference_evidence.sh` 已逐项核对 ASR 与 speaker candidate registry digest、共享 contract suite digest、fixture/model artifact digest、alpha ASR benchmark/decision/corpus 三向摘要、三份 ASR 与六份 speaker 推荐内存 benchmark 的 runtime/model/corpus/digest 引用、speaker identity 聚合、LLM factual fixture 与资源优先级报告；任一引用漂移即 fail closed。完整 `SPIKE-ASR-001/summary.json` 与 `SPIKE-SPK-001/summary.json` 仍不存在，因此完整性检查把状态明确记录为 `alpha-default-selected-release-blocked`：允许 alpha 使用已过门槛的 SenseVoice，但不得改写成发布默认或发布就绪。

## 8. 说话人分段与长期人物

### 8.1 同一人物管线，按来源调度

所有来源都经过 `VAD → 会话内分段/聚类 → SessionSpeaker → SpeakerOccurrence → 全局 Person 匹配`。单人内容只产生一个 `SessionSpeaker`，不是不同的类型或捷径。来源提示可以参与证据质量计算，但不能直接等同于现实人物或绕过统一阈值。

2026-08-30 内录复现暴露固定 Fluid SDK 的阈值单位不一致：配置声明 community-1 的欧氏距离 `0.6`，AHC 却先执行 `sqrt(2 - 2 * argument)`，把相同实参扩大成约 `0.8944`。适配层显式传入 `1 - 0.6² / 2 = 0.82`，恢复原定义的距离；不得通过强制两人来满足测试。此次只修聚类单位，保留原模型、256 维身份空间、全局匹配阈值和人工关系；新作业使用 `fluid-speaker-final-v2-community-distance-0.6` 配置版本，旧证据不自动重写。两条合成输入和同场 AMI tuning 的近讲/远场轨均有无人数提示对照。评估器同时取消原来的 `1...4` 上限，避免固定四簇回退掩盖缺陷；既有 AMI 留出集在原全局身份阈值下通过，混淆率 2.2136%、错误身份与错误合并均为零，同时保留 DER 25.1138%、JER 34.0834% 的真实误差。此次是已有语料回归，不宣称新的未见语料选型；安装版重处理仍须完成。

- **口述**：在实时预算内尽力维护说话人边界；结束后对完整音频执行最终多人分段与聚类，并为每个稳定说话人进入全局匹配。外部纯文字插入可先完成，最终人物作业异步更新 bestASR 历史，不得重复或回改已插入文本。
- **线下麦克风**：实时会话内 A/B/C，结束后使用同一最终分段、聚类与全局匹配接口修正漂移。
- **系统音频**：远端混合轨和可选本机麦克风轨都进入相同接口；轨道来源可以作为“本机发言者候选”证据，但长期关联仍使用相同质量门槛与全局 Person 空间。
- **导入媒体**：使用同一领域结果的离线调度；不建立导入专用人物实体。

不同来源允许使用不同的在线窗口、优先级或离线重算时机，但给定等价证据时必须产生等价的身份关系、未知/候选/已匹配状态和人工纠错行为。

`BestASRSpeakerRouting` 对四类入口使用一个 `SpeakerRoutingRequest → SessionSpeaker/SpeakerOccurrence/PersonAssociation` contract。入口只决定允许的 source-track role：口述为本机麦克风、线下录音为房间麦克风、系统内录为远端系统音频及可选本机麦克风、导入为原文件轨；任何交叉误路由均失败关闭。人物匹配策略作为版本化参数注入，短片段、重叠、背景声或低质量证据即使带有高相似候选也不能自动合并；不同入口不能拥有不同阈值。当前 `contractProbe` 数值仅用于确定性 fixtures；推荐内存合成 smoke 的 enrollment-only 阈值也只验证计算协议和保守拒绝行为，两者都不是 6.7 完整发布矩阵后的阈值。

默认口述插入由独立 projection 只读取最终 transcript revision，生成一个稳定 idempotency key 的无标签纯文字命令，并明确不等待 speaker resolution。当前 alpha 的生产 scheduler 在插入结果持久化后，以会话 UUID、输入 revision 和音频范围确定性生成一个 `SessionSpeaker`、每个来源范围一个 `SpeakerOccurrence`（`unknown` 关系）以及一个 queued `speakerFinal` durable job；track、簇、出现和 job 在同一 GRDB 事务内幂等写入。重复调度命中相同稳定 ID，不会新增出现记录或再次插入；后续人物结果只更新历史关系。

### 8.2 三层身份关系

- `SessionSpeaker`：只在一条会话中稳定，允许结束后重算。
- `Person`：跨记录的长期实体，具有稳定 UUID、可选姓名、别名、确认状态和多个特征中心。
- `SpeakerOccurrence`：连接时间片段、`SessionSpeaker` 与 `Person`，保存来源（track provenance、平台元数据、声纹、用户确认）和置信证据。

### 8.3 防污染策略

- 只有质量合格、足够长、非重叠、会话内稳定的片段可更新人物特征。
- 按通道类别维护多个 centroid：近场麦克风、远场房间、会议软件压缩、导入媒体；不把所有样本盲目平均。
- 自动合并阈值以精确率优先；中置信只提供候选，低置信保持未知。
- “不是同一人”、合并、拆分、命名和撤销都是不可变操作记录；人物 ID 不因重建嵌入而变化。
- 模型升级创建新 embedding space；旧特征保留到新索引完整构建并通过校验后再切换。

## 9. 本地文本智能

`MemoryCore` 在最终逐字稿提交后以 durable job 运行事件候选和跨记录整理。输入只包含本机持久化的会话修订 ID、时间、人物关联和允许的来源上下文；输出为带证据引用的 `EventCandidate`，不会直接改写 `Event`。高置信自动关联同样写入可撤销操作记录，人工创建、移入、移出、合并和拆分始终优先。事件标题、摘要、主题、结论和待办都是可重新生成的派生文档，事件—会话和事件—人物关系才是持久化组织语义。

本地文字请求将带编号的真实逐字稿与可选 `sourceContext` 分开，两者共享同一输入字节上限。录制时间和人物标签只用于归属与顺序，不能冒充原话或期限；自动记录标题不进入事件摘要的证据。事件整理 ID 包含每个来源修订及归属上下文。保存时在同一事务重新验证当前终稿和事件关系；相同 ID 只接受相同结果的幂等重试，不覆盖结果或复活旧稿。全文校对、分段校对和版本恢复都会使旧事件整理失效，而不会删除它们。

事件发现的 `apple-natural-language-event-v2-source-anchors` 候选策略仅比较来源内容；自动导航标题不进入语义输入，事件标题本身不能替代其成员记录的证据。已有事件关联和新事件聚类都要求至少两个去停用词后的共同主题词，再使用本机句向量、时间、人物和来源评分。通用应答、同一天或同一 App 不能单独生成事件建议。这是针对误归类的保守限制，不代表语义模型已经通过独立真实语料选型，也不限制用户手动关联或语义搜索。

人物和事件页面默认把待确认队列收为带数量的展开项，展开后的滚动区域有高度上限，给当前选择的时间线与原音入口保留主要阅读空间。整理卡片默认阅读，按需进入编辑；仅当正文去掉列表标记后与结构化项目完全一致时去重，独立正文、用户改写、来源链接和完整编辑能力始终保留。关系写入后的完成反馈在刷新列表后显示，不被普通数量统计立即覆盖。

导入选择器在 key/main window 因失焦为空时，仍从可见且可成为主窗口的非面板工作区选择 parent，再激活并附着 sheet；已有工作区不能因为从后台触发导入而退回独立窗口。没有可见工作区时才允许独立选择器。

- `TextIntelligenceBackend` 接收逐字稿修订 ID、片段引用和结构化任务，不直接读取任意数据库状态。
- 润色输出先经过确定性的零容忍事实门：分别比较数字、金额、百分比、日期/时间、邮件、URL、显式词典人名/术语、中英文否定、承诺词和“行动人—承诺—动作”关系，并要求候选内容是原内容的保序子序列以阻止新增事实。任一类别变化、来源 revision 不匹配、超时、模型缺失或输出畸形都会拒绝模型结果。
- 安全降级顺序是确定性“仅补句末标点”派生修订，其自身仍须通过同一事实门；若该结果也不合法才直接选择原始 ASR 修订。原文、模型候选选择结果和最终插入修订互不覆盖，派生记录保留来源 revision、模型 artifact 与 config hash。
- 摘要、决策和待办使用结构化 schema；每个结论必须引用一个或多个 transcript segment ID。
- 同一输入、模型和配置产生幂等派生版本；重新生成不会覆盖旧版本。
- 运行时优先验证 MLX Swift、llama.cpp 和 LiteRT-LM。MLX Swift 对 macOS/iOS 共用 Swift 代码最有利；LiteRT-LM Swift 当前仍属早期阶段；最终选择由内存、首 token、吞吐、事实保真和签名分发测试决定。

口述 alpha 已把本地文本实现收敛到精确固定的 `mlx-swift-lm` 3.31.3（commit `1c05248bb0899e2a7a4962b84d319cf12f4e12aa`）和 `mlx-community/Qwen3-1.7B-4bit` revision `21457c6f`（只计算声明运行文件的 tree SHA-256：`09570edbadcacc0bb3abc5c58d688f92978cd62601cf98e11cf38356fd5bd7be`）。`BestASRMLXRuntime` 隔离文字模型的 MLX SDK；语音模型由 `BestASRQwenRuntime` 独立隔离。`BestASRLocalText`、`BestASRDictation`、领域和持久化层仍只依赖协议，不导入模型 SDK。生产启动只接受 `LocalModelManager` 已逐文件验尺寸、摘要并原子激活的本地目录，不调用 Hugging Face Hub 或任何自动下载接口。虽然 tokenizer 的传递依赖含有网络能力，生产调用路径只构造本地 URL；真实候选运行和此前文字模型的已安装口述路径均在拒绝出站网络的 sandbox 中通过，新增语音运行时须完成独立的受影响链路验证。

生成链路先做确定性口头填充词/相邻重复/句末标点整理，再以 `/no_think`、temperature 0、有界 source/context/output token、KV cache、超时和取消调用模型，并且只接受单字段 JSON。prompt-like 输入不能扩大指令权限。模型结果继续通过同一零容忍事实门；失败、超时、畸形输出、模型缺失或来源 revision 漂移都退回已验证的确定性标点版本，必要时退回原始 ASR。App 因而可以把本地润色设为默认，但模型是可选安装项，缺失时仍保持完整的本地口述闭环。

版本化双语/对抗选择集对 0.6B、1.7B 和 4B 三个固定 artifact 做了真实推理。0.6B 未通过样式/事实用例，4B 出现 4 个事实错误；1.7B 混合链路在 12 个样本、24 次调用中实现事实错误 0、生成失败 0、重复不一致 0、样式通过 12/12，加载 405.489 ms、P50 328.112 ms、P95 417.228 ms、峰值 RSS 1,083,047,936 字节。`script/validate_local_text_evidence.sh` 将 artifact/runtime/corpus 引用、2 秒 P95、3 GiB RSS、零事实错误和证据隐私 schema 作为 fail-closed 门槛。该结论只选择口述 alpha 默认，不自动等于发布默认。

本地词典使用 `DictionaryEntryID` 稳定 UUID、显式 `Revision`、标准写法、口语形式、启用状态与墓碑时间。GRDB 以乐观 revision 冲突保护实现添加、搜索、编辑、禁用和删除；设置页直接调用该本地 repository，不存在网络 adapter。每次上下文只投影至多 64 项/16 KiB 的已启用记录，并携带 entry ID/revision 形成不暴露词典内容的 config fingerprint；变化会在同一事务中把当前派生文本标为 stale。投影必须把“标准写法—口语形式”作为结构化映射贯穿流式、句末、终稿和历史重算，不能只传标准词列表。SenseVoice 先对明确且无歧义的口语表面做大小写/宽度兼容的精确归一化，同一表面出现多次时全部改为标准写法；同一口语表面若指向多个标准词则 fail closed，不替换，也不允许级联替换制造新事实。随后才允许既有的有界唯一近音/近形纠正。每项最多 32 个口语形式、每个字段最多 128 字符，下一次 ASR 与事实门使用新的标准写法。普通诊断仍只允许条目数量和原因码，禁止词典正文。

最小历史页从 GRDB 的会话 snapshot 读取 completed、processing、failed 和 recovered 状态，分别展示不可变 raw ASR 与当前 polished 派生文本；显式 Copy 只在用户点击时写系统剪贴板。对已封存且可重试的记录，恢复路径重新打开 AudioJournal 的已提交范围并复用同一处理协调器与插入幂等键；成功后写 `recovered_at`，失败时不删除来源音频。取消的临时口述不进入正常历史。
启动扫描识别的中断会话保留原持久化 phase，但资料库显示为“可恢复”，并纳入同名筛选，而不是显示为仍在本次进程中“处理中”。记录详情直接提供恢复按钮；实际恢复期间显示进度且禁用同一来源的删除和重复恢复。成功后刷新已打开记录的逐字稿、人物、来源和播放器，不要求先关掉详情再打开；若正在阅读这条记录，将不再适用的恢复/失败/处理中筛选切回全部，保持结果可见，浏览其他记录则保持筛选不变。不可修复且没有已提交音频的失败单独显示，不混进可恢复记录。
取消事务会在同一 GRDB 写事务内先解除该临时会话的 transcript revision 自引用，再删除派生记录、修订、音频索引、任务、snapshot 与 session；这一步只清理用户明确取消的未提交会话，不能波及其他会话或已保留源音频。

`BestASRLocalText` 的 `VersionedLocalTextAdapter` 实现统一 `LocalTextEngine`，只接收 ModelManager 已校验的离线 artifact 和显式的逐字稿 revision/segment 引用，不允许 runtime 隐式联网。rewrite、structured summary 与 action item 各自校验输出形状；每个 claim/item 的引用必须是请求中已有的 segment ID，低于支持阈值的内容只能标为 `cautious` 或被省略，不能以确定措辞返回。

协调层返回双输出：原 `TranscriptRevision` 作为不可变 source snapshot 原样保留，另建带 input revision、model artifact、config hash、内容 digest 和新稳定 ID 的 `DerivedDocument`。重新生成只新增派生版本；失败则返回包含 source transcript ID/revision、任务、类别、代码和可重试性的结构化 failure，不创建半成品，也不改写源逐字稿。

事实门槛不使用加权总分：`LLMFactualHardGate` 把数字、日期、否定、人名和行动责任人分别与 source annotations 对齐，任一类别错误超过零容忍 release policy 就直接淘汰候选。`SPIKE-LLM-001` 必须同时证明更高 style preference 不能绕过该门槛、无错误候选不会被误杀、五类 planted regression 都被捕获且 source transcript 不发生修改。

## 10. 跨 App 文本插入

1. 口述开始时记录目标 PID、bundle ID、窗口/元素可重建描述、选择范围与剪贴板 change count，不保存密码或文本内容作为目标指纹。
2. 结束时重新解析目标，确认仍可编辑且不是 `kAXSecureTextFieldSubrole`。
   Codex 的 ProseMirror 编辑器只在 bundle 精确属于 Codex、角色为 enabled `AXTextArea`、选择范围存在、目标非 secure 且 DOM class 精确为 `ProseMirror` 时启用专用解析；其 Chromium `ChromeAXNodeId` 只形成不含正文的稳定 digest，用于跨 AX 引用重建确认。任一强条件缺失都不得降级成“像编辑器”的猜测。
   Chrome/Electron 编辑器缺少 `AXIdentifier` 时，不使用不稳定的 `CFHash` 重建身份；同一 App 进程内由 AX 端口保留一个有界、仅内存的 opaque element registry，以 `CFEqual` 复用目标 token。token 只在生产适配器中形成 digest，AX 引用和原 token 均不落库；App/目标进程重启后 registry 丢失并安全保留待复制结果，不能猜测恢复目标。
3. 首选 Accessibility 的可写 value/selected range 操作；应用不支持时使用安全粘贴兜底。
   对未变化的空选区，连续英文口述只在内存中检查光标前一个 ASCII 字符，并在确有词边界需要时补一个空格；不读取周边正文进入持久化、日志或目标指纹。
4. 生产 AX 目标读取、重校验、TextKit 写入、剪贴板与键盘事件事务整体固定在 `MainActor`；不能以 `Thread.isMainThread` 代替主队列隔离，因为 Swift cooperative executor 可能位于主线程但不拥有 AppKit 要求的主 dispatch queue。
   录音期间的无修饰键 `Esc` 由同一全局事件 tap 优先消费并映射为取消；只有 tap 不可用时才退回 NSEvent 监听，避免前台 App 同时处理该按键或重复提交生命周期命令。
   全局开始快捷键在 event-tap 回调内只允许一次直接焦点读取，不等待、不重试、不遍历 AX 祖先或子树；Codex 若在该瞬间只暴露中间容器，则先让回调返回，再由普通异步目标捕获执行有界稳定化。event tap 被系统因超时或用户输入禁用时，后端必须清除全部物理按键锁存、补发对应 release transition 后再启用，不能因丢失 key-up 把以后所有快捷键误判为长按重复。模型层以真实 press/release transition 为准，不再用时间窗吞掉用户快速的第二次按键。
   启动命令一进入麦克风准备就发布 `.preparing`，悬浮条立即显示目标 App 或“只保存到资料库”的失败关闭去向；准备期间收到结束、暂停或取消不会静默丢弃，而是在进入 recording 后执行最后一个明确命令。从其他 App 触发的全局快捷键或菜单栏入口才允许捕获外部插入目标；主窗口“开始口述”明确只保存到资料库，且任何入口都拒绝把 bestASR 自己的搜索框或编辑控件作为写入目标。完成和可恢复失败都短暂保留最终文字、复制入口与去向反馈，随后自动收起；取消期间保持可见进度，悬浮条始终不可成为 key/main window。
5. 粘贴兜底完整快照一般剪贴板的多 item/多 type 内容，写入临时文本并模拟粘贴；仅在 change count 仍表明本 App 拥有剪贴板时恢复，避免覆盖用户期间复制的新内容。
   Monaco/Chromium 在关闭屏幕阅读器模式时可能已接受定向 `Command-V`，却持续报告空 AX value 和未变化选区。仅当目标本来就缺少稳定 `AXIdentifier`、粘贴后仍通过同一进程/opaque element/选区/可编辑/非 secure 的完整重校验，且剪贴板事务可恢复时，允许把该投递认定为成功；有稳定标识的目标仍必须观察到 value 或选区变化，不能把任意键盘投递当成成功。
6. 若目标、选区或用户输入发生冲突，不猜测位置：保留结果到剪贴板/预览并明确提示。
   `DictationInsertionResult` 同步持久化一个不含目标内容或 App 元数据的枚举 failure reason，使 UI 能区分权限缺失、目标/选区变化、受保护输入区、AX 写入失败、剪贴板兜底失败和幂等歧义，不能把所有失败伪装成普通 completed。
7. 绝不自动触发 Return/发送。
8. V1 默认只插入一份不带说话人标签的纯文字；该呈现不删除、不扁平化 bestASR 内部的 `SessionSpeaker`、`SpeakerOccurrence`、`Person`、时间片段或来源证据。

Terminal、浏览器编辑器、富文本、Electron App、原生 TextKit 和密码框必须进入插入兼容性矩阵。

`BestASRTextInsertionProbe` 已把权限拒绝、不可编辑/secure field、焦点与 selection 竞争、明确“未写入”的 AX unsupported 后 clipboard fallback、写入效果不明时拒绝重复粘贴，以及 clipboard change-count 竞争编码为失败关闭 contract；9 个确定性场景均无错误目标写入。随后在已解锁设备上运行真实 `AXUIElement`/`NSPasteboard`/HID Command-V 端口及签名合成 AppKit fixture，7/7 live 场景通过、错误目标写入为 0，且证据不保存目标文本、剪贴板内容或 bundle ID。版本化兼容矩阵覆盖 TextEdit 1.20、Chrome 150、Word 16.104、Outlook 16.104 的空白 draft subject、VS Code 1.127.0 屏幕阅读器模式，以及 Terminal 2.15 的隔离合成输入；每个目标均执行 20 次标准路径与 5 次强制 fallback，成功率 100%，错误目标写入、剪贴板恢复失败和意外副作用均为 0。Terminal 只在 bundle 精确为 `com.apple.Terminal`、角色为启用或未声明 `AXEnabled` 的非安全 `AXTextArea`、selection 存在、Secure Event Input 未启用且当前值仅为已知合成值加不超过 4096 个 UTF-16 纯空白视口字符时进入验收；其生产插入只允许 `Command-V`，永不发送 Return。安装包实测进一步覆盖未聚焦 bestASR 时的空白 Codex ProseMirror composer 与空白未保存 Word 文档，两者都只插入一份持久化最终文本、恢复原剪贴板并在测试后清空/不保存；隐私安全证据为 `artifacts/evidence/installed-app/cross-app-insertion-20260824.json`。口述 alpha 明确选择 TextEdit、Chrome 和 VS Code 作为首个支持集，`validate_dictation_alpha_targets.sh` 同时交叉验证三目标矩阵与 direct/fallback/secure/conflict 的 live 场景，因此 alpha gate 为 `pass`；完整 `SPIKE-INS-001` 插入发布裁决也已由 Terminal 的 25/25 结果收口为 `pass`。

## 11. 持久化与搜索

### 11.1 推荐基线

采用 SQLite + GRDB 作为本地 source of truth，原因是：

- 明确事务、WAL、迁移和并发控制；
- FTS5 可满足逐字稿、人物和整理结果的本地搜索；
- 可在 macOS/iOS 共用领域与存储代码；
- 可为未来 CKSyncEngine 或其他同步后端维护显式 change log，而不把领域模型绑定到 CloudKit/Core Data。

该选择在加密与多进程 Spike 通过前为“推荐、未最终接受”。

### 11.2 核心实体

`sessions`、`tracks`、`audio_chunks`、`timeline_events`、`transcript_revisions`、`transcript_segments`、`session_speakers`、`persons`、`person_embeddings`、`speaker_occurrences`、`events`、`event_sessions`、`event_link_rejections`、`event_people`、`event_candidates`、`event_text_documents`、`event_edit_operations`、`source_context_events`、`local_text_documents`、`durable_jobs`、`change_log`、`tombstones`。

- 对外领域 ID 一律 UUID；本地整数 rowid 只可用于索引优化。
- 音频资产使用相对路径/内容摘要，不把绝对路径写进领域记录。
- 人物姓名不复制进每段逐字稿；显示时通过人物关系解析。
- 事件不复制会话正文；通过多对多关系和带修订号的来源引用解析。删除事件只解除组织关系，除非用户另行明确删除源记录。
- FTS 是可重建索引，不作为唯一事实来源；当前 FTS5 trigram 索引覆盖标题、来源 App/文件、逐字稿、润色/整理结果、人物 UUID/姓名/别名/稳定未知编号、事件标题/说明以及来源上下文。三字及以上查询走索引，短查询走有界 SQL fallback；人物、事件和来源上下文变更由增量 trigger 更新，索引不进入完整归档。
- schema migration 前自动创建一致性备份，并在旧格式 fixture 上做向前迁移测试。
- portable schema 16 在 schema 15 的无损外键修复基础上加入 `events`、`event_sessions`、`event_link_rejections`、`event_people`、`event_candidates`、`event_text_documents` 与可撤销 `event_edit_operations`。`events.confirmation_state` 区分自动与用户确认；人工移出、移动或拆分会留下拒绝关系，后续本地重算不得重新覆盖。导入旧 schema 12–15 归档时先验证旧表序与全部数据，再按版本补齐空的来源上下文、平台人物证据和七张事件表，最后在同一事务导入，禁止部分覆盖。
- 只有用户在生产确认框中明确选择永久删除后，才允许先把存在的 session 资产目录原子移入 staging、在单一 GRDB 事务内删除完整关系链，再提交文件删除；数据库失败必须回滚 staging。捕获若在首个 journal 创建前失败，session 可以合法地没有资产目录，此时“文件侧已经为空”不能阻止已确认的数据库删除；该例外只属于显式删除事务，不能被缓存清理、恢复扫描或磁盘压力路径复用。

### 11.3 加密

- 数据库优先验证 GRDB + SQLCipher 的完整页级加密；音频/导出暂存验证 CryptoKit AES-GCM 分块加密。
- 主密钥由 Keychain 保存，数据库与资产使用独立派生 key；日志、文件名和 manifest 仍需避免泄漏敏感标题。
- 完整 `.bestasrarchive` 不复用只能在来源 Mac 解开的本地主密钥：导出时生成独立 archive data key，再由用户归档口令/恢复秘密派生的 portable wrapping key 保护。KDF、参数和分块容器由 `SPIKE-MIG-001` 冻结。
- 归档全过程不得落地明文数据库或明文音频临时目录；bestASR 是 V1 唯一提供该格式读写 UI 的产品，但安全性依赖认证加密和用户秘密，不能依赖格式不公开。
- 必须先验证：恢复/迁移、Keychain 丢失行为、崩溃中间态、FTS 性能、XPC 访问和签名公证。
- 若加密 Spike 未通过，不得以“数据只在本机”等同于“静态数据已安全加密”。

## 12. 隐私、安全与网络

详细资产分类、信任边界、攻击/失败路径与验证映射见 [THREAT_MODEL.md](../security/THREAT_MODEL.md)。本节只列实现基线。

- 默认没有产品遥测、远程日志或自动崩溃上报；项目命令通过 `.codex/config.toml` 设置 `DO_NOT_TRACK=1`。
- 正常运行的网络出口只有用户触发/允许的模型与 App 更新，以及用户显式启用的自有设备整理链路（只经 SSH 本地端口转发访问回环地址，见文首“远程整理器”一节）。使用独立 `NetworkPolicy` allowlist；捕获和推理模块不直接持有网络客户端。
- 模型下载到可重新生成的缓存目录，核验 manifest 签名、SHA-256、字节数、许可和兼容性后原子切换到本机 Application Support 的已安装版本；保留上一已知可用版本。普通发行安装使用系统 Caches，当前开发安装把 `~/Library/Caches/com.bestasr.app` 稳定链接到 `/Volumes/BestASRBuild/bestASR/runtime-cache/com.bestasr.app`，外置盘缺失时初始化明确失败且不得回退到 Application Support 或仓库生成第二份下载缓存。
- `Logger` 的动态用户值使用 private privacy，禁止打印音频样本、完整文本、词典、声纹、窗口标题或参会者姓名。
- 诊断包先本地生成清单供用户预览，默认只含版本、状态码、耗时、资源和脱敏时间线。
- DMG 分发启用 Hardened Runtime、最小 entitlements、Developer ID 签名与公证。是否启用 App Sandbox 由捕获/AX Spike 决定；DMG 公证并不强制 App Sandbox。
- 本机 daily-use Release 使用同一 Apple Development 证书和固定 bundle identifier 签名，以保持 TCC 权限身份跨构建稳定；Release 构建结束后立即注销 Xcode 自动注册的外置构建 bundle，安装脚本拒绝 ad-hoc daily-use 包，并在外置构建盘挂载时把上一版本保存在 `/Volumes/BestASRBuild/bestASR/installation-backups`，避免构建产物或回滚副本作为第二个同名 bundle 出现在应用、自动化或 TCC 选择器中。外置盘未挂载时构建、注销与安装都 fail-closed，不会把大体积备份回退写入本机。该本机签名不替代 Developer ID、公证或公开发布门禁。
- `run_release_smoke.sh` 已验证 Release App 与嵌入式 XPC 均为 arm64、deployment minOS 14.2、Hardened Runtime、有效嵌套签名，且 App entitlement 仅为 audio input；UDZO DMG 创建与 checksum verify 通过。当前 Keychain 中没有 Developer ID Application identity，也未配置 notarytool profile，因此发布证据保持 `blocked`、`releaseEligible: false`，Gatekeeper/staple 不得标成通过。
- 只有显式设置 release-signing opt-in、Developer ID identity 与 notarytool Keychain profile 时，脚本才执行带 secure timestamp 的嵌套签名、提交、公证票据 staple 与 Gatekeeper 检查；摘要不记录身份名称或凭据。
- 对音频捕获范围、录音指示、删除影响和未来同步范围使用明确文案，不把系统权限授权解释成产品可任意使用数据。

## 13. 模型与 App 更新

- 模型 registry manifest 包含 artifact ID、用途、语言、硬件档、最小 App/OS、文件列表、摘要、总大小、来源、许可证与归因。
- 不要求最终用户拥有 Hugging Face token；发布模型必须托管在产品可直接下载、可校验的分发端点或随包提供。
- 模型激活采用双槽/版本目录，健康检查成功后以 fsync + atomic rename 更新 pointer；启动时重新验证 active 与 last-known-good，active 损坏时只回退到再次验真的上一版本，两者均损坏则进入可修复状态而不破坏用户内容。
- App 更新首选 Sparkle 2 的 EdDSA 签名更新链路，并另外保留 Apple notarization；是否自动下载默认由产品决策，检查更新不得上传内容。
- App 与模型使用不同的信任边界。模型使用固定注册表、原子 staging/active pointer、逐文件尺寸与 SHA-256、运行时健康检查及 last-known-good 回滚；说话人模型切换后会把可重建历史任务改写到新 artifact/embedding space 后重排队，保留用户确认关系、姓名和稳定人物 ID。App 只在用户允许时用无 cookie、无缓存、无凭据的 ephemeral 请求检查官方 GitHub 公开 release 元数据（仓库只在 `AppUpdateChecker.repositorySlug` 一处定义，当前为 `Yusong-Enceladus/mindloom`，只接受该仓库在 github.com 上的 release 页）；自动检查默认关闭，用户在设置中开启后才在启动时检查，手动“检查更新”随时可用；发现新版后显式交给用户打开正式发布页；正式安装包仍必须通过 Developer ID、公证、staple 和 Gatekeeper，不能把 fixture 更新探针当作生产发行信任。
- `update-rollback-summary.json` 覆盖 10 个独立场景：签名 App/模型成功切换且保留上一版本，以及 App/模型签名篡改、摘要篡改、部分下载、App 健康检查失败和版本回退。全部失败场景保持 App/模型 active pointer、历史数据和原始音频不变，并清理 staging；因此 App 包、模型 artifact 与用户数据根不得合并为同一更新事务或清理命名空间。
- 生成 SBOM/NOTICE，并在 CI 中阻止许可、摘要或来源未登记的模型进入 release manifest。
- `generate_supply_chain.sh` 从精确版本的 dependency/model registries 生成 CycloneDX 1.6 SBOM，并对 Release `.app` 内每个文件记录路径、字节数、SHA-256 与类型。Mach-O 只能来自 first-party allowlist 或 `shipped` dependency 的登记路径；模型文件必须同时匹配 ModelManager manifest 的 package path、大小和 digest。
- `validate_release_package.sh` 对冻结 manifest 执行完整文件集合与 digest 比较。当前 Release App 为 7 个登记文件、2 个 first-party Mach-O、0 个模型和 0 个第三方运行时组件；加入额外二进制/模型、修改资源或遗漏 NOTICE 均 fail closed。

## 14. 未来迁移与跨设备同步

V1 不实现在线同步，也不做云同步或多人协作；用户自有 DGX Spark 上的远程整理器只接收整理输入、返回派生结果，不是同步通道（见文首“远程整理器”一节）。但现在必须实现以下不可逆基础：

- 稳定 UUID、对象版本、创建/修改设备 ID、删除墓碑和不可变变更记录；
- 人物合并/拆分建模为操作图，而不是破坏性改主键；
- 事件创建/归入/移出/合并/拆分同样建模为可重放操作图；
- 音频使用内容摘要、相对引用和可分块资产协议；
- 派生模型输出可重新生成，默认不作为同步源事实；
- `SyncAdapter` 只读取/写入领域 change set，本地 repository 永远先提交；
- 冲突按字段定义：标题/备注可保留双版本，用户确认的人物操作优先于自动匹配，删除与恢复必须显式，逐字稿人工编辑不能被模型重算覆盖。

V1 同时交付两种本地数据出口：

- **源音频导出**：整段资产保持导入原文件或本机原始捕获格式；区间裁剪不改写源，优先保持原容器/编码，必要转码时使用无损格式并提示。
- **完整离线迁移**：`.bestasrarchive` 是版本化、带完整性校验的加密容器，包含全部可迁移用户数据和原始音频；用户持有的 archive secret 必须能在没有来源 Mac Keychain 的另一台 Mac 上恢复。

完整归档不作为云同步协议。未来同步通过 `SyncAdapter` 按 record/change set 与分块 asset 增量工作，独立处理重试、冲突、删除、配额和设备撤销。

后续优先评估 CloudKit private database + CKSyncEngine：Apple 提供本地/远端 record 同步、私有数据库、加密字段和默认加密的 CKAsset；它适合 iPhone/Mac 同 Apple ID。若产品必须使用独立登录态，则同一 `SyncAdapter` 可接产品后端。当前不提前绑定身份提供者。

建议未来默认只同步文本、用户编辑、人物名称/关系和设置；原始音频与声纹属于大体积高敏感资产，必须单独选择并完成端到端加密/密钥恢复设计。

## 15. 可观察性与故障恢复

- 用户主动“从原音重新识别”属于同一四入口管线：新文字与自动说话人后续任务须在同一 SQLite 事务中发布，不能只有 ASR 成功就遗漏人物更新。原音和旧文字版本保留，任务输入携带同一新 revision 与当前人物 pipeline 配置。已有人工确认人物的记录保留这些人工决定，不自动重新划分并覆盖它们；界面明确区分“人物已更新 / 已排队 / 保留人工确认”，不能笼统宣布全部完成。资料库切换记录会清除上一条的操作反馈，异步完成消息只能回写发起操作的当前记录。
- 每个命令、会话、音频块、作业和派生结果有 correlation ID；日志只记录 ID、状态和脱敏指标。
- durable job 状态：`queued/running/succeeded/retryableFailed/permanentFailed/cancelled`，带 lease 和幂等提交。
- `speakerFinal` 领取必须同时存在 `speaker_job_inputs` 与同一 session 的 `dictation_job_sessions` 关联；缺少或不一致的遗留/损坏任务保留为 `permanentFailed/corruptInput` 审计记录，不能因排序靠前而持续回滚事务、阻塞后续有效任务。仍在有效 lease 内的 running 任务不被抢占，过期后才按同一结构规则恢复或隔离。
- 说话人 worker 的一次 drain 对每个 job ID 最多尝试一次，并把本轮已尝试集合传给事务化 claim；单条失败后继续处理其他 session，fresh queued 优先于 retryable，失败任务只在下一次显式唤醒/启动时重试。FluidAudio `noSpeechDetected` 是确定性的无证据结果，映射为非重试 `corruptInput`；模型未加载、配置不兼容和瞬时 runtime 故障保持不同类别，不能用统一 transient 掩盖。
- App 启动执行恢复器：未封存会话、未提交块、过期 job lease、模型下载临时目录和索引版本逐项修复。
- 故障注入必须覆盖 worker crash、主进程 kill、磁盘满、权限撤销、来源退出、设备切换、模型损坏、数据库迁移中断和断网。
- 用户始终能区分“录音安全”“草稿可用”“最终处理完成”“某个派生任务失败”。

## 16. 测试与发布门槛

- 领域状态机、修订合并、人物操作、冲突规则和删除使用纯 Swift 单元/性质测试。
- 捕获、数据库、XPC、模型、插入和模型更新使用集成测试与保存 fixture。
- UI 使用 XCTest/Accessibility 标识；关键界面做浅色/深色、动态字体、VoiceOver 和多窗口快照。
- ASR/说话人/LLM 采用版本化本地语料与 [EVALUATION_PLAN.md](../quality/EVALUATION_PLAN.md)；私人音频不进 Git，只提交 manifest/hash 和聚合指标。
- 发布构建必须通过离线测试、网络出口检查、签名/公证/Gatekeeper、全新用户安装、旧数据库迁移、模型损坏回滚和 2 小时长录音。
- PRD requirement、test/probe 和 evidence 必须可追踪；仅完成 UI happy path 不能声明功能完成。
- `validate_traceability.sh` 解析 PRD ID、`TM-*` 及真实 test/evidence 路径；孤立 ID、失效路径或空证据均 fail closed。`validate_product_consistency.sh` 另外冻结四入口人物等价、纯文字/内部证据分离、口述 MVP 复用 V1、V1 无在线同步但 sync-ready（自有整理设备不是同步）、离线与录音优先（含自有设备整理的数据边界）五项跨文档/代码约束。
- `generate_engineering_readiness.sh` 不把“测试脚本成功”混同为“产品可发布”：它分别汇总 pass、fail、conditional、未决任务与外部依赖。任一失败、conditional 或待办都会保持 delivery `incomplete` 且 `releaseEligible: false`。
- 产品体验另设正式安装包门槛：必须从首次启动或稳定已安装状态连续完成 PRD 24.6，验证主窗口不冻结、口述 panel 不抢焦点、播放器/逐字稿双向同步、人物/事件纠错可撤销以及错误状态保留数据。AX 标识存在、单页截图或分散 probe 不得将该门槛改为 pass。
- 模型门槛按阶段独立选择：流式草稿、句末/最终、强制对齐、会后说话人、跨记录 embedding 和本地文本可使用不同后端。一个 alpha 后端已接入不得阻止同语料候选横评，也不得把供应商榜单写成发布结论。

## 17. 实现顺序

1. 保留已验证的捕获、AudioJournal、持久化、恢复、模型和人物/事件领域能力，先建立任务型 presentation stores 与一致的状态词汇。
2. 重构 AppShell、首次启动、权限、菜单栏、非激活口述条和今天页。
3. 统一四入口记录工作区和资料库详情，完成播放器/逐字稿/纠错/来源的一个选择与加载状态机。
4. 重构人物与事件的浏览、候选确认、纠错、撤销和回源投影。
5. 用已有 BenchCLI/语料基础完成分阶段候选横评，冻结流式、最终、对齐、说话人、embedding 与文本后端 ADR 并接入。
6. 完成整理、搜索、词典、导出、存储、恢复、断网和隐私交互。
7. 全部 P0/P1 实现结束后执行 PRD 24.6 的一个正式安装包验收，再完成最低设备、长时与发行门槛。

每一步直接从 `IMPLEMENTATION_STATUS.md` 中最接近完整用户结果的未完成 P0 推进；不以“页面完成”代替端到端证据。

## 18. 尚未冻结的实现选择

- 最终 ASR、VAD、diarization、embedding 与 LLM 模型及量化。
- XPC 是否在 V1 强制启用，以及 worker 的共享文件访问方式。
- AudioJournal 的最终块编码、块长和压缩策略。
- SQLCipher 与音频分块加密的最终组合及密钥恢复体验。
- App Sandbox 是否可在不破坏 AX 插入与 Process Tap 的前提下启用。
- 模型下载总预算、低磁盘水位与 16 GB/更高内存档位的自动运行配置。
- `.bestasrarchive` 的 KDF、加密分块、压缩、流式导入和恢复细节；交付范围本身已经冻结。

这些不是遗漏，而是明确绑定到 Spike、基准或用户决策的冻结门槛。
