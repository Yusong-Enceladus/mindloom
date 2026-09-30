# Aggregate-only egress census of an organizer.db (what the Spark actually received from the Mac). Prints no content.
import sqlite3, sys, json, collections, re
p = sys.argv[1]
c = sqlite3.connect("file:" + p + "?mode=ro", uri=True)
children = {r[0] for r in c.execute("select child_id from item_segments")}
seg_cols = [r[1] for r in c.execute("pragma table_info(items)")]
out = {"db": p.split("/hack/")[-1], "items_total_rows": 0, "received": {}, "blobs": {}, "spark_created_segments": len(children)}
agg = collections.defaultdict(lambda: collections.Counter())
first_rev = {}
for row in c.execute("select item_id, revision, kind, source_app, text, segments, persons, has_image from items"):
    iid, rev, kind, app, text, segs, persons, has_img = row
    out["items_total_rows"] += 1
    if iid in children:
        continue
    a = agg[kind]
    a["rows"] += 1
    if rev == 1: a["items"] += 1
    a["text_bytes"] += len((text or "").encode())
    a["segments_bytes"] += len((segs or "").encode())
    a["persons_bytes"] += len((persons or "").encode())
    a["has_image"] += int(has_img or 0)
out["received"] = {k: dict(v) for k, v in agg.items()}
mimes = collections.Counter(); mbytes = collections.Counter(); biggest = 0
for iid, rev, mime, n in c.execute("select item_id, revision, mime, length(data) from item_blobs"):
    mimes[mime] += 1; mbytes[mime] += n; biggest = max(biggest, n)
out["blobs"] = {m: {"count": mimes[m], "bytes": mbytes[m]} for m in mimes}
out["blob_max_bytes"] = biggest
# any audio anywhere? (mime or a RIFF/ID3/ftyp/OggS/fLaC magic in blobs)
magic = c.execute("select count(*) from item_blobs where substr(data,1,4) in (x'52494646', x'4F676753', x'664C6143') or substr(data,1,3)=x'494433' or mime like 'audio/%' or mime like 'video/%'").fetchone()[0]
out["audio_or_video_blobs"] = magic
# JPEG EXIF (APP1 'Exif') present in image blobs?
exif = 0; nj = 0
for (d,) in c.execute("select data from item_blobs where mime in ('image/jpeg','image/jpg')"):
    nj += 1
    if b"Exif\x00\x00" in d[:65536]: exif += 1
out["jpeg_blobs"] = nj; out["jpeg_with_exif"] = exif
png_exif = 0; npng = 0
for (d,) in c.execute("select data from item_blobs where mime='image/png'"):
    npng += 1
    if b"eXIf" in d: png_exif += 1
out["png_blobs"] = npng; out["png_with_exif"] = png_exif
# segments: what fields does a transcript segment carry? (keys only)
keys = collections.Counter()
for (s,) in c.execute("select segments from items where segments is not null and segments != '' and segments != '[]' limit 2000"):
    try:
        for seg in json.loads(s):
            keys.update(seg.keys())
    except Exception:
        pass
out["segment_keys"] = dict(keys)
pk = collections.Counter()
for (s,) in c.execute("select persons from items where persons is not null and persons != '' and persons != '[]' limit 2000"):
    try:
        for q in json.loads(s):
            pk.update(q.keys() if isinstance(q, dict) else ["<str>"])
    except Exception:
        pass
out["person_keys"] = dict(pk)
# embedding-like float arrays in received segment/person fields (voiceprints would be long float vectors)
vec = 0
for (s,) in c.execute("select coalesce(segments,'') || coalesce(persons,'') from items"):
    if re.search(r"\[(-?\d+\.\d+,\s*){32,}", s or ""): vec += 1
out["received_rows_with_float_vectors_ge32"] = vec
out["inbox_rows"] = c.execute("select count(*) from inbox").fetchone()[0]
print(json.dumps(out, ensure_ascii=False))
