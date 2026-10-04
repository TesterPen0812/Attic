#!/usr/bin/env python3
"""The SQL guard must reject both payload mechanisms, not only old getters."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class MetadataSQLGateTests(unittest.TestCase):
    def evaluate(self, sql):
        with tempfile.TemporaryDirectory(prefix="p4-sql-gate-") as root:
            log = Path(root) / "query.log"
            log.write_text("P4_METADATA_QUERY_BEGIN\n" + sql + "\nP4_METADATA_QUERY_END\n")
            return subprocess.run([sys.executable, str(Path(__file__).with_name("p4_metadata_projection_gate.py")), str(log)],
                                  capture_output=True, text=True).returncode

    def test_dictionary_projection_passes(self):
        self.assertEqual(self.evaluate("CoreData: sql: SELECT t0.Z_PK, t0.ZID FROM ZCANVASSTROKEITEM t0 WHERE t0.ZCANVASID = ?"), 0)

    def test_legacy_inline_body_fails(self):
        self.assertNotEqual(self.evaluate("SELECT t0.Z_PK, t0.ZPAYLOAD FROM ZCANVASSTROKEITEM t0"), 0)

    def test_experimental_binary_column_fails(self):
        self.assertNotEqual(self.evaluate("SELECT t0.ZBINARYPAYLOAD FROM ZCANVASSTROKEITEM t0"), 0)

    def test_separate_payload_entity_read_fails(self):
        self.assertNotEqual(self.evaluate("SELECT t0.Z_PK FROM ZCANVASSTROKEITEM t0\nSELECT t1.ZBYTES FROM ZCANVASINKPAYLOADITEM t1"), 0)

    def test_wildcard_and_missing_stroke_select_fail(self):
        self.assertNotEqual(self.evaluate("SELECT * FROM ZCANVASSTROKEITEM"), 0)
        self.assertNotEqual(self.evaluate("SELECT Z_PK FROM ZCANVASBOARDITEM"), 0)


if __name__ == "__main__":
    unittest.main()
