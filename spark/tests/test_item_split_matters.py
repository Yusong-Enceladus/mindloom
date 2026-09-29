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
