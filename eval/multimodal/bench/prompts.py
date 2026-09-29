"""Frozen extraction prompts and JSON schemas for the mm-v1 VLM benchmark (prompt set "mm-prompt-v1").

One neutral prompt per image type, the same for every model. The type is given (the benchmark
measures reading, not routing). Written and smoke-tested on the dev split only; never edited after
looking at test results. Standard library only, so the runner can import it on a Spark node.
"""

from __future__ import annotations

PROMPT_VERSION = "mm-prompt-v1"

SYSTEM = (
    "你是一个严谨的图像文字读取器。只根据图片里实际能看到的内容填写 JSON：\n"
    "- 文字照图中原样抄写，不翻译、不改写、不补全；数字、单位、货币符号、小数位、千分位、标点都照原样。\n"
    "- 看不清或图中没有的内容填空字符串 \"\" 或空数组 []，不要猜，不要编造。\n"
    "- 图片角落的“合成数据”水印不是内容，忽略它。\n"
    "- 只输出一个紧凑的 JSON 对象（不缩进、不换行），不要解释。"
)

S = {"type": "string"}
B = {"type": "boolean"}


def obj(props: dict) -> dict:
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


def arr(items: dict) -> dict:
    return {"type": "array", "items": items}


def enum(*values: str) -> dict:
    return {"type": "string", "enum": list(values)}


