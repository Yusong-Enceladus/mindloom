"""People: voice persons from the Mac, chat senders from screenshots and pasted chat text, and
deterministic linking.

Voiceprints never reach this service. The Mac sends only opaque person ids and optional display
names. Chat senders (a screenshot's messages, or "名：…" lines and "名 10:05" bylines in pasted text)
get deterministic ids derived from their name, so the same name from either source is one person.
A chat sender is linked to a voice person automatically only when exactly one voice person has the
same (normalized) name and no user decision says they differ; other near matches (an alias such as
小满 / 林小满, or 老周 / 周建国) become a same_person question, never a silent merge. The owner (我 and
the configured owner aliases) is never recorded as a chat person.
"""

from __future__ import annotations

import re
import unicodedata
import uuid
from typing import Iterable, Optional

from .store import Store

_NS = uuid.UUID("6f1f7c1e-2b0a-4e4f-9a57-0c0ffee00001")
SELF_NAMES = {"我", "自己", "本人", "me", "self", "我自己"}
_SELF_NORMS = {"".join(n.split()).casefold() for n in SELF_NAMES}
_PREFIXES = ("老", "小", "阿")
_SUFFIXES = ("老师", "经理", "总监", "同学", "先生", "女士", "师傅", "阿姨", "叔叔", "总", "哥", "姐", "姨", "叔")

# ---- speakers in pasted chat text ------------------------------------------------------------
# "名：内容" / "名: 内容" at the start of a line (content on the same line), also after the timestamp an
# exported chat puts first ("[08-17 12:29] 名：…", "[2026-08-17 12:29:05] 名：…"), and a byline "名 10:05"
# or "名 2026/9/24 10:05" on its own line followed by the message. The name part allows CJK, Latin,
# "·" and a "-remark" suffix (周建国-装修, 苏禾Suhe), no digits and no clause punctuation.
_NAME = r"[\u4e00-\u9fffA-Za-z·•][\u4e00-\u9fffA-Za-z·• \-_.]{0,15}"
_STAMP = (r"(?:[\[【]\s*(?:(?:\d{4}[-/.年])?\d{1,2}[-/.月]\d{1,2}日?\s*)?\d{1,2}:\d{2}(?::\d{2})?\s*[\]】]\s*)?")
_SPEAKER_LINE = re.compile(r"^\s*" + _STAMP + r"(?P<name>" + _NAME + r")\s*[：:](?P<rest>.*)$")
_BYLINE = re.compile(r"^\s*(?P<name>" + _NAME + r")\s+(?:\d{4}[-/年.]\d{1,2}[-/月.]\d{1,2}日?\s*)?"
                     r"(?:(?:上午|下午|晚上|早上)\s*)?\d{1,2}:\d{2}(?::\d{2})?\s*$")
# Field labels and headings that look like "X：" but are not people (general document vocabulary).
_LABELS = {
    "时间", "日期", "地点", "地址", "电话", "手机", "邮箱", "微信", "主题", "议题", "标题", "内容", "摘要", "总结", "结论",
    "原因", "问题", "回答", "答复", "问", "答", "目标", "截止", "金额", "价格", "报价", "预算", "合计", "总计", "小计",
    "总价", "单价", "数量", "状态", "进度", "说明", "要求", "附件", "链接", "网址", "结果", "计划", "待办", "下一步",
    "备注", "注意", "提示", "注", "补充", "更新", "步骤", "任务", "需求", "事项", "建议", "优点", "缺点", "风险",
    "例如", "比如", "举例", "方案", "工期", "付款", "费用", "规格", "型号", "尺寸", "版本", "来源", "作者", "编号",
    "订单", "订单号", "单号", "快递", "物流", "账号", "密码", "验证码", "姓名", "名称", "称呼", "身份", "职位",
    "部门", "公司", "单位", "学校", "班级", "上午", "下午", "晚上", "中午", "早上", "今天", "明天", "昨天",
    "第一", "第二", "第三", "首先", "其次", "然后", "最后", "另外", "此外", "总之", "重点", "要点", "关键",
    "q", "a", "ps", "p.s", "note", "notes", "todo", "tip", "tips", "re", "fw", "fwd", "subject", "from", "to",
    "cc", "date", "time", "http", "https", "ftp", "mailto", "file", "step", "summary", "title", "status",
    # e-mail headers and forwarded-message blocks
    "抄送", "密送", "发件人", "收件人", "发送时间", "收件时间", "发送日期", "回复", "转发", "签名", "正文", "原邮件",
}
# Heading-like endings: "付款方式：", "报价人：", "注意事项：", "任务完成：" are labels, not names.
_LABEL_ENDINGS = ("方式", "时间", "日期", "地点", "地址", "事项", "情况", "结果", "说明", "计划", "安排", "清单",
                  "要点", "备注", "费用", "价格", "金额", "合计", "完成", "建议", "问题", "要求", "步骤", "内容",
                  "进度", "状态", "信息", "记录", "总结", "目标", "人", "表", "单", "项", "类", "期")
