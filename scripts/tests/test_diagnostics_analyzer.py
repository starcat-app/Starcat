"""验证诊断解析器处理旧日志、关联故障、部分损坏和安全读取边界。"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

SOURCE = Path(__file__).resolve().parents[2] / "skills/starcat-diagnostics/scripts/analyze.py"
SPEC = importlib.util.spec_from_file_location("diagnostics_analyzer", SOURCE)
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)


class DiagnosticAnalyzerTests(unittest.TestCase):
    """用独立输入验证报告事实，不依赖固定文案或实现细节。"""

    def event(self, **values):
        """每个样本默认是一次服务失败，调用方只覆盖场景变化。"""
        return dict(timestamp="2026-11-10T01:00:00Z", category="license",
                    operation="validate", level="error", statusCode=502, **values)

    def analyze(self, source, **options):
        """与 CLI 使用相同筛选参数。"""
        args = dict(module=None, operation_id=None, request_id=None, error_code=None,
                    since=None, until=None, limit=100)
        return ANALYZER.analyze(source, argparse.Namespace(**(args | options)))

    def test_legacy_and_malformed_lines(self):
        files = {"diagnostic-log.jsonl": (
            json.dumps(self.event()) + '\ninvalid\n{"timestamp":[],"category":"x","operation":"x"}'
        ).encode()}
        events, _, gaps = ANALYZER.collect(files)
        self.assertEqual(len(events), 1)
        self.assertTrue(any("2 行" in gap for gap in gaps))
        self.assertTrue(any("历史事件" in gap for gap in gaps))

    def test_bundle_counts_correlation_and_privacy(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            events = [self.event(schemaVersion=2, operationID="a", occurrenceCount=3,
                                 message="Bearer customer-secret /Users/alice/private.txt"),
                      dict(self.event(schemaVersion=2, operationID="a"),
                           timestamp="2026-11-10T01:01:00Z", level="info", outcome="succeeded"),
                      dict(self.event(schemaVersion=2, operationID={"bad": True}),
                           outcome="succeeded"),
                      dict(self.event(schemaVersion=2), outcome="cancelled")]
            payload = "\n".join(json.dumps(e) for e in events).encode()
            manifest = dict(exportID="example", files=[dict(path="events.jsonl", bytes=len(payload),
                            sha256=hashlib.sha256(payload).hexdigest())],
                            collectors=[dict(name="system", status="notCollected")])
            bundle = folder / "sample.zip"
            with zipfile.ZipFile(bundle, "w") as archive:
                archive.writestr("events.jsonl", payload)
                archive.writestr("manifest.json", json.dumps(manifest))
            report = self.analyze(bundle)
            self.assertEqual(report["incidents"][0]["count"], 3)
            self.assertEqual(report["incidents"][0]["recovery"], "后续同一操作成功")
            self.assertEqual(report["cancelledEvents"], 1)
            self.assertNotIn("customer-secret", json.dumps(report))
            self.assertNotIn("alice", json.dumps(report))
            self.assertTrue(any("system" in gap for gap in report["evidenceGaps"]))
            self.assertEqual(self.analyze(bundle, operation_id="a")["selectedEvents"], 2)

    def test_success_in_another_operation_is_not_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "events.jsonl"
            source.write_text("\n".join(map(json.dumps, [
                self.event(operationID="first"),
                dict(self.event(operationID="second"), timestamp="2026-11-10T02:00:00Z",
                     outcome="succeeded", level="info")
            ])))
            self.assertEqual(self.analyze(source)["incidents"][0]["recovery"], "未找到关联恢复证据")

    def test_manifest_missing_and_checksum(self):
        _, _, gaps = ANALYZER.collect({"manifest.json": json.dumps(dict(files=[
            dict(path="missing.json"), dict(path="events.jsonl", sha256="wrong")
        ])).encode(), "events.jsonl": json.dumps(self.event()).encode()})
        self.assertTrue(any("文件缺失" in gap for gap in gaps))
        self.assertTrue(any("校验失败" in gap for gap in gaps))

    def test_zip_traversal_and_duplicates_rejected(self):
        for names in [("../events.jsonl",), ("/events.jsonl",), ("events.jsonl", "events.jsonl")]:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "sample.zip"
                with zipfile.ZipFile(source, "w") as archive:
                    for name in names:
                        archive.writestr(name, "{}")
                with self.assertRaises(ValueError):
                    ANALYZER.load_files(source)

    def test_invalid_time_and_empty_evidence(self):
        with self.assertRaises(argparse.ArgumentTypeError):
            ANALYZER.iso_argument("yesterday")
        _, _, gaps = ANALYZER.collect({})
        self.assertTrue(any("不能认定" in gap for gap in gaps))

    def test_filesystem_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "link").symlink_to(SOURCE)
            with self.assertRaises(ValueError):
                ANALYZER.load_files(source)


if __name__ == "__main__":
    unittest.main()
