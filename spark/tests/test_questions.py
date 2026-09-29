from organizer.decisions import answer_question

from conftest import assign_out, event_of, ingest, make_item


def _ask_always(data, schema):
    """The model reports doubt about the best candidate (the organizer decides whether to ask)."""
    if not data["candidates"]:
        return assign_out("new", obj="待确认事项", reason="没有候选")
    cand = data["candidates"][0]
    first = cand["first_item"]["item_id"]
    return assign_out("ask", cand["event_id"], obj="待确认事项", judged=[{"event_id": cand["event_id"], "match": "unsure"}],
                      reason="时间相近但对象不确定", item_ids=[first])


def test_ask_creates_one_question_and_keeps_item_in_its_own_event(org, chat):
    first = make_item("咖啡馆菜单", minutes=0)
    ingest(org, first)
    org.drain()
    chat.handlers["event-assign"] = _ask_always
    second = make_item("周五要确认的事", minutes=5)
    ingest(org, second)
    org.drain()
    qs = org.state(0)["questions"]
    assert len(qs) == 1
    q = qs[0]
    assert q["kind"] == "same_event" and q["a"] == second["item_id"] and q["b"] == event_of(org, first["item_id"])
    assert "是同一件事吗" in q["prompt_zh"]
    assert event_of(org, second["item_id"]) != event_of(org, first["item_id"])
    row = org.store.one("SELECT * FROM questions WHERE question_id=?", (q["question_id"],))
    assert row["day_key"] == second["started_at"][:10]
    assert '"action":"new"' in row["provisional"] and first["item_id"] in row["b_items_at_ask"]


def test_same_event_questions_have_their_own_open_and_daily_budget(org, chat):
    ingest(org, make_item("咖啡馆菜单", minutes=0))
    org.drain()
    chat.handlers["event-assign"] = _ask_always
    for i in range(5):
        ingest(org, make_item(f"待确认事项{i}", minutes=10 + i))
    org.drain()
    # max 2 same_event questions per item-day (and max 2 open per kind); the rest stay provisional "new"
    assert len(org.store.open_questions()) == 2
    budget = org.store.all("SELECT reason FROM proposals WHERE kind='assign' AND reason LIKE 'ask_budget%'")
    assert len(budget) == 3
    # the grammar never changes with the question budget: ask is always offered
    enums = [c[2]["properties"]["decision"]["enum"] for c in chat.calls if c[0] == "event-assign"]
    assert all(e == ["attach", "new", "none", "ask"] for e in enums)


def test_answer_yes_moves_item_and_cleans_up(org, chat):
    first = make_item("咖啡馆菜单", minutes=0)
    ingest(org, first)
    org.drain()
    chat.handlers["event-assign"] = _ask_always
    second = make_item("周五要确认的事", minutes=5)
    ingest(org, second)
    org.drain()
    q = org.store.open_questions()[0]
    provisional = event_of(org, second["item_id"])
    assert answer_question(org, q["question_id"], True)[0] == 200
    org.drain()
    assert event_of(org, second["item_id"]) == event_of(org, first["item_id"])
    assert org.store.get_event(provisional)["deleted"]
    assert org.state(0)["questions"] == []
    assert answer_question(org, q["question_id"], True)[0] == 200  # idempotent
    assert answer_question(org, q["question_id"], False)[0] == 409
    assert answer_question(org, "missing", True)[0] == 404


def test_answer_no_is_a_permanent_constraint(org, chat):
    first = make_item("咖啡馆菜单", minutes=0)
    ingest(org, first)
    org.drain()
    chat.handlers["event-assign"] = _ask_always
    second = make_item("周五要确认的事", minutes=5)
    ingest(org, second)
    org.drain()
    q = org.store.open_questions()[0]
    target = q["b"]
    assert answer_question(org, q["question_id"], False)[0] == 200
    assert org.store.has_constraint("forbid_item_event", second["item_id"], target)
    # never asked again about the same item
    ingest(org, dict(second, revision=2, text="周五要确认的事（补充）"))
    org.drain()
    assert org.store.open_questions() == []
    assert event_of(org, second["item_id"]) != target
