# 多格式文件读取评测集（合成）

用来评“用户丢进来的任何文件能不能读对、能不能归到对的事件里”。165 个文件，33 种格式各 5 个，595 道带金标准的问答；另有一个 50 条素材的多格式场景（6 件事）。**全部内容都是虚构的**：人名、公司、编号、金额都是编的，邮箱只用 `example.com/org/net`，电话只用 555 号段；文件里读者看得到的地方有“合成数据”标记。生成过程没有调用任何模型。

| | 数量 |
|---|---|
| 文件 | 165（33 种 × 5），5.7 MB |
| 语言 | 中文 141，英文 24 |
| 问答 | 595（contains 288 / number 258 / exact 49；其中 12 道是数数类 `derived`） |
| 文本层 | full 96（可直接抽文字）/ partial 19（部分内容只在图里）/ none 50（纯图、扫描、视频、动图） |
| 切分 | dev 50 / test 115（30/70，按格式分层；场景文件随所属事件） |

## 目录

- `corpus/<type>/<id>.<ext>`：原文件。`pdf_scanned` 目录里是扩展名为 `.pdf` 的纯图片扫描件。
- `truth/<type>/<id>.json`：金标准，每个文件一份。
- `manifest.json`：所有文件的清单（类型、路径、切分、文本层、所属场景条目）。
- `scenario-multiformat/`：`scenario.json`（全部 50 条）、`scenario.dev.json`（16 条）、`scenario.test.json`（34 条）。
- `tools/`：`build.py` 生成全部内容，`verify.py` 做无模型校验，`score.py` 打分，`extract.py` 是纯 Python/系统工具的抽取器。

## 每种格式考什么

| 格式 | 刻意放进去的难点 |
|---|---|
| txt | UTF-8、UTF-8 BOM、CRLF、GB18030 |
| md | front matter、任务清单、表格 |
| rtf / doc | 由 macOS `textutil` 生成（doc 是 docx 转的 Word 97 文件），中文是转义字符 |
| html / webarchive | 导航与页脚噪声；webarchive 是 Safari 二进制 plist，带一个 PNG 子资源 |
| csv | 逗号、分号、制表符分隔；GB18030；首行是标题/注释行 |
| json / xml | 嵌套结构、命名空间、RSS、属性里的数值 |
| docx / odt | 页眉页脚、表格、列表 |
| xlsx / ods | 每个至少 2 个工作表；合并的标题行和分组表头、纵向合并单元格；公式都带缓存值（含跨表引用），读缓存值即可 |
| pptx / odp | 文字页 + 整页图片页（答案只在图里），演讲者备注 |
| pdf | 有文本层（嵌入子集字体），表格；论文草稿两页、表在第 2 页；没有 Info 元数据 |
| pdf_scanned | 纯图片页：灰度、倾斜、噪点、公章，没有文本层；采购合同两页 |
| epub | EPUB 3，多章节、表格 |
| eml | 附件（PDF、docx、txt、xlsx、CSV）、base64 / quoted-printable 正文、纯 HTML 正文 + 内嵌图片、multipart/alternative |
| mbox | 2–5 封的邮件线程，含 GBK 编码的邮件 |
| ics | 时区 TZID、RRULE 重复、全天事件、提醒、参会人 |
| vcf | vCard 3.0 / 4.0，以及旧安卓导出的 2.1 quoted-printable |
| zip | 文件夹结构、图片成员、一个嵌套的 zip |
| png / webp / bmp | 图表、应用截图、表格、标签；bmp 是 8 位调色板 |
| jpg / heic | 手机拍的纸面（倾斜、阴影、暖光）；heic 由 `sips` 转出 |
| gif | 3 帧动图，每帧文字不同，只看首帧会答错 |
| tiff | 多页扫描件、1 位传真（Group 4） |
| svg | 文字在 `<text>` 元素里：海报、柱状图、组织架构、座位表 |
| mp4 / mov | 幻灯片录屏（H.264）；mp4 无音轨，部分 mov 带静音 AAC 音轨 |

## 金标准（truth JSON）

```
file_id, path, type, ext, mime, filename（用户看到的文件名）, lang, split, synthetic,
scenario: {item_id, ref, events} | null,
text_layer: full | partial | none,
text: 文件的全部可读内容（图里画出来的字也在内）,
key_lines: 含答案或关键数字的行, picture_only_lines: 其中只在图里的行,
key_fields, numbers: [{value, label}],
qa: [{id, q, a, match: exact|contains|number, accept?, tol?, derived?}],
structure: 格式相关的事实（工作表、图片页、帧数、时长、附件、zip 成员……）,
notes, bytes, sha256
```

`build.py` 会检查每道非 `derived` 的问答都能在 `text` 里找到答案（数字按千分位、百分比等写法匹配），找不到就拒绝生成。

## 生成与校验

在 macOS 上（需要 `textutil`、`sips`、`plutil`），用装了依赖的 Python（用 3.12 验证过）：

