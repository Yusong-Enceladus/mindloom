"""Adversarial review of privacy contract v6, Spark side: the review's proofs, kept as regression tests.

Each test proves one finding of the v6 privacy review (review/FINDINGS.md, F-numbers below): it encodes what the
contract promises. They failed on the reviewed branch (ef3392a) and pass with the fixes; tests/test_privacy_fixes.py
covers the fixes these do not. F13 is a documented limitation, kept here as an expected failure. Invented content
only.
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import zipfile

import pytest
from fastapi.testclient import TestClient

from conftest import TEST_KEY, assign_out, default_brief, chat_extraction, image_reader, make_item, raw_connect
from organizer import keys, masking
from organizer.api import build_organizer, create_app
from organizer.clients import HashEmbedClient

SENTINEL = "哨兵QRWZ字样"


def post(c, *items):
    return c.post("/v1/items", json={"items": list(items)})


def decrypted_dump(path) -> str:
    """Every row of every table, read with the test key (what someone holding the key could see)."""
    conn = raw_connect(path)
    try:
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        out = []
        for t in tables:
            for row in conn.execute(f'SELECT * FROM "{t}"'):
                out.append(t + ": " + repr([v.decode("utf-8", "replace") if isinstance(v, bytes) else v
                                            for v in row]))
        return "\n".join(out)
    finally:
        conn.close()


def where(dump: str, needle: str) -> list[str]:
    """table: ...context... for every row that still holds `needle`."""
    out = []
    for line in dump.splitlines():
        i = line.find(needle)
        if i >= 0:
            out.append(line.split(":", 1)[0] + ": …" + line[max(0, i - 60):i + 40] + "…")
    return out


def png(width: int = 96, height: int = 96) -> bytes:
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (width, height), (240, 240, 240)).save(buf, "PNG")
    return buf.getvalue()


# ---- F7: read-then-delete misses superseded revisions ------------------------------------------------


def test_bytes_of_a_revision_superseded_before_it_was_read_are_deleted(org, client, chat):
    """Contract §0.4 / §2: image and file bytes are deleted once read; /v1/stats blob_bytes must reach 0.
    A revision replaced before the worker read it is marked 'superseded' and never read, so its bytes stay."""
    shot = make_item(kind="image", image_b64=base64.b64encode(png()).decode())
    assert post(client, shot).json()["accepted"] == 1
    # the Mac re-sends the item (a caption edit, a re-normalized copy) before the Spark got to it
    assert post(client, dict(shot, revision=2, image_b64=base64.b64encode(png(97, 97)).decode())).json()["accepted"] == 1
    org.drain()
    left = org.store.all("SELECT revision, LENGTH(data) AS n FROM item_blobs WHERE item_id=?", (shot["item_id"],))
    assert client.get("/v1/stats").json()["blob_bytes"] == 0, f"bytes kept for superseded revisions: {left}"


# ---- F5: purge scope (and F6: keyframes of a deleted recording) ------------------------------------


def test_delete_leaves_no_copy_in_an_event_the_item_was_moved_out_of(org, client, chat):
    """Contract §2 DELETE: runs.output about the item and briefs that quote it are cleared. purge_item only
    looks at events the item is in *now* (removed=0); an event it left keeps the brief runs that quoted it."""
    keep = make_item("咖啡馆菜单周五定下来", minutes=0)
    gone = make_item(f"咖啡馆门头招牌下周装，师傅说{SENTINEL}", minutes=5)

    def paraphrasing_brief(data, schema):
        # A real brief paraphrases: it quotes the item, but not from its first character.
        if not any(SENTINEL in i["text"] for i in data["items"]):
            return default_brief(data, schema)
        line = f"招牌下周装，{SENTINEL}"
        return {"title": "咖啡馆安排", "status_line": line + "。", "off_anchor_item_ids": [],
                "status_facts": [{"text": line, "state": "info", "date": "", "quote": "",
                                  "item_ids": [data["items"][-1]["item_id"]]}]}

    chat.handlers["event-brief"] = paraphrasing_brief
    post(client, keep, gone)
    org.drain()  # one 咖啡馆 event whose card quotes `gone` (not from its first character)
    assert SENTINEL in decrypted_dump(org.store.path)
    first = org.store.current_event_link(gone["item_id"])["event_id"]
    r = client.post("/v1/decisions", json={"decisions": [
        {"kind": "file_item_new_event", "item_id": gone["item_id"]}]}).json()
    assert r["applied"] == 1
    org.drain()
    assert org.store.current_event_link(gone["item_id"])["event_id"] != first
    assert SENTINEL not in json.dumps(org.store.get_event(first), ensure_ascii=False)  # its card was rewritten
    assert client.delete(f"/v1/items/{gone['item_id']}").json() == {"deleted": True}
    org.drain()
    dump = decrypted_dump(org.store.path)
    assert SENTINEL not in dump, f"deleted item's text still in: {where(dump, SENTINEL)}"


def test_delete_leaves_no_copy_in_a_user_deleted_event(org, client, chat):
    """A user-deleted event keeps its item links and card; the worker never re-briefs a deleted event, so the
    card text written from the deleted item stays."""
    keep = make_item("咖啡馆菜单周五定下来", minutes=0)
    gone = make_item(f"咖啡馆{SENTINEL}门头招牌下周装", minutes=5)
    post(client, keep, gone)
    org.drain()
    ev = org.store.current_event_link(gone["item_id"])["event_id"]
    assert SENTINEL in org.store.get_event(ev)["status_line"]
    assert client.post("/v1/decisions", json={"decisions": [
        {"kind": "delete_event", "event_id": ev}]}).json()["applied"] == 1
    assert client.delete(f"/v1/items/{gone['item_id']}").json() == {"deleted": True}
    org.drain()
    dump = decrypted_dump(org.store.path)
    assert SENTINEL not in dump, f"deleted item's text still in: {where(dump, SENTINEL)}"


def test_delete_does_not_rely_on_a_successful_rebrief(org, client, chat):
    """purge_item drops facts citing the item but leaves the event's title and status line to the next brief.
    When that brief fails (model down, or invalid output twice: "previous card kept"), the card written from
    the deleted item stays in the store and is served to the Mac by /v1/state."""
    keep = make_item("咖啡馆菜单周五定下来", minutes=0)
    gone = make_item(f"咖啡馆{SENTINEL}门头招牌下周装", minutes=5)
    post(client, keep, gone)
    org.drain()
    ev = org.store.current_event_link(gone["item_id"])["event_id"]
    assert SENTINEL in org.store.get_event(ev)["status_line"]
    chat.handlers["event-brief"] = lambda data, schema: {"title": ""}  # the rebrief fails validation
    assert client.delete(f"/v1/items/{gone['item_id']}").json() == {"deleted": True}
    org.drain()
    served = json.dumps(client.get("/v1/state").json()["events"], ensure_ascii=False)
    assert SENTINEL not in served, "the Mac is still served a card quoting the deleted item"


def test_delete_clears_the_event_anchor_the_item_seeded(org, client, chat):
    """events.anchor is set once from the seed item's object (event-assign item_object) and never rewritten
    by a brief. Deleting the seed item leaves it on an event that still has other items."""
    gone = make_item(f"咖啡馆{SENTINEL}门头招牌下周装", minutes=0)
    keep = make_item("咖啡馆菜单周五定下来", minutes=5)
    chat.push("event-assign", assign_out("new", obj=f"咖啡馆{SENTINEL}招牌"))
    post(client, gone, keep)
    org.drain()
    ev = org.store.current_event_link(keep["item_id"])["event_id"]
    assert org.store.current_event_link(gone["item_id"])["event_id"] == ev
    assert client.delete(f"/v1/items/{gone['item_id']}").json() == {"deleted": True}
    org.drain()
    anchor = org.store.get_event(ev)["anchor"]
    assert SENTINEL not in anchor, f"anchor written from the deleted item kept: {anchor!r}"


def test_delete_while_a_brief_is_being_written_leaves_no_copy(org, client, chat):
    """The purge clears runs and proposals *before* an in-flight event-brief returns; the brief's run record and
    its 'superseded' proposal are then written with the deleted item's text (no tombstone check on an event
    subject)."""
    keep = make_item("咖啡馆菜单周五定下来", minutes=0)
    post(client, keep)
    org.drain()
    gone = make_item(f"咖啡馆{SENTINEL}门头招牌下周装", minutes=5)
    post(client, gone)

    def delete_during_the_brief(_data):
        client.delete(f"/v1/items/{gone['item_id']}")

    chat.before["event-brief"] = delete_during_the_brief
    org.drain()
    dump = decrypted_dump(org.store.path)
    assert SENTINEL not in dump, f"deleted item's text still in: {where(dump, SENTINEL)}"


def test_deleting_a_recording_also_deletes_its_keyframes(org, client, chat):
    """Keyframes of a recording are separate kind=image items (parent_item_id). The Mac deletes only the
    recording's session and queues only its id; the Spark purge does not follow parent_item_id either, so the
    keyframe readings (text burned into the video) stay."""
    rec = make_item("会议录音：咖啡馆装修", kind="imported_media", minutes=0)
    frame = make_item(kind="image", image_b64=base64.b64encode(png()).decode(), minutes=0)
    frame.update(parent_item_id=rec["item_id"], frame_ms=12_000)
    chat.handlers["image-read"] = image_reader(chat_extraction(
        [{"sender": "投影", "is_self": False, "time": "", "text": f"装修预算 {SENTINEL} 共 18 万"}], "装修预算"))
    post(client, rec, frame)
    org.drain()
    assert SENTINEL in decrypted_dump(org.store.path)
    assert client.delete(f"/v1/items/{rec['item_id']}").json() == {"deleted": True}
    org.drain()
    dump = decrypted_dump(org.store.path)
    assert SENTINEL not in dump, f"keyframe reading of the deleted recording still in: {where(dump, SENTINEL)}"


# ---- F12: defence-in-depth masking misses a text field; purge keeps it ----------------------------------


def test_incoming_source_app_name_is_masked_again_and_purged(org, client):
    """Contract §3: incoming text fields are masked again on the Spark. mask_incoming skips source_app.name, and
    the integrity trigger forbids a purge from clearing it."""
    it = make_item("咖啡馆菜单周五定下来", app="微信 - 王师傅 13812345678")
    post(client, it)
    stored = org.store.one("SELECT source_app FROM items WHERE item_id=?", (it["item_id"],))["source_app"]
    assert "13812345678" not in stored, f"unmasked number stored: {stored}"


# ---- F3: pictures inside file bytes reach the vision model unredacted --------------------------------------


FILE_WRAPS = ["png_named_xlsx", "zip_of_pngs_named_xlsx", "scanned_pdf", "docx_with_screenshot",
              "iwork_preview"]


@pytest.mark.parametrize("wrap", FILE_WRAPS)
def test_a_file_item_never_sends_an_unredacted_image_to_the_vision_model(org, client, chat, wrap):
    """Contract §4: only the Mac's redacted send copy of an image may reach a model. The Mac sends these as file
    bytes without redaction: by extension (isSendableFile: a PNG or a zip renamed .xlsx), a PDF with any page
    lacking a text layer ("scanned pages go as the file itself"), every .docx/.odt/.doc (even though the Mac reads
    their text), and an iWork package's preview. The Spark sniffs content and renders / extracts the pictures
    and reads them with the vision model as screenshots."""
    import filefixtures as F
    shot = png(400, 300)
    name = "报销.xlsx"
    if wrap == "png_named_xlsx":
        data = shot
    elif wrap == "zip_of_pngs_named_xlsx":
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("身份证正面.png", shot)
            z.writestr("身份证反面.png", png(401, 300))
        data = buf.getvalue()
    elif wrap == "scanned_pdf":
        data, name = F.scanned_pdf(1), "身份证扫描.pdf"
    elif wrap == "docx_with_screenshot":
        data, name = F.docx(["报销说明，截图见下"], image=F.png(400, 300, "13812345678")), "报销说明.docx"
    else:
        data, name = F.iwork_with_preview(F.png(400, 300, "13812345678")), "方案.key"
    f = make_item(kind="file")
    f.update(filename=name, bytes_b64=base64.b64encode(data).decode(), sha256=hashlib.sha256(data).hexdigest())
    post(client, f)
    org.drain()
    images_seen = [c for c in chat.calls if c[0] == "image-read" or any(
        isinstance(m.get("content"), list) and any(p.get("type") == "image_url" for p in m["content"])
        for m in c[3])]
    assert not images_seen, f"{len(images_seen)} model call(s) got raw image bytes from a file named .xlsx"


# ---- F8: masking false negatives on common formats -------------------------------------------------------

KEY = bytes([0x11]) * 32

COMMON = [
    # (id, text, the value that must not survive)
    ("otp_number_first_zh", "123456（登录验证码，5分钟内有效，请勿泄露）", "123456"),
    ("otp_number_first_en", "482913 is your Microsoft verification code", "482913"),
    ("otp_gap_over_6", "宠物店积分兑换要短信验证码，刚收到的是 2802", "2802"),
    ("otp_jiaoyanma", "短信校验码 739146，请在页面输入", "739146"),
    ("otp_code_is", "Your code is 551903", "551903"),
    ("password_chat_order", "密码我私信你了：Kx9#mQ2v", "Kx9#mQ2v"),
    ("password_for_x_is", "The password for the NAS is Hunter22!", "Hunter22!"),
    ("pin", "银行卡取款 PIN 739146", "739146"),
    ("phone_newline_split", "王师傅手机 138 1234\n5678", "5678"),
    ("phone_nbsp", "王师傅手机 138 1234 5678", "1234 5678"),
    ("phone_dots", "王师傅 138.1234.5678", "1234.5678"),
    ("phone_fullwidth", "王师傅手机１３８１２３４５６７８", "１２３４５６７８"),
    ("phone_spoken_hanzi", "我的手机号是一三八一二三四五六七八", "一二三四五六七八"),
    ("landline_space", "公司座机 010 6278 1234", "6278 1234"),
    ("landline_parens", "公司座机 (0755)86013388", "86013388"),
    ("us_phone", "Call Peggy at +1 (415) 555-0100", "555-0100"),
    ("hk_phone_no_plus", "香港同事 9123 4567（WhatsApp）", "9123 4567"),
    ("amex_15", "Amex card 3782 822463 10005 expires 09/28", "822463"),
    ("corp_account_non_luhn", "对公账号：755912345610801 开户行招商银行", "755912345610801"),
    ("bank_card_newline", "卡号 6222 0212\n3456 7894", "3456 7894"),
    ("stripe_live", "STRIPE_SECRET_KEY=sk_test_EXAMPLEKEY0000ABCD", "EXAMPLEKEY0000ABCD"),
    ("jwt", "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcDEF123ghiJKL456", "eyJhbGciOiJIUzI1NiJ9"),
    ("aws_secret", "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"),
    ("aliyun_ak", "阿里云 AccessKey LTAI5tQ2x8Zk9Ab3cD7eF1gH", "LTAI5tQ2x8Zk9Ab3cD7eF1gH"),
    ("env_api_key", "API_KEY: 9f8e7d6c5b4a39281706f5e4d3c2b1a0", "9f8e7d6c5b4a39281706f5e4d3c2b1a0"),
    ("db_url_password", "postgres://admin:S3cretPw@dbhost:5432/prod", "S3cretPw"),
    ("pem_private_key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU\n-----END",
     "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU"),
    ("id_card_spaced", "身份证 110101 19900307 1234", "19900307 1234"),
    ("id_card_15", "老身份证号 110101900307123", "110101900307123"),
    ("email_fullwidth_at", "邮箱 li.mu＠example.com", "li.mu"),
]


@pytest.mark.parametrize("case", COMMON, ids=[c[0] for c in COMMON])
def test_common_identifier_formats_are_masked(case):
    _id, text, value = case
    masked = masking.mask(text, KEY)[0]
    assert value not in masked, f"{text!r} -> {masked!r}"


# ---- F4: "forget me" races a model call in flight ------------------------------------------------------

OTHER_KEY = bytes([0x77]) * 32


@pytest.fixture
def locked(settings, chat):
    settings.unlock_key = None
    org = build_organizer(settings, chat=chat, embedder=HashEmbedClient())
    app = create_app(settings, organizer=org)
    with TestClient(app, headers={"Authorization": f"Bearer {app.state.link_token}"}) as c:
        c.org = org
        yield c


def test_a_model_call_in_flight_during_wipe_writes_nothing_into_the_next_store(locked, settings, chat):
    """Contract §0.5 / §6: "make the Spark forget me" wipes everything; the Mac then unlocks at once with a new
    key (forgetOnOrganizer -> loadKeys -> startRuntime). A model call already in flight when the wipe lands
    returns into the *new* store: the worker checks the unlock session only between jobs, and the write paths
    only check tombstones (none exist in a fresh store)."""
    c, org = locked, locked.org
    assert c.post("/v1/unlock", json={"key": TEST_KEY.hex()}).status_code == 200
    c.headers["X-Mindloom-Access"] = keys.access_proof(TEST_KEY)
    chat.handlers["image-read"] = image_reader(chat_extraction(
        [{"sender": "王师傅", "is_self": False, "time": "10:02", "text": f"门头尺寸 {SENTINEL}"}], "门头尺寸"))
    shot = make_item(kind="image", image_b64=base64.b64encode(png()).decode())
    assert post(c, shot).json()["accepted"] == 1
    old_key_id = keys.derive_keys(TEST_KEY)[0]

    def forget_during_the_call(_data):
        assert c.post("/v1/wipe", json={"key_id": old_key_id}).json() == {"wiped": True}
        assert c.post("/v1/unlock", json={"key": OTHER_KEY.hex()}).json()["created"] is True

    chat.before["image-read"] = forget_during_the_call
    org.drain()
    new_store = settings.data_dir / "organizer.db"
    from organizer import db
    conn = db.connect(new_store, keys.derive_keys(OTHER_KEY)[1])
    try:
        rows = [t + ": " + repr(r) for t in ("item_derived", "runs", "proposals", "events")
                for r in conn.execute(f"SELECT * FROM {t}").fetchall()]
    finally:
        conn.close()
    leaked = [r for r in rows if SENTINEL in r]
    assert not leaked, f"the forgotten library's content was written into the new store: {leaked}"


# ---- F13: placeholders of short identifiers are invertible by whoever holds the library key ---------------


@pytest.mark.xfail(strict=True, reason="F13, documented limitation (docs/PRIVACY.md): the Spark holds the key its "
                                      "placeholder tags are made with while it is unlocked, so a short value can be "
                                      "found again by trying all of them; masking keeps values out of prompts, the "
                                      "model server and logs, not away from whoever holds the library key")
def test_a_verification_code_placeholder_cannot_be_inverted_with_the_key_the_spark_holds():
    """Contract §1: the Spark derives mask_key from library_key (in its memory while unlocked). A 24-bit HMAC tag
    over a 6-digit code is inverted by trying the 10^6 codes: masking hides short values from the model server
    and logs, not from the Spark process or anyone who obtains the key there."""
    import hmac as _hmac
    mask_key = keys.derive_keys(TEST_KEY)[2]
    placeholder = masking.mask("验证码 482913", mask_key)[0].split(" ", 1)[1]
    tag = placeholder.split("·")[1][:6]
    hits = [f"{n:06d}" for n in range(1_000_000)
            if _hmac.new(mask_key, f"otp:{n:06d}".encode(), hashlib.sha256).hexdigest()[:6] == tag]
    assert hits != ["482913"], f"{placeholder} inverted to {hits} with the Spark-side key"
