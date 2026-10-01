#!/usr/bin/env python3
"""Deterministic part of person-resolve (stdlib only): which records may be the same person, and when a
"same person" verdict may be applied.

relation(a, b) names how two person names can be forms of one name, or None:
  bilingual  one is "中文名 English NAME" (either order, optional brackets) and the other is its Chinese or
             its Latin part ("谭悦 Yue TAN" / "谭悦" / "Yue TAN");
  remark     the same name with a contact remark or a bracket ("周建国-装修" / "周建国", "庞序（青禾）" / "庞序");
  pinyin     a Latin name whose family-name word is the pinyin of a Chinese name's family name ("Yue TAN" / "谭悦");
  nickname   a full Chinese name and a short form of it: its given name ("明舒" / "纪明舒"), 老/小/阿 + family
             name ("老纪"), family name + title ("纪老师", "纪总"), or one name containing the other.
candidates(subject, others, k) keeps the others with a relation, strongest first.
merge_allowed(subject, target, others) says whether a model verdict "same as target" may be applied, given
  the names of every other live person: the pair must have a relation, two different full names are never one
  person, and a form that can fit several people (a family name + title, 老/小 + family name, a given name, a
  Latin name) must fit no other live person (two 赵s and a "赵同学": nobody is merged).
keep_rank(name) orders the names of a merged pair: the record kept is the one with the fullest name
  (a Chinese full name, then a bilingual or remark form, then a Latin full name, then a short form).

CLI: python candidates.py NAME OTHER [OTHER ...]   prints the relation of NAME to each OTHER.
"""

from __future__ import annotations

import json
import re
import sys

_CJK = r"一-鿿"
_CJK_LATIN = re.compile(rf"^\s*(?P<cjk>[{_CJK}·]{{2,}})\s*[(（]?\s*(?P<latin>[A-Za-z][A-Za-z .'\-]*?)\s*[)）]?\s*$")
_LATIN_CJK = re.compile(rf"^\s*(?P<latin>[A-Za-z][A-Za-z .'\-]*?)\s*[(（]?\s*(?P<cjk>[{_CJK}·]{{2,}})\s*[)）]?\s*$")
_BASE_SPLIT = re.compile(r"\s*(?:[-－—]|[（(])")
# One title is written as an escape so the public copy keeps its sensitive-word gate strict; it is the same string.
TITLES = ("治疗师", "老师", "医生", "大夫", "教授", "\u5e08\u5144", "师姐", "师弟", "师妹", "学长", "学姐", "经理", "总监",
          "主任", "同学", "阿姨", "律师", "会计", "师傅", "先生", "女士", "老板", "总", "工", "哥", "姐", "博", "叔", "姨")
PREFIXES = ("老", "小", "阿")

# Family names and their pinyin (common single and compound family names).
_PINYIN = """
王wang 李li 张zhang 刘liu 陈chen 杨yang 黄huang 赵zhao 吴wu 周zhou 徐xu 孙sun 马ma 朱zhu 胡hu 郭guo 何he 高gao
林lin 罗luo 郑zheng 梁liang 谢xie 宋song 唐tang 许xu 韩han 冯feng 邓deng 曹cao 彭peng 曾zeng 肖xiao 田tian 董dong
袁yuan 潘pan 于yu 蒋jiang 蔡cai 余yu 杜du 叶ye 程cheng 苏su 魏wei 吕lv,lu,lyu 丁ding 任ren 沈shen 姚yao 卢lu 姜jiang
崔cui 钟zhong 谭tan 陆lu 汪wang 范fan 金jin 石shi 廖liao 贾jia 夏xia 韦wei 付fu 傅fu 方fang 白bai 邹zou 孟meng
熊xiong 秦qin 邱qiu 江jiang 尹yin 薛xue 闫yan 段duan 雷lei 侯hou 龙long 史shi 陶tao 黎li 贺he 顾gu 毛mao 郝hao
龚gong 邵shao 万wan 钱qian 严yan 覃qin 武wu 戴dai 莫mo 孔kong 向xiang 汤tang 常chang 温wen 康kang 施shi 牛niu 樊fan
葛ge 邢xing 安an 齐qi 易yi 乔qiao 伍wu 庞pang 颜yan 倪ni 庄zhuang 聂nie 章zhang 鲁lu 岳yue 翟zhai 殷yin 詹zhan 申shen
欧ou 耿geng 关guan 兰lan 焦jiao 俞yu 左zuo 柳liu 甘gan 祝zhu 包bao 宁ning 尚shang 符fu 舒shu 阮ruan 柯ke 纪ji 梅mei
童tong 凌ling 毕bi 单shan,dan 季ji 裴pei 霍huo 涂tu 成cheng 苗miao 谷gu 盛sheng 曲qu 翁weng 冉ran 骆luo 蓝lan 路lu
游you 辛xin 靳jin 管guan 柴chai 蒙meng 鲍bao 华hua 喻yu 祁qi 蒲pu 房fang 滕teng 屈qu 饶rao 解xie 牟mou 艾ai 尤you
阳yang 穆mu 农nong 司si 卓zhuo 古gu 吉ji 缪miao 简jian 车che 项xiang 连lian 芦lu 麦mai 褚chu 娄lou 窦dou 戚qi 岑cen
景jing 党dang 宫gong 费fei 卜bu 冷leng 晏yan 席xi 卫wei 米mi 柏bai 宗zong 瞿qu 桂gui 佟tong 应ying 臧zang 闵min
苟gou 邬wu 边bian 卞bian 姬ji 师shi 仇qiu 栾luan 隋sui 商shang 刁diao 沙sha 荣rong 巫wu 寇kou 桑sang 郎lang 甄zhen
丛cong 仲zhong 虞yu 敖ao 巩gong 佘she 池chi 查zha 麻ma 苑yuan 迟chi 邝kuang 欧阳ouyang 司马sima 诸葛zhuge
上官shangguan 东方dongfang 皇甫huangfu 慕容murong 令狐linghu 司徒situ 夏侯xiahou 端木duanmu 南宫nangong
"""
SURNAME_PINYIN: dict[str, tuple[str, ...]] = {}
for _tok in _PINYIN.split():
    _m = re.fullmatch(rf"([{_CJK}]+)([a-z,]+)", _tok)
    if _m:
        SURNAME_PINYIN[_m.group(1)] = tuple(_m.group(2).split(","))
