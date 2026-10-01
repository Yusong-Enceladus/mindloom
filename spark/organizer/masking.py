"""Masking spec v3 (privacy contract section 3; v2 after the privacy review, v3 after the masking evaluation).

The Mac (Swift) and this organizer must produce byte-identical output for every vector in
privacy/mask_vectors.json; spark/tests/test_privacy.py checks the file's SHA-256 and every vector.
Identifiers that organizing does not need (secrets, passwords, verification codes, ID-card and bank-card
numbers, phone numbers, landlines, e-mail and IP addresses, licence plates) become stable placeholders
such as 〔手机号·a1b2c3〕; names, dates, amounts and places are kept.

On the Spark, every text produced from bytes (image-read fields, file-read text and summary) is masked
before it is stored or put in any prompt, and incoming text is masked again as defence in depth; masking is
idempotent, so text the Mac already masked with the same key is unchanged.

Public API
    derive_keys(library_key) -> (key_id, store_key, mask_key)      (organizer/keys.py)
    mask(text, mask_key)     -> (masked_text, spans)
    mask_text(text, mask_key) -> masked_text
    mask_obj(value, mask_key) -> every string inside dicts / lists masked (keys and ids left alone)
    unmask(text, mapping)    -> text with known placeholders restored
    repair_placeholders(output, input_text) -> (output with broken placeholders rewritten, count)

Algorithm (unchanged from the reference; do not edit a rule here without changing the shared vectors)
    A sweep runs the detectors in ORDER. For one detector, on the current text:
    1. Every placeholder already in the text is a claimed span (placeholders
       from the input and from earlier detectors alike).
    2. For each sub-pattern, every start position where the regex matches
       yields one candidate: search from 0; after each match, search again
       from match.start()+1; lookbehind sees the whole text (ICU: use
       transparent bounds). The value is group 0 or the pattern's group 1.
    3. Candidates are sorted by (match start, longer match first, sub-pattern
       index) and accepted greedily: a candidate is taken when its whole
       match overlaps neither a claimed span nor a match already taken by
       this detector, and its validator (if any) passes.
    4. The detector's values are replaced by placeholders before the next
       detector runs.
    Sweeps repeat until a sweep changes nothing, so mask(mask(x)) == mask(x)
    holds by construction.

Characters are Unicode scalar values (Python str indices). Only ASCII digits
and letters are recognised; there is no Unicode normalisation.
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import re
from typing import Any, Callable, Dict, List, NamedTuple, Optional, Sequence, Tuple

from .keys import derive_keys  # noqa: F401  (re-exported: the contract's key derivation)

SPEC_VERSION = "mindloom-mask-v3"

LB = "〔"  # 〔
RB = "〕"  # 〕
DOT = "·"  # ·

ORDER: Tuple[str, ...] = (
    "secret",
    "password",
    "otp",
    "id_card",
    "bank_card",
    "phone",
    "landline",
    "email",
    "ip",
    "plate",
)

LABELS: Dict[str, str] = {
    "secret": "密钥",
    "password": "密码",
    "otp": "验证码",
    "id_card": "身份证号",
    "bank_card": "银行卡号",
    "phone": "手机号",
    "landline": "电话",
    "email": "邮箱",
    "ip": "IP",
    "plate": "车牌号",
}


# ---------------------------------------------------------------- regex sources
#
# Every source below is valid in both Python `re` and ICU
# (NSRegularExpression): ASCII classes only, fixed-width lookbehind,
# numbered backreferences, no inline flags. Case-insensitive keywords are
# spelled out as [Aa] classes so both engines behave identically.


def _ci(word: str) -> str:
    out = []
    for ch in word:
        if "a" <= ch.lower() <= "z":
            out.append("[" + ch.upper() + ch.lower() + "]")
        elif ch == " ":
            out.append("[ ]")
        elif ch == "_":
            out.append("_")
        else:
            out.append(re.escape(ch))
    return "".join(out)


BR = LB + RB  # the two placeholder brackets; every adjacency guard includes them

PLACEHOLDER_RE_SRC = (
    LB
    + "(?:"
    + "|".join(re.escape(LABELS[t]) for t in ORDER)
    + ")(?:"
    + DOT
    + "[0-9a-f]{6})?"
    + RB
)

# --- secret
SECRET_SRCS = [
    # 0 OpenAI-style key; the body must contain a digit
    r"(?<![A-Za-z0-9_" + BR + r"\-])sk-(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{16,}",
    # 1 GitHub classic token
    r"(?<![A-Za-z0-9_" + BR + r"])ghp_[A-Za-z0-9]{20,}",
    # 2 GitHub fine-grained token
    r"(?<![A-Za-z0-9_" + BR + r"])github_pat_[A-Za-z0-9_]{20,}",
    # 3 Slack token
    r"(?<![A-Za-z0-9_" + BR + r"\-])xox[abprs]-[A-Za-z0-9\-]{10,}",
    # 4 AWS access key id
    r"(?<![A-Za-z0-9" + BR + r"])AKIA[0-9A-Z]{16}(?![A-Za-z0-9" + BR + r"])",
    # 5 Google API key
    r"(?<![A-Za-z0-9_" + BR + r"\-])AIza[0-9A-Za-z_\-]{35}(?![0-9A-Za-z_" + BR + r"\-])",
    # 6 Bearer token (value = group 1): >= 16 chars, may not end in '.'
    r"(?<![A-Za-z" + BR + r"])[Bb]earer[ ]+([A-Za-z0-9._~+/\-]{15,}[A-Za-z0-9_~+/\-]=*)",
    # 7 URL query value of a secret-bearing key (value = group 1)
    r"[?&](?:"
    + "|".join(
        _ci(k)
        for k in (
            "access_token",
            "api_key",
            "signature",
            "password",
            "secret",
            "token",
            "key",
            "sig",
        )
    )
    + r")=([A-Za-z0-9._~%+/=\-]*[A-Za-z0-9_~%+/=\-])",
]
# --- v2 (privacy review F8): more key formats
# names whose assigned value is a secret (`API_KEY: …`, `aws_secret_access_key = …`); matched in any case
SECRET_NAMES = (
    "aws_secret_access_key", "secret_access_key", "access_key_secret", "accesskeysecret", "client_secret",
    "app_secret", "secret_key", "private_key", "access_key", "api_key", "apikey", "auth_token", "access_token",
    "refresh_token", "secret", "token",
)
SECRET_SRCS += [
    # 8 Stripe secret / restricted key
    r"(?<![A-Za-z0-9_" + BR + r"\-])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}",
    # 9 JSON Web Token: header.payload[.signature]
    r"(?<![A-Za-z0-9_" + BR + r"\-])eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]{8,})?",
    # 10 Alibaba Cloud AccessKey ID
    r"(?<![A-Za-z0-9" + BR + r"])LTAI[A-Za-z0-9]{12,24}(?![A-Za-z0-9" + BR + r"])",
    # 11 a secret-bearing name assigned a value (value = group 1): >= 16 characters with a digit
    r"(?<![A-Za-z0-9])(?:" + "|".join(_ci(k) for k in SECRET_NAMES) + r")[\"']?[ ]{0,2}[:=][ ]{0,2}[\"']?"
    r"(?=[A-Za-z0-9/+_.=\-]*[0-9])([A-Za-z0-9/+_.=\-]{16,})",
    # 12 the password in a URL's user info: scheme://user:password@host (value = group 1)
    r"[A-Za-z][A-Za-z0-9+.\-]{1,15}://[^ \t\r\n:/@" + BR + r"]{1,64}:([^ \t\r\n:/@" + BR + r"]{1,128})@",
    # 13 the body of a PEM private key (value = group 1)
    r"-----BEGIN[ A-Z]{0,30} PRIVATE KEY-----[ \t\r\n]*([A-Za-z0-9+/=\r\n]{16,}[A-Za-z0-9+/=])",
]
SECRET_GROUPS = [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1]

# --- password
PW_KEYWORD = (
    r"(?:密码|口令|(?<![A-Za-z" + BR + r"])(?:"
    + _ci("password")
    + "|"
    + _ci("passwd")
    + "|"
    + _ci("pwd")
    + r")(?![A-Za-z]))"
)
# token characters: printable ASCII except space and the prose delimiters
# ' " ` ( ) [ ] { } < > , \ |
PW_T = r"[A-Za-z0-9!#$%\&*+./:;=?@\^_~\-]"
# the last token character may not be sentence punctuation . : ; ?
PW_TLAST = r"[A-Za-z0-9!#$%\&*+/=@\^_~\-]"
PW_TOKEN = PW_T + "{3,63}" + PW_TLAST
PASSWORD_SRCS = [
    # 0 with an assignment: 密码：x / 密码是 x / 密码为 x / password=x / password is x
    PW_KEYWORD
    + r"(?:[ ]{0,2}(?:[:：=]|是|为)[ ]{0,2}|[ ]{1,2}[Ii][Ss][ ]{1,2})['\"“‘「]?("
    + PW_TOKEN
    + ")",
    # 1 bare: keyword, up to two spaces, a token that contains a digit
    PW_KEYWORD + r"[ ]{0,2}(?=" + PW_T + r"*[0-9])(" + PW_TOKEN + ")",
]
PASSWORD_SRCS += [
    # 2 (v2) keyword, a short aside, then a colon: 密码我私信你了：x
    r"(?:密码|口令)[^:：\n" + BR + r"]{1,8}[:：][ ]{0,2}['\"“‘「]?(" + PW_TOKEN + ")",
    # 3 (v2) the password for <something> is x
    r"(?<![A-Za-z" + BR + r"])" + _ci("password") + r"[ ]" + _ci("for") + r"[ ][^\n:：" + BR + r"]{1,32}?[ ]"
    + _ci("is") + r"[ ]{1,2}['\"“‘「]?(" + PW_TOKEN + ")",
    # 4 (v2) a PIN of 4-8 digits
    r"(?<![A-Za-z" + BR + r"])(?:PIN|Pin|pin)(?![A-Za-z])[ ]?码?[ ]{0,2}(?:[:：=]|是|为)?[ ]{0,2}([0-9]{4,8})"
    r"(?![0-9A-Za-z" + BR + r"])(?![.:/\-][0-9])(?![ ]?[年月日号点时分秒次个元条位])",
]
PASSWORD_GROUPS = [1, 1, 1, 1, 1]

# --- otp
OTP_KEYWORD_ZH = r"验证码|校验码|动态码|短信码|确认码|动态密码"
OTP_SRCS = [
    # 0 keyword first, up to 12 other characters (v2: was 6), then the code
    r"(?:" + OTP_KEYWORD_ZH + r"|(?<![A-Za-z" + BR + r"])(?:"
    + _ci("verification code")
    + "|"
    + _ci("code is")
    + "|"
    + _ci("otp")
    + r")(?![A-Za-z]))"
    + r"[^0-9" + BR + r"]{0,12}([0-9]{4,8})(?![0-9A-Za-z" + BR + r"])(?![.:/\-][0-9" + LB + r"])"
    + r"(?![ ]?[年月日号点时分秒次个元条位])",
    # 1 (v2) the code first: 4-6 digits that are not a group of a longer number, then within 24 characters of the
    # same line a code keyword
    r"(?<![0-9A-Za-z" + BR + r".:/\-])(?<![0-9][ \-.·\u00a0])([0-9]{4,6})(?![0-9A-Za-z" + BR + r"])"
    r"(?![.:/\-][0-9])(?![ \u00a0·][0-9])"
    + r"(?![ ]?[年月日号点时分秒次个元条位期届])[^0-9" + BR + r"\n]{0,24}?"
    + r"(?:" + OTP_KEYWORD_ZH + r"|(?<![A-Za-z])(?:" + _ci("verification code") + "|" + _ci("security code") + "|"
    + _ci("login code") + "|" + _ci("passcode") + "|" + _ci("otp") + r")(?![A-Za-z]))",
    # 2 (v3, masking evaluation 2026-09-30) the keyword, then within the same sentence (up to 40 characters, no
    # digit, line break or sentence end) a cue that hands over the value (是 / 为 / a colon / "is"), then the code:
    # "短信验证码刚刚发过来了，我收到的是 2802", "验证码发你手机上了，告诉我是多少：4821".
    r"(?:" + OTP_KEYWORD_ZH + r"|(?<![A-Za-z" + BR + r"])(?:" + _ci("verification code") + "|" + _ci("otp")
    + r")(?![A-Za-z]))"
    + r"[^0-9" + BR + r"\n。！？!?；;]{0,40}?"
    + r"(?:是|为|[:：]|(?<![A-Za-z])" + _ci("is") + r"(?![A-Za-z]))[ ]{0,2}"
    + r"([0-9]{4,8})(?![0-9A-Za-z" + BR + r"])(?![.:/\-][0-9" + LB + r"])(?![ ]?[年月日号点时分秒次个元条位])",
]
OTP_GROUPS = [1, 1, 1]

# --- id card (validated: calendar date + ISO 7064 MOD 11-2)
ID_SRCS = [
    r"(?<![0-9" + BR + r"])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])"
    r"(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9" + BR + r"])",
]
ID_SRCS += [
    # 1 (v2) written in groups 6-8-4 (spaces or dashes); the date must be valid (the check digit is not required)
    r"(?<![0-9" + BR + r"])[1-9][0-9]{5}([ \-])(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])\1"
    r"[0-9]{3}[0-9Xx](?![0-9A-Za-z" + BR + r"])",
    # 2 (v2) the old 15-digit number (YYMMDD, 19YY): an ID word within 12 characters before
    r"(?<![0-9A-Za-z" + BR + r"])[1-9][0-9]{5}[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}"
    r"(?![0-9A-Za-z" + BR + r"])",
]
ID_GROUPS = [0, 0, 0]
# Keyword windows are searched with an end position (Python) / range end (ICU): no lookahead in these, so both
# engines agree at the window's edge.
ID_KEYWORD_SRC = r"身份证|证件|身份号|(?<![A-Za-z])(?:ID|Id|id)"

# --- bank card (validated: Luhn + keyword-or-IIN)
BANK_SRCS = [
    # 0 contiguous 16-19 digits
    r"(?<![0-9A-Za-z" + BR + r"])[0-9]{16,19}(?![0-9A-Za-z" + BR + r"])",
    # 1 four groups of four (+ optional 1-3), one consistent separator
    r"(?<![0-9A-Za-z" + BR + r"])(?<![0-9" + RB + r"][ \-])[0-9]{4}([ \-])[0-9]{4}\1[0-9]{4}\1[0-9]{4}"
    r"(?:\1[0-9]{1,3})?(?![0-9A-Za-z" + BR + r"])(?![ \-][0-9" + LB + r"])",
]
BANK_SRCS += [
    # 2 (v2) four groups of four whose separators differ (a card wrapped onto the next line): space, dash, newline
    r"(?<![0-9A-Za-z" + BR + r"])(?<![0-9" + RB + r"][ \-\n])[0-9]{4}[ \-\n]{1,2}[0-9]{4}[ \-\n]{1,2}[0-9]{4}"
    r"[ \-\n]{1,2}[0-9]{4}(?:[ \-\n]{1,2}[0-9]{1,3})?(?![0-9A-Za-z" + BR + r"])(?![ \-\n][0-9" + LB + r"])",
    # 3 (v2) American Express 4-6-5 (15 digits, Luhn)
    r"(?<![0-9A-Za-z" + BR + r"])3[47][0-9]{2}([ \-]?)[0-9]{6}\1[0-9]{5}(?![0-9A-Za-z" + BR + r"])"
    r"(?![ \-][0-9" + LB + r"])",
    # 4 (v2) an account number after an account word: 12-20 digits, no Luhn check (value = group 1)
    r"(?:对公账号|对公账户|银行账号|银行账户|收款账号|收款账户|账号|账户|帐号|帐户|(?<![A-Za-z])" + _ci("account")
    + r"(?:[ ](?:" + _ci("no") + r"\.?|" + _ci("number") + r"))?)[ ]{0,2}[:：]?[ ]{0,2}"
    r"([0-9](?:[0-9]|[ \-](?=[0-9])){10,26}[0-9])(?![0-9A-Za-z" + BR + r"])",
]
BANK_GROUPS = [0, 0, 0, 0, 1]
BANK_KEYWORD_SRC = r"卡号|银行卡|储蓄卡|信用卡|账号|(?<![A-Za-z])" + _ci("card")
BANK_KEYWORD_WINDOW = 12
BANK_IIN_SRC = r"62|4|5[1-5]|3[47]"

# --- phone
PHONE_SRCS = [
    r"(?<![0-9" + BR + r"])(?<![0-9" + RB + r"]\.)(?:\+?86[ \-]?)?1[3-9][0-9]([ \-]?)[0-9]{4}\1[0-9]{4}"
    r"(?![0-9" + BR + r"])(?!\.[0-9" + LB + r"])",
]
PHONE_SRCS += [
    # 1 (v2) other separators, mixed: dots, middle dots, no-break spaces, a line break (a number wrapped in a chat)
    r"(?<![0-9" + BR + r"])(?<![0-9" + RB + r"][.·])(?:\+?86[ \-]?)?1[3-9][0-9][ \-.·\u00a0\n]{1,2}[0-9]{4}"
    r"[ \-.·\u00a0\n]{1,2}[0-9]{4}(?![0-9" + BR + r"])(?![.·][0-9" + LB + r"])",
    # 2 (v2) full-width digits
    r"(?<![0-9０-９" + BR + r"])(?:[＋+]?[８8][６6][ \-]?)?１[３-９][０-９]{9}(?![0-9０-９" + BR + r"])",
    # 3 (v2) spoken Chinese digits: 一三八一二三四五六七八
    r"(?<![〇零一二三四五六七八九幺两" + BR + r"])[一幺][三四五六七八九][〇零一二三四五六七八九幺两]{9}"
    r"(?![〇零一二三四五六七八九幺两" + BR + r"])",
]
PHONE_GROUPS = [0, 0, 0, 0]

# --- landline (validated: a "+" number has 6-14 digits after the country code)
LANDLINE_SRCS = [
    # 0 contract form: 010-62781234 / 0755-86013388
    r"(?<![0-9A-Za-z" + BR + r"\-])0[0-9]{2,3}-[0-9]{7,8}(?![0-9" + BR + r"])",
    # 1 grouped domestic: 010-6278-1234
    r"(?<![0-9A-Za-z" + BR + r"\-])0[0-9]{2,3}-[0-9]{3,4}-[0-9]{4}(?![0-9" + BR + r"])",
    # 2 contract form: +44 2071838750
    r"(?<![0-9A-Za-z" + BR + r"+])\+[0-9]{1,3}[ \-][0-9]{6,14}(?![0-9" + BR + r"])",
    # 3 grouped international: +86-10-5550-0199 / +1 415 555 2671
    r"(?<![0-9A-Za-z" + BR + r"+])\+[0-9]{1,3}(?:[ \-][0-9]{1,5}){2,5}(?![0-9" + BR + r"])(?![ \-][0-9" + LB + r"])",
]
LANDLINE_SRCS += [
    # 4 (v2) domestic with spaces: 010 6278 1234
    r"(?<![0-9A-Za-z" + BR + r"\-])0[0-9]{2,3}[ ][0-9]{3,4}[ ][0-9]{4}(?![0-9" + BR + r"])(?![ \-][0-9" + LB + r"])",
    # 5 (v2) area code in brackets: (0755)86013388 / （010）6278-1234
    r"(?<![0-9A-Za-z" + BR + r"])[(（]0[0-9]{2,3}[)）][ \-]?[0-9]{3,4}[ \-]?[0-9]{4}(?![0-9" + BR + r"])"
    r"(?![ \-][0-9" + LB + r"])",
    # 6 (v2) international with the area code in brackets: +1 (415) 555-0100
    r"(?<![0-9A-Za-z" + BR + r"+])\+[0-9]{1,3}[ ]?[(（][0-9]{1,4}[)）][ \-]?[0-9]{2,4}(?:[ \-][0-9]{2,5}){0,2}"
    r"(?![0-9" + BR + r"])(?![ \-][0-9" + LB + r"])",
    # 7 (v2) eight digits grouped 4-4 with a phone word within 12 characters before or after (a Hong Kong or
    # Macau number written without its country code)
    r"(?<![0-9A-Za-z" + BR + r"\-])[2-9][0-9]{3}[ \-][0-9]{4}(?![0-9" + BR + r"])(?![ \-][0-9" + LB + r"])",
]
LANDLINE_GROUPS = [0, 0, 0, 0, 0, 0, 0, 0]
PHONE_WORD_SRC = (r"电话|手机|座机|号码|联系|致电|拨打|打给|微信|(?<![A-Za-z])(?:" + _ci("whatsapp") + "|" + _ci("tel")
                  + "|" + _ci("phone") + "|" + _ci("call") + "|" + _ci("mobile") + r")")
PHONE_WORD_WINDOW = 12

# --- email
EMAIL_SRCS = [
    r"(?<![A-Za-z0-9._%+" + BR + r"\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"
    r"(?![A-Za-z0-9" + BR + r"])",
]
EMAIL_SRCS += [
    # 1 (v2) a full-width at sign
    r"(?<![A-Za-z0-9._%+" + BR + r"\-])[A-Za-z0-9._%+\-]+＠[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(?![A-Za-z0-9" + BR + r"])",
]
EMAIL_GROUPS = [0, 0]

# --- ip
_OCT = r"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
IP_SRCS = [
    r"(?<![0-9A-Za-z" + BR + r"])(?<![0-9" + RB + r"]\.)"
    + _OCT
    + r"\."
    + _OCT
    + r"\."
    + _OCT
    + r"\."
    + _OCT
    + r"(?![0-9" + BR + r"])(?!\.[0-9" + LB + r"])",
]
IP_GROUPS = [0]

# --- plate (validated: the serial has at least 3 digits)
PLATE_PROVINCES = "京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼"
PLATE_SEPARATORS = " ·•・-"
PLATE_SRCS = [
    r"(?<![A-Za-z0-9" + BR + r"])[" + PLATE_PROVINCES + r"][A-HJ-NP-Z][ ·•・\-]?"
    r"(?:[A-HJ-NP-Z0-9]{5,6}|[A-HJ-NP-Z0-9]{4}[挂学警港澳])(?![A-Za-z0-9" + BR + r"])",
]
PLATE_GROUPS = [0]


# ---------------------------------------------------------------- validators


def _luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = ord(ch) - 48
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


_ID_WEIGHTS = (7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2)
_ID_CHECK = "10X98765432"


def _id_ok(value: str) -> bool:
    v = value.upper()
    try:
        datetime.date(int(v[6:10]), int(v[10:12]), int(v[12:14]))
    except ValueError:
        return False
    s = sum(int(v[i]) * _ID_WEIGHTS[i] for i in range(17))
    return _ID_CHECK[s % 11] == v[17]


# ---------------------------------------------------------------- normalisation


# v2: separators that may sit inside a number (removed before tagging), and digits written another way.
NUMBER_SEPARATORS = " -.·\u00a0\n()（）"
_DIGIT_MAP = {**{chr(0xFF10 + i): str(i) for i in range(10)}, "＋": "+",
              **{ch: str(i) for i, ch in enumerate("〇一二三四五六七八九")}, "零": "0", "幺": "1", "两": "2"}


def _digits_ascii(value: str) -> str:
    return "".join(_DIGIT_MAP.get(ch, ch) for ch in value)


def _strip_separators(value: str) -> str:
    return "".join(ch for ch in value if ch not in NUMBER_SEPARATORS)


def normalize(kind: str, value: str) -> str:
    """The string that is tagged. Formatting separators go; content stays. v2: full-width and spoken Chinese
    digits become ASCII digits, a full-width at sign becomes @, and dots, middle dots, no-break spaces, line
    breaks and brackets inside a number go too (so a number gets the same tag however it was written)."""
    if kind in ("phone", "landline", "id_card", "bank_card", "plate"):
        if kind == "plate":
            v = value.replace(" ", "").replace("-", "")
            for ch in PLATE_SEPARATORS:
                v = v.replace(ch, "")
            return v
        v = _strip_separators(_digits_ascii(value))
        if kind == "phone":
            if v.startswith("+86"):
                v = v[3:]
            elif v.startswith("86") and len(v) == 13:
                v = v[2:]
        elif kind == "id_card":
            v = v.upper()
        return v
    if kind == "email":
        return value.replace("＠", "@").lower()
    return value  # secret, password, otp, ip: exact


def tag(mask_key: bytes, kind: str, normalized: str) -> str:
    msg = (kind + ":" + normalized).encode("utf-8")
    return hmac.new(mask_key, msg, hashlib.sha256).hexdigest()[:6]


def placeholder(mask_key: bytes, kind: str, value: str) -> str:
    return LB + LABELS[kind] + DOT + tag(mask_key, kind, normalize(kind, value)) + RB


# ---------------------------------------------------------------- engine


_Validator = Callable[[str, int, int, str, List[Tuple[int, int]]], bool]


class _Pattern(NamedTuple):
    rx: "re.Pattern[str]"
    group: int
    validate: Optional[_Validator]


class _Detector(NamedTuple):
    kind: str
    patterns: Tuple[_Pattern, ...]


def _compile(srcs: Sequence[str], groups: Sequence[int],
             validators: Sequence[Optional[_Validator]]) -> Tuple[_Pattern, ...]:
    """v2: each pattern has its own validator (None = none)."""
    assert len(srcs) == len(groups) == len(validators)
    return tuple(_Pattern(re.compile(s), g, v) for s, g, v in zip(srcs, groups, validators))


_BANK_KW_RX = re.compile(BANK_KEYWORD_SRC)
_BANK_IIN_RX = re.compile(BANK_IIN_SRC)
_ID_KW_RX = re.compile(ID_KEYWORD_SRC)
_PHONE_WORD_RX = re.compile(PHONE_WORD_SRC)


def _overlaps(a0: int, a1: int, spans: Sequence[Tuple[int, int]]) -> bool:
    for b0, b1 in spans:
        if a0 < b1 and b0 < a1:
            return True
    return False


def _keyword_in(rx: "re.Pattern[str]", text: str, w0: int, w1: int, claimed: List[Tuple[int, int]]) -> bool:
    """Whether rx matches inside text[w0:w1] (lookbehind sees the whole text) outside every claimed span."""
    pos = w0
    while True:
        m = rx.search(text, pos, w1)
        if m is None:
            return False
        if not _overlaps(m.start(), m.end(), claimed):
            return True
        pos = m.start() + 1


def _bank_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    digits = _strip_separators(value)
    if not 16 <= len(digits) <= 19 or not _luhn_ok(digits):
        return False
    if _BANK_IIN_RX.match(digits):
        return True
    return _keyword_in(_BANK_KW_RX, text, max(0, v0 - BANK_KEYWORD_WINDOW), v0, claimed)


def _amex_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    digits = _strip_separators(value)
    return len(digits) == 15 and _luhn_ok(digits)


def _account_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    return 12 <= len(_strip_separators(value)) <= 20


def _landline_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    if not value.startswith("+"):
        return True
    rest = re.split(r"[ -]", value)[1:]
    # v2: digits only (a bracketed area code counts its digits, not its brackets)
    n = sum(1 for p in rest for ch in p if "0" <= ch <= "9")
    return 6 <= n <= 14


def _phone_word_near(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    """A phone word within 12 characters before the number or after it."""
    return _keyword_in(_PHONE_WORD_RX, text, max(0, v0 - PHONE_WORD_WINDOW), v0, claimed) or \
        _keyword_in(_PHONE_WORD_RX, text, v1, min(len(text), v1 + PHONE_WORD_WINDOW), claimed)


def _plate_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    return sum(1 for ch in value[2:] if "0" <= ch <= "9") >= 3


def _id_validate(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    return _id_ok(value)


def _date_ok(year: int, month: int, day: int) -> bool:
    try:
        datetime.date(year, month, day)
    except ValueError:
        return False
    return True


def _id_grouped_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    v = _strip_separators(value)
    return len(v) == 18 and _date_ok(int(v[6:10]), int(v[10:12]), int(v[12:14]))


def _id15_ok(text: str, v0: int, v1: int, value: str, claimed: List[Tuple[int, int]]) -> bool:
    return len(value) == 15 and _date_ok(1900 + int(value[6:8]), int(value[8:10]), int(value[10:12])) and \
        _keyword_in(_ID_KW_RX, text, max(0, v0 - BANK_KEYWORD_WINDOW), v0, claimed)


DETECTORS: Tuple[_Detector, ...] = (
    _Detector("secret", _compile(SECRET_SRCS, SECRET_GROUPS, [None] * len(SECRET_SRCS))),
    _Detector("password", _compile(PASSWORD_SRCS, PASSWORD_GROUPS, [None] * len(PASSWORD_SRCS))),
    _Detector("otp", _compile(OTP_SRCS, OTP_GROUPS, [None] * len(OTP_SRCS))),
    _Detector("id_card", _compile(ID_SRCS, ID_GROUPS, [_id_validate, _id_grouped_ok, _id15_ok])),
    _Detector("bank_card", _compile(BANK_SRCS, BANK_GROUPS, [_bank_ok, _bank_ok, _bank_ok, _amex_ok, _account_ok])),
    _Detector("phone", _compile(PHONE_SRCS, PHONE_GROUPS, [None] * len(PHONE_SRCS))),
    _Detector("landline", _compile(LANDLINE_SRCS, LANDLINE_GROUPS,
                                   [_landline_ok] * 7 + [_phone_word_near])),
    _Detector("email", _compile(EMAIL_SRCS, EMAIL_GROUPS, [None] * len(EMAIL_SRCS))),
    _Detector("ip", _compile(IP_SRCS, IP_GROUPS, [None])),
    _Detector("plate", _compile(PLATE_SRCS, PLATE_GROUPS, [_plate_ok])),
)
assert tuple(d.kind for d in DETECTORS) == ORDER

PLACEHOLDER_RX = re.compile(PLACEHOLDER_RE_SRC)


def _detect(det: _Detector, text: str) -> List[Tuple[int, int]]:
    """Value spans one detector masks in `text`, in text order.

    Placeholders already in `text` (from the input or from earlier
    detectors) are claimed: no whole match may overlap them.
    """
    claimed: List[Tuple[int, int]] = [m.span() for m in PLACEHOLDER_RX.finditer(text)]
    cands = []  # (mstart, -mlen, pidx, mend, v0, v1)
    n = len(text)
    for pidx, pat in enumerate(det.patterns):
        pos = 0
        while pos <= n:
            m = pat.rx.search(text, pos)
            if m is None:
                break
            v0, v1 = m.span(pat.group)
            if v1 > v0:
                cands.append((m.start(), -(m.end() - m.start()), pidx, m.end(), v0, v1))
            pos = m.start() + 1
    cands.sort()
    taken: List[Tuple[int, int]] = []
    values: List[Tuple[int, int]] = []
    for ms, _neg_len, pidx, me, v0, v1 in cands:
        if _overlaps(ms, me, claimed) or _overlaps(ms, me, taken):
            continue
        validate = det.patterns[pidx].validate
        if validate is not None and not validate(text, v0, v1, text[v0:v1], claimed):
            continue
        taken.append((ms, me))
        values.append((v0, v1))
    values.sort()
    return values


def mask(text: str, mask_key: bytes) -> Tuple[str, List[dict]]:
    """Mask `text`. Returns (masked_text, spans).

    Each span is {type, label, placeholder, original, start, end}; start/end
    index the ORIGINAL input (Python str indices = Unicode scalars).
    """
    masked, spans, _passes = mask_with_passes(text, mask_key)
    return masked, spans


def mask_with_passes(text: str, mask_key: bytes) -> Tuple[str, List[dict], int]:
    """`mask` plus the number of sweeps that changed the text (0 or more).

    One sweep runs the detectors in ORDER; each detector's matches are
    replaced before the next detector runs. Sweeps repeat until one changes
    nothing, which makes the result a fixpoint (idempotent by construction).
    """
    if not isinstance(mask_key, (bytes, bytearray)) or len(mask_key) != 32:
        raise ValueError("mask_key must be 32 bytes")
    mask_key = bytes(mask_key)
    spans: List[dict] = []
    cur = text
    # origin[i] = index in the original input of cur[i], or -1 inside a
    # placeholder this call inserted (nothing ever matches inside those).
    origin: List[int] = list(range(len(text)))
    passes = 0
    while True:
        changed = False
        for det in DETECTORS:
            values = _detect(det, cur)
            if not values:
                continue
            changed = True
            out: List[str] = []
            new_origin: List[int] = []
            last = 0
            for v0, v1 in values:
                original = cur[v0:v1]
                ph = placeholder(mask_key, det.kind, original)
                out.append(cur[last:v0])
                new_origin.extend(origin[last:v0])
                out.append(ph)
                new_origin.extend([-1] * len(ph))
                last = v1
                o0 = origin[v0]
                spans.append(
                    {
                        "type": det.kind,
                        "label": LABELS[det.kind],
                        "placeholder": ph,
                        "original": original,
                        "start": o0,
                        "end": o0 + len(original),
                    }
                )
            out.append(cur[last:])
            new_origin.extend(origin[last:])
            cur = "".join(out)
            origin = new_origin
        if not changed:
            break
        passes += 1
    spans.sort(key=lambda s: s["start"])
    return cur, spans, passes


def unmask(text: str, mapping: Dict[str, str]) -> str:
    """Restore placeholders found in `mapping` (placeholder -> original).

    Unknown tagged placeholders are shown without their tag (〔手机号〕), as
    the contract prescribes for the Mac UI.
    """

    def repl(m: "re.Match[str]") -> str:
        ph = m.group(0)
        if ph in mapping:
            return mapping[ph]
        if DOT in ph:
            return ph.split(DOT, 1)[0] + RB
        return ph

    return PLACEHOLDER_RX.sub(repl, text)


# ---------------------------------------------------------------- helpers for the organizer

# Values under these keys are identifiers or fixed vocabulary, never free text: they are left alone.
_STRUCTURAL_KEYS = frozenset({
    "type", "kind", "key", "source", "doc_kind", "summary_source", "run_id", "detect_run_id", "screenshot_run_id",
    "image_run_ids", "item_id", "seg_id", "event_id", "person_id", "parent_item_id", "sha256", "mime", "uti",
    "state", "date", "error", "fmt", "captured_at", "started_at", "ended_at", "received_at",
})


def mask_text(text: Optional[str], mask_key: bytes) -> Optional[str]:
    """The masked text (None and "" pass through)."""
    if not text:
        return text
    return mask(text, mask_key)[0]


# ---------------------------------------------------------------- placeholder repair (model outputs)
#
# A model sometimes breaks a placeholder it copies from its input: "邮箱验证码3feb18" for 〔验证码·3feb18〕 (the
# masking evaluation of 2026-09-30 saw it in item-split gists). The Mac cannot restore the broken form and would
# show a code-like string. The organizer repairs every skill output deterministically before it is validated or
# stored: a 6-hex tag of a placeholder that was in that call's input, found outside a canonical 〔label·tag〕, is
# rewritten to that placeholder, together with what is left of its label, dot and placeholder brackets.

_TAGGED_RX = re.compile(LB + "(" + "|".join(re.escape(LABELS[t]) for t in ORDER) + ")" + DOT + "([0-9a-f]{6})" + RB)
_BARE_TAG_RX = re.compile(r"(?<![0-9A-Za-z])([0-9A-Fa-f]{6})(?![0-9A-Za-z])")
_REPAIR_SEPARATORS = "·・.:：- "
_LABELS_LONGEST_FIRST = sorted(LABELS.values(), key=len, reverse=True)


def placeholder_tags(text: Optional[str]) -> Dict[str, set]:
    """tag -> the canonical placeholders carrying it in `text` (normally one; two on a 24-bit tag collision)."""
    known: Dict[str, set] = {}
    for m in _TAGGED_RX.finditer(text or ""):
        known.setdefault(m.group(2), set()).add(m.group(0))
    return known


def _repair_text(text: str, known: Dict[str, set]) -> Tuple[str, int]:
    protected = [m.span() for m in _TAGGED_RX.finditer(text) if m.group(0) in known.get(m.group(2), ())]
    out: List[str] = []
    pos = n = 0
    for m in _BARE_TAG_RX.finditer(text):
        tag = m.group(1).lower()
        a, b = m.span(1)
        if tag not in known or a < pos or any(p0 <= a < p1 for p0, p1 in protected):
            continue
        sep = a - 1 if a - 1 >= pos and text[a - 1] in _REPAIR_SEPARATORS else a
        label = next((lab for lab in _LABELS_LONGEST_FIRST if text[pos:sep].endswith(lab)), None)
        cands = known[tag]
        if len(cands) == 1:
            ph = next(iter(cands))
        else:  # two values share the tag: only the label left in the text can say which one it was
            fits = [c for c in cands if label is not None and c.startswith(LB + label + DOT)]
            if len(fits) != 1:
                continue
            ph = fits[0]
        start, end = a, b
        if label is not None:
            lab_start = sep - len(label)
            # its own label is taken; another label only inside placeholder brackets (〔手机号·tag〕 for 〔验证码·tag〕)
            if LB + label + DOT == ph[: len(label) + 2] or (lab_start - 1 >= pos and text[lab_start - 1] == LB):
                start = lab_start
        if start == a and sep < a and sep - 1 >= pos and text[sep - 1] == LB:
            start = sep  # 〔·tag〕
        if start - 1 >= pos and text[start - 1] == LB:
            start -= 1
        if end < len(text) and text[end] == RB:
            end += 1
        out.append(text[pos:start])
        out.append(ph)
        pos = end
        n += 1
    if not n:
        return text, 0
    out.append(text[pos:])
    return "".join(out), n


def repair_placeholders(value: Any, reference: Optional[str]) -> Tuple[Any, int]:
    """(a copy of a JSON-like model output with broken placeholders repaired, how many were repaired).
    `reference` is the text the model was given (its input); only placeholders present there are repaired, so
    nothing is ever invented. Dict keys and values under the structural keys (ids, types, dates) are left alone."""
    known = placeholder_tags(reference)
    if not known:
        return value, 0
    count = [0]

    def walk(v: Any, key: Optional[str]) -> Any:
        if isinstance(v, str):
            if key in _STRUCTURAL_KEYS:
                return v
            fixed, k = _repair_text(v, known)
            count[0] += k
            return fixed
        if isinstance(v, dict):
            return {k: walk(x, k if isinstance(k, str) else None) for k, x in v.items()}
        if isinstance(v, (list, tuple)):
            return [walk(x, key) for x in v]
        return v

    return walk(value, None), count[0]


def mask_obj(value: Any, mask_key: bytes, _key: Optional[str] = None) -> Any:
    """A copy of a JSON-like value with every free-text string masked. Dict keys, and values under the
    structural keys above (ids, types, dates), are kept as they are."""
    if isinstance(value, str):
        return value if _key in _STRUCTURAL_KEYS else mask_text(value, mask_key)
    if isinstance(value, dict):
        return {k: mask_obj(v, mask_key, k if isinstance(k, str) else None) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [mask_obj(v, mask_key, _key) for v in value]
    return value
