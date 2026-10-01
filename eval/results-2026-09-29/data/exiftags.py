import sys, struct, collections, json
import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parents[3] / "spark"))
from organizer.db import open_for_analysis  # noqa: E402  (plaintext or synthetic-key encrypted store)
c = open_for_analysis(sys.argv[1])
tags = collections.Counter(); gps = 0; n = 0
names = {0x010F: "Make", 0x0110: "Model", 0x0112: "Orientation", 0x011A: "XResolution", 0x011B: "YResolution",
         0x0128: "ResolutionUnit", 0x0131: "Software", 0x0132: "DateTime", 0x8769: "ExifIFD", 0x8825: "GPSIFD",
         0xA002: "PixelXDimension", 0xA003: "PixelYDimension", 0xA001: "ColorSpace", 0x9003: "DateTimeOriginal",
         0x9004: "DateTimeDigitized", 0x927C: "MakerNote", 0x9286: "UserComment", 0xA433: "LensMake", 0xA434: "LensModel"}


def ifd(buf, off, e, depth=0):
    out = []
    if off + 2 > len(buf):
        return out
    cnt = struct.unpack(e + "H", buf[off:off + 2])[0]
    for i in range(cnt):
        p = off + 2 + 12 * i
        if p + 12 > len(buf):
            break
        tag, typ, num, val = struct.unpack(e + "HHII", buf[p:p + 12])
        out.append(tag)
        if tag == 0x8769 and depth == 0:
            out += ifd(buf, val, e, 1)
    return out


for (d,) in c.execute("select data from item_blobs where mime='image/jpeg'"):
    n += 1
    i = d.find(b"Exif\x00\x00")
    if i < 0:
        continue
    t = d[i + 6:i + 6 + 65536]
    e = "<" if t[:2] == b"II" else ">"
    off = struct.unpack(e + "I", t[4:8])[0]
    ts = ifd(t, off, e)
    for tg in set(ts):
        tags[names.get(tg, hex(tg))] += 1
    if 0x8825 in ts:
        gps += 1
print(json.dumps({"jpeg": n, "exif_tags_seen": dict(tags), "with_gps_ifd": gps}))
