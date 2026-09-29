#!/usr/bin/env python3

"""Build a content-isolated FLEURS + synthetic ASR tuning corpus.

The public transcripts and audio remain below the caller-provided external
corpus root. Only a content-free manifest is suitable for Git.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import tarfile
import uuid


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )


def atomic_write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(canonical_json(value))
    os.replace(temporary, path)


def require_keys(value: dict, keys: tuple[str, ...], context: str) -> None:
    missing = [key for key in keys if key not in value]
    if missing:
        raise ValueError(f"{context} is missing required fields")


def verify_artifact(path: Path, specification: dict) -> None:
    require_keys(specification, ("fileName", "sizeBytes", "sha256"), "artifact")
    if not path.is_file():
        raise ValueError("pinned public corpus artifact is unavailable")
    if path.stat().st_size != specification["sizeBytes"]:
        raise ValueError("pinned public corpus artifact has the wrong size")
    if sha256(path) != specification["sha256"]:
        raise ValueError("pinned public corpus artifact has the wrong digest")


def duration_band(duration: float, bands: list[dict]) -> str | None:
    for band in bands:
        if band["minimumSeconds"] <= duration < band["maximumSecondsExclusive"]:
            return band["id"]
    return None


def load_rows(metadata_path: Path, subset: dict, selection: dict) -> list[dict]:
    bands = selection["durationBands"]
    groups: dict[tuple[str, str], list[dict]] = {}
    with metadata_path.open("r", encoding="utf-8", newline="") as source:
        for fields in csv.reader(source, delimiter="\t"):
            if len(fields) != 7:
                raise ValueError("unexpected FLEURS metadata row shape")
            sample_id, file_name, raw_text, normalized_text, characters, frames, gender = (
                fields
            )
            if not re.fullmatch(r"[0-9]+\.wav", file_name):
                raise ValueError("unsafe FLEURS audio file name")
            if not raw_text.strip() or not normalized_text.strip() or not characters.strip():
                raise ValueError("incomplete FLEURS transcript metadata")
            try:
                frame_count = int(frames)
                int(sample_id)
            except ValueError as error:
                raise ValueError("invalid FLEURS numeric metadata") from error
            if gender not in {"FEMALE", "MALE"} or frame_count <= 0:
                raise ValueError("invalid FLEURS sample metadata")
            seconds = frame_count / 16_000.0
            band = duration_band(seconds, bands)
            if band is None:
                continue
            row = {
                "fileName": file_name,
                "reference": normalized_text.strip(),
                "frames": frame_count,
                "gender": gender,
                "band": band,
            }
            groups.setdefault((gender, band), []).append(row)

    selected: list[dict] = []
    count = selection["samplesPerGenderAndBand"]
    revision = subset["datasetRevision"]
    for gender in ("FEMALE", "MALE"):
        for band in bands:
            key = (gender, band["id"])
            candidates = groups.get(key, [])
            if len(candidates) < count:
                raise ValueError("FLEURS stratum does not contain enough samples")
            candidates.sort(
                key=lambda row: hashlib.sha256(
                    (
                        f"{revision}:{subset['id']}:dev:{row['fileName']}"
                    ).encode("utf-8")
                ).hexdigest()
            )
            selected.extend(candidates[:count])
    return selected


def copy_verified(source: Path, destination: Path, expected_digest: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if not destination.is_file() or sha256(destination) != expected_digest:
            raise ValueError("existing prepared corpus file failed verification")
        return
    temporary = destination.with_name(destination.name + ".tmp")
    shutil.copyfile(source, temporary)
    if sha256(temporary) != expected_digest:
        temporary.unlink(missing_ok=True)
        raise ValueError("prepared corpus copy failed verification")
    os.replace(temporary, destination)


def read_wave_metadata(path: Path) -> tuple[int, int, int]:
    """Return channels, sample rate, and frame count for PCM/float WAV."""

    format_fields: tuple[int, int, int] | None = None
    data_size: int | None = None
    with path.open("rb") as source:
        header = source.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise ValueError("selected FLEURS audio is not a RIFF/WAVE file")
        while True:
            chunk_header = source.read(8)
            if not chunk_header:
                break
            if len(chunk_header) != 8:
                raise ValueError("selected FLEURS WAV has a truncated chunk header")
            chunk_id, chunk_size = struct.unpack("<4sI", chunk_header)
            chunk_start = source.tell()
            if chunk_id == b"fmt ":
                chunk = source.read(chunk_size)
                if len(chunk) != chunk_size or chunk_size < 16:
                    raise ValueError("selected FLEURS WAV has an invalid format chunk")
                format_tag, channels, sample_rate, _, block_align, bits = struct.unpack(
                    "<HHIIHH", chunk[:16]
                )
                if format_tag not in {1, 3, 0xFFFE} or bits <= 0:
                    raise ValueError("selected FLEURS WAV uses an unsupported format")
                format_fields = (channels, sample_rate, block_align)
            elif chunk_id == b"data":
                data_size = chunk_size
            source.seek(chunk_start + chunk_size + (chunk_size & 1))

    if format_fields is None or data_size is None:
        raise ValueError("selected FLEURS WAV is missing required chunks")
    channels, sample_rate, block_align = format_fields
    if channels <= 0 or block_align <= 0 or data_size % block_align != 0:
        raise ValueError("selected FLEURS WAV has invalid frame alignment")
    return channels, sample_rate, data_size // block_align


def extract_selected(
    archive_path: Path, destination_root: Path, rows: list[dict]
) -> dict[str, str]:
    digests: dict[str, str] = {}
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for row in rows:
            member_name = f"dev/{row['fileName']}"
            try:
                member = archive.getmember(member_name)
            except KeyError as error:
                raise ValueError("selected FLEURS audio is missing from archive") from error
            if not member.isfile() or member.name != member_name:
                raise ValueError("unsafe FLEURS archive member")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ValueError("unable to read selected FLEURS audio")
            destination = destination_root / row["fileName"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_name(destination.name + ".tmp")
            with temporary.open("wb") as output:
                shutil.copyfileobj(extracted, output)
            source_digest = sha256(temporary)
            if destination.exists() and sha256(destination) == source_digest:
                temporary.unlink()
            else:
                os.replace(temporary, destination)
            channels, sample_rate, frame_count = read_wave_metadata(destination)
            if (
                channels != 1
                or sample_rate != 16_000
                or frame_count != row["frames"]
            ):
                raise ValueError("selected FLEURS WAV metadata does not match source")
            digests[row["fileName"]] = sha256(destination)
    return digests


def load_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--downloads-root", required=True, type=Path)
    parser.add_argument("--corpus-root", required=True, type=Path)
    parser.add_argument("--synthetic-run", required=True, type=Path)
    parser.add_argument("--synthetic-manifest", required=True, type=Path)
    parser.add_argument("--synthetic-audio-root", required=True, type=Path)
    arguments = parser.parse_args()

    plan = load_json(arguments.plan)
    require_keys(
        plan,
        (
            "schemaVersion",
            "kind",
            "datasetID",
            "datasetRevision",
            "split",
            "manifestID",
            "version",
            "runID",
            "stageRunIDs",
            "sampleNamespace",
            "selection",
            "subsets",
            "syntheticComponent",
        ),
        "evaluation plan",
    )
    if (
        plan["schemaVersion"] != 1
        or plan["kind"] != "fleurs-public-asr-evaluation-plan"
        or plan["split"] != "dev"
        or len(plan["subsets"]) != 2
    ):
        raise ValueError("unsupported public ASR evaluation plan")
    namespace = uuid.UUID(plan["sampleNamespace"])
    uuid.UUID(plan["runID"])
    for language in ("zh-CN", "en-US"):
        uuid.UUID(plan["stageRunIDs"][language])
    selection = plan["selection"]
    if (
        selection.get("strategy") != "sha256-stratified-gender-duration"
        or selection.get("referenceField") != "normalized_transcription"
        or not isinstance(selection.get("samplesPerGenderAndBand"), int)
        or selection["samplesPerGenderAndBand"] <= 0
        or len(selection.get("durationBands", [])) != 3
    ):
        raise ValueError("invalid public ASR selection policy")

    corpus_root = arguments.corpus_root.resolve()
    audio_root = corpus_root / "audio"
    corpus_root.mkdir(parents=True, exist_ok=True)
    local_samples: list[dict] = []
    content_samples: list[dict] = []

    synthetic_run = load_json(arguments.synthetic_run)
    synthetic_manifest = load_json(arguments.synthetic_manifest)
    component = plan["syntheticComponent"]
    if (
        synthetic_run.get("manifestID") != component["manifestID"]
        or synthetic_run.get("version") != component["version"]
        or synthetic_manifest.get("manifestID") != component["manifestID"]
        or synthetic_manifest.get("version") != component["version"]
    ):
        raise ValueError("synthetic ASR component does not match the plan")
    manifest_by_uuid = {
        sample["sampleUUID"]: sample for sample in synthetic_manifest["samples"]
    }
    for sample in synthetic_run["samples"]:
        source = (arguments.synthetic_audio_root / sample["relativeAudioPath"]).resolve()
        if not source.is_file() or arguments.synthetic_audio_root.resolve() not in source.parents:
            raise ValueError("unsafe synthetic ASR audio path")
        content = manifest_by_uuid.get(sample["sampleUUID"])
        if content is None or sha256(source) != content["contentDigest"]:
            raise ValueError("synthetic ASR component failed verification")
        destination = audio_root / "product-synthetic" / source.name
        copy_verified(source, destination, content["contentDigest"])
        local_sample = dict(sample)
        local_sample["relativeAudioPath"] = f"product-synthetic/{source.name}"
        local_samples.append(local_sample)

    expected_public_count = 0
    for configured_subset in plan["subsets"]:
        subset = dict(configured_subset)
        subset["datasetRevision"] = plan["datasetRevision"]
        require_keys(
            subset,
            ("id", "language", "languageTag", "metadata", "audioArchive"),
            "FLEURS subset",
        )
        download_directory = arguments.downloads_root / subset["id"]
        metadata_path = download_directory / subset["metadata"]["fileName"]
        archive_path = download_directory / subset["audioArchive"]["fileName"]
        verify_artifact(metadata_path, subset["metadata"])
        verify_artifact(archive_path, subset["audioArchive"])
        rows = load_rows(metadata_path, subset, selection)
        expected_subset_count = (
            2
            * len(selection["durationBands"])
            * selection["samplesPerGenderAndBand"]
        )
        if len(rows) != expected_subset_count:
            raise ValueError("public ASR subset selection count is unstable")
        expected_public_count += expected_subset_count
        digests = extract_selected(
            archive_path, audio_root / "fleurs" / subset["id"], rows
        )
        for row in rows:
            sample_uuid = uuid.uuid5(
                namespace,
                (
                    f"{plan['datasetID']}:{plan['datasetRevision']}:"
                    f"{subset['id']}:dev:{row['fileName']}"
                ),
            )
            gender_tag = row["gender"].lower()
            relative_path = f"fleurs/{subset['id']}/{row['fileName']}"
            tags = sorted(
                {
                    "asr",
                    "fleurs",
                    subset["languageTag"],
                    "local-only",
                    "public-licensed",
                    "read-speech",
                    "real-human",
                    gender_tag,
                    row["band"],
                    "tuning",
                }
            )
            local_samples.append(
                {
                    "sampleUUID": str(sample_uuid),
                    "relativeAudioPath": relative_path,
                    "languages": [subset["language"]],
                    "tags": tags,
                    "reference": row["reference"],
                    "dictionaryTerms": [],
                    "dangerousTokens": [],
                }
            )
            content_samples.append(
                {
                    "sampleUUID": str(sample_uuid),
                    "consentClass": "public",
                    "assetReference": (
                        "external-corpus://google-fleurs/"
                        f"{plan['datasetRevision']}/{subset['id']}/dev/"
                        f"{row['fileName']}"
                    ),
                    "contentDigest": digests[row["fileName"]],
                    "languages": [subset["language"]],
                    "tags": tags,
                }
            )

    if (
        expected_public_count != 48
        or len(content_samples) != 48
        or len(local_samples) != 64
    ):
        raise ValueError("combined public ASR tuning corpus has an unexpected size")
    if len({sample["sampleUUID"] for sample in local_samples}) != len(local_samples):
        raise ValueError("combined public ASR tuning corpus has duplicate sample IDs")

    local_samples.sort(key=lambda sample: sample["sampleUUID"])
    content_samples.sort(key=lambda sample: sample["sampleUUID"])
    def write_local_run(path: Path, run_id: str, samples: list[dict]) -> None:
        atomic_write_json(
            path,
            {
                "schemaVersion": 1,
                "kind": "alpha-asr-local-corpus-run",
                "runID": run_id,
                "manifestID": plan["manifestID"],
                "version": plan["version"],
                "samples": samples,
            },
        )

    write_local_run(corpus_root / "local-run.json", plan["runID"], local_samples)
    for language, suffix in (("zh-CN", "zh"), ("en-US", "en")):
        stage_samples = [
            sample
            for sample in local_samples
            if (
                ("real-human" in sample["tags"] and language in sample["languages"])
                or sample["languages"] == [language]
                or "silence" in sample["tags"]
                or "noise" in sample["tags"]
            )
        ]
        if len(stage_samples) != 32:
            raise ValueError("stage-specific ASR tuning corpus has an unexpected size")
        write_local_run(
            corpus_root / f"local-run-{suffix}.json",
            plan["stageRunIDs"][language],
            stage_samples,
        )
    atomic_write_json(
        corpus_root / "content-manifest.json",
        {
            "schemaVersion": 1,
            "kind": "corpus-manifest",
            "manifestID": plan["manifestID"],
            "version": plan["version"],
            "tier": "public",
            "releaseHoldout": False,
            "containsPrivateContent": False,
            "samples": content_samples,
        },
    )
    print(f"public ASR tuning corpus prepared: {len(local_samples)} samples")
    print(f"public real-human samples: {expected_public_count}")
    print("stage-specific samples: zh-CN=32 en-US=32")


if __name__ == "__main__":
    main()
