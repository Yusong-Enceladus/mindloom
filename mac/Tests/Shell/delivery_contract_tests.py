#!/usr/bin/env python3
"""Synthetic xUnit parser regressions. These are not Delivery execution evidence."""

import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import sys


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("delivery_contract", ROOT / "script/delivery_contract_evidence.py")
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


class DeliveryContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bestasr-delivery-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "tests.xml"
        self.root = ET.Element("testsuites")
        self.suite = ET.SubElement(self.root, "testsuite")
        for identifier in sorted(CONTRACT.source_contract()[0]):
            suite, name = identifier.split("/")
            ET.SubElement(self.suite, "testcase", classname="BestASRDeliveryTests." + suite, name=name)

    def summary(self, exit_code=0):
        ET.ElementTree(self.root).write(self.path)
        return CONTRACT.summarize(self.path, exit_code)

    def testCompleteCurrentTestRunPasses(self):
        summary = self.summary()
        self.assertTrue(CONTRACT.validate(summary))
        self.assertFalse(summary["liveCompatibilityEvaluated"])
        self.assertEqual(summary["kind"], "delivery-policy-test-contract")

    def testSkippedFailedAndErroredTestsNeverCountAsPass(self):
        for tag in ("skipped", "failure", "error"):
            with self.subTest(tag=tag):
                child = ET.SubElement(self.suite[0], tag)
                child.text = "SYNTHETIC PRIVATE-LIKE CONTENT MUST NOT BE COPIED"
                summary = self.summary()
                self.assertFalse(CONTRACT.validate(summary))
                self.assertNotIn("PRIVATE-LIKE", str(summary))
                self.suite[0].remove(child)

    def testMissingDuplicateAndUnexpectedTestsFail(self):
        removed = self.suite[0]
        self.suite.remove(removed)
        self.assertFalse(CONTRACT.validate(self.summary()))
        self.suite.append(removed)
        self.suite.append(copy.deepcopy(removed))
        self.assertFalse(CONTRACT.validate(self.summary()))
        self.suite.remove(self.suite[-1])
        ET.SubElement(self.suite, "testcase", classname="HistoricalAXProbe", name="notCurrent")
        self.assertFalse(CONTRACT.validate(self.summary()))

    def testCommandFailureOverridesAPassingReport(self):
        self.assertFalse(CONTRACT.validate(self.summary(exit_code=1)))

    def testSuiteLevelFailuresAreNotLost(self):
        self.suite.set("errors", "1")
        self.assertFalse(CONTRACT.validate(self.summary()))

    def testMissingMalformedAndEmptyReportsFail(self):
        self.assertFalse(CONTRACT.validate(CONTRACT.summarize(self.path, 0)))
        self.path.write_text("invalid xml")
        self.assertFalse(CONTRACT.validate(CONTRACT.summarize(self.path, 0)))
        self.suite.clear()
        self.assertFalse(CONTRACT.validate(self.summary()))

    def testHistoricalKindStaleSourceAndForgedCountsFail(self):
        for field, replacement in (("kind", "text-insertion-policy-contract"),
                                   ("sourceDigest", "0" * 64), ("passedCaseCount", 0),
                                   ("testExitCode", False), ("liveCompatibilityEvaluated", True)):
            with self.subTest(field=field):
                summary = self.summary()
                summary[field] = replacement
                self.assertFalse(CONTRACT.validate(summary))
        summary = self.summary()
        summary["unexpected"] = "not accepted"
        self.assertFalse(CONTRACT.validate(summary))


if __name__ == "__main__":
    unittest.main()
