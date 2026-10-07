#!/usr/bin/env python3
"""On-device zh-CN recognition bench for 织机 on a real iPhone (DEBUG build).

Synthetic speech only: the clips are made on the Mac with `say -v Tingting`
from the sentences below, copied into the app's data container and fed to the
voice session through the DEBUG audio-file hook. No microphone, no real voice,
no network (the Speech model download is the system's own). Audio never goes
into Git; keep the bench directory on the build volume.

  device_voice_bench.py make  <bench-dir>
  device_voice_bench.py run   <bench-dir> --device <udid> [--background-app <bundle-id>]
  device_voice_bench.py score <bench-dir>/results.json <bench-dir>/references.json

`run` copies <bench-dir>/{clips,background} to Documents/bench in the app's
data container, launches the app with the bench arguments, optionally sends it
to the background by launching another app once the foreground clips are
done, and copies results.json back.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import shutil
import tempfile
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

# The installed app (iOS/project.yml MINDLOOM_PHONE_BUNDLE_ID; device_build.sh PHONE_BUNDLE_ID).
BUNDLE_ID = os.environ.get("PHONE_BUNDLE_ID", "app.mindloom")
VOICE = "Tingting"

# Realistic dictation: lab chat, meeting next steps, times and numbers.
# Numbers are written the way they are spoken, so the reference is exact.
SHORT = [
    ("s01", "\u5E08\u5144，模型今晚跑完，明早我把结果发群里。"),
    ("s02", "下周二上午十点开组会，记得把实验数据整理好。"),
    ("s03", "这次训练用了八张卡，一共跑了三十六个小时。"),
    ("s04", "我晚上七点半到实验室，帮我留个座位。"),
    ("s05", "会议的下一步是先确定预算，再联系供应商。"),
    ("s06", "论文初稿周五之前发给导师看一下。"),
    ("s07", "测试集的准确率从百分之八十二提高到了百分之八十九。"),
    ("s08", "明天下午三点在三楼会议室讨论新版本的发布计划。"),
    ("s09", "把这个bug修好以后再提交代码。"),
    ("s10", "快递放在楼下门卫那里，下班记得去拿。"),
]
LONG = [
    (
        "l01",
        "今天的组会主要讨论了三件事。第一，数据清洗的脚本已经写完，下周一开始跑全量数据。"
        "第二，新模型在验证集上的效果比基线好一些，但是推理速度慢了大约百分之二十。"
        "第三，下个月的投稿截止时间是十五号，大家需要在十号之前把各自负责的部分写完。",
    ),
    (
        "l02",
        "明天上午我先去图书馆查几篇相关的论文，中午回实验室吃饭。"
        "下午两点和合作方开一个线上会议，确认一下接口的格式。"
        "晚上如果有时间的话，再把上周的实验重新跑一遍，看看结果是不是稳定。",
    ),
    (
        "l03",
        "王老师您好，上次您提到的那个数据集我们已经下载好了，一共大概有十二万条记录。"
        "我们打算先抽取一千条做人工标注，估计需要两周时间。"
        "标注规范写好以后我会先发给您过目，有问题请随时告诉我。",
    ),
    (
        "l04",
        "提醒一下自己，周四下午四点要去学院办公室交材料，记得带上学生证和两张一寸照片。"
        "周五晚上八点和朋友在学校东门吃饭，一共六个人，我已经订好了靠窗的位置。",
    ),
    (
        "l05",
        "这个版本主要修复了三个问题。第一个是在网络不好的时候上传会失败，现在加了自动重试。"
        "第二个是夜间模式下有几处文字颜色看不清。"
        "第三个是导出文件时文件名里的空格会被换成下划线，这个行为已经改回来了。",
    ),
]
# Run again from the background after 60 s there: one short, one long.
BACKGROUND = ["s08", "l01"]


# ---------------------------------------------------------------- make


def make(bench: Path) -> None:
    clips = bench / "clips"
    background = bench / "background"
    for folder in (clips, background):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
    references = {}
    for clip_id, text in SHORT + LONG:
        out = clips / f"{clip_id}.wav"
        subprocess.run(
            ["say", "-v", VOICE, "-o", str(out), "--file-format=WAVE",
             "--data-format=LEI16@16000", text],
            check=True,
        )
        references[out.name] = text
    for index, clip_id in enumerate(BACKGROUND, 1):
        name = f"bg{index}_{clip_id}.wav"
        shutil.copy(clips / f"{clip_id}.wav", background / name)
        references[name] = dict(SHORT + LONG)[clip_id]
    (bench / "references.json").write_text(
        json.dumps(references, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for path in sorted(clips.glob("*.wav")):
        with wave.open(str(path)) as audio:
            seconds = audio.getnframes() / audio.getframerate()
        print(f"{path.name}  {seconds:5.1f} s  {references[path.name]}")


# ---------------------------------------------------------------- run


def devicectl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["xcrun", "devicectl", "device", *args], check=check, capture_output=True, text=True)


def pull(device: str, bench: Path) -> dict | None:
    out = bench / "results.json"
    result = devicectl(
        "copy", "from", "--device", device, "--domain-type", "appDataContainer",
        "--domain-identifier", BUNDLE_ID, "--source", "Documents/bench/results.json",
        "--destination", str(out), check=False)
    if result.returncode != 0 or not out.exists():
        return None
    try:
        return json.loads(out.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def run(bench: Path, device: str, background_app: str | None, timeout: float) -> None:
    # One copy of both folders: with Xcode 27's devicectl, "--remove-existing-content" on a second
    # copy into Documents/bench/<folder> empties Documents/bench, so the first folder vanished.
    with tempfile.TemporaryDirectory() as staging:
        for folder in ("clips", "background"):
            shutil.copytree(bench / folder, Path(staging) / folder)
        devicectl(
            "copy", "to", "--device", device, "--domain-type", "appDataContainer",
            "--domain-identifier", BUNDLE_ID, "--source", staging,
            "--destination", "Documents/bench", "--remove-existing-content", "true")
    first = sorted((bench / "clips").glob("*.wav"))[0].name
    devicectl(
        "process", "launch", "--device", device, "--terminate-existing", BUNDLE_ID,
        # "--" keeps devicectl (Xcode 27) from reading "-MindloomVoiceFile" as its own "-l".
        "--",
        "-MindloomVoiceFile", f"Documents/bench/clips/{first}",
        "-MindloomDebugVoiceBench", "Documents/bench",
        "-pairingDeferred", "YES")
    print(f"launched with {first}")
    expected = len(list((bench / "clips").glob("*.wav")))
    sent_to_background = False
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        time.sleep(10)
        report = pull(device, bench)
        if report is None:
            continue
        summary = (report.get("session_status"), len(report.get("clips", [])),
                   (report.get("background") or {}).get("status"), report.get("done"))
        if summary != last:
            print(f"{time.strftime('%H:%M:%S')} session={summary[0]} clips={summary[1]}/{expected} "
                  f"background={summary[2]} done={summary[3]}")
            last = summary
        if report.get("done"):
            return
        if (background_app and not sent_to_background and report.get("background")
                and report["background"].get("status", "").startswith("waiting")):
            devicectl("process", "launch", "--device", device, background_app)
            sent_to_background = True
            print(f"sent the app to the background by opening {background_app}")
    print("timed out waiting for the bench", file=sys.stderr)


# ---------------------------------------------------------------- score

CHINESE_DIGITS = "零一二三四五六七八九"


def cardinal(number: int) -> str:
    """Mandarin reading of a non-negative integer below 10^8."""
    if number < 10:
        return CHINESE_DIGITS[number]
    if number >= 10_000:
        high, low = divmod(number, 10_000)
        text = cardinal(high) + "万"
        if low:
            text += ("零" if low < 1000 else "") + cardinal(low)
        return text
    units = [(1000, "千"), (100, "百"), (10, "十")]
    text = ""
    pending_zero = False
    for value, unit in units:
        digit, number = divmod(number, value)
        if digit:
            if pending_zero:
                text += "零"
                pending_zero = False
            text += CHINESE_DIGITS[digit] + unit
        elif text:
            pending_zero = True
    if number:
        if pending_zero:
            text += "零"
        text += CHINESE_DIGITS[number]
    if text.startswith("一十"):
        text = text[1:]
    return text


def readings(token: str) -> list[str]:
    """Every plausible spoken form of a digit token from the recognizer."""
    if "." in token:
        whole, fraction = token.split(".", 1)
        heads = readings(whole) if whole else [""]
        tail = "".join(CHINESE_DIGITS[int(d)] for d in fraction)
        return [head + "点" + tail for head in heads]
    forms = ["".join(CHINESE_DIGITS[int(d)] for d in token)]
    if not (len(token) > 1 and token.startswith("0")) and len(token) <= 8:
        forms.append(cardinal(int(token)))
    forms += [form.replace("二", "两", 1) for form in forms if form.startswith("二")]
    return list(dict.fromkeys(forms))


def strip(text: str) -> str:
    """NFKC, lowercase, no punctuation or spaces; digits kept as they are."""
    text = unicodedata.normalize("NFKC", text).lower().replace("〇", "零")
    return "".join(ch for ch in text if ch.isalnum() or ch in ".:%")


def expand_times(text: str) -> list[str]:
    match = re.search(r"(\d{1,2}):(\d{2})", text)
    if not match:
        return [text]
    hour, minute = match.group(1), int(match.group(2))
    spoken = [f"{hour}点{minute}分"]
    if minute == 30:
        spoken.append(f"{hour}点半")
    if minute == 0:
        spoken.append(f"{hour}点")
    return [v for s in spoken for v in expand_times(text[: match.start()] + s + text[match.end():])]


def distance(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def number_insensitive(hypothesis: str, reference: str) -> str:
    """The hypothesis with every digit token rewritten to the spoken form
    that matches the reference best (format, not content, is forgiven)."""
    best_text, best_cost = None, None
    for timed in expand_times(hypothesis):
        timed = re.sub(r"(\d+(?:\.\d+)?)%", r"百分之\1", timed)
        parts = re.split(r"(\d+(?:\.\d+)?)", timed)
        choices = [readings(p) if i % 2 else [p.replace(".", "").replace(":", "")]
                   for i, p in enumerate(parts)]
        # Coordinate descent over the digit tokens (few tokens per clip).
        picked = [c[0] for c in choices]
        for _ in range(2):
            for index, options in enumerate(choices):
                if len(options) < 2:
                    continue
                costs = []
                for option in options:
                    trial = picked[:index] + [option] + picked[index + 1:]
                    costs.append((distance("".join(trial), reference), option))
                picked[index] = min(costs)[1]
        text = "".join(picked)
        cost = distance(text, reference)
        if best_cost is None or cost < best_cost:
            best_text, best_cost = text, cost
    return best_text or ""


def score(results_path: Path, references_path: Path) -> None:
    report = json.loads(results_path.read_text(encoding="utf-8"))
    references = json.loads(references_path.read_text(encoding="utf-8"))
    clips = list(report.get("clips", [])) + list((report.get("background") or {}).get("clips", []))
    rows = []
    totals = {"foreground": [0, 0, 0], "background": [0, 0, 0]}
    for clip in clips:
        reference = strip(references[clip["file"]]).replace(".", "").replace(":", "").replace("%", "")
        hypothesis = clip.get("text") or ""
        raw = distance(strip(hypothesis).replace(".", "").replace(":", ""), reference)
        normalized = distance(number_insensitive(strip(hypothesis), reference), reference)
        bucket = totals[clip["phase"]]
        bucket[0] += raw
        bucket[1] += normalized
        bucket[2] += len(reference)
        rows.append((clip, raw / len(reference), normalized / len(reference), hypothesis))
    print("| clip | phase | audio s | first partial ms | final after release ms | raw CER | CER (number format forgiven) | transcript |")
    print("|---|---|---|---|---|---|---|---|")
    for clip, raw, normalized, hypothesis in rows:
        seconds = (clip.get("duration_ms") or 0) / 1000
        print(f"| {clip['file']} | {clip['phase']} | {seconds:.1f} | {clip.get('first_partial_ms', '–')} | "
              f"{clip.get('final_after_release_ms', '–')} | {raw:.1%} | {normalized:.1%} | "
              f"{hypothesis or clip.get('error') or clip.get('outcome')} |")
    for phase, (raw, normalized, length) in totals.items():
        if length:
            print(f"\n{phase}: raw CER {raw / length:.2%}, number-format-forgiven CER "
                  f"{normalized / length:.2%} over {length} reference characters")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("make")
    p.add_argument("bench", type=Path)
    p = sub.add_parser("run")
    p.add_argument("bench", type=Path)
    p.add_argument("--device", required=True)
    p.add_argument("--background-app")
    p.add_argument("--timeout", type=float, default=1800)
    p = sub.add_parser("score")
    p.add_argument("results", type=Path)
    p.add_argument("references", type=Path)
    args = parser.parse_args()
    if args.command == "make":
        make(args.bench)
    elif args.command == "run":
        run(args.bench, args.device, args.background_app, args.timeout)
    else:
        score(args.results, args.references)


if __name__ == "__main__":
    main()
