"""验证应急包不包含客户自由文本、不会破坏已有目标，并可由解析 Skill 读取。"""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from scripts.tests.test_diagnostics_analyzer import ANALYZER

SOURCE = Path(__file__).resolve().parents[1] / "export-diagnostics.py"
SPEC = importlib.util.spec_from_file_location("diagnostics_emergency", SOURCE)
EMERGENCY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EMERGENCY)


class DiagnosticEmergencyTests(unittest.TestCase):
    """应用不可启动时只允许读取诊断白名单文件。"""

    def test_round_trip_and_private_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "diagnostics"
            source.mkdir()
            (source / "diagnostic-log.jsonl").write_text(json.dumps(dict(
                timestamp="2026-11-10T01:00:00Z", category="followGraph", operation="pageMerge",
                level="info", message="customer private prompt",
                fields=dict(totalCount=87, displayedCount=78, token="secret")
            )) + "\nbroken\n")
            (source / "private.sqlite").write_text("database content")
            target = root / "bundle.zip"
            EMERGENCY.export(source, target)
            with zipfile.ZipFile(target) as archive:
                combined = b"\n".join(archive.read(name) for name in archive.namelist())
                self.assertNotIn(b"customer", combined)
                self.assertNotIn(b"database content", combined)
                self.assertNotIn(b"secret", combined)
                manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(manifest["damagedLines"], 1)
            events, manifest, gaps = ANALYZER.collect(ANALYZER.load_files(target))
            self.assertEqual(events[0]["fields"]["totalCount"], 87)
            self.assertFalse(any("校验失败" in gap for gap in gaps))
            self.assertEqual(manifest["mode"], "emergency")

    def test_failure_does_not_replace_existing_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "old.zip"
            target.write_bytes(b"keep")
            with self.assertRaises(ValueError):
                EMERGENCY.export(root, target)
            self.assertEqual(target.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