# English field words and document labels ("Tel:", "Authors:", "Submission ID:", "Input Rows:"). A Latin
# "name" made only of these words is a label, not a person.
_FIELD_WORDS = {
    "tel", "phone", "mobile", "fax", "email", "e-mail", "mail", "author", "authors", "submission", "id", "server",
    "proxy", "host", "port", "user", "username", "password", "input", "output", "rows", "row", "columns", "column",
    "name", "address", "url", "link", "key", "value", "type", "error", "warning", "info", "debug", "result",
    "results", "abstract", "keywords", "keyword", "bcc", "attachment", "attachments", "location", "venue",
    "agenda", "deadline", "total", "price", "amount", "answer", "question", "reply", "company", "department",
    "organization", "role", "position", "website", "source", "target", "version", "model", "dataset", "method",
    "baseline", "reviewer", "reviewers", "editor", "paper", "manuscript", "figure", "table", "section",
    "appendix", "reference", "references", "track", "decision", "score", "scores", "comments", "comment",
    "affiliation", "contact", "office", "room", "code", "log", "path", "config", "default", "example", "response",
    "request", "status", "state", "note", "notes", "todo", "summary", "title", "date", "time", "from", "to", "cc",
    "subject", "action", "owner", "item", "items", "category", "tag", "tags", "level", "priority", "memo",
    "update", "background", "goal", "goals", "plan", "next", "steps", "step", "q", "a", "re", "fw", "fwd", "ps",
    "current", "average", "archive", "conference", "description", "module", "metric", "metrics", "prompt",
    "test", "case", "rate", "success", "dropped", "files", "file", "usage", "window", "severity",
}
# Words and characters that make a CJK "name" a clause or an instruction ("先确认一下：", "现在到哪一步：").
_CLAUSE_CHARS = set("哪吗呢吧么啥怎了的呀啊哦嗯着")
_CLAUSE_WORDS = ("一下", "注意", "提醒", "确认", "通知", "关于", "以下", "如下", "具体", "当前", "目前", "其他", "其它")
# Common family names (single and compound), for telling a person's name from a two-character word when a
# text has only one "X：" line.
_SURNAMES = set(
    "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢"
    "姜崔钟谭陆汪范金石廖贾夏韦付傅方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤常温康施"
    "牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛"
    "曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席"
    "卫米柏宗瞿桂佟应臧闵苟邬边卞姬师仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩佘池查麻苑迟邝")
_COMPOUND_SURNAMES = ("欧阳", "司马", "诸葛", "上官", "东方", "皇甫", "尉迟", "公孙", "慕容", "令狐", "长孙", "宇文",
                      "司徒", "夏侯", "轩辕", "端木", "独孤", "南宫", "西门", "澹台")
# Titles a surname takes ("纪治疗师", "谭老师"), and what family members are called.
# One title is written as an escape so the public copy keeps its sensitive-word gate strict; it is the same string.
_TITLES = ("治疗师", "老师", "医生", "大夫", "教授", "\u5e08\u5144", "师姐", "师弟", "师妹", "学长", "学姐", "经理", "总监",
           "主任", "同学", "阿姨", "律师", "会计", "师傅", "先生", "女士", "老板", "总", "工", "哥", "姐", "博", "叔", "姨")