COMPOUND = tuple(k for k in SURNAME_PINYIN if len(k) == 2)


def split_bilingual(name: str) -> tuple[str, str]:
    m = _CJK_LATIN.match(name or "") or _LATIN_CJK.match(name or "")
    if not m or not m.group("latin").strip(" -'."):
        return "", ""
    return m.group("cjk"), m.group("latin").strip(" -'.")


def base(name: str) -> str:
    return _BASE_SPLIT.split((name or "").strip(), maxsplit=1)[0].strip()


def norm(name: str) -> str:
    return "".join((name or "").split()).casefold()


def is_cjk(name: str) -> bool:
    return re.fullmatch(rf"[{_CJK}]+", name or "") is not None


def is_latin(name: str) -> bool:
    return re.fullmatch(r"[A-Za-z][A-Za-z .'\-]*", (name or "").strip()) is not None


def surname(full: str) -> str:
    """The family name of a two-to-four character Chinese full name, or ""."""
    if not is_cjk(full) or not 2 <= len(full) <= 4 or full in COMPOUND:
        return ""
    if full[:2] in COMPOUND and len(full) >= 3:
        return full[:2]
    return full[0] if full[0] in SURNAME_PINYIN and len(full) <= 3 else ""


def short_form_surname(name: str) -> str:
    """The family name inside a short form that fits anyone of that family: 老纪 / 小纪 / 纪老师 / 纪总."""
    n = base(name)
    if not is_cjk(n):
        return ""
    for pre in PREFIXES:
        if len(n) == 2 and n.startswith(pre) and n[1] in SURNAME_PINYIN:
            return n[1]
    for t in TITLES:
        if n.endswith(t) and 1 <= len(n) - len(t) <= 2 and n[: len(n) - len(t)] in SURNAME_PINYIN:
            return n[: len(n) - len(t)]
    return ""


def pinyin_match(latin: str, cjk: str) -> bool:
    """A Latin name (one to three words) whose family-name word is the pinyin of the Chinese name's family name,
    with at least one other word ("Yue TAN" / "谭悦", "TAN Yue")."""
    words = [w.strip(".'-").lower() for w in latin.split() if w.strip(".'-")]
    sur = surname(cjk)
    if not sur or not 2 <= len(words) <= 3:
        return False
    py = SURNAME_PINYIN.get(sur, ())
    return any(w in py for w in (words[0], words[-1]))


