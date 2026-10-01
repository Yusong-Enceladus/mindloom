"""item-split 1.2.0 (from claude/scale-quality): only substantial matters split; no-matter segments stay
unfiled. Fake model, invented data."""

from __future__ import annotations

from conftest import event_of, ingest, make_item


def _units_mod(org):
    return org.registry.script("item-split", "units")


def test_one_matter_with_a_one_line_aside_is_not_split(org):
    units = _units_mod(org)
    text = ("咖啡馆的新菜单这周要定下来，先把拿铁和手冲的价格核一遍。甜品那边再加两款季节限定，周五试吃。"
            "试吃完了把最终菜单发给设计师排版，下周一送印。对了，记得多喝水。")
    us = units.build_units(text)
    last = us[-1]["u"]
    out = {"matters": ["咖啡馆新菜单", "喝水"],
           "segments": [{"from": "U1", "to": us[-2]["u"], "matter": 1, "gist": "新菜单定价和试吃"},
                        {"from": last, "to": last, "matter": 2, "gist": "多喝水"}]}
    assert units.segments_from_output(out, us) == []


def test_three_short_matters_still_split(org):
    units = _units_mod(org)
    text = ("菜园那边的浇水排班我改好了，周二周四归我，周六归隔壁的罗阿姨，下周开始执行。给我爸买的助听器戴着有啸叫，"
            "店里说七天内可以退，我明天上午拿过去。读书会下个月的场地还没定，图书馆的活动室要提前两周申请，我今晚就在网上填表。")
    us = units.build_units(text)
    assert units.prefilter(text, len(us), "dictation")
    out = {"matters": ["菜园浇水排班", "助听器退货", "读书会场地"],
           "segments": [{"from": u["u"], "to": u["u"], "matter": n, "gist": "x"} for n, u in enumerate(us, 1)]}
    assert len(units.segments_from_output(out, us)) == 3


def test_no_matter_segment_is_unfiled_without_an_assign_call(org, chat):
    text = ("甲(00:00:03):\n先说咖啡馆，咖啡馆的豆子下周换供应商，报价每公斤一百二。\n\n乙(00:00:40):\n咖啡馆豆子我来谈，周三给答复。\n\n"
            "甲(00:01:10):\n中午吃什么？楼下那家面馆又涨价了，真离谱。\n\n乙(00:01:40):\n哈哈，那就点外卖吧。\n\n"
            "甲(00:02:10):\n再说读书会，读书会下个月的书目定了吗？\n\n乙(00:02:50):\n读书会书目我周五发群里。\n")

    def split(data, schema):
        u = [x["u"] for x in data["units"]]
        return {"matters": ["咖啡馆豆子供应商", "读书会书目"],
                "segments": [{"from": u[0], "to": u[1], "matter": 1, "gist": "豆子换供应商"},
                             {"from": u[2], "to": u[3], "matter": 0, "gist": "午饭闲聊"},
                             {"from": u[4], "to": u[5], "matter": 2, "gist": "读书会书目"}]}
    chat.handlers["item-split"] = split
    item = make_item(text, kind="meeting_online", app="腾讯会议")
    ingest(org, item)
    org.drain()
    segs = org.store.segments_of(item["item_id"])
    assert [s["no_matter"] for s in segs] == [0, 1, 0]
    chit = segs[1]["child_id"]
    assert org.store.is_unfiled(chit) and event_of(org, chit) is None
    assert all(d["item"]["text"].find("面馆") < 0 for s, d, _, _ in chat.calls if s == "event-assign")
    unfiled = org.state(0)["unfiled"]
    assert any(u.get("seg_id") == segs[1]["seg_id"] and u["item_id"] == item["item_id"] for u in unfiled)


# ---- item-split 1.3.0: the user's current matters (known_matters) --------------------------------------

THREE = ("菜园那边的浇水排班我改好了，周二周四归我，周六归隔壁的罗阿姨，下周开始执行。给我爸买的助听器戴着有啸叫，"
         "店里说七天内可以退，我明天上午拿过去。读书会下个月的场地还没定，图书馆的活动室要提前两周申请，我今晚就在网上填表。")


def test_matters_under_the_same_known_matter_are_one_matter(org):
    units = _units_mod(org)
    us = units.build_units(THREE)
    seg = [{"from": u["u"], "to": u["u"], "matter": n, "gist": "x"} for n, u in enumerate(us, 1)]
    same = {"matters": ["排班", "退货", "场地"], "known": ["E4", "E4", "E4"], "segments": seg}
    assert units.segments_from_output(same, us) == []                       # all one known matter: whole
    two = {"matters": ["排班", "退货", "场地"], "known": ["E4", "", "E4"], "segments": seg}
    parts = units.segments_from_output(two, us)
    assert [p["matter"] for p in parts] == [1, 2, 1]                        # the two E4 parts are matter 1
    assert len(units.segments_from_output(dict(two, known=["", "", ""]), us)) == 3


