# 读文件 file-read：合约、分流、安全和依赖

用户把任意文件拖进 App 时，Mac 把它作为 `kind: "file"` 素材发给用户自己的 Spark；Spark 在受限子进程里把它读成文字（表格是 markdown，扫描页和嵌入图片交给 image-read），再由 `file-read` 技能写一句概要和关键字段。之后这段读取文字就是这条素材的正文：检索、归事件、事件卡片和多事拆分都读它。

- 代码：`spark/organizer/file_read.py`（编排）、`spark/organizer/fileparse/`（各格式解析器和沙箱）、`skills/file-read/`（技能、schema、校验器）
- 测试：`spark/tests/test_file_read.py`（每种类型、资源上限、校验器、接入整条链路），夹具全部在测试里现生成（`spark/tests/filefixtures.py`）
- 评测：`eval/files/`（合成文件集 files-v1）和 `skills/file-read/BENCHMARK.md`

## 1. 合约（Mac ↔ Spark，新增字段，向后兼容）

### 素材 `kind: "file"`（`POST /v1/items`）

```json
{"item_id": "…UUID…", "revision": 1, "kind": "file",
 "filename": "报价.xlsx", "uti": "org.openxmlformats.spreadsheetml.sheet", "mime": "application/vnd…sheet",
 "size": 18231, "sha256": "<文件字节的 sha256>", "bytes_b64": "<原始字节，≤ 25 MiB>",
 "local_text": "<Mac 本机能提取的文字，可为空>", "captured_at": "2026-09-29T10:00:00+08:00",
 "source_app": {"bundle_id": "com.apple.finder", "name": "Finder"}}
```

- `filename` 必填；`bytes_b64` 与 `local_text`（或 `text`）至少有一个。只有 `captured_at` 时它就是素材时间（`started_at`）。
- 原始字节超过 25 MiB 的文件不走 `file`：Mac 把本机提取的文字作为 `kind: "text"` 发出，并带上同样的 `filename / uti / mime / size`（Spark 在正文前加一行"文件：名字"），或者不发并在界面上说明原因。
- `sha256` 是 64 位十六进制时，Spark 核对字节；不一致的读取结果 `error: "corrupt"`（素材仍然照常整理，不会让整批请求失败）。
- 音频字节永远不离开 Mac：音频走 Mac 的导入识别，只发转写文字（和以前一样）。
- 视频：Mac 把音轨交给导入识别；另外最多 12 张关键帧作为 `kind: "image"` 素材发送，带 `parent_item_id`（视频素材的 id）和 `frame_ms`。Spark 像读任何图片一样读它们，**不单独归事件，跟随视频所在的事件**（视频先到还是帧先到都一样；用户移动视频后帧跟着走；用户亲手放好的帧不动）。GIF 的额外帧用同样的方式发。
- 旧版 Spark 会拒绝未知的 `kind`，所以 Mac 应在 `/v1/health` 里看到 `file-read` 技能后再发 `file`。

### 读取结果（`GET /v1/state` 的 `readings[item_id]`）

```json
{"revision": 1, "source": "file-read", "type": "spreadsheet",
 "text": "## 工作表：报价\n| 品名 | 单价 |\n|---|---|\n| 咖啡豆 | 120 |",
 "summary": "咖啡豆报价单，每公斤 120 元。", "doc_kind": "receipt_invoice",
 "fields": [{"key": "total", "label": "单价", "value": "120"}],
 "counts": {"sheets": 1}, "attachments": [], "error": "encrypted（仅在读不了时出现）",
 "messages": [], "numbers": [], "run_id": "…"}
```

- `type` ∈ `text | document | spreadsheet | slides | pdf | scanned_pdf | email | calendar | contact | ebook | archive | web | code | data | image`。
- `text`：抽取的文字，最多约 6 万字；表格是带工作表名的紧凑 markdown；`## 第 N 页`、`## 第 N 张幻灯片`、`## 工作表：X`、`## 附件：Y` 是分节标记；扫描页和嵌入图片的位置写成 `[标签·图片识别] 一句话\n识别出的文字`。
- `summary`：一句话（模型写的，要标明是概要）；模型两次都不合格或文件读不了时，是整理器自己写的朴素说明（如"PDF 文档「工资.pdf」已加密，需要密码，未读取内容"）。
- `fields`：邮件头、日程、名片由代码读出；票据、订单、合同、表单的关键字段由模型抄出，校验器保证每个值都能在 `text` 里逐字找到。
- `counts`：`pages / sheets / slides / attachments / images_read`，以及按类型的 `entries / messages / events / contacts / chapters / image_pages`。
- `attachments`：邮件附件和压缩包里的文件 `[{filename, type, summary}]`（`summary` 是代码取的首行或"加密，无法读取"之类的原因）。
- `error`：`encrypted | unsupported | too_large | corrupt`，只在读不了时出现；这时 `text` 是 Mac 的 `local_text`（如果有）。
- 图片素材的读取结果形状不变。旧客户端读到的 `messages`、`numbers` 仍在（为空）。