_KIN = {"妈", "妈妈", "老妈", "爸", "爸爸", "老爸", "老婆", "老公", "媳妇", "哥哥", "姐姐", "弟弟", "妹妹", "奶奶",
        "爷爷", "外婆", "外公", "姥姥", "姥爷", "婆婆", "公公", "岳母", "岳父", "舅舅", "姑姑", "叔叔", "伯伯",
        "儿子", "女儿", "宝宝", "母上", "老爷子", "老太太"}
_BASE_SPLIT = re.compile(r"\s*(?:[-－—]|[（(])")
_REMARK = re.compile(r"[^\s\-－—]\s*[-－—]\s*\S")


def _clean_name(raw: str) -> str:
    name = unicodedata.normalize("NFKC", raw or "").strip().strip("·•-_. ")
    # Latin names may have one inner space ("Peggy Chen"); a CJK name never does.
    if " " in name and re.search(r"[\u4e00-\u9fff]", name):
        return ""
    return name


def name_base(name: str) -> str:
    """The name without a remark: "周建国-装修" -> "周建国", "庞学长（青禾）" -> "庞学长"."""
    return _BASE_SPLIT.split((name or "").strip(), maxsplit=1)[0].strip()


def _is_label(name: str) -> bool:
    n = norm(name)
    if not n or n in _LABELS:
        return True
    base = n.split("-")[0]
    if base in _LABELS:
        return True
    return len(base) >= 3 and re.fullmatch(r"[\u4e00-\u9fff]+", base) is not None and base.endswith(_LABEL_ENDINGS)


def _is_latin_label(name: str) -> bool:
    """A Latin "name" that is a code key or a field label: lowercase-first, camelCase, snake_case or dotted
    tokens, an exception class ("ValueError"), or made only of English field words ("Submission ID", "Tel")."""
    base = name_base(name)
    words = re.findall(r"[A-Za-z][A-Za-z'.\-_]*", base)
    if not words or re.search(r"[\u4e00-\u9fff]", base):
        return False
    for w in words:
        if w[0].islower() or "_" in w or "." in w.strip(".") or re.search(r"[a-z][A-Z]", w):
            return True
        if re.search(r"(Error|Exception|Warning)$", w):
            return True
    return all(w.lower().strip(".") in _FIELD_WORDS for w in words)


def _is_clause(name: str) -> bool:
    """A CJK "name" that is a phrase: longer than a name, or carrying a particle or an instruction word."""
    base = re.sub(r"[^\u4e00-\u9fff]", "", name_base(name))
    if not base:
        return False
    if len(base) > 4:
        return True
    if len(base) == 4 and not (base.startswith(_COMPOUND_SURNAMES) or base.endswith(_TITLES)):
        return True
    return len(base) >= 2 and (any(ch in _CLAUSE_CHARS for ch in base) or any(w in base for w in _CLAUSE_WORDS))


_NAME_LIST_SEP = re.compile(r"[,，;；、]")
_EMAILISH = re.compile(r"[\w.+-]+@[\w-]+(\.[\w-]+)+")


def _is_name_list(rest: str) -> bool:
    """"抄送：张三；李四" / "收件人：a@example.com": the text after the colon lists people, it is not speech."""
    rest = rest.strip()
    if _EMAILISH.search(rest) and len(_EMAILISH.sub("", rest).strip(" ,，;；、<>()（）")) <= 12:
        return True
    parts = [p.strip() for p in _NAME_LIST_SEP.split(rest) if p.strip()]
    if len(parts) < 2:
        return False
    return all(looks_like_person_name(p) or re.fullmatch(r"[A-Z][a-z]+( [A-Z][a-zA-Z]+)?", p) for p in parts)


