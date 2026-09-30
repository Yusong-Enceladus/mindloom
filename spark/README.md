# Spark 端整理服务（织机）

把来自口述、会议转写、用户粘贴的文字、文档和截图整理成具体事件：这件事是什么、现在到哪一步、有哪些人参与、结论来自哪条原始素材。采集和回放由 Mac 客户端负责，整理在用户拥有的 DGX Spark 上运行。当前仓库包含整理服务、五个核心 Agent Skills、一个只读 recall 占位实现，以及完全虚构的评测数据。Mac 客户端在本仓库的 `mac/` 目录。以下命令除特别说明外都在仓库根目录执行。

我们希望解决的不是“又多了一份会议摘要”，而是信息散落在多个来源之后，人很难追踪同一件事的变化。例如，店主在会议里确认上线日期，在聊天截图里修改预算，又在一次口述中决定先交付点单功能、推迟支付功能。整理器应把这些素材串到同一个事件，保留来龙去脉，同时不把同一位店主谈到的聚餐安排混进来。最新状态应体现已经确认的变化，不把早期预算当作当前约定，也不能把计划写成已经完成。

模型的输出是建议，用户的修改优先。系统支持改名、移动和移除素材、合并或区分事件、命名和区分人物、置顶和减少展示，并为模型整理与人工决定保存记录。素材按修订号追加保存，重复传输不会重复创建记录。模型生成摘要期间，如果用户改变素材归属或上传新修订，旧结果会被丢弃并重新整理，避免把用户刚纠正的内容写回来。引用标识和结构化输出由程序校验，但引用存在不等于事实完全正确，因此仍需要真实模型评测和人工审阅。

项目采用确定性的任务路由：读截图、读文件、切分多事素材、归事件、写事件简介、首页排序各使用一个独立 Skill。它没有内置聊天 Agent，也没有让模型自主调用任意系统工具。素材中的命令式文字始终是待整理的数据。recall 是只读的关键词检索入口，目前不是完整的语义问答产品。声音、声纹和词典的 Mac 端边界需要在 Mac 仓库中另行验证；这个服务只接收协议规定的文字、图片、来源和人物标识，不接收原始音频。

## 当前交付范围

