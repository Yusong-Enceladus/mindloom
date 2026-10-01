"""Regressions found by the first evaluation run on the Sparks (2026-09-26). All data invented."""

from conftest import TINY_PNG_B64, event_of, ingest, make_item


def test_rejected_image_read_still_places_the_item(org, chat):
    # A text-only model answers an image request with HTTP 400 (the client raises ValueError).
    # The item must still be organized instead of failing its job three times and never being placed.
    def reject(data, schema):
        raise ValueError('HTTP 400: {"error": "model is not a multimodal model"}')

    chat.handlers["image-read"] = reject
    note = make_item("咖啡馆菜单周五定")
    shot = make_item(kind="image", minutes=5, image_b64=TINY_PNG_B64)
    ingest(org, note, shot)
    org.drain()
    assert event_of(org, shot["item_id"]) is not None
    job = org.store.one("SELECT state FROM jobs WHERE item_id=?", (shot["item_id"],))
    assert job["state"] == "done"
    # contract v6 (read-then-delete): the image is not kept for a later try; the item is marked unreadable
    # and its bytes are deleted, so nothing but the (empty) reading stays on the Spark
    derived = org.store.get_derived(shot["item_id"], shot["revision"])
    assert derived["screenshot_run_id"] == "unreadable:1" and derived["reading"]["error"] == "unreadable"
    assert org.store.get_blob(shot["item_id"], shot["revision"]) is None
    assert org.state(0)["readings"][shot["item_id"]]["error"] == "unreadable"
