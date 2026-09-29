# files-v1：读文件评测集（合成数据）

给 file-read 打分用的 60 个虚构文件：20 个模板（通知 docx、会议纪要 .doc、租赁合同 .odt、发票 PDF、预订确认 .rtf、扫描 PDF、报销 xlsx、预算 .xls、库存 csv、路线图 pptx、培训 .ppt、带附件的邮件 eml、日程 ics、名片 vcf、网页 webarchive、资料 zip、笔记 md、电子书 epub、Keynote 预览、加密 PDF）× 3 个变体。所有人名、公司、单号、金额都是编的；文件里的图片来自 `eval/multimodal`（mm-v1）同一划分的合成图。

- 划分：每个模板的变体 a 是 **dev**（20 个），b、c 是 **test**（40 个）。只在 dev 上调提示词、代码和金标准写法；test 只用来报告数字。
- `generate.py`：生成器（在装有 LibreOffice 的 Spark 上跑；Office 文件用 `spark/tests/filefixtures.py` 写出，旧格式、ODF、RTF 和 PDF 由 LibreOffice 转换；LibreOffice 只用于造数据，整理器从不调用它）。
- `data/`、`gold/`、`manifest.json`：这次评测用的文件和金标准（`type`、`error`、`must_contain`、`must_contain_image`、`summary_groups`、`fields`、`det_fields`）。
- `run_files.py`：把每个文件送进整理器的真实路径（`organizer.file_read.read_file`）并计分；`--parse-only` 不调模型，`--condition bare` 去掉技能正文，`--rescore` 用当前金标准重算已保存的记录。
- `results/`：各次运行的逐文件记录和汇总；结论见 `skills/file-read/BENCHMARK.md`。