- 后端：Python 3.12、FastAPI、SQLite、单后台 worker。
- 本地模型：兼容 `/v1/chat/completions` 的服务；真实验收优先复用 Spark 上现有 Qwen。
- 检索：兼容 `/v1/embeddings` 的本地服务；不可用时退化为时间、人物和来源检索，健康信息明确显示退化模式。
- Skills：`event-assign`、`event-brief`、`home-rank`、`image-read`、`item-split`、`file-read`；`recall` 为 P1 占位。
- 网络：默认仅监听回环地址，通过 SSH 隧道访问。不要直接把服务绑定到局域网或公网。
- 链路令牌：首次启动时在数据目录生成 `link_token`（64 位十六进制，权限 0600，重启不变）。文件存在时所有请求都要带 `Authorization: Bearer <令牌>`，否则返回 401；仅测试和评测可用 `ORGANIZER_REQUIRE_TOKEN=0` 关闭。Mac 只通过已认证的 SSH 单独执行 `cat` 读取令牌，只保存在内存或钥匙串。
- 存储标识：`/v1/health` 和 `/v1/state` 返回 `store_id`，数据库新建时生成一次；它变化说明 Spark 端被重置，Mac 应清空投影和游标并重传已送达素材的最新修订。
- 素材修订：同一 `item_id`（也接受 `id`）同一修订号是重复；更高修订号替换当前内容并重新整理（模型归类的重新判断，用户归类的保持不动）；更低修订号视为过期并忽略，均计入 `duplicates`。
- 云端：整理链路不需要云模型 API；安装依赖、下载模型是独立的准备步骤。
- 归事件：模型先写出素材说的**具体对象**、它是不是一件事，再对最可能的候选逐个判断"是不是同一个对象"；动作由程序按这些判断推出（`skills/event-assign/scripts/decide.py`）：唯一同一对象才归入，拿不准就提问（先放进自己的新事件，绝不先归入），不是事（闲聊、群发通知、通用知识问答、指令样文字）就留在"未归档"。每个事件有一个固定的对象 `anchor`（由第一条素材定下，简介不会改写它），候选同时展示最早一条和最近两条素材；机主本人从不算"共同人物"。
- 未归档：`/v1/state` 新增 `unfiled`（当前完整列表，`[{item_id, reason, since}]`），事件新增 `handle`（E 编号）和 `anchor`，均为新增字段。用户"这条不属于这个事件"（`remove_item`）后，素材不再变成单条事件，而是进未归档，出现匹配的事件时会被重新判断（最多两次）；新决定 `unfile_item` 把素材移出事件并保持未归档（模型正在判断的归类不会覆盖它），`move_item` 把它归入已有事件，`file_item_new_event {item_id, new_event_id?}` 把它单独建成一个事件（`new_event_id` 可由 Mac 预先生成 UUID）。
- 读图结果：`/v1/state` 新增 `readings`（按 `item_id`，含来源修订号 `revision`、只含读到文字的 `text`、`messages`，以及单独的一句摘要 `summary`），和事件一样按游标增量返回，只给素材当前修订的结果；Mac 用它显示和导出截图里的文字，摘要要标明是读图概要。
- 人物：除了声音里的人和截图里的发送人，粘贴的聊天文字里"名：…"行和"名 10:05"署名也会成为人物（与截图发送人同一套 id）。本人（"我"及 `ORGANIZER_OWNER_ALIASES` 里的名字）不算人物；近似的名字只提"是不是同一个人"，不自动合并。粘贴文字里的人名只用于人物页、简介和状态，不参与归事件的检索和判断（那是素材自己的原话，同一个人也常同时在办两件事）。
- 提问预算：`same_event` 与 `same_person` 各自最多 2 个待答；`same_event` 每个素材日期最多 2 个、对同一事件每天最多 1 个；72 小时未答自动过期（按整理器时钟），先前的临时归属保留。
- 简介：状态行是首页卡片上的一行（显示宽度 ≤ 24，中文字算 1、英文数字算 0.5，目标 18），先写现在的状态或下一个有日期的步骤，过长时只保留放得下的前几个分句；事实文字不再重复 `date` 字段里的日期。首页排序在模型打分后加一条规则：7 天内有未办待办的事件不会排在什么都没剩的事件后面。每条事实带进度状态（计划/进行中/已完成/取消/信息）和日期；标"已完成"必须摘录素材原话，校验器拒绝没有原话支持的"已…"和相对日期（今天/明天/下周…；素材自己说了"下周"且那一周相对 as_of 仍是下一周时容许）；只说定下来的话（"那就这么定"）只能证明"已决定"，不能证明已签、已付、已发货。状态和事实里的每个日期都必须能在所引素材里找到："下周""月底""N 个工作日"由 `skills/event-brief/scripts/dates.py` 换算成范围，不能从范围里挑一天写死，两次都不合格时只删掉那个日期。简介只看本事件最新素材的时间 `as_of`，不看现在的时间；两次都不合格时只采用单独合格的部分。
- 时钟：`ORGANIZER_CLOCK=wall`（默认）| `replay`（回放历史素材时以最新素材时间为"现在"，评测使用；重启后从已处理的最新素材时间继续）| `fixed:<ISO>`；`/v1/health` 返回 `clock`。模型看到的事件和素材一律用短编号（E3、I17），不出现 UUID。
  **历史素材流、补录、规模回放必须用 `replay`**：用 `wall` 时提问的 72 小时过期按墙上时间永远到不了，开头问出的 2 个问题会一直占满预算，之后所有"拿不准"都变成临时新事件、所有"合并这两个事件？"都被丢掉，人物也不再提问；首页排序的"今天"也会变成真实今天。只有 Mac 实时发送的新素材才用 `wall`。墙上时钟遇到两天前采集的素材时，`/v1/health` 的 `clock_warning` 会提示。
