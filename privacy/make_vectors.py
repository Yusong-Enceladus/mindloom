#!/usr/bin/env python3
"""Build privacy/mask_vectors.json (masking spec v3) from hand-annotated cases.

Every case lists exactly which substrings must be masked, as (type, original)
in text order. The generator refuses to write the file if the organizer's
masking (spark/organizer/masking.py, the Python reference of the spec) disagrees
with an annotation, so each "expected" string is checked by hand-written
intent, not just by running the implementation. The Mac keeps a byte-identical
copy (both test suites assert its SHA-256). Every number, key and address here
is invented.

Spec v1 (2026-09-30) had the cases up to the v1 guards; v2 adds the formats the
privacy review found unmasked (finding F8) and guards for the new rules; v3 adds
the conversational verification-code phrasing the masking evaluation found
unmasked (a keyword, some chat, then "是 / 为 / ：/ is" and the code, within one
sentence of up to 40 characters) and its guards.

    python3 privacy/make_vectors.py            # rewrite privacy/mask_vectors.json
    python3 privacy/make_vectors.py --check    # exit 1 if the file would change
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "spark"))
from organizer import keys as _keys  # noqa: E402
from organizer import masking as mask_ref  # noqa: E402

MASK_KEY = bytes([0x11]) * 32
DERIVE_LIBRARY_KEYS = [bytes(range(32))]
OUT = os.path.join(HERE, "mask_vectors.json")

AIZA = "AIza" + "SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q"  # 4 + 35 chars

# (input, [(type, original), ...])  -- positives
POSITIVE = [
    # secret
    ("OpenAI key: sk-proj-Ab3dEf6hIj9kLm2nOp5q 别外传", [("secret", "sk-proj-Ab3dEf6hIj9kLm2nOp5q")]),
    ("旧 token ghp_A1b2C3d4E5f6G7h8I9j0K1l2 已吊销", [("secret", "ghp_A1b2C3d4E5f6G7h8I9j0K1l2")]),
    ("fine-grained: github_pat_11ABCDEFG0123456789_abcdefXYZ", [("secret", "github_pat_11ABCDEFG0123456789_abcdefXYZ")]),
    ("Slack 机器人 xoxb-2026-0929-abcdefABCDEF 放在 .env", [("secret", "xoxb-2026-0929-abcdefABCDEF")]),
    ("AWS AKIAIOSFODNN7EXAMPLE 放在 CI 里", [("secret", "AKIAIOSFODNN7EXAMPLE")]),
    ("地图 key=" + AIZA + " 限额 1000/天", [("secret", AIZA)]),
    (
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl",
        [("secret", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl")],
    ),
    (
        "回调 https://api.example.com/v1/cb?user=lin&token=a1B2c3D4e5&lang=zh",
        [("secret", "a1B2c3D4e5")],
    ),
    (
        "下载链接 https://files.example.org/x.pdf?sig=ZmFrZS1zaWc%3D&expires=1790000000。",
        [("secret", "ZmFrZS1zaWc%3D")],
    ),
    ("password: sk-proj-Abc123def456ghi789 先用着", [("secret", "sk-proj-Abc123def456ghi789")]),
    # password
    ("WiFi 密码：Lab@2026wifi，别发群里", [("password", "Lab@2026wifi")]),
    ("登录密码 abc12345，支付密码 778899", [("password", "abc12345"), ("password", "778899")]),
    ("服务器 root 密码是 Tr0ub4dor&3", [("password", "Tr0ub4dor&3")]),
    ("password: hunter2024!", [("password", "hunter2024!")]),
    ("OK, the password is Blue-Sky-77.", [("password", "Blue-Sky-77")]),
    ("口令 Xk9#mQ2z 只用一次", [("password", "Xk9#mQ2z")]),
    ("新密码为 'Qimu@2026'，登录后改掉", [("password", "Qimu@2026")]),
    ("密码：13812345678（就是我手机号）", [("password", "13812345678")]),
    # otp
    ("【清川银行】验证码 482913，5 分钟内有效，请勿告知他人。", [("otp", "482913")]),
    ("Your verification code is 0725.", [("otp", "0725")]),
    ("OTP: 90210388", [("otp", "90210388")]),
    ("动态码：3391", [("otp", "3391")]),
    ("验证码已发送至 13812345678，请查收", [("phone", "13812345678")]),
    # id card
    ("身份证号 11010519491231002X", [("id_card", "11010519491231002X")]),
    (
        "甲方 440305199901011235，乙方 510107200002293211",
        [("id_card", "440305199901011235"), ("id_card", "510107200002293211")],
    ),
    (
        "证件 11010519491231002x 与 11010519491231002X 是同一个人",
        [("id_card", "11010519491231002x"), ("id_card", "11010519491231002X")],
    ),
    # bank card
    ("银行卡号 6222 0212 3456 7890 128", [("bank_card", "6222 0212 3456 7890 128")]),
    ("卡号：6217-0000-1234-5670", [("bank_card", "6217-0000-1234-5670")]),
    ("测试卡 4111111111111111 已失效", [("bank_card", "4111111111111111")]),
    ("credit card 5500 0055 5555 5559", [("bank_card", "5500 0055 5555 5559")]),
    ("账号 1234567812345670", [("bank_card", "1234567812345670")]),
    ("JCB card 3530111333300000", [("bank_card", "3530111333300000")]),
    (
        "工资卡 6228480012345678903，报销也打到 6228 4800 1234 5678 903",
        [("bank_card", "6228480012345678903"), ("bank_card", "6228 4800 1234 5678 903")],
    ),
    # phone
    ("手机：13812345678", [("phone", "13812345678")]),
    ("电话 138 1234 5678，微信同号", [("phone", "138 1234 5678")]),
    ("call +86 139-1234-5678 after 6pm", [("phone", "+86 139-1234-5678")]),
    (
        "13712345678 / +86 137 1234 5678 / 86-137-1234-5678 是同一个号",
        [("phone", "13712345678"), ("phone", "+86 137 1234 5678"), ("phone", "86-137-1234-5678")],
    ),
    ("快递到了（尾号见短信），联系 19912340000。", [("phone", "19912340000")]),
    # landline
    ("办公室电话 010-62781234 转 801", [("landline", "010-62781234")]),
    ("前台 0755-8601-3388，分机另说", [("landline", "0755-8601-3388")]),
    ("London office +44 2071838750", [("landline", "+44 2071838750")]),
    ("酒店前台 +86-10-5550-0199，夜间不接", [("landline", "+86-10-5550-0199")]),
    ("总部 0755-86013388-8021", [("landline", "0755-86013388")]),
    # email
    (
        "请发到 Lin.ZhiYuan@QingChuan-U.example 或 lin.zhiyuan@qingchuan-u.example",
        [("email", "Lin.ZhiYuan@QingChuan-U.example"), ("email", "lin.zhiyuan@qingchuan-u.example")],
    ),
    (
        "Zane 的邮箱 zane_lin+nc27@mail.example.com，手机 15900001111",
        [("email", "zane_lin+nc27@mail.example.com"), ("phone", "15900001111")],
    ),
    ("From: Robotics Weekly <digest@robotics-weekly.example>", [("email", "digest@robotics-weekly.example")]),
    ("13812345678@163.com 是她的邮箱", [("phone", "13812345678")]),
    # ip
    ("ssh lin@192.0.2.10 -p 2222", [("ip", "192.0.2.10")]),
    ("服务跑在 198.51.100.7:8080/v1，出口 IP 是 203.0.113.1。", [("ip", "198.51.100.7"), ("ip", "203.0.113.1")]),
    # plate
    ("车停在 B2，车牌京A12345", [("plate", "京A12345")]),
    ("新能源 沪AD12345 和 粤B·8K2Q7", [("plate", "沪AD12345"), ("plate", "粤B·8K2Q7")]),
    ("教练车 京A1234学", [("plate", "京A1234学")]),
    # adjacency and multi-line
    ("Tel13812345678", [("phone", "13812345678")]),
    ("姓名：张三\n手机：13812345678\n邮箱：zs@example.com\n", [("phone", "13812345678"), ("email", "zs@example.com")]),
    # the bank keyword window counts Unicode scalars (9 emoji + space: keyword inside 12)
    ("卡号🙂🙂🙂🙂🙂🙂🙂🙂🙂 1234567812345670", [("bank_card", "1234567812345670")]),
    # the otp gap counts Unicode scalars (6 emoji)
    ("验证码🙂🙂🙂🙂🙂🙂1234", [("otp", "1234")]),
    # mixed and repeated
    (
        "Pls send the deck to anna.wu@startup.example, cc 李雷 (13900001111)；WiFi password: Qimu#2026",
        [("email", "anna.wu@startup.example"), ("phone", "13900001111"), ("password", "Qimu#2026")],
    ),
    (
        "韩策：13800001111，再说一遍 138-0000-1111，别记错",
        [("phone", "13800001111"), ("phone", "138-0000-1111")],
    ),
    (
        "出租方 吴秀兰，身份证 11010519491231002X，电话 010-62781234，"
        "收款 6222 0212 3456 7890 128，邮箱 wu.xl@example.org，车 京A12345",
        [
            ("id_card", "11010519491231002X"),
            ("landline", "010-62781234"),
            ("bank_card", "6222 0212 3456 7890 128"),
            ("email", "wu.xl@example.org"),
            ("plate", "京A12345"),
        ],
    ),
    # ---- spec v2 (privacy review F8) ----
    # verification codes: the code first, other keywords, a longer gap
    ("123456（登录验证码，5分钟内有效，请勿泄露）", [("otp", "123456")]),
    ("482913 is your Microsoft verification code", [("otp", "482913")]),
    ("【招商银行】739146（动态验证码）请勿泄露", [("otp", "739146")]),
    ("宠物店积分兑换要短信验证码，刚收到的是 2802", [("otp", "2802")]),
    ("短信校验码 739146，请在页面输入", [("otp", "739146")]),
    ("Your code is 551903", [("otp", "551903")]),
    # the code-first rule never takes a group of a longer number (here a phone number's last four digits)
    (
        "请打 138 1234 5678 或发 a.b@Example.com，验证码 482913。",
        [("phone", "138 1234 5678"), ("email", "a.b@Example.com"), ("otp", "482913")],
    ),
    ("卡号 6222 0212 3456 7894 的动态验证码稍后发", [("bank_card", "6222 0212 3456 7894")]),
    ("验证码🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂1234", [("otp", "1234")]),
    # passwords
    ("密码我私信你了：Kx9#mQ2v", [("password", "Kx9#mQ2v")]),
    ("The password for the NAS is Hunter22!", [("password", "Hunter22!")]),
    ("银行卡取款 PIN 739146", [("password", "739146")]),
    # phones written other ways (the same number gets the same tag)
    ("王师傅手机 138 1234\n5678", [("phone", "138 1234\n5678")]),
    ("王师傅手机 138\u00a01234\u00a05678", [("phone", "138\u00a01234\u00a05678")]),
    ("王师傅 138.1234.5678，联系电话 138·1234·5678", [("phone", "138.1234.5678"), ("phone", "138·1234·5678")]),
    ("王师傅手机１３８１２３４５６７８", [("phone", "１３８１２３４５６７８")]),
    ("我的手机号是一三八一二三四五六七八", [("phone", "一三八一二三四五六七八")]),
    ("138.1234.5678 和 13812345678 是同一个号", [("phone", "138.1234.5678"), ("phone", "13812345678")]),
    # landlines and numbers abroad
    ("公司座机 010 6278 1234", [("landline", "010 6278 1234")]),
    ("公司座机 (0755)86013388", [("landline", "(0755)86013388")]),
    ("Call Peggy at +1 (415) 555-0100", [("landline", "+1 (415) 555-0100")]),
    ("香港同事 9123 4567（WhatsApp）", [("landline", "9123 4567")]),
    # cards and accounts
    ("Amex card 3782 822463 10005 expires 09/28", [("bank_card", "3782 822463 10005")]),
    ("对公账号：755912345610801 开户行招商银行", [("bank_card", "755912345610801")]),
    ("卡号 6222 0212\n3456 7894", [("bank_card", "6222 0212\n3456 7894")]),
    # keys and secrets
    ("STRIPE_SECRET_KEY=sk_test_EXAMPLEKEY0000ABCD", [("secret", "sk_test_EXAMPLEKEY0000ABCD")]),
    (
        "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcDEF123ghiJKL456",
        [("secret", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcDEF123ghiJKL456")],
    ),
    (
        "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        [("secret", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")],
    ),
    ("阿里云 AccessKey LTAI5tQ2x8Zk9Ab3cD7eF1gH", [("secret", "LTAI5tQ2x8Zk9Ab3cD7eF1gH")]),
    ("API_KEY: 9f8e7d6c5b4a39281706f5e4d3c2b1a0", [("secret", "9f8e7d6c5b4a39281706f5e4d3c2b1a0")]),
    ("postgres://admin:S3cretPw@dbhost:5432/prod", [("secret", "S3cretPw")]),
    (
        "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU\n-----END",
        [("secret", "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU")],
    ),
    # ID numbers and e-mail
    ("身份证 110101 19900307 1234", [("id_card", "110101 19900307 1234")]),
    ("老身份证号 110101900307123", [("id_card", "110101900307123")]),
    ("邮箱 li.mu＠example.com", [("email", "li.mu＠example.com")]),
    # ---- spec v3 (masking evaluation, 2026-09-30) ----
    # a code handed over in conversation: keyword, then chat within the sentence, then 是 / 为 / a colon / "is"
    ("宠物店会员积分兑换要短信验证码，刚收到的是 2802", [("otp", "2802")]),
    ("短信验证码刚刚发过来了，我收到的是 2802", [("otp", "2802")]),
    ("验证码发你手机上了，收到之后告诉我是多少：4821", [("otp", "4821")]),
    ("登录的验证码……稍等一下哈，我看看是多少，好像是 928371", [("otp", "928371")]),
    ("The verification code we just texted you, as requested, is 604918.", [("otp", "604918")]),
    ("动态密码我这边显示的应该为 55120938", [("otp", "55120938")]),
    # the same code in two phrasings gets one placeholder
    ("验证码刚刚到了，是 2802；再说一遍验证码 2802", [("otp", "2802"), ("otp", "2802")]),
    # a phone number after the cue is still a phone number (the code rule takes 4-8 digits only)
    ("验证码发到了，手机号是 13812345678", [("phone", "13812345678")]),
]

# False-positive guards: nothing may be masked.
GUARDS = [
    "组会改到 2026-09-29 14:30，地点 B203",
    "截止 20260929 23:59 AoE",
    "预算 ¥12,800.00，已付 ¥3,200，余 ¥9,600.00",
    "实验编号 EXP-20260912-003 已归档",
    "Python 3.10.2 和 CUDA 12.4，驱动 550.54.15",
    "Twin-7 机器人今天标定，Twin-7 的夹爪换了",
    "卡号 6222021234567891（这串校验不对）",
    "订单号 2026092912345678 已发货",
    "编号 1234567812345670 只是批次号",
    "账号在备注里写过了，另外这是订单编号 1234567812345670",
    "会议室 A-1203，3 号楼 502 室，12F 茶水间",
    "学号 2021013456，工号 88012",
    "10012345678 和 12012345678 都不是手机号",
    "流水 20260929123 已入账",
    "时间 09:30-11:45，12:00 午饭",
    "arXiv:2409.12345，DOI 10.1145/3544548.3581234",
    "NC27-4471 投稿号，页数 9",
    "第3组做了12次实验，温度37.5度，成功率 83.3%",
    "坐标 31.2304,121.4737",
    "版本 v1.2.3.4，另一个是 1.2.3.4.5，还有 300.1.1.1",
    "loss 0.13812345678，lr 3e-4",
    "发票代码：144032000115，发票号码：88291044",
    "快递单号 SF1357924680114",
    "password reset link expires in 30 minutes",
    "密码长度至少 8 位，需要包含大小写",
    "passwordless ssh 已配置，cd $(pwd)/build",
    "验证码有效期 10 分钟",
    "OTP 功能在 2026 年上线",
    "task-management-pipeline-v2 和 sk-abcdefghijklmnopqrst 都不是密钥",
    "Bearer token 认证在 v2 里",
    "身份证号 110105194912310021（校验位不对）",
    "身份证号 510107200102293214（2001 年没有 2 月 29 日）",
    "新CUDA12 驱动，新H100 集群",
    "GPU 8 × H100，80GB，1,048,576 MB",
    "林知远 9 月 30 日在北京海淀区中关村大街 1 号付了 ¥3,000",
    "lin@devbox:~$ squeue -u lin",
    "@林知远 早，@韩策 下午见",
    "https://example.com/search?q=清川&page=2",
    "客服 400-820-8820，工作日 9:00-18:00",
    "尾号3842的包裹已到达，取件码 5-2-7031",
    "编号 138123456789 共 12 位",
    "序列号 ABC4111111111111111",
    "密码是什么来着？口令也忘了",
    "卡号🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂 1234567812345670",
    "验证码🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂1234",
    # ---- spec v2 guards ----
    "我今天写了 1234 行 code，明天提交",
    "error code 5003 已修复",
    "密码学课程：周三 14:00 上课",
    "PIN 码在卡背面",
    "第 2024 期验证码活动",
    "共发送 5000 条验证码短信",
    "2026-09-30 的验证码已作废",
    "打印 2 份，编号 2026 0930",
    "账号 123456（6 位）",
    "对公账号：7559 1234 待补全",
    "我的 token: abc123",
    "https://example.com:8443/path?q=1",
    "邮箱写成 a＠b 不完整",
    "一三五七九是奇数",
    "１２３４５ 是全角数字",
    "订单 110101900307123 已发货",
    "版本号 1.3.8 已发布，下载 1234.5678 次",
    # ---- spec v3 guards ----
    "验证码的事情已经解决了，谢谢大家。下午的会议室是 3021",
    "验证码这件事我们回头再说，先把明天上午开会要用的材料、投影仪和签到表都准备好，另外打印机的纸也要补上，房间号是 4021",
    "验证码有效期为 1800 秒，过期重发",
    "验证码登录那个需求，排期是 2026 年 10 月",
    "验证码短信的单价是 0.045 元",
    "OTP sent; the balance is 4521",
]

# Already-masked inputs: masking must return them unchanged.
IDEMPOTENT_EXTRA = [
    "〔手机号〕 已隐藏，〔邮箱〕 也是",
    "〔验证码〕1234 是占位符后面的数字",
    "〔密码·abc123〕 和 〔验证码·123456〕",
]


def _fix_guard_ids():
    # make sure the invalid-date ID guard really has a valid check digit, so it
    # fails only because of the date
    w, c = mask_ref._ID_WEIGHTS, mask_ref._ID_CHECK
    p17 = "51010720010229321"
    good = p17 + c[sum(int(p17[i]) * w[i] for i in range(17)) % 11]
    for i, g in enumerate(GUARDS):
        if "510107200102293214" in g:
            GUARDS[i] = g.replace("510107200102293214", good)


_fix_guard_ids()


def build():
    vectors = []
    problems = []
    for text, want in POSITIVE:
        masked, spans = mask_ref.mask(text, MASK_KEY)
        got = [(s["type"], s["original"]) for s in spans]
        if got != want:
            problems.append((text, want, got))
        vectors.append({"input": text, "expected": masked})
    for text in GUARDS:
        masked, spans = mask_ref.mask(text, MASK_KEY)
        if spans or masked != text:
            problems.append((text, [], [(s["type"], s["original"]) for s in spans]))
        vectors.append({"input": text, "expected": text})
    # idempotence: every 4th positive output, fed back in, plus hand-made ones
    idem_inputs = [v["expected"] for v in vectors[: len(POSITIVE) : 4]] + IDEMPOTENT_EXTRA
    idem_inputs.append(
        "〔手机号·" + mask_ref.tag(MASK_KEY, "phone", "13812345678") + "〕 和 13900001111"
    )
    for text in idem_inputs[:-1]:
        masked, spans = mask_ref.mask(text, MASK_KEY)
        if spans or masked != text:
            problems.append((text, [], [(s["type"], s["original"]) for s in spans]))
        vectors.append({"input": text, "expected": text})
    last = idem_inputs[-1]
    masked, spans = mask_ref.mask(last, MASK_KEY)
    if [(s["type"], s["original"]) for s in spans] != [("phone", "13900001111")]:
        problems.append((last, [("phone", "13900001111")], spans))
    vectors.append({"input": last, "expected": masked})

    derive = []
    for lk in DERIVE_LIBRARY_KEYS:
        key_id, store_key, mask_key = mask_ref.derive_keys(lk)
        derive.append(
            {
                "library_key_hex": lk.hex(),
                "key_id": key_id,
                "store_key_hex": store_key.hex(),
                "mask_key_hex": mask_key.hex(),
                "sqlcipher_pragma": 'PRAGMA key = "x\'' + store_key.hex() + '\'";',
            }
        )
    doc = {
        "spec": mask_ref.SPEC_VERSION,
        "mask_key_hex": MASK_KEY.hex(),
        "placeholder_format": "〔<label>·<first 6 lowercase hex of HMAC-SHA256(mask_key, type + \":\" + normalized)>〕",
        "labels": {k: mask_ref.LABELS[k] for k in mask_ref.ORDER},
        "order": list(mask_ref.ORDER),
        "derive": derive,
        "vectors": vectors,
    }
    return doc, problems


def serialize(doc) -> bytes:
    return (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def main(argv):
    doc, problems = build()
    if problems:
        for text, want, got in problems:
            print("MISMATCH:", text, "\n  want:", want, "\n  got: ", got, file=sys.stderr)
        return 1
    data = serialize(doc)
    if "--check" in argv:
        with open(OUT, "rb") as fh:
            same = fh.read() == data
        print("up to date" if same else "STALE")
        return 0 if same else 1
    with open(OUT, "wb") as fh:
        fh.write(data)
    print(len(doc["vectors"]), "vectors;", "sha256", hashlib.sha256(data).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