TYPES: dict[str, dict] = {
    "chat_screenshot": {
        "prompt": (
            "这是一张聊天软件的截图。按从上到下的顺序输出每一条消息。\n"
            "- chat_title：顶部的会话标题（不含群人数）。is_group：是否群聊。\n"
            "- messages：每条消息 {sender, is_self, time, text, kind}：\n"
            "  - 右侧气泡是截图者本人发的：sender 写“我”（英文界面写“Me”），is_self 为 true。\n"
            "  - 左侧气泡：sender 写气泡旁显示的名字；单聊里气泡旁没有名字时写会话标题。\n"
            "  - time：这条消息上方画出来的时间标签原文（如“昨天 21:03”），没有就写 \"\"。\n"
            "  - text：消息原文。语音气泡写“[语音 N秒]”，图片写“[图片]”，文件写“[文件 文件名]”。\n"
            "  - kind：text / voice / image / file。"
        ),
        "schema": obj({
            "chat_title": S, "is_group": B,
            "messages": arr(obj({"sender": S, "is_self": B, "time": S, "text": S,
                                 "kind": enum("text", "voice", "image", "file")})),
        }),
    },
    "chart_dashboard": {
        "prompt": (
            "这是一张图表或数据看板。\n"
            "- chart_type：bar（竖向柱状）/ line（折线）/ grouped_bar（分组柱状）/ pie（饼图）/ hbar（横向柱状）/ dashboard（带 KPI 卡片的看板）。\n"
            "- title：图表标题。x_label、y_label：坐标轴标题。unit：数值单位。没有的写 \"\"。\n"
            "- kpis：KPI 卡片 [{label, value, delta}]，value、delta 照抄卡片上的文字；没有卡片就写 []。\n"
            "- series：每个数据系列 {name, points, trend}。name 是图例或系列名（没有图例时写纵轴或图中给出的指标名）；"
            "points 是 [{category, value}]，category 是该点的分类标签（横轴刻度、饼图扇区或横向柱的纵轴标签），"
            "value 照抄该点的数据标签文字。trend 是该系列沿有序横轴（时间、版本）的整体走势："
            "up / down / flat / rise_then_fall / fall_then_rise；横轴没有先后顺序（地区、部门、饼图）写 none。"
        ),
        "schema": obj({
            "chart_type": enum("bar", "line", "grouped_bar", "pie", "hbar", "dashboard"),
            "title": S, "x_label": S, "y_label": S, "unit": S,
            "kpis": arr(obj({"label": S, "value": S, "delta": S})),
            "series": arr(obj({"name": S, "points": arr(obj({"category": S, "value": S})),
                               "trend": enum("up", "down", "flat", "rise_then_fall", "fall_then_rise", "none")})),
        }),
    },
    "slide": {
        "prompt": (
            "这是一页幻灯片（导出图，或投影幕布的照片）。\n"
            "- title：标题。subtitle：副标题（没有写 \"\"）。\n"
            "- bullets：按顺序的要点 [{level, text}]，level 0 是一级要点、1 是缩进的二级要点；text 不含项目符号。\n"
            "- kpis：页面上的数字卡片 [{label, value}]，没有就写 []。\n"
            "- footer：页脚文字。page：页码原文（如“18 / 28”）。"
        ),
        "schema": obj({
            "title": S, "subtitle": S,
            "bullets": arr(obj({"level": {"type": "integer", "enum": [0, 1, 2]}, "text": S})),
            "kpis": arr(obj({"label": S, "value": S})),
            "footer": S, "page": S,
        }),
    },
    "whiteboard_handwriting": {
        "prompt": (
            "这是白板、黑板、笔记本或便利贴上的手写内容。\n"
            "- surface：whiteboard / blackboard / notebook / sticky_notes。\n"
            "- lines：按阅读顺序逐行输出 {text, struck, checked, is_title}：text 是这一行的原文（被划掉的也照抄，不含勾选框符号）；"
            "struck 表示这一行被划掉；checked 表示行首的方框打了勾；is_title 表示这是标题行。"
            "多张便利贴按从左到右、从上到下的顺序依次输出。"
        ),
        "schema": obj({
            "surface": enum("whiteboard", "blackboard", "notebook", "sticky_notes"),
            "lines": arr(obj({"text": S, "struck": B, "checked": B, "is_title": B})),
        }),
    },
    "receipt_invoice": {
        "prompt": (
            "这是一张小票、销售单或发票的照片。\n"
            "- doc_kind：receipt（小票）/ invoice（销售单、发票）。\n"
            "- merchant：开单的商家名称。buyer：客户/购买方（没有写 \"\"）。\n"
            "- date：日期，写成 YYYY-MM-DD。date_text：图上日期的原文。time：时间（没有写 \"\"）。\n"
            "- doc_no：单号或发票号原文。currency：CNY、USD 等币种代码。\n"
            "- items：商品明细 [{name, qty, unit, unit_price, amount}]，qty、unit_price、amount 照图上的数字（不带货币符号）。\n"
            "- subtotal、discount、tax、total：小计、优惠、税、合计/实付的数字（不带货币符号），图上没有的写 \"\"。\n"
            "- payment_method：支付或结算方式。total_in_words：大写金额（没有写 \"\"）。\n"
            "- lines：从上到下，图上每一行印刷文字的原文。"
        ),
        "schema": obj({
            "doc_kind": enum("receipt", "invoice"),
            "merchant": S, "buyer": S, "date": S, "date_text": S, "time": S, "doc_no": S, "currency": S,
            "items": arr(obj({"name": S, "qty": S, "unit": S, "unit_price": S, "amount": S})),
            "subtotal": S, "discount": S, "tax": S, "total": S, "payment_method": S, "total_in_words": S,
            "lines": arr(S),
        }),
    },
    "scanned_document": {
        "prompt": (
            "这是一页扫描的文档。\n"
            "- title：文档标题。\n"
            "- fields：标题下方的抬头字段 [{key, value}]（例如“发文部门：行政部”写成 key“发文部门”、value“行政部”）。\n"
            "- blocks：正文按阅读顺序分块，每块 {type, text, header, rows}：type 为 heading（小标题）/ paragraph（段落，段内折行拼成一行）/ "
            "list_item（列表项，保留编号）/ table（表格）。heading、paragraph、list_item 填 text，header 和 rows 写 []；"
            "table 的 text 写 \"\"，header 为表头各列，rows 为每一行的各个单元格。不要输出页码。"
        ),
        "schema": obj({
            "title": S,
            "fields": arr(obj({"key": S, "value": S})),
            "blocks": arr(obj({"type": enum("heading", "paragraph", "list_item", "table"), "text": S,
                               "header": arr(S), "rows": arr(arr(S))})),
        }),
    },
    "form_label_sign": {
        "prompt": (
            "这是一张标签、面单、铭牌、价签、门牌、营业时间牌、报修单或库位标签的照片。\n"
            "- label_kind：shipping_label（快递面单）/ nameplate（设备铭牌）/ price_tag（价签）/ room_sign（会议室门牌）/ "
            "hours_sign（营业时间牌）/ repair_form（报修单）/ bin_label（库位标签）。\n"
            "- fields：每个字段 {key, label, value}：label 是图上印的字段名原文（没有字段名写 \"\"），value 是字段值的原文。"
            "key 从下面的英文名里选（都不合适时自拟小写英文名）：\n"
            "  shipping_label：carrier, tracking_no, recipient, recipient_phone, recipient_address, sender, sender_phone, sender_address, goods, weight, pieces, date\n"
            "  nameplate：product, model, voltage, frequency, power, capacity, ip_rating, serial_no, manufacture_date, manufacturer\n"
            "  price_tag：product, spec, origin, unit_price, original_price, price, barcode\n"
            "  room_sign：room, capacity, equipment, contact_ext\n"
            "  hours_sign：shop, weekday_hours, weekend_hours, parking_limit, parking_fee\n"
            "  repair_form：reporter, room, phone, issue, visit_time, emergency_contact\n"
            "  bin_label：location, item, sku, quantity, lot, expiry\n"
            "- lines：按阅读顺序，图上每一行文字的原文。"
        ),
        "schema": obj({
            "label_kind": enum("shipping_label", "nameplate", "price_tag", "room_sign", "hours_sign", "repair_form", "bin_label"),
            "fields": arr(obj({"key": S, "label": S, "value": S})),
            "lines": arr(S),
        }),
    },
}


def messages_for(image_type: str, data_uri: str) -> list[dict]:
    spec = TYPES[image_type]
    return [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": data_uri}},
            {"type": "text", "text": spec["prompt"]},
        ]},
    ]


def schema_for(image_type: str) -> dict:
    return TYPES[image_type]["schema"]