- 会议转写导出（2026-09-28 新增）：文字素材若是腾讯会议（`名字(HH:MM:SS):` 一行、下面是发言段落）、飞书（`名字 HH:MM:SS` 一行）、Zoom（`[HH:MM:SS] 名字: 内容`）或带说话人的 VTT/SRT 导出，就按发言解析成 `turns [{speaker, t, text, start, end}]`（`spark/organizer/transcripts.py`；Mac 的 `MemoryTranscriptText` 规则相同，两端都用 `spark/tests/fixtures/transcript_formats.json` 里的用例逐字检查发言和字符偏移，偏移按 Unicode 标量计，CRLF 算 2）。发言人成为人物（`origin: "transcript"`），名字可以是"中文名 English NAME"，走同一条近似名字 `same_person` 提问路径；机主（任一部分命中 `ORGANIZER_OWNER_ALIASES`）和"说话人1"这类通用标签不算人物。
- 一条素材里有几件事（新增 Skill `item-split`）：会议转写、长口述/笔记、脑暴清单先过便宜的预筛（≥90 字且至少 3 个单元），再由 `item-split` 按发言/句子切成几段，每段单独归事件（归入/新建/未归档/提问）；只讲一件事的不切。`/v1/state` 的事件新增 `segments: [{item_id, seg_id, start, end, gist}]`（`start`/`end` 是素材文字里的字符位置，会议转写按发言对齐；`item_ids` 仍是去重后的素材 id），未归档新增可选的 `seg_id/start/end/gist`，问题新增 `a_seg_id`/`b_seg_id`，事实新增 `segment_refs`。决定 `remove_item`/`move_item`/`unfile_item`/`file_item_new_event` 可带 `seg_id` 只动那一段；不带时作用于该素材的所有段。素材新修订会重新切分、重新归类（用户放好的段不动），同一修订重试不会重复切分。内部每段是一条子素材，子素材 id 不会出现在接口里。
- 切分更严（item-split 1.2.0，2026-09-29）：同一件事的子任务、方面、步骤不再单独切出来；只有至少两件"实质的事"（≥2 个单元或 ≥12 个字）才切；会议里夹着的闲聊可以标成 `matter: 0`，这一段直接留在"未归档"（`reason: "none"`），不调用归事件。
- 简介不再为证据和日期错误重问（2026-09-29）：简介只因"已完成没有原话支持""日期查不到来源""相对日期""过长"不合格时，不再调第二次模型，而是由校验器的修补直接删掉那个日期、把没有原话的"已完成"改成计划或信息（文字本身说已完成的就删掉）；修补后若连一条事实或状态行都不剩，仍照旧重问一次。格式错误、JSON 和 schema 错误照旧重问。
- 手机入口（新增）：`POST /v1/inbox`（令牌）收 `{source, kind: text|image, text?, image_b64?, received_at}`，`GET /v1/inbox?since=游标` 和 `POST /v1/inbox/{id}/ack` 给 Mac 取走、确认；确认后 Spark 删除正文。Spark 上的 `spark/zhiji-inbox add --source iPhone [--image 文件|-]` 从 stdin 读文字，供 iOS 快捷指令"通过 SSH 运行脚本"调用；`zhiji-inbox gate` 可作为 SSH 密钥的强制命令。设置方法和手机键盘设计见 `docs/PHONE.md`。
- 吞吐（新增）：`ORGANIZER_WORKERS=N`（默认 1 = 原来的逐条串行）让模型调用在有界线程池上并发：排队素材的读图、切分、向量提前做；归事件仍按队列顺序逐条进行；事件简介和首页排序在固定的滞后（`ORGANIZER_PIPELINE_LAG`，默认 2 条）后生效，所以结果只取决于队列顺序、与线程快慢和池大小无关（`spark/organizer/pipeline.py`）。
- 规模（新增）：候选检索仍是全部事件上的 top-k，但每个事件的检索特征按版本缓存，上千条素材时不再每条重算所有向量；首页排序只让模型给一个短名单打分（置顶、7 天内有待办的、最近更新的，最多 `rank_max_events` 个），其余按最近更新时间给不超过 0.3 的分数；提问预算不变。
- 读文件（新增 Skill `file-read`，2026-09-29）：新素材类型 `kind: "file"`（`filename / uti / mime / size / sha256 / bytes_b64（≤ 25 MiB）/ local_text / captured_at`）。Spark 在有 CPU、内存、时间上限且禁用网络的子进程里按内容签名分流解析：Word / Excel / PowerPoint（含 97–2003 旧格式和 WPS 的 .wps / .et / .dps）、OpenDocument、XMind 思维导图、SQLite、PDF（没有文字层的页交给 image-read，≤ 20 页）、邮件（eml / msg / mbox）及其附件、ics、vcf、epub、zip / tar / gz（≤ 2 层、200 个文件、100 MB）、网页存档、文本 / 代码 / 数据文件、Pages / Numbers / Keynote 的预览；文档里的图片交给 image-read（≤ 10 张）。`file-read` 写一句概要和票据类文档的关键字段，校验器要求概要里的数字和字段值都能在文字里找到。`/v1/state` 的 `readings` 对文件给出 `{type, text, summary, fields, counts, attachments, error?, source: "file-read"}`；之后归事件、卡片、拆分读的就是这段文字。视频关键帧作为带 `parent_item_id` 的图片素材发送，跟随视频所在的事件。合约、分流表、安全措施和新依赖（许可、网络行为）见 `docs/FILE_READ.md`，评测见 `skills/file-read/BENCHMARK.md`。
- 时区：素材自带的非 UTC 偏移就是用户的本地时间；UTC（`Z`）时间按 `ORGANIZER_TZ`（IANA 名称，默认 Spark 本机时区）换算后再算日期、"今天/明天"和每日提问预算。Mac 应发送本地偏移。