def looks_like_person_name(name: str) -> bool:
    """Whether a name, read on its own, is shaped like a person's name or how people are called: a family
    name and one or two characters (上官岚), 老/小/阿 + family name (老谭), family name + title (郝工, 谭老师),
    a family term (妈妈), or a bilingual transcript name. Used where one "X：" line is all the evidence."""
    base = name_base(name)
    cjk, latin = split_bilingual(base)
    if cjk and latin:
        return True
    if _REMARK.search(name) and re.fullmatch(r"[\u4e00-\u9fff]{1,4}|[A-Za-z][A-Za-z .']{0,20}", base or ""):
        return True  # a contact saved as "name-remark" ("岚-印刷厂", "周建国-装修")
    if not re.fullmatch(r"[\u4e00-\u9fff]{1,4}", base or ""):
        return False
    if base in _KIN:
        return True
    if base[:2] in _COMPOUND_SURNAMES and 3 <= len(base) <= 4:
        return True
    if len(base) >= 2 and base[0] in "老小阿" and base[1] in _SURNAMES:
        return len(base) <= 3
    if base[0] in _SURNAMES and 2 <= len(base) <= 3:
        return True
    return len(base) >= 2 and base[0] in _SURNAMES and base.endswith(_TITLES)


def speakers_in_text(text: str) -> list[str]:
    """Names of the people speaking in pasted chat text, in order of first appearance.

    A speaker line needs content after the colon on the same line ("谈判建议：" followed by a list is a
    heading). Skipped: field labels ("时间：", "付款方式：", "备注：", e-mail headers such as "抄送："),
    English field words and code keys ("Tel:", "Submission ID:", "server:", "fontSize:", "ValueError:"),
    phrases ("现在到哪一步：", "先确认一下："), and lines whose content is only a list of names or addresses.
    A text with a single speaker line is a label far more often than a chat: its name is taken only when
    it reads as a person's name (looks_like_person_name), and a Latin name only from a text with at least
    two speaker lines. The owner is not removed here; the caller drops 我 and the configured owner aliases.
    """
    found: list[str] = []   # one name per accepted speaker line
    lines = (text or "").splitlines()
    for i, line in enumerate(lines):
        name = ""
        m = _SPEAKER_LINE.match(line)
        if m and m.group("rest").strip() and not m.group("rest").lstrip().startswith("//"):
            name = _clean_name(m.group("name"))
            if name and _is_name_list(m.group("rest")):
                continue
        else:
            b = _BYLINE.match(line)
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
            if b and nxt:
                name = _clean_name(b.group("name"))
        if not name or _is_label(name) or _is_latin_label(name) or _is_clause(name):
            continue
        if (len(re.sub(r"[^\u4e00-\u9fff]", "", name_base(name))) == 1 and not re.search(r"[A-Za-z]", name)
                and not _REMARK.search(name) and name not in SELF_NAMES):
            continue  # one character is not a name ("另："); a contact's remark ("岚-印刷厂") makes it one
        found.append(name)
    many = len(found) >= 2
    out: list[str] = []
    for name in found:
        latin = re.search(r"[\u4e00-\u9fff]", name) is None
        if latin and not many:
            continue
        if not many and not looks_like_person_name(name) and name not in SELF_NAMES:
            continue
        if name not in out:
            out.append(name)
    return out


def norm(name: str) -> str:
    return "".join(name.split()).casefold()


def core(name: str) -> str:
    n = norm(name)
    for suf in _SUFFIXES:
        if n.endswith(suf) and len(n) > len(suf):
            n = n[: -len(suf)]
            break
    for pre in _PREFIXES:
        if n.startswith(pre) and len(n) > len(pre):
            n = n[len(pre):]
            break
    return n


def _near(a: str, b: str) -> bool:
    """Plausibly the same person but not certain: same core name, containment, or 老张 vs 张三."""
    na, nb, ca, cb = norm(a), norm(b), core(a), core(b)
    if ca == cb:
        return True
    if min(len(na), len(nb)) >= 2 and (na in nb or nb in na):
        return True
    return (len(ca) == 1 and nb.startswith(ca)) or (len(cb) == 1 and na.startswith(cb))


