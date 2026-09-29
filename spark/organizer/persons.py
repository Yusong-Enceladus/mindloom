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
# "名：内容" / "名: 内容" at the start of a line (content on the same line), and a byline "名 10:05"
# or "名 2026/9/24 10:05" on its own line followed by the message. The name part allows CJK, Latin,
# "·" and a "-remark" suffix (周建国-装修, 苏禾Suhe), no digits and no clause punctuation.
_NAME = r"[\u4e00-\u9fffA-Za-z·•][\u4e00-\u9fffA-Za-z·• \-_.]{0,15}"
_SPEAKER_LINE = re.compile(r"^\s*(?P<name>" + _NAME + r")\s*[：:](?P<rest>.*)$")
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
}
# Heading-like endings: "付款方式：", "报价人：", "注意事项：", "任务完成：" are labels, not names.
_LABEL_ENDINGS = ("方式", "时间", "日期", "地点", "地址", "事项", "情况", "结果", "说明", "计划", "安排", "清单",
                  "要点", "备注", "费用", "价格", "金额", "合计", "完成", "建议", "问题", "要求", "步骤", "内容",
                  "进度", "状态", "信息", "记录", "总结", "目标", "人", "表", "单", "项", "类", "期")


def _clean_name(raw: str) -> str:
    name = unicodedata.normalize("NFKC", raw or "").strip().strip("·•-_. ")
    # Latin names may have one inner space ("Peggy Chen"); a CJK name never does.
    if " " in name and re.search(r"[\u4e00-\u9fff]", name):
        return ""
    return name


def _is_label(name: str) -> bool:
    n = norm(name)
    if not n or n in _LABELS:
        return True
    base = n.split("-")[0]
    if base in _LABELS:
        return True
    return len(base) >= 3 and re.fullmatch(r"[\u4e00-\u9fff]+", base) is not None and base.endswith(_LABEL_ENDINGS)


def speakers_in_text(text: str) -> list[str]:
    """Names of the people speaking in pasted chat text, in order of first appearance.

    A speaker line needs content after the colon on the same line ("谈判建议：" followed by a list is a
    heading), and field labels ("时间：", "付款方式：", "备注：") are skipped. The owner is not removed
    here; the caller drops 我 and the configured owner aliases.
    """
    out: list[str] = []
    lines = (text or "").splitlines()
    for i, line in enumerate(lines):
        name = ""
        m = _SPEAKER_LINE.match(line)
        if m and m.group("rest").strip() and not m.group("rest").lstrip().startswith("//"):
            name = _clean_name(m.group("name"))
        else:
            b = _BYLINE.match(line)
            nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
            if b and nxt:
                name = _clean_name(b.group("name"))
        if not name or _is_label(name):
            continue
        if len(re.sub(r"[^\u4e00-\u9fff]", "", name.split("-")[0])) > 6:
            continue  # a clause, not a name
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
        name, so every source shares one person; the origin is the source that first named them."""
        pid = chat_person_id(name)
        with self.store.tx():
            if self.get(pid) is None:
                self.store.x(
                    "INSERT INTO persons(person_id, display_name, name_source, origin, created_at, seq) VALUES (?,?,?,?,?,?)",
                    (pid, name.strip(), source, "transcript" if source == "transcript" else "chat",
                     self.store.now(), self.store.bump()),
                )
        return pid

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