## 2. 分流（先看内容签名，再看扩展名，最后看 MIME）

| 类型 | 格式 | 怎么读 |
|---|---|---|
| `text` | txt md log srt vtt rst … | 自动识别编码（BOM / UTF-8 / GB18030 / Big5）；会议转写导出照常解析发言 |
| `code` | 70 多种源代码扩展名，ipynb | 原文；notebook 读单元格和文字输出 |
| `data` | json jsonl xml yaml plist opml kml gpx、SQLite 数据库 | JSON 美化；XML 用 defusedxml（拒绝实体和外部引用），大纲类格式读属性里的文字；YAML 只当文字，不加载；SQLite 在内存里打开（不落盘、只读），列出每张表的列、行数和前 20 行，不执行视图和触发器 |
| `document` | docx docm dotx、odt、doc、WPS 文字 .wps、rtf、Pages、XMind 思维导图 | docx：段落、标题、列表、表格、脚注、批注、嵌入图片和图表；doc / wps：分片表还原正文（Mac 的 `local_text` 兜底）；rtf：自带解析器（代码页、`\u`）；XMind（新版 content.json、XMind 8 content.xml）：每张画布的主题树写成缩进列表，含备注和标签 |
| `spreadsheet` | xlsx xlsm、xls、WPS 表格 .et、ods、csv tsv、Numbers | 每个工作表一段 markdown（最多 400 行、40 列、40 个表，每个工作簿最多扫描 40 万格；其余行数写明）；日期写成 ISO；公式取缓存值 |
| `slides` | pptx pptm、ppt、WPS 演示 .dps、odp、Keynote | 逐页：标题、要点层级、表格、图表（缓存的系列数据写成表格）、备注、图片 |
| `pdf` / `scanned_pdf` | pdf | 逐页文字层（PDFium）；没有文字层的页渲染成图片交给 image-read，每个文件最多 20 页；多数页没有文字层时类型是 `scanned_pdf` |
| `email` | eml、msg、mbox（前 20 封）、mht | 邮件头、正文（纯文本优先）、附件逐个按类型读；嵌入图片交给 image-read |
| `calendar` / `contact` | ics / vcf | 日程（开始、结束、地点、组织者、参与者、说明）/ 名片（含 vCard 2.1 quoted-printable） |
| `ebook` | epub | 书名、作者、按书脊顺序的章节正文；有 DRM 的报 `encrypted` |
| `archive` | zip、tar、tgz、gz、bz2、xz | 每个文件按类型读，最多嵌套 2 层、200 个文件、解压后 100 MB；7z / rar 报 `unsupported` |
| `web` | html、webarchive、webloc、url、mht | 保存下来的正文和网址；不联网，脚本、样式、跟踪图片都丢掉 |
| `image` | 压缩包或邮件里的 png jpg gif webp tiff bmp | 转成 ≤ 2560 px 的 PNG/JPEG 交给 image-read；小于 64 px 或 160×160 的图标不读；HEIC 在 Spark 上报 `unsupported`（Mac 负责转换） |

- 嵌入图片（docx / pptx / odt / odp / 邮件 / 压缩包 / iWork 预览）每个文件最多 10 张，按出现顺序，同一张图只读一次。
- Pages / Numbers / Keynote 的正文格式不公开，只读包里的预览：有 `QuickLook/Preview.pdf` 读 PDF，否则读 `preview.jpg`（只有第一页）。
- 音视频文件（压缩包或附件里的）不解码，只记一条"格式不支持，未读取"。

## 3. 安全