```bash
pip install pillow python-docx openpyxl python-pptx odfpy pymupdf fonttools imageio-ffmpeg jsonschema
python eval/files-multiformat/tools/build.py     # 重建 corpus/ truth/ manifest.json scenario-multiformat/
python eval/files-multiformat/tools/verify.py    # 无模型校验，失败时退出码 1
```

`verify.py` 检查：每个有文本层的文件用普通解析器（openpyxl、odfpy、python-pptx、PyMuPDF、email、zipfile、plistlib、textutil 等）抽出来的文字里能找到全部 key_lines；扫描件确实没有文本层；工作表数、合并单元格、公式缓存值；pptx/odp 的图片页编号；GIF 3 帧互不相同；视频时长与音轨；HEIC、TIFF 页数；zip 成员与嵌套；邮件附件；EPUB 的 mimetype 位置；webarchive 能过 `plutil -lint`；sha256；三个场景文件符合 `eval/schema/scenario.schema.json`。图片、扫描件、视频里的字没有做 OCR 核对，它们的金标准就是画上去的字符串。

重建的内容是确定的（固定随机种子）：再建一次，金标准、场景文件和 123 个文件逐字节相同；docx、pptx、odt、ods、odp、pdf、eml 和含这些格式的 zip 会因为打包时间、PDF 文件 ID、邮件分隔符不同而字节不同，读出的内容不变（`verify.py` 按内容校验，sha256 记录的是提交的这一版）。

## 打分

```bash
python eval/files-multiformat/tools/score.py --questions --split dev > /tmp/q.jsonl    # 给读取器的问题（不含答案）
# 读取器每个文件输出一行：{"file_id": "pptx-01", "answers": {"q1": "..."}, "text": "可选：完整读出的文字"}
python eval/files-multiformat/tools/score.py --pred /tmp/pred.jsonl --split dev --out /tmp/score.json
```

- `exact`：金标准字符串（或 `accept` 里的写法）作为完整词出现在回答里；`contains`：出现即可（统一做 NFKC、小写、去空格和标点）；`number`：回答里有一个数等于金标准（`tol` 为绝对误差；“96.2%” 同时算 96.2 和 0.962，“3.6万” 算 36000）。
- 给了 `text` 时另报 key_lines 召回和数字召回；结果按 full / partial / none 分开报，纯图片内容和有文本层的内容不要混成一个数。
- 只在 dev 上调提示词和流程；test 只评一次。

## 多格式场景

`scenario-multiformat/scenario.json` 用仓库原有的场景格式：一周（2026-10-12 至 10-17）的实验室素材，43 个文件（覆盖全部 33 种格式）+ 7 条聊天粘贴，分属 6 件事：LoomNet 论文投稿、GPU 服务器采购、硕士开题答辩、澄川科技横向项目、Elena Park 来访讲座、数芽标注外包；另有 3 条噪声（食堂菜单、健身课表、快递短信）。有 1 条跨两件事的素材（组会 PPT），22 条事实（含被更新取代的旧事实，如答辩改期、航班延误、准确率刷新），2 个检查点。

文件条目新增四个字段（已加进 `eval/schema/scenario.schema.json`，都是可选的）：`file`（相对场景目录的原文件路径）、`mime_type`、`file_truth`（金标准路径）和 `file_text`（金标准文字，供 `eval/score.py` 核对卡片说法是否有出处）；后两个只用于打分，不发送。`eval/score.py` 的场景校验也已接受带 `file` 的 document/image 条目，三个场景文件校验 0 错误 0 警告。`eval/tools/to_items.py` 按整理器的文件协议发送这类条目：PNG/JPEG 图片仍是 `kind=image`（`image_b64`），其他文件改成 `kind=file`，带 `filename`、`mime`、`size`、`bytes_b64`（原文件字节），由 Spark 上的 file-read 读取。`--file-text gold` 则保留原 kind、不发字节，把金标准文字放进 `text`，跑一个“读取完全正确”时的上限，报告时必须标明是上限：

```bash
python eval/tools/to_items.py eval/files-multiformat/scenario-multiformat/scenario.dev.json -o /tmp/files-dev-items.jsonl
python eval/tools/to_items.py eval/files-multiformat/scenario-multiformat/scenario.dev.json --file-text gold -o /tmp/files-dev-oracle.jsonl
```

按事件切分：讲座、标注外包两件事和食堂菜单是 dev（`scenario.dev.json`），其余四件事是 test（`scenario.test.json`）。整份 `scenario.json` 含 test 素材，标为 holdout，不能拿来调提示词。

## 已知限制

- 渲染用 macOS 自带字体（冬青黑体、Arial Unicode）；在别的系统上重建，图片的字节会不同，金标准不变。
- 公开导出的敏感信息检查（`tools/public_export/gate.py`）会按类型拦下 heic、tiff、gif（这些文件由程序生成、没有拍摄元数据）；公开导出时需要为 `eval/files-multiformat/corpus/{heic,tiff,gif}` 加例外或排除。PDF 已去掉 Info 元数据，邮箱都是 example 域名。
- 问答是抽取式的（找得到的事实、数字和少量数数），不考跨文件推理；跨文件归属由多格式场景考。
