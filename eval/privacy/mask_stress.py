#!/usr/bin/env python3
"""Numbers stress variant of the frozen holdout set (holdout-week-v2), for the masking evaluation.

The same 46 items, 7 events, 42 facts, 6 checkpoints and gold labels as holdout-week-v2; only item text
changes. Realistic synthetic identifiers are written into the text the way they turn up in a working week:

  - every contact gets one phone number and one e-mail address, reused across that person's items in
    different spellings (138 1234 5678 / 13812345678 / 138-1234-5678 / +86 138 1234 5678; the Singapore and
    Australian customers get +65 / +61 numbers);
  - bank-card numbers in payment, refund and reimbursement items; PRC ID-card numbers in the discharge summary,
    a family chat and the trade-fair application;
  - verification codes in three of the four noise items; an API key in a pasted dev chat (the fourth noise
    item); one password in the trade-fair chat.

Nothing else changes: no gold fact key contains an inserted value, the four screenshots are the same PNGs
(on the Mac they would be redacted by on-device text recognition, which this Spark-side evaluation cannot
run), and names, dates, amounts, order numbers and places are left as they are.

Every value is synthetic and drawn from random.Random(seed); bank-card numbers are Luhn-valid and ID numbers
carry a valid birth date and ISO 7064 MOD 11-2 check digit, so they look real to the masker. E-mail domains
are fictional `.example.*` names.

  python3 eval/privacy/mask_stress.py --out DIR [--seed 20260930]
  python3 eval/privacy/mask_stress.py --probe --out DIR2

--probe writes a small identifier-centric scenario instead (mask-probe: 13 text items, 5 matters in which the
number is the point: a contact's new phone number, a refund to a card, ID numbers for trade-fair badges, a new
system account, a customer's new e-mail). The holdout variant rarely puts a number on a card, so this probe is
what exercises the return path: placeholders in titles, status lines and facts, and their restoration on the
Mac. Its extra values come from random.Random(seed + 1), so the stress set above is unchanged.

Writes DIR/scenario.json (scenario_id holdout-week-v2-numbers, split holdout-stress, synthetic: true),
DIR/assets/ (the unchanged screenshots) and DIR/identifiers.json (one row per inserted occurrence: type,
person, item, field, surface form, format). The generated files contain fake keys and card numbers, so they
are written outside the repository and not committed; the generator and seed reproduce them byte for byte.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
import string
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "scenarios" / "holdout-week-v2" / "scenario.json"
DEFAULT_SEED = 20260930


# ------------------------------------------------------------------------------------------ value makers

def luhn_complete(prefix: str, length: int, rng: random.Random) -> str:
    body = prefix + "".join(rng.choice(string.digits) for _ in range(length - len(prefix) - 1))
    total = 0
    for i, ch in enumerate(reversed(body)):
        d = int(ch)
        if i % 2 == 0:  # the digit next to the check digit is doubled
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return body + str((10 - total % 10) % 10)


def prc_id(region: str, born: date, male: bool, rng: random.Random) -> str:
    seq = rng.randrange(0, 100)
    third = rng.choice("13579" if male else "02468")
    body = f"{region}{born:%Y%m%d}{seq:02d}{third}"
    weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    check = "10X98765432"[sum(int(c) * w for c, w in zip(body, weights)) % 11]
    return body + check


def cn_mobile(rng: random.Random) -> str:
    return rng.choice(["135", "137", "138", "139", "150", "158", "186", "188", "199"]) + \
        "".join(rng.choice(string.digits) for _ in range(8))


def fmt_mobile(num: str, style: str) -> str:
    if style == "compact":
        return num
    if style == "344":
        return f"{num[:3]} {num[3:7]} {num[7:]}"
    if style == "dash":
        return f"{num[:3]}-{num[3:7]}-{num[7:]}"
    if style == "+86":
        return f"+86 {num[:3]} {num[3:7]} {num[7:]}"
    raise ValueError(style)


def group4(num: str) -> str:
    return " ".join(num[i:i + 4] for i in range(0, len(num), 4))


def email(local: str, *domain: str) -> str:
    return local + chr(64) + ".".join(domain)  # assembled at runtime: no address literal in this file


def make_values(rng: random.Random) -> dict:
    v: dict[str, str] = {}
    for who in ("owner", "feng", "xu", "tang", "deng", "he", "meng"):
        v[f"{who}_phone"] = cn_mobile(rng)
    v["wilson_phone"] = "9" + "".join(rng.choice(string.digits) for _ in range(7))
    v["peggy_phone"] = "4" + "".join(rng.choice(string.digits) for _ in range(8))
    v["owner_email"] = email("yun.cheng", "hetian-trade", "example", "cn")
    v["tang_email"] = email("tangyue", "hetian-trade", "example", "cn")
    v["wilson_email"] = email("wilson.huang", "nananhome", "example", "sg")
    v["peggy_email"] = email("peggy", "morningbowl", "example", "au")
    v["feng_email"] = email("fengjing.acc", "mail", "example", "cn")
    v["xu_email"] = email("xu.guodong", "deshengyao", "example", "cn")
    v["he_email"] = email("hexiaolan", "hdqc", "example", "com")
    v["dad_id"] = prc_id("330203", date(1955, 3, 1 + rng.randrange(28)), True, rng)
    v["tang_id"] = prc_id("330212", date(1998, 1 + rng.randrange(12), 1 + rng.randrange(28)), False, rng)
    v["card_cmb"] = luhn_complete("622588", 16, rng)       # company card, trade-fair deposit
    v["card_icbc"] = luhn_complete("622202", 19, rng)      # company account card, tax refund
    v["card_citic"] = luhn_complete("625804", 16, rng)     # owner's credit card, family reimbursement
    v["card_visa"] = luhn_complete("453914", 16, rng)      # customer's card, refund
    v["otp_prop"] = f"{rng.randrange(10 ** 5, 10 ** 6)}"
    v["otp_pet"] = f"{rng.randrange(1000, 10 ** 4)}"
    v["otp_news"] = f"{rng.randrange(10 ** 5, 10 ** 6)}"
    alnum = string.ascii_letters + string.digits
    key = "".join(rng.choice(alnum) for _ in range(40))
    v["api_key"] = "sk" + "-proj-" + key[:3] + "7" + key[4:]  # the masker wants a digit in the body
    v["password"] = "Ht" + "".join(rng.choice(alnum) for _ in range(5)) + "#" + f"{rng.randrange(10, 99)}"
    return v


# ------------------------------------------------------------------------------------------ insertions
#
# (item ref, field, op, anchor, template). field: "text" or "seg:<k>"; op: "replace" (anchor must occur once),
# "append". Templates reference slots {name:style}; each slot is one inserted occurrence in identifiers.json.

EDITS = [
    ("d1-02", "text", "replace", "这两样周五13号中午前给我",
     "这两样周五13号中午前发我邮箱 {feng_email}"),
    ("d1-03", "seg:2", "append", None, "他手机换了，新号是{deng_phone:344}。"),
    ("d1-05", "seg:4", "append", None, "有急事直接打我手机 {wilson_phone:+65}。"),
    ("d2-02", "text", "append", None, "\n--\nPeggy Mok · Morning Bowl Homewares\n{peggy_email} | {peggy_phone:+61}"),
    ("d2-04", "text", "replace", "更新的PO下午发你邮箱。",
     "更新的PO下午发你邮箱，我换了新邮箱 {wilson_email}，以后发这个。"),
    ("d2-06", "text", "replace", "采购联系人：黄立伟",
     "采购联系人：黄立伟  电话：{wilson_phone:+65}  邮箱：{wilson_email}"),
    ("d2-06", "text", "replace", "卖方：禾田器物贸易有限公司  联系人：程芸",
     "卖方：禾田器物贸易有限公司  联系人：程芸  电话：{owner_phone:+86}  邮箱：{owner_email}"),
    ("d2-07", "text", "append", None, "\n{owner_email} | {owner_phone:344}"),
    ("d2-08", "text", "replace", "出院可能要晚一天。",
     "出院可能要晚一天。\n周秀琴：出院结算要爸的身份证号，我发这里：{dad_id}，磊磊你记一下。"),
    ("d2-09", "text", "append", None, "\n许厂长：对了，我手机换号了，新号 {xu_phone:compact}，旧号下周停。"),
    ("d3-04", "text", "replace", "联系人：唐悦",
     "联系人：唐悦  手机：{tang_phone:dash}  邮箱：{tang_email}\n联系人身份证号：{tang_id}（办参展证用）"),
    ("d3-05", "text", "replace", "电子版发你邮箱了", "电子版从 {xu_email} 发你邮箱了"),
    ("d3-07", "text", "replace", "要的话今晚回我，我锁舱。",
     "要的话今晚回我，我锁舱，或者直接打我电话 {deng_phone:+86}。"),
    ("d3-09", "text", "append", None, "\n小唐：报名系统用我的邮箱 {tang_email} 登录，密码 {password} ，你有空看一下展位图。"),
    ("d4-01", "seg:2", "append", None, "有事打我手机 {meng_phone:344}。"),
    ("d4-03", "text", "replace", "姓名：程建华  性别：男  年龄：71岁",
     "姓名：程建华  性别：男  年龄：71岁  身份证号：{dad_id}"),
    ("d5-01", "seg:2", "replace", "今天晚上发给黄立伟那边，抄送您。",
     "今天晚上从 {he_email} 发给黄立伟那边，抄送您。"),
    ("d5-02", "text", "replace", "展位定金8000昨天下午已经付了",
     "展位定金8000昨天下午用公司招行卡 {card_cmb:4x4} 付了"),
    ("d5-05", "seg:4", "append", None, "阿强手机是 {deng_phone:compact} 吧？"),
    ("d5-06", "text", "append", None,
     "退税款打到公司工行账户，卡号 {card_icbc:4x4}。有事打我手机 {feng_phone:dash}。"),
    ("d6-01", "text", "append", None,
     "助行器和扶手一共1,286元，用我那张中信信用卡 {card_citic:compact} 付的，回头跟哥一人一半。"
     "孟老师电话 {meng_phone:compact} 也存一下。"),
    ("d6-03", "text", "replace", "退款到账跟我说一声。",
     "退款请打到我这张 Visa 卡：{card_visa:4x4}，到账跟我说一声。"),
    ("d6-03", "text", "append", None, "\n{peggy_email} | {peggy_phone:+61}"),
    # noise items: verification codes and a pasted dev chat
    ("d1-08", "text", "append", None, "\n【青枫里物业】您正在登录物业缴费小程序，验证码 {otp_prop}，5分钟内有效，请勿告诉他人。"),
    ("d2-05", "text", "append", None, "宠物店会员积分兑换要短信验证码，刚收到的是 {otp_pet}。"),
    ("d3-01", "text", "append", None, "\n【订阅确认】您的邮箱验证码：{otp_news}，10分钟内有效。"),
    ("d4-08", "text", "append", None,
     "\n\n你贴的脚本我改好了，把第3行的 API_KEY = \"{api_key}\" 换成环境变量读取，"
     "不要把密钥直接写在代码里。"),
]

SLOT_TYPES = {
    "phone": "phone", "email": "email", "id": "id_card", "card": "bank_card", "otp": "otp",
    "api": "secret", "password": "password",
}
OWNERS = {"owner": "p_owner", "wilson": "p_wilson", "peggy": "p_peggy", "feng": "p_feng", "xu": "p_xu",
          "tang": "p_tang", "deng": "p_deng", "he": "p_he", "meng": "p_meng", "dad": "p_dad"}
CARD_OWNERS = {"card_cmb": "company", "card_icbc": "company", "card_citic": "p_owner", "card_visa": "p_peggy"}


def render_slot(name: str, style: str, values: dict) -> tuple[str, str, str]:
    """(surface form, format label, normalized value) of one slot."""
    raw = values[name]
    if name.endswith("_phone"):
        if name == "wilson_phone":
            return f"+65 {raw[:4]} {raw[4:]}", "sg_mobile_+65_4-4", "65" + raw
        if name == "peggy_phone":
            return f"+61 {raw[:3]} {raw[3:6]} {raw[6:]}", "au_mobile_+61_3-3-3", "61" + raw
        return fmt_mobile(raw, style), f"cn_mobile_{style}", raw
    if name.startswith("card_"):
        return (group4(raw) if style == "4x4" else raw), f"bank_card_{len(raw)}_{style or 'compact'}", raw
    if name.endswith("_email"):
        return raw, "email", raw.lower()
    if name.endswith("_id"):
        return raw, "prc_id_18", raw
    if name.startswith("otp_"):
        return raw, f"otp_{len(raw)}", raw
    if name == "api_key":
        return raw, "api_key_sk-proj", raw
    if name == "password":
        return raw, "password_after_keyword", raw
    raise KeyError(name)


def slot_type(name: str) -> str:
    for prefix, t in (("card_", "bank_card"), ("otp_", "otp")):
        if name.startswith(prefix):
            return t
    if name == "api_key":
        return "secret"
    if name == "password":
        return "password"
    return SLOT_TYPES[name.rsplit("_", 1)[1]]


def fill(template: str, values: dict) -> tuple[str, list[dict]]:
    out, slots, i = [], [], 0
    while i < len(template):
        j = template.find("{", i)
        if j < 0:
            out.append(template[i:])
            break
        k = template.index("}", j)
        out.append(template[i:j])
        name, _, style = template[j + 1:k].partition(":")
        surface, fmt, norm = render_slot(name, style, values)
        owner = CARD_OWNERS.get(name) or OWNERS.get(name.split("_", 1)[0])
        slots.append({"slot": name, "type": slot_type(name), "person": owner, "surface": surface, "format": fmt,
                      "normalized": norm})
        out.append(surface)
        i = k + 1
    return "".join(out), slots


def build(seed: int) -> tuple[dict, list[dict]]:
    scenario = json.loads(SOURCE.read_text(encoding="utf-8"))
    rng = random.Random(seed)
    values = make_values(rng)
    by_ref = {it["ref"]: it for it in scenario["items"]}
    rows: list[dict] = []
    for ref, field, op, anchor, template in EDITS:
        item = by_ref[ref]
        text, slots = fill(template, values)
        if field == "text":
            cur = item["text"]
        else:
            cur = item["segments"][int(field.split(":")[1])]["text"]
        if op == "replace":
            if cur.count(anchor) != 1:
                raise SystemExit(f"{ref}: anchor {anchor!r} occurs {cur.count(anchor)} times")
            new = cur.replace(anchor, text)
        else:
            new = cur + text
        if field == "text":
            item["text"] = new
        else:
            item["segments"][int(field.split(":")[1])]["text"] = new
        for s in slots:
            rows.append({"item_id": item["item_id"], "ref": ref, "field": field, "noise": not item["events"], **s})
    scenario["scenario_id"] = "holdout-week-v2-numbers"
    scenario["split"] = "holdout-stress"
    scenario["title"] = scenario["title"] + "（号码压力版）"
    scenario["description"] = (
        f"由 eval/privacy/mask_stress.py（seed {seed}）从冻结的 holdout-week-v2 生成：条目、事件、事实、检查点和金标准"
        "都不变，只在条目文字里写入合成的手机号、邮箱、银行卡号、身份证号、验证码、API 密钥和一个密码，用来测遮号对整理质量的影响。"
        "原场景说明：" + scenario["description"])
    scenario["synthetic"] = True
    return scenario, rows


# ------------------------------------------------------------------------------------------ restoration probe

PROBE_EVENTS = [
    ("ev_deng_number", "货代阿强换手机号"), ("ev_peggy_refund", "Peggy 破损退款退到卡"),
    ("ev_fair_badges", "春季展参展证办理"), ("ev_erp_account", "ERP 新账号开通"),
    ("ev_wilson_email", "Wilson 换新邮箱"),
]
# (ref, day, time, source app, gold event, template)
PROBE_ITEMS = [
    ("p1-01", 16, "09:10", "微信", "ev_deng_number",
     "强哥-货代：芸姐，我手机换号了，新号 {deng_phone:344}，旧号这周五停机。报关行和船公司那边我也会通知。"),
    ("p1-02", 16, "09:40", "微信", "ev_peggy_refund",
     "Peggy：Yun，破损那42个的193.20美元请退到我这张 Visa 卡 {card_visa:4x4}，谢谢！"),
    ("p1-03", 16, "10:30", "企业微信", "ev_deng_number",
     "我：小唐，把阿强的新号 {deng_phone:compact} 更新到订舱联系人表里，旧号周五就停了。"),
    ("p1-04", 16, "11:00", "邮件", "ev_fair_badges",
     "发件人：春季家居礼品展组委会\n主题：参展证信息\n请于11月20日前回复参展人员姓名和身份证号，用于制作参展证。"),
    ("p1-05", 16, "14:20", "企业微信", "ev_erp_account",
     "IT小周：芸姐，ERP给你开好账号了，登录邮箱 {owner_email}，初始密码 {password}，第一次登录要改密码。"),
    ("p1-06", 16, "15:00", "微信", "ev_wilson_email",
     "Wilson：Yun，我们公司换了邮件系统，我的新邮箱是 {wilson_email}，旧邮箱月底停用。PO和发票以后都发新邮箱。"),
    ("p2-01", 17, "09:30", "企业微信", "ev_fair_badges",
     "小唐：芸姐，参展证要身份证号，我填了我的 {tang_id}，你的是不是 {owner_id}？"),
    ("p2-02", 17, "10:15", "微信", "ev_peggy_refund",
     "我：冯姐，Peggy的退款193.20美元请从公司招行卡 {card_cmb:4x4} 付，退到她的 Visa 卡 {card_visa:4x4}。"),
    ("p2-03", 17, "11:40", "短信", "ev_erp_account",
     "【禾田ERP】您正在修改登录密码，验证码 {otp_prop}，5分钟内有效。"),
    ("p2-04", 17, "16:00", "企业微信", "ev_wilson_email",
     "我：小唐，Wilson的新邮箱 {wilson_email} 记一下，下周的装运通知发到这个地址，电话还是 {wilson_phone:+65}。"),
    ("p3-01", 18, "10:00", "企业微信", "ev_deng_number",
     "小唐：芸姐，订舱联系人表改好了，阿强那栏已经换成 {deng_phone:dash}。"),
    ("p3-02", 18, "11:30", "微信", "ev_peggy_refund",
     "冯姐：Peggy的退款已经从招行卡 {card_cmb:compact} 转出，到她那张Visa卡大概3个工作日。"),
    ("p3-03", 18, "15:30", "邮件", "ev_fair_badges",
     "发件人：春季家居礼品展组委会\n主题：参展证已制作\n唐悦（身份证号 {tang_id}）、程芸（身份证号 {owner_id}）的参展证已制作完成，"
     "展会前凭身份证到服务台领取。"),
]


def build_probe(seed: int) -> tuple[dict, list[dict]]:
    import uuid
    values = make_values(random.Random(seed))  # same people, same numbers as the stress set
    extra = random.Random(seed + 1)
    values["owner_id"] = prc_id("330203", date(1989, 1 + extra.randrange(12), 1 + extra.randrange(28)), False, extra)
    ns = uuid.UUID("1b0e8f3c-5a52-4f55-9d11-6d61736b7072")
    items, rows = [], []
    for ref, day, hhmm, app, ev, template in PROBE_ITEMS:
        text, slots = fill(template, values)
        iid = str(uuid.uuid5(ns, ref))
        items.append({"item_id": iid, "ref": ref, "t": f"2026-11-{day:02d}T{hhmm}:00+08:00", "kind": "text",
                      "source_app": app, "persons": [], "events": [ev], "text": text})
        rows += [{"item_id": iid, "ref": ref, "field": "text", "noise": False, **sl} for sl in slots]
    scenario = {
        "scenario_id": "mask-probe", "version": 1, "split": "probe", "synthetic": True, "locale": "zh-CN",
        "title": "遮号还原探针", "description": f"由 eval/privacy/mask_stress.py --probe（seed {seed}）生成的合成场景："
        "号码本身就是事情的内容（换号、退款到卡、参展证身份证号、系统账号、换邮箱），用来检查占位符能不能原样回来、在 Mac 上还原。",
        "owner_person_id": "p_owner",
        "people": [{"person_id": "p_owner", "display_name": "程芸", "is_owner": True, "aliases": ["我", "芸姐", "Yun"]}],
        "events": [{"event_id": e, "kind": "main", "difficulty": "easy", "title": t} for e, t in PROBE_EVENTS],
        "items": items, "facts": [],
        "checkpoints": [{"checkpoint_id": "cp_end", "after_item_id": items[-1]["item_id"], "label": "结束", "expected": {}}],
    }
    return scenario, rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="output directory (outside the repository)")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--probe", action="store_true", help="write the restoration probe scenario instead")
    args = ap.parse_args(argv)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    scenario, rows = build_probe(args.seed) if args.probe else build(args.seed)
    data = json.dumps(scenario, ensure_ascii=False, indent=1).encode("utf-8")
    (out / "scenario.json").write_bytes(data)
    if not args.probe:
        shutil.copytree(SOURCE.parent / "assets", out / "assets", dirs_exist_ok=True)
    meta = {"seed": args.seed, "source": None if args.probe else "eval/scenarios/holdout-week-v2/scenario.json",
            "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "scenario_sha256": hashlib.sha256(data).hexdigest(), "occurrences": rows}
    (out / "identifiers.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    types: dict[str, int] = {}
    for r in rows:
        types[r["type"]] = types.get(r["type"], 0) + 1
    print(f"{out / 'scenario.json'}: {len(rows)} identifier occurrences in "
          f"{len({r['ref'] for r in rows})} items {types}; sha256 {meta['scenario_sha256'][:16]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
