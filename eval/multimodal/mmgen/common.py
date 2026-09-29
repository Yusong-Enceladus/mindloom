"""Shared pools and helpers. Every name, shop, address and number here is invented."""

from __future__ import annotations

import datetime as dt
import random
import re

from PIL import ImageDraw

ZH_NAMES = ["周婷", "赵磊", "孙悦", "吴昊", "郑楠", "何静", "高远", "林欣", "许诺", "韩梅", "冯晨", "邓一凡",
            "罗佳宁", "谢雨桐", "宋柯", "唐宁", "曹静怡", "袁野", "蒋南", "沈乔"]
# visually or phonetically close pairs: the hard case is keeping them apart
SIMILAR_ZH = [("王晓林", "王晓琳"), ("李明", "李鸣"), ("陈思远", "陈思源"), ("张一帆", "张亦凡"), ("刘佳", "刘嘉")]
EN_NAMES = ["Priya Nair", "Tom Becker", "Julia Park", "Sam Ortiz", "Lena Hoffmann", "Diego Ramos", "Mia Chen",
            "Noah Grant", "Ella Moore", "Ravi Shah"]
SIMILAR_EN = [("Chen Wei", "Chen Wen"), ("Anna Li", "Anna Lu"), ("Mark Olsen", "Mark Olson")]

ZH_SHOPS = ["青禾便利店", "南巷咖啡", "拾光面馆", "小满烘焙坊", "禾木生鲜超市", "北窗文具", "一隅花店", "橙石五金",
            "半亩农场直营店", "知白书店", "鹿野咖啡", "云杉家居"]
EN_SHOPS = ["Maple & Pine Grocery", "Harborlane Coffee Co.", "Bluewren Hardware", "Riverside Stationery",
            "Copperleaf Bakery", "Northfield Books"]
ZH_COMPANIES = ["示例科技有限公司", "青岚设计工作室", "穗禾里食品有限公司", "溪远物流有限公司", "拾光文化传媒", "云岭电器有限公司"]
EN_COMPANIES = ["Northwind Labs Ltd.", "Bluecove Design Studio", "Fernhollow Foods Inc.", "Tallpine Logistics LLC"]
ZH_CITIES = ["云岭市", "江枫市", "青川市", "溪桥市"]
ZH_DISTRICTS = ["东湖区", "桂香区", "白石区", "临溪区"]
ZH_ROADS = ["杉木路", "桂香路", "望湖街", "青石巷", "梧桐大道", "云栖路"]
EN_STREETS = ["Birch Lane", "Harbor Street", "Maple Avenue", "Orchard Road"]
EN_TOWNS = ["Fairview", "Lakeside", "Millbrook", "Stonebridge"]

WEEKDAYS_ZH = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
WEEKDAYS_EN = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def rdate(rng: random.Random, start=dt.date(2026, 8, 3), days=80) -> dt.date:
    return start + dt.timedelta(days=rng.randrange(days))


def money(x: float, decimals: int = 2, comma: bool = True) -> str:
    return f"{x:,.{decimals}f}" if comma else f"{x:.{decimals}f}"


def cjk_upper(amount: float) -> str:
    """人民币大写 (e.g. 1280.50 -> 壹仟贰佰捌拾元伍角整)."""
    digits = "零壹贰叁肆伍陆柒捌玖"
    units = ["", "拾", "佰", "仟"]
    big = ["", "万", "亿"]
    fen_total = int(round(amount * 100))
    yuan, jiao, fen = fen_total // 100, fen_total // 10 % 10, fen_total % 10
    s = ""
    if yuan == 0:
        s = "零"
    else:
        groups = []
        while yuan:
            groups.append(yuan % 10000)
            yuan //= 10000
        parts = []
        for gi in range(len(groups) - 1, -1, -1):
            g = groups[gi]
            if g == 0:
                if parts and not parts[-1].endswith("零"):
                    parts.append("零")
                continue
            gs = ""
            zero = False
            for ui in range(3, -1, -1):
                dgt = g // (10 ** ui) % 10
                if dgt == 0:
                    zero = bool(gs)
                else:
                    if zero:
                        gs += "零"
                        zero = False
                    gs += digits[dgt] + units[ui]
            if parts and g < 1000 and not parts[-1].endswith("零"):
                gs = "零" + gs
            parts.append(gs + big[gi])
        s = "".join(parts).strip("零")
    s += "元"
    if jiao == 0 and fen == 0:
        return s + "整"
    if jiao:
        s += digits[jiao] + "角"
    elif fen:
        s += "零"
    if fen:
        s += digits[fen] + "分"
    else:
        s += "整"
    return s


_LATIN = re.compile(r"[A-Za-z0-9.,:;!?'\"()%/&+\-@#$€£¥]")


def wrap(text: str, font, max_w: float, draw: ImageDraw.ImageDraw | None = None) -> list[str]:
    """Wrap by width: CJK breaks anywhere, Latin runs break at spaces when possible."""
    if draw is None:
        from PIL import Image
        draw = ImageDraw.Draw(Image.new("RGB", (4, 4)))
    lines: list[str] = []
    for para in text.split("\n"):
        tokens = re.findall(r"[A-Za-z0-9.,:;!?'\"()%/&+\-@#$€£¥]+|\s+|.", para)
        cur = ""
        for tok in tokens:
            if draw.textlength(cur + tok, font=font) <= max_w:
                cur += tok
                continue
            if cur.strip():
                lines.append(cur.rstrip())
                cur = tok.lstrip()
            else:
                cur = tok
            while cur and draw.textlength(cur, font=font) > max_w:  # a token longer than a line
                k = 1
                while k < len(cur) and draw.textlength(cur[:k + 1], font=font) <= max_w:
                    k += 1
                lines.append(cur[:k])
                cur = cur[k:]
        lines.append(cur.rstrip())
    return lines


def mixed_lang(text: str) -> str:
    """'zh', 'en' or 'mixed' for a piece of text."""
    has_cjk = any("一" <= ch <= "鿿" for ch in text)
    latin_words = re.findall(r"[A-Za-z]{2,}", text)
    if has_cjk and len(latin_words) >= 2:
        return "mixed"
    return "zh" if has_cjk else "en"


UNIT_RE = re.compile(
    r"\d[\d,.]*\s?(?:kg|g|mL|ml|L|km|m²|㎡|m|cm|mm|W|kW|V|Hz|℃|°C|%|GB|MB|KB|ms|s|min|h|元/公斤|元/斤|元/㎡|元|万元|万|"
    r"公斤|斤|克|件|箱|个|人|天|小时|分钟|秒|公里|平方米|平米|毫升|升|/月|/L|/100g|/h|mph|lb|oz|in|ft|x|×)",
    re.I)


def has_units(texts) -> bool:
    return sum(len(UNIT_RE.findall(t)) for t in texts) >= 2