## 开始运行

先准备自己的本地聊天和向量服务，再在仓库根目录执行：

```bash
python3 -m venv .venv
.venv/bin/pip install -e './spark[test]' pillow
mkdir -p "$HOME/memory-demo-data" && chmod 700 "$HOME/memory-demo-data"
cd spark
ORGANIZER_DATA_DIR="$HOME/memory-demo-data" \
ORGANIZER_LLM_URL=http://127.0.0.1:8000/v1 \
ORGANIZER_EMBED_URL=http://127.0.0.1:8002/v1 \
../.venv/bin/python -m organizer
```

客户端示例（把 `YOUR_SPARK` 替换为自己的 SSH 主机别名）：

令牌在 `<ORGANIZER_DATA_DIR>/link_token`；下面沿用上面启动示例的 `$HOME/memory-demo-data`。

服务默认只在私有 Unix 套接字 `<数据目录>/organizer.sock` 上提供接口（可用 `ORGANIZER_UDS` 改路径），数据目录必须是 0700。SSH 转发到这个套接字（把 `/home/YOU` 换成 Spark 上的家目录绝对路径）：

```bash
ssh -N -L 127.0.0.1:18765:/home/YOU/memory-demo-data/organizer.sock YOUR_SPARK
TOKEN=$(ssh YOUR_SPARK cat memory-demo-data/link_token)
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl --fail -H @- http://127.0.0.1:18765/v1/health
```

在 Spark 本机上直接用套接字：`curl --unix-socket <数据目录>/organizer.sock http://organizer/v1/health`（`spark/ctl.sh status` 就是这样做的）。Mac 应用同样转发到这个套接字（`-L 127.0.0.1:<随机端口>:<套接字绝对路径>`）。只有显式设置 `ORGANIZER_TCP=1` 时服务才另外监听 `127.0.0.1:<ORGANIZER_PORT>`：回环端口在服务停机时可以被本机任何用户占用，向它发送令牌就等于把令牌交给对方，所以仓库里的工具都不用它。

服务健康中的 `ok` 检查模型目录是否可访问，不能代替真实生成验收。`retrieval_mode` 显示向量检索是否可用。

如果专门测试已有的 Step3-VL + llama.cpp 服务，可显式设置 `ORGANIZER_CHAT_BACKEND=step3-llama-native`，并把 `ORGANIZER_LLM_URL` 指到该服务的本地 `/v1` 地址。此适配用于其始终打开思考块的模板，不能作为其他模型的通用替代。默认仍使用 OpenAI 兼容路径；完整应用验收目前基于 Qwen。

## 测试和评测

```bash
cd spark
../.venv/bin/python -m pytest -q
cd ..
.venv/bin/python eval/score.py --gold eval/scenarios/dev-week-v1/scenario.json --validate
.venv/bin/python eval/run_eval_overnight.py eval/scenarios/dev-week-v1/scenario.json \
  --out /tmp/memory-eval-new-run --embed-url http://127.0.0.1:8002/v1
```

`eval/run_eval_overnight.py` 是 2026-09-26 夜间评测（当时的内部报告，未公开）所用的驱动；`eval/run_eval.py` 是各 Skill `BENCHMARK.md` 所用的驱动（`--condition skills|bare|baseline`），用法见其文件头。评测目录必须不存在。每次运行使用独立数据库，黄金标签只用于事后评分，不传给模型。`--mode without-skills` 保持模型、输入、检索、schema 和校验器一致，仅移除技能说明，用来测量说明文本的影响；它不是纯向量基线。`eval/smoke_api.py` 会向**空的演示实例**写入四条虚构素材，验证归类、更新状态、重传和人工修改，不应用于个人数据库。

## 诚实标注

Mac 端原有工作从 7 月开始；黑客松新增或完善的是 Spark 整理链路、Skills 和相应评测。代码来源、线上新增改动和本次接手修复应分开记录。服务可启动、模拟测试通过、真实模型评测通过、Mac 全链路完成，是不同的验收阶段。准确进度见各 Skill 的 `BENCHMARK.md` 和 `docs/EVALUATION.md`，尚未完成的功能不放进演示成功清单。