def test_known_matters_are_the_largest_events_in_creation_order(org):
    units = _units_mod(org)
    events = [{"id": f"E{n}", "title": f"事{n}", "n": n, "order": n} for n in range(1, 40)]
    known = units.known_matters(events)
    assert len(known) == units.KNOWN_MAX and known[0]["id"] == "E16" and known[-1]["id"] == "E39"
    assert units.known_matters([{"id": "E1", "title": "小事", "n": 2, "order": 1}]) == []


def test_a_known_id_that_was_not_shown_is_rejected_and_salvaged(org):
    units = _units_mod(org)
    validator = org.registry.for_job("split").validator
    us = units.build_units(THREE)
    ids = [u["u"] for u in us]
    out = {"matters": ["排班", "退货"], "known": ["E4", "E99"],
           "segments": [{"from": ids[0], "to": ids[0], "matter": 1, "gist": "x"},
                        {"from": ids[1], "to": ids[2], "matter": 2, "gist": "y"}]}
    ctx = {"unit_ids": ids, "known": ["E4"]}
    errors = validator(out, ctx)
    assert errors and all(e.startswith("known") for e in errors)
    fixed = units.salvage(out, errors, lambda o: validator(o, ctx))
    assert fixed["known"] == ["E4", ""]


def test_the_organizer_shows_item_split_its_largest_events(org, chat):
    for n in range(4):
        ingest(org, make_item(f"咖啡馆的豆子第{n}批到了", minutes=n))
    org.drain()
    long = make_item(THREE + "咖啡馆的豆子也要再订一批。", minutes=30)
    ingest(org, long)
    org.drain()
    data = [c[1] for c in chat.calls if c[0] == "item-split"][-1]
    assert [k["title"] for k in data.get("known_matters", [])] and all(k["id"].startswith("E") for k in data["known_matters"])


def test_an_output_with_an_unused_matter_or_overlapping_segments_is_repaired(org):
    units = _units_mod(org)
    validator = org.registry.for_job("split").validator
    us = units.build_units(THREE)
    ids = [u["u"] for u in us]
    ctx = {"unit_ids": ids, "known": []}
    out = {"matters": ["排班", "没用上", "场地"], "known": ["", "", ""],
           "segments": [{"from": ids[2], "to": ids[2], "matter": 3, "gist": "场地"},
                        {"from": ids[0], "to": ids[1], "matter": 1, "gist": "排班"},
                        {"from": ids[1], "to": ids[1], "matter": 1, "gist": "重叠"}]}
    errors = validator(out, ctx)
    fixed = units.salvage(out, errors, lambda o: validator(o, ctx))
    assert fixed["matters"] == ["排班", "场地"] and [g["matter"] for g in fixed["segments"]] == [1, 2]
    assert [g["from"] for g in fixed["segments"]] == [ids[0], ids[2]]
    assert units.salvage(dict(out, segments=[{"from": "U9", "to": "U1", "matter": 1, "gist": "x"}]),
                         ["segments[0]: unknown unit id"], lambda o: validator(o, ctx)) is None


def test_a_passing_mention_of_another_matter_does_not_split_a_long_item(org):
    units = _units_mod(org)
    main = "".join(f"新菜单第{n}项的定价、原料和试吃安排都要在周五前定下来，价格再和供应商核一遍。" for n in range(12))
    text = main + "对了，家里热水器又坏了。"
    us = units.build_units(text)
    last = us[-1]["u"]
    out = {"matters": ["咖啡馆新菜单", "热水器报修"], "known": ["", ""],
           "segments": [{"from": "U1", "to": us[-2]["u"], "matter": 1, "gist": "新菜单"},
                        {"from": last, "to": last, "matter": 2, "gist": "热水器坏了"}]}
    assert units.segments_from_output(out, us) == []            # 12 characters of a 400-character item
    long_second = "".join(f"排练室装修期间要找临时场地，第{n}个备选是街道图书馆的多功能厅，周三去看。" for n in range(5))
    us2 = units.build_units(main + long_second)
    k = next(i for i, u in enumerate(us2) if "排练室" in u["text"])
    out2 = {"matters": ["咖啡馆新菜单", "临时排练场地"], "known": ["", ""],
            "segments": [{"from": "U1", "to": us2[k - 1]["u"], "matter": 1, "gist": "新菜单"},
                         {"from": us2[k]["u"], "to": us2[-1]["u"], "matter": 2, "gist": "临时场地"}]}
    assert len(units.segments_from_output(out2, us2)) == 2      # a second matter of 150+ characters still splits