_CJK_LATIN = re.compile(r"^\s*(?P<cjk>[\u4e00-\u9fff·]{2,})\s*[(（]?\s*(?P<latin>[A-Za-z][A-Za-z .'\-]*?)\s*[)）]?\s*$")
_LATIN_CJK = re.compile(r"^\s*(?P<latin>[A-Za-z][A-Za-z .'\-]*?)\s*[(（]?\s*(?P<cjk>[\u4e00-\u9fff·]{2,})\s*[)）]?\s*$")


def split_bilingual(name: str) -> tuple[str, str]:
    """("谭悦", "Yue TAN") for a "中文名 English NAME" form (either order, optional brackets:
    "以宁 (Nina)", "Nina苏以宁"); ("", "") otherwise. The CJK part needs at least two characters."""
    m = _CJK_LATIN.match(name or "") or _LATIN_CJK.match(name or "")
    if not m or not m.group("latin").strip(" -'."):
        return "", ""
    return m.group("cjk"), m.group("latin").strip(" -'.")


def canonical_form(name: str) -> str:
    """The name a chat or transcript person is kept under: the CJK part of a bilingual name ("谭悦 Yue
    TAN" -> "谭悦") when the evidence is strong (the CJK part reads as a full name, or the Latin part has two
    words); the bilingual form stays as an alias. Everything else is kept as written: a contact remark
    ("纪老师-数学") may be what tells two people apart, so those are joined only by the people pass."""
    raw = (name or "").strip()
    cjk, latin = split_bilingual(raw)
    if cjk and latin and not _is_latin_label(latin) and (looks_like_person_name(cjk) or len(latin.split()) >= 2):
        return cjk
    return raw


def name_variants(name: str) -> list[str]:
    """Normalized forms of a name: the whole, and for "中文名 English NAME" its CJK and Latin parts."""
    out = [norm(name)]
    cjk = "".join(re.findall(r"[\u4e00-\u9fff·]+", name or ""))
    latin = " ".join(re.findall(r"[A-Za-z][A-Za-z.\-']*", name or ""))
    for part in (cjk, latin):
        if part and cjk and latin and norm(part) not in out:
            out.append(norm(part))
    return out


_WHERE = {"chat": "聊天里的", "transcript": "会议记录里的"}


def _searchable_names(name: str) -> list[str]:
    """The forms of a record's name that are searched for in item text: a two-to-four character CJK name
    (a bilingual name's CJK part), and a Latin name of two or more words ("Lifeng HAN")."""
    out: list[str] = []
    raw = (name or "").strip()
    cjk, latin = split_bilingual(raw)
    for part in ([cjk, latin] if cjk and latin else [raw]):
        part = part.strip()
        if re.fullmatch(r"[\u4e00-\u9fff]{2,4}", part) and not _is_label(part) and not _is_clause(part):
            out.append(part)
        elif re.fullmatch(r"[A-Za-z][A-Za-z.'\-]*( [A-Za-z][A-Za-z.'\-]*){1,2}", part) and not _is_latin_label(part):
            out.append(part)
    return out


def chat_person_id(name: str) -> str:
    return "chat-" + str(uuid.uuid5(_NS, norm(name)))


