#!/usr/bin/env python3
"""Current Delivery XCTest evidence; never converts historical AX probe results."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from datetime import datetime, timezone
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
SUITES = (
    "BoundarySpacingTests", "DeliveryInsertionPortTests", "DeliveryVerdictTests",
    "PasteboardPromiseTests",
)
KIND = "delivery-policy-test-contract"


def source_contract():
    package = ROOT / "Packages/BestASRCore"
    tests = package / "Tests/BestASRDeliveryTests"
    required = set()
    for suite in SUITES:
        names = re.findall(r"^\s*func (test\w+)\s*\(", (tests / (suite + ".swift")).read_text(), re.M)
        if not names or len(names) != len(set(names)):
            raise ValueError("missing-or-duplicate-source-tests")
        required.update(suite + "/" + name for name in names)
    files = list((package / "Sources/BestASRDelivery").glob("*.swift"))
    files += [tests / (suite + ".swift") for suite in SUITES]
    files += [package / "Sources/BestASRDictation" / name for name in ("DictationTypes.swift", "DictationPorts.swift")]
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes() + b"\0")
    return required, digest.hexdigest()


def summarize(report_path, exit_code):
    required, digest = source_contract()
    issues = []
    observed = {}
    if exit_code != 0:
        issues.append("test-command-failed")
    try:
        report = ET.parse(report_path).getroot()
        if report.tag not in ("testsuites", "testsuite"):
            raise ValueError("unsupported report")
        for suite in report.iter("testsuite"):
            for key in ("failures", "errors", "skipped"):
                if int(suite.get(key, "0")) != 0:
                    issues.append("suite-" + key)
        for case in report.iter("testcase"):
            suite = case.get("classname", "").rsplit(".", 1)[-1]
            name = case.get("name", "").removesuffix("()")
            identifier = suite + "/" + name
            if identifier not in required:
                issues.append("unexpected-test")
                continue
            if identifier in observed:
                issues.append("duplicate-test")
            result = "pass"
            if case.find("skipped") is not None:
                result = "skipped"
            if case.find("failure") is not None or case.find("error") is not None:
                result = "fail"
            observed[identifier] = result
    except (OSError, ET.ParseError, ValueError):
        issues.append("missing-or-invalid-xunit")
    if set(observed) != required:
        issues.append("missing-required-test")
    if any(result != "pass" for result in observed.values()):
        issues.append("test-not-passed")
    results = [{"id": identifier, "status": observed[identifier]} for identifier in sorted(observed)]
    return {
        "schemaVersion": 1,
        "kind": KIND,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceDigest": digest,
        "scope": "deterministic-delivery-tests",
        "liveCompatibilityEvaluated": False,
        "status": "fail" if issues else "pass",
        "testExitCode": exit_code,
        "requiredCaseCount": len(required),
        "observedCaseCount": len(results),
        "passedCaseCount": sum(item["status"] == "pass" for item in results),
        "skippedCaseCount": sum(item["status"] == "skipped" for item in results),
        "failedCaseCount": sum(item["status"] == "fail" for item in results),
        "tests": results,
        "issues": sorted(set(issues)),
    }


def validate(summary):
    """Fail closed on old schemas, missing/skipped tests and stale source evidence."""
    required, digest = source_contract()
    expected_keys = {
        "schemaVersion", "kind", "generatedAt", "sourceDigest", "scope",
        "liveCompatibilityEvaluated", "status", "testExitCode", "requiredCaseCount",
        "observedCaseCount", "passedCaseCount", "skippedCaseCount", "failedCaseCount",
        "tests", "issues",
    }
    if not isinstance(summary, dict) or set(summary) != expected_keys:
        return False
    if (type(summary["schemaVersion"]) is not int or summary["schemaVersion"] != 1
            or summary["kind"] != KIND or summary["sourceDigest"] != digest
            or summary["scope"] != "deterministic-delivery-tests"
            or summary["liveCompatibilityEvaluated"] is not False
            or summary["status"] != "pass" or summary["issues"] != []):
        return False
    try:
        if datetime.fromisoformat(summary["generatedAt"]).tzinfo is None:
            return False
    except (ValueError, TypeError):
        return False
    expected_counts = {
        "testExitCode": 0, "requiredCaseCount": len(required),
        "observedCaseCount": len(required), "passedCaseCount": len(required),
        "skippedCaseCount": 0, "failedCaseCount": 0,
    }
    if any(type(summary[key]) is not int or summary[key] != value for key, value in expected_counts.items()):
        return False
    expected = [{"id": identifier, "status": "pass"} for identifier in sorted(required)]
    return summary["tests"] == expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--xunit", type=Path)
    mode.add_argument("--validate", action="store_true")
    parser.add_argument("--test-exit-code", type=int)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    if args.xunit is not None:
        if args.test_exit_code is None:
            parser.error("--xunit requires --test-exit-code")
        summary = summarize(args.xunit, args.test_exit_code)
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.summary.with_name(args.summary.name + ".tmp")
        temporary.write_text(json.dumps(summary, indent=2) + "\n")
        temporary.replace(args.summary)
    else:
        try:
            summary = json.loads(args.summary.read_text())
        except (OSError, ValueError):
            print("delivery contract evidence failed: missing or invalid summary", file=sys.stderr)
            return 1
    passed = validate(summary)
    print("delivery contract evidence: " + ("pass" if passed else "fail"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