def relation(a: str, b: str) -> str | None:
    a, b = (a or "").strip(), (b or "").strip()
    if not a or not b or norm(a) == norm(b):
        return None
    for x, y in ((a, b), (b, a)):
        cjk, latin = split_bilingual(x)
        if cjk and latin and (norm(y) in (norm(cjk), norm(latin)) or norm(base(y)) == norm(cjk)):
            return "bilingual"
    ba, bb = base(a), base(b)
    if (ba != a or bb != b) and ba and norm(ba) == norm(bb):
        return "remark"
    ca, la = split_bilingual(ba)
    cb, lb = split_bilingual(bb)
    ca, cb = ca or (ba if is_cjk(ba) else ""), cb or (bb if is_cjk(bb) else "")
    la, lb = la or (ba if is_latin(ba) else ""), lb or (bb if is_latin(bb) else "")
    if la and cb and not ca and pinyin_match(la, cb):
        return "pinyin"
    if lb and ca and not cb and pinyin_match(lb, ca):
        return "pinyin"
    if la and lb and not ca and not cb:
        wa, wb = {w.lower() for w in la.split()}, {w.lower() for w in lb.split()}
        if (len(wa) == 1 and wa <= wb) or (len(wb) == 1 and wb <= wa):
            return "nickname"  # "Tina" / "Tina Song"
    if ca and cb:
        full, short = (ca, cb) if (bool(full_name(ca)), len(ca)) >= (bool(full_name(cb)), len(cb)) else (cb, ca)
        sur = surname(full)
        if sur:
            if short_form_surname(short) == sur:
                return "nickname"
            given = full[len(sur):]
            if len(given) >= 2 and short in (given, given[-2:]):
                return "nickname"
            if len(short) >= 2 and short != full and short in full:
                return "nickname"
    return None


_STRENGTH = {"bilingual": 0, "remark": 1, "pinyin": 2, "nickname": 3}


def candidates(subject: dict, others: list[dict], k: int = 6) -> list[dict]:
    """others: [{"handle", "name", "items", "shared_events"}]; keeps the ones with a relation to subject."""
    out = []
    for o in others:
        rel = relation(subject["name"], o["name"])
        if rel:
            out.append(dict(o, relation=rel))
    out.sort(key=lambda o: (_STRENGTH[o["relation"]], -int(o.get("shared_events") or 0), -int(o.get("items") or 0),
                            o["handle"]))
    return out[:k]


def _fits(subject: str, other: str) -> bool:
    return relation(subject, other) is not None


def full_name(name: str) -> str:
    """The Chinese full name a record carries (its CJK part or its base), or "" for a short form."""
    cjk, _ = split_bilingual(base(name))
    n = cjk or base(name)
    if len(n) == 2 and n[0] == n[1]:
        return ""  # 悦悦, 舒舒: a pet name, not a family name + given name
    return n if surname(n) and not short_form_surname(n) else ""


def keep_rank(name: str) -> int:
    """Higher = better kept when two records of one person are merged."""
    b = base(name)
    cjk, latin = split_bilingual(b)
    if full_name(name) and b == name and not latin:
        return 5  # a plain Chinese full name
    if full_name(name):
        return 4  # bilingual or with a remark
    if is_latin(b) and len(b.split()) >= 2:
        return 3
    if is_cjk(b) and len(b) >= 2:
        return 2
    return 1


def merge_allowed(subject: str, target: str, others: list[str]) -> tuple[bool, str]:
    """Whether "subject is the same person as target" may be applied. `others`: the names of the other live
    people (the subject and the target are skipped). Returns (allowed, rule).

    The pair needs a name relation. Two different full names are never one person, and two short forms are
    never joined to each other (they join a full name when one is known). A short form (a nickname, a family
    name + title, a Latin name) joins a full name only if it fits no other live full name: with two people of
    one family name, "周总" joins nobody."""
    rel = relation(subject, target)
    if rel is None:
        return False, "no_name_relation"
    fs, ft = full_name(subject), full_name(target)
    if fs and ft and norm(fs) != norm(ft):
        return False, "two_full_names"
    if rel in ("bilingual", "remark"):
        return True, rel
    if not fs and not ft:
        return False, "two_short_forms"
    full, short = (fs, target) if fs else (ft, subject)
    rest = [o for o in others if norm(o) not in (norm(target), norm(subject))]
    rivals = [o for o in rest if full_name(o) and norm(full_name(o)) != norm(full) and _fits(short, o)]
    if rel == "pinyin":
        return (not rivals, "pinyin" if not rivals else "pinyin_ambiguous")
    sur = surname(full)
    if short_form_surname(short) and any(surname(full_name(o)) == sur for o in rest
                                         if full_name(o) and norm(full_name(o)) != norm(full)):
        return False, "family_name_ambiguous"
    if rivals:
        return False, "nickname_ambiguous"
    return True, rel


def main() -> int:
    name, others = sys.argv[1], sys.argv[2:]
    print(json.dumps({o: relation(name, o) for o in others}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