class People:
    def __init__(self, store: Store, max_open_questions: int, self_ids: tuple[str, ...] | list[str] = (),
                 owner_aliases: Iterable[str] = ()):
        self.store = store
        # Open same_person questions allowed at once (a budget separate from same_event questions).
        self.max_open_questions = max_open_questions
        # The Mac user's own voice id(s), if configured. A voice labelled 我/本人/... is also the owner.
        self.self_ids = set(self_ids)
        # Names the owner goes by in chats (ORGANIZER_OWNER_ALIASES); 我/本人/自己 are always the owner.
        self.owner_norms = _SELF_NORMS | {norm(a) for a in owner_aliases if a and a.strip()}

    def is_owner_name(self, name: Optional[str]) -> bool:
        """The owner by any configured alias. A transcript name "中文名 English NAME" is the owner when
        either part is an alias."""
        return bool(name) and any(v in self.owner_norms for v in name_variants(name))

    # ---- lookups -------------------------------------------------------------

    def get(self, person_id: str) -> Optional[dict]:
        return self.store.one("SELECT * FROM persons WHERE person_id=?", (person_id,))

    def canonical(self, person_id: str) -> str:
        seen = set()
        current = person_id
        while current not in seen:
            seen.add(current)
            row = self.get(current)
            if not row or not row["merged_into"]:
                return current
            current = row["merged_into"]
        return current

    def name(self, person_id: str) -> Optional[str]:
        row = self.get(self.canonical(person_id))
        return row["display_name"] if row else None

    def label(self, person_id: str) -> str:
        return self.name(person_id) or "未命名的人"

    def is_self(self, person_id: str) -> bool:
        """The owner is not evidence that two items share a matter: every dictation has the owner."""
        canon = self.canonical(person_id)
        if person_id in self.self_ids or canon in self.self_ids:
            return True
        return self.is_owner_name(self.name(canon))

    def others(self, person_ids: list[str]) -> list[str]:
        return [p for p in person_ids if not self.is_self(p)]

    def aliases(self, person_id: str) -> list[str]:
        canon = self.get(person_id)
        own = canon["display_name"] if canon else None
        names: list[str] = []
        for row in self.store.all("SELECT person_id, display_name FROM persons WHERE merged_into IS NOT NULL"):
            if self.canonical(row["person_id"]) == person_id and row["display_name"]:
                if row["display_name"] != own and row["display_name"] not in names:
                    names.append(row["display_name"])
        return names

    def are_different(self, a: str, b: str) -> bool:
        x, y = sorted((a, b))
        return self.store.one("SELECT 1 FROM person_links WHERE a=? AND b=? AND relation='different'", (x, y)) is not None

    # ---- writes --------------------------------------------------------------

    def upsert_voice(self, person_id: str, display_name: Optional[str]) -> bool:
        """Record a voice person from the Mac. Returns True when a new name became known."""
        with self.store.tx():
            row = self.get(person_id)
            if row is None:
                self.store.x(
                    "INSERT INTO persons(person_id, display_name, name_source, origin, created_at, seq) VALUES (?,?,?,?,?,?)",
                    (person_id, display_name, "mac" if display_name else None, "voice", self.store.now(), self.store.bump()),
                )
                return bool(display_name)
            if display_name and row["name_source"] != "user" and row["display_name"] != display_name:
                self.store.x("UPDATE persons SET display_name=?, name_source='mac', seq=? WHERE person_id=?",
                             (display_name, self.store.bump(), person_id))
                return True
            return False

    def upsert_chat(self, name: str, source: str = "screenshot") -> str:
        """A chat sender, from a screenshot (source "screenshot"), pasted chat text ("text") or a meeting
        transcript's speaker ("transcript", origin "transcript"). The id depends only on the normalized
        name, so every source shares one person; the origin is the source that first named them. A bilingual
        transcript name ("谭悦 Yue TAN") is kept under its Chinese name (canonical_form), with the full
        form as a merged alias record, so it is the same person as a plain "谭悦" from a chat."""
        name = name.strip()
        kept = canonical_form(name)
        pid = chat_person_id(kept)
        origin = "transcript" if source == "transcript" else "chat"
        with self.store.tx():
            if self.get(pid) is None:
                self.store.x(
                    "INSERT INTO persons(person_id, display_name, name_source, origin, created_at, seq) VALUES (?,?,?,?,?,?)",
                    (pid, kept, source, origin, self.store.now(), self.store.bump()),
                )
            if kept != name:
                alias = chat_person_id(name)
                row = self.get(alias)
                if row is None:
                    self.store.x(
                        "INSERT INTO persons(person_id, display_name, name_source, origin, created_at, seq, merged_into)"
                        " VALUES (?,?,?,?,?,?,?)",
                        (alias, name, source, origin, self.store.now(), self.store.bump(), self.canonical(pid)),
                    )
                elif not row["merged_into"] and self.canonical(pid) != alias and not self.are_different(alias, pid):
                    self.merge(pid, alias, "bilingual")
        return pid

    def status(self, person_id: str) -> Optional[str]:
        """None (a person), 'role' or 'not_person' (set by the people pass) for the canonical record."""
        row = self.get(self.canonical(person_id))
        return row["status"] if row and "status" in row.keys() else None

    def set_name(self, person_id: str, display_name: str) -> None:
        with self.store.tx():
            if self.get(person_id) is None:
                self.store.x(
                    "INSERT INTO persons(person_id, display_name, name_source, origin, created_at, seq) VALUES (?,?,?,?,?,?)",
                    (person_id, display_name, "user", "voice", self.store.now(), self.store.bump()),
                )
            else:
                self.store.x("UPDATE persons SET display_name=?, name_source='user', seq=? WHERE person_id=?",
                             (display_name, self.store.bump(), person_id))
            self._touch_events_of(person_id)

    def merge(self, a: str, b: str, source: str) -> str:
        """Merge two persons; a voice person stays canonical. Returns the canonical id."""
        with self.store.tx():
            ca, cb = self.canonical(a), self.canonical(b)
            if ca == cb:
                return ca
            ra, rb = self.get(ca), self.get(cb)
            keep, drop = (ca, cb)
            if ra and rb and ra["origin"] != "voice" and rb["origin"] == "voice":
                keep, drop = cb, ca
            self.store.x("UPDATE persons SET merged_into=?, seq=? WHERE person_id=?", (keep, self.store.bump(), drop))
            self.store.x("UPDATE persons SET seq=? WHERE person_id=?", (self.store.bump(), keep))
            x, y = sorted((a, b))
            self.store.x("INSERT OR REPLACE INTO person_links(a, b, relation, source, created_at) VALUES (?,?,?,?,?)",
                         (x, y, "same", source, self.store.now()))
            self._touch_events_of(drop)
            return keep

    def mark_different(self, a: str, b: str, source: str) -> None:
        x, y = sorted((a, b))
        with self.store.tx():
            self.store.x("INSERT OR REPLACE INTO person_links(a, b, relation, source, created_at) VALUES (?,?,?,?,?)",
                         (x, y, "different", source, self.store.now()))

    def add_item_person(self, item_id: str, person_id: str, role: str) -> None:
        self.store.x("INSERT OR IGNORE INTO item_persons(item_id, person_id, role) VALUES (?,?,?)", (item_id, person_id, role))

    # ---- mentions ------------------------------------------------------------

    def mention_index(self) -> list[tuple[str, str]]:
        """(name, canonical person id) pairs searched for in item text, longest first. A name is searched
        only when the people pass judged its record a person (not a role or a label) whose name is not also
        an ordinary word, it is a full-looking name (two to four CJK characters, or a Latin name of two words),
        and it belongs to exactly one live person. The owner's names are never searched."""
        judged = {r["person_id"]: r for r in self.store.all(
            "SELECT person_id, verdict, common_word FROM person_checks")}
        by_name: dict[str, set[str]] = {}
        for r in self.store.all("SELECT person_id, display_name, origin, name_source FROM persons"
                                " WHERE display_name IS NOT NULL"):
            chk = judged.get(r["person_id"])
            # A voice the user named on the Mac is a person; its name is searched when it reads as a full name.
            voice_ok = r["origin"] == "voice" and looks_like_person_name(r["display_name"]) and \
                len(name_base(r["display_name"])) >= 2 and not _is_label(r["display_name"])
            if not voice_ok and (not chk or chk["verdict"] != "person" or chk["common_word"]):
                continue
            canon = self.canonical(r["person_id"])
            if self.status(canon) in ("role", "not_person") or self.is_self(canon):
                continue
            for n in _searchable_names(r["display_name"]):
                if norm(n) in self.owner_norms:
                    continue
                by_name.setdefault(n, set()).add(canon)
        pairs = [(n, next(iter(ids))) for n, ids in by_name.items() if len(ids) == 1]
        return sorted(pairs, key=lambda p: (-len(p[0]), p[0]))

    @staticmethod
    def find_mentions(text: str, index: list[tuple[str, str]]) -> list[str]:
        """Canonical ids of indexed people named in `text`: longest names first, a matched span is not
        matched again by a shorter name, and a Latin name must stand as whole words."""
        text = text or ""
        taken = [False] * len(text)
        out: list[str] = []
        for name, pid in index:
            start = 0
            latin = re.fullmatch(r"[A-Za-z .'\-]+", name) is not None
            while True:
                k = text.find(name, start)
                if k < 0:
                    break
                start = k + 1
                end = k + len(name)
                if any(taken[k:end]):
                    continue
                if latin and ((k > 0 and text[k - 1].isalpha()) or (end < len(text) and text[end].isalpha())):
                    continue
                for j in range(k, end):
                    taken[j] = True
                if pid not in out:
                    out.append(pid)
        return out

    def item_person_ids(self, item_id: str, exclude_roles: tuple[str, ...] = ()) -> list[str]:
        out: list[str] = []
        for row in self.store.all("SELECT person_id, role FROM item_persons WHERE item_id=? ORDER BY rowid", (item_id,)):
            if row["role"] in exclude_roles:
                continue
            pid = self.canonical(row["person_id"])
            if pid not in out:
                out.append(pid)
        return out

    def _touch_events_of(self, person_id: str) -> None:
        ids = {person_id} | {r["person_id"] for r in self.store.all("SELECT person_id FROM persons WHERE merged_into=?", (person_id,))}
        marks = ",".join("?" * len(ids))
        for row in self.store.all(
            f"SELECT DISTINCT ei.event_id FROM event_items ei JOIN item_persons ip ON ip.item_id = ei.item_id"
            f" WHERE ip.person_id IN ({marks}) AND ei.removed=0", list(ids)):
            self.store.update_event(row["event_id"])

    # ---- linking -------------------------------------------------------------

    def link_chat_person(self, chat_pid: str) -> str:
        """Try to link one chat sender to a voice person. Returns 'linked', 'asked' or 'none'.

        An exact name match with exactly one voice person links. A near name (alias, nickname, a
        "-remark" suffix) of a voice person or of another chat sender becomes a same_person question.
        """
        chat = self.get(chat_pid)
        if not chat or chat["merged_into"] or not chat["display_name"]:
            return "none"
        voices = self.store.all(
            "SELECT * FROM persons WHERE origin='voice' AND merged_into IS NULL AND display_name IS NOT NULL")
        voices = [v for v in voices if not self.are_different(chat_pid, v["person_id"])
                  and not self.is_self(v["person_id"])]
        exact = [v for v in voices if norm(v["display_name"]) == norm(chat["display_name"])
                 or norm(chat["display_name"]) in {norm(a) for a in self.aliases(v["person_id"])}]
        if len(exact) == 1:
            self.merge(exact[0]["person_id"], chat_pid, "name_match")
            return "linked"
        near = exact or [v for v in voices if _near(v["display_name"], chat["display_name"])]
        where = _WHERE.get(chat["origin"], "聊天里的")
        for v in near:
            qid = self.store.create_question(
                "same_person", chat_pid, v["person_id"],
                f"{where}「{chat['display_name']}」和声音里的「{v['display_name']}」是同一个人吗？",
                self.max_open_questions,
            )
            if qid:
                return "asked"
        others = self.store.all(
            "SELECT * FROM persons WHERE origin IN ('chat','transcript') AND merged_into IS NULL"
            " AND display_name IS NOT NULL AND person_id != ? ORDER BY seq", (chat_pid,))
        for o in others:
            if self.canonical(o["person_id"]) == self.canonical(chat_pid) or self.are_different(chat_pid, o["person_id"]):
                continue
            if self.is_owner_name(o["display_name"]) or not _near(o["display_name"], chat["display_name"]):
                continue
            qid = self.store.create_question(
                "same_person", chat_pid, o["person_id"],
                f"{where}「{chat['display_name']}」和{_WHERE.get(o['origin'], '聊天里的')}「{o['display_name']}」是同一个人吗？",
                self.max_open_questions,
            )
            if qid:
                return "asked"
        return "none"

    def link_all_chat_persons(self) -> None:
        for row in self.store.all("SELECT person_id FROM persons WHERE origin IN ('chat','transcript')"
                                  " AND merged_into IS NULL"):
            self.link_chat_person(row["person_id"])
