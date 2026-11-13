"""验证诊断解析器处理旧日志、关联故障、部分损坏和安全读取边界。"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
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

    def test_schema_three_admission_breadcrumbs_and_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "events.jsonl"
            failure = self.event(schemaVersion=3, visibility="issue", impact="blocked", outcome="failed",
                summaryKey="diagnostics.issue.aiUnavailable", operationID="root", occurrenceCount=2,
                breadcrumbs=[dict(phase="response", requestID="request", operationID="child",
                    serverTraceID="trace", elapsedMs=12, fields=dict(attempt=2, token="private"))],
                breadcrumbsTruncated=True, context=dict(repoID="ref:0000000000000001"))
            excluded = dict(failure, visibility="context")
            other_scope = dict(failure, context=dict(repoID="ref:0000000000000002"))
            source.write_text("\n".join(map(json.dumps, [failure, excluded, other_scope])))
            report = self.analyze(source, request_id="request")
            self.assertEqual(len(report["incidents"]), 2)
            self.assertEqual([item["count"] for item in report["incidents"]], [2, 2])
            self.assertTrue(all(item["severe"] for item in report["incidents"]))
            self.assertEqual(report["incidents"][0]["actualAttempts"], 1)
            self.assertEqual(report["incidents"][0]["serverTraceIDs"], ["trace"])
            self.assertEqual(self.analyze(source, operation_id="child")["selectedEvents"], 3)
            stage = report["timeline"][0]["breadcrumbs"][0]
            self.assertEqual(stage["elapsedMs"], 12)
            self.assertEqual(stage["fields"], dict(attempt=2))
            self.assertNotIn("private", json.dumps(report))
            self.assertTrue(any("截断" in gap for gap in report["evidenceGaps"]))
            self.assertFalse(any("更高格式" in gap for gap in report["evidenceGaps"]))
            failure.pop("summaryKey")
            source.write_text(json.dumps(failure))
            missing_summary = self.analyze(source)
            self.assertTrue(missing_summary["incidents"][0]["severe"])
            self.assertEqual(missing_summary["incidents"][0]["summaryKey"], "diagnostics.issue.generic")

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
        ], health=dict(readFailures=1, droppedEvents=2))).encode(),
            "events.jsonl": json.dumps(self.event()).encode()})
        self.assertTrue(any("文件缺失" in gap for gap in gaps))
        self.assertTrue(any("校验失败" in gap for gap in gaps))
        self.assertTrue(any("readFailures=1" in gap for gap in gaps))
        self.assertTrue(any("droppedEvents=2" in gap for gap in gaps))

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

    def test_related_graph_evidence_and_request_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "events.jsonl"
            graph = dict(self.event(schemaVersion=2, operationID="child", parentOperationID="root"),
                         category="followGraph", fields={"totalCount": 87, "renderedCount": 78,
                                                       "canLoadMore": False, "prompt": "private text"})
            source.write_text("\n".join(map(json.dumps, [
                self.event(schemaVersion=2, operationID="root", requestID="request-1"),
                graph,
                self.event(schemaVersion=2, operationID="other", requestID="request-2")
            ])))
            report = self.analyze(source, operation_id="root")
            self.assertEqual(report["selectedEvents"], 2)
            self.assertEqual(report["observations"][0]["fields"],
                             dict(totalCount=87, renderedCount=78, canLoadMore=False))
            self.assertEqual(report["incidents"][0]["actualAttempts"], 1)
            self.assertNotIn("private text", json.dumps(report))

    def test_zip_links_and_oversized_payload_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.zip"
            link = zipfile.ZipInfo("events.jsonl")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(link, "/outside")
            with self.assertRaises(ValueError):
                ANALYZER.load_files(source)
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("events.jsonl", "{}")
            with patch.object(ANALYZER, "MAX_FILE", 1), self.assertRaises(ValueError):
                ANALYZER.load_files(source)

    def test_newer_schema_and_unlisted_files_report_gaps(self):
        _, _, gaps = ANALYZER.collect({
            "manifest.json": json.dumps(dict(files=[])).encode(),
            "events.jsonl": json.dumps(self.event(schemaVersion=4)).encode()
        })
        self.assertTrue(any("更高格式" in gap for gap in gaps))
        self.assertTrue(any("未列出" in gap for gap in gaps))

    def test_nonfinite_numbers_are_omitted_without_replacing_with_zero(self):
        event = self.event(durationMs=float("nan"), fields={"count": float("inf"), "totalCount": 0})
        result = ANALYZER.public_event(event)
        self.assertNotIn("durationMs", result)
        self.assertEqual(result["fields"], {"totalCount": 0})
        json.dumps(result, allow_nan=False)

    def test_open_operations_and_cross_session_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "events.jsonl"
            source.write_text("\n".join(map(json.dumps, [
                self.event(schemaVersion=2, sessionID="first", operationID="same"),
                dict(self.event(schemaVersion=2, sessionID="second", operationID="same"),
                     timestamp="2026-11-10T02:00:00Z", outcome="succeeded", level="info"),
                dict(self.event(schemaVersion=2, sessionID="first", operationID="runtime"),
                     category="runtime", level="info", phase="versionProbe")
            ])))
            report = self.analyze(source)
            self.assertEqual(report["incidents"][0]["recovery"], "未找到关联恢复证据")
            runtime = next(x for x in report["openOperations"] if x["event"]["operationID"] == "runtime")
            self.assertIsNone(runtime["elapsedMs"])
            self.assertEqual(runtime["endReason"], "unknown")
            self.assertIsInstance(runtime["idleMs"], int)


if __name__ == "__main__":
    unittest.main()