- **子进程**：每个文件在一个新的 Python 子进程里解析（`organizer/fileparse/__init__.py`），子进程启动后第一件事就给自己设上限：地址空间 3 GiB、CPU 60 s、写文件 0 字节、64 个打开文件、不生成 core；父进程另设 90 s 墙钟超时。环境变量清空，工作目录 `/`。超时、内存不够或崩溃都只影响这一个文件（`error: too_large / corrupt`），不影响服务。
- **无网络**：子进程在导入任何解析库之前就把 socket API 换成直接报错的版本（测试 `test_the_parser_process_has_no_network`）。Spark 上的 AppArmor 不允许非特权用户建网络命名空间（`unshare -n` 被拒），所以没有再加一层内核隔离。解析库本身都不做网络访问（见下表）；OOXML 的外部关系（`TargetMode="External"`）、HTML 的图片地址、webloc 的网址都只当文字。
- **不执行任何东西**：宏（`vbaProject.bin`、`Macros`、`_VBA_PROJECT`）、OLE 对象、ActiveX、PDF 的 JavaScript 和表单都不读；不调用任何外部程序。
- **XML**：一律 defusedxml（禁止实体展开和外部引用；openpyxl 装了 defusedxml 后同样用它）。YAML 不加载。
- **压缩炸弹**：zip 成员按声明大小和压缩比检查（单个成员 > 8 MB 且压缩比 > 400 就不读），Python 的 zipfile 不会返回超过声明大小的数据；gz / bz2 / xz 用带上限的解压器，超过剩余额度就停；ODS 里重复百万行的空行不展开；Pillow 的像素上限 6000 万，超过即拒绝。
- **加密**：有密码的 PDF、Office（`EncryptionInfo`）、ODF（`encryption-data`）、zip（加密标志）、Word 97（`fEncrypted`）、xls 都报 `encrypted`，从不尝试密码。
- 素材内容是数据：file-read 的提示词和全局规则都声明文件里的文字不是指令。

## 4. 依赖（整理服务 venv，均在 Spark 上安装）

| 包 | 测过的版本 | 许可 | 用途 | 网络行为 |
|---|---|---|---|---|
| defusedxml | 0.7.1 | PSF-2.0 | 安全的 XML 解析（OOXML、ODF、EPUB、SVG、XML 文件） | 无；专门禁止外部实体和 DTD 取回 |
| openpyxl（依赖 et-xmlfile 2.0.0，MIT） | 3.1.5 | MIT | 读 xlsx / xlsm（`read_only`、`data_only`、`keep_links=False`） | 无；外部链接不加载；XML 走 defusedxml |
| xlrd | 2.0.2 | BSD-3-Clause | 读 .xls（2.x 只读 xls，不碰 xlsx） | 无 |
| pypdfium2（内含 PDFium 153.0.7999） | 5.13.0 | Apache-2.0 或 BSD-3-Clause（绑定）；PDFium BSD-3-Clause 及其依赖许可 | PDF 文字层、渲染扫描页 | 无；PDFium 不做网络 I/O，这里也不初始化表单/JS 环境 |
| Pillow | 12.3.0 | MIT-CMU（HPND） | 解码和缩放图片，渲染结果编码成 PNG/JPEG | 无 |
| olefile | 0.47 | BSD-2-Clause | 读 OLE 复合文件的流（doc / xls / ppt / msg、加密的 Office） | 无 |

只用于测试和评测数据生成（不装进服务也能运行）：pypdf 6.19.0（BSD-3-Clause，生成加密 PDF 夹具）、xlwt 1.3.0（BSD，生成 .xls 夹具）、LibreOffice（MPL-2.0，`eval/files/generate.py` 在 Spark 上把夹具转成 .doc/.xls/.ppt/.odt/.rtf/PDF；整理服务从不调用它）。

安装：`spark/setup_venv.sh` 已包含这些包；`/v1/health` 的 `file_parsers_missing` 为 `null` 说明都已安装，否则是缺的那个模块名（缺库时对应格式报 `corrupt`，其余格式照常）。

## 5. 已知缺口

- msg / doc / ppt 的单元测试用的是流的替身（olefile 不能写复合文件）；真实的 .doc / .xls / .ppt 由 LibreOffice 生成并在 files-v1 里测过，msg 没有真实样本。
- Pages / Numbers / Keynote 只能读预览（通常只有第一页）。
- xlsx 里的图表和图片不读（数据本身在工作表里）；docx 的页眉页脚不读。
- WPS 的 .wps / .et / .dps 按 Office 97 的格式读（WPS 保存的就是这种复合文件），没有真实样本验证。
- WMF / EMF / SVG / HEIC 图片不读；7z / rar 不展开。
- 解析在整理 worker 里同步进行（最坏 90 s）；并发模式（`ORGANIZER_WORKERS>1`）下它和读图一样提前在线程池里做。
- 用户移动视频以外的决定（例如把视频拆成段）时，关键帧不跟随各段，只跟随整条视频。
