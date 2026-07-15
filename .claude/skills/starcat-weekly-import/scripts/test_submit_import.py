#!/usr/bin/env python3
"""submit_import.py 的离线边界测试。"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from submit_import import load_and_validate


class SubmitImportTests(unittest.TestCase):
    def write_payload(self, payload: dict) -> str:
        path = Path(tempfile.mkdtemp()) / "input.json"
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return str(path)

    def test_auto_idempotency_key_is_stable_after_normalization(self) -> None:
        first = self.write_payload({"repositories": [{"owner": " Acme ", "repo": "Agent"}]})
        second = self.write_payload({"source_code": "ai_intelligence", "repositories": [{"owner": "Acme", "repo": "Agent"}]})

        self.assertEqual(load_and_validate(first)["idempotency_key"], load_and_validate(second)["idempotency_key"])

    def test_explicit_idempotency_key_wins(self) -> None:
        path = self.write_payload({"idempotency_key": "news-001", "repositories": [{"owner": "Acme", "repo": "Agent"}]})
        self.assertEqual(load_and_validate(path)["idempotency_key"], "news-001")

    def test_unsafe_source_url_is_rejected(self) -> None:
        for source_url in ("javascript:alert(1)", "file:///tmp/news", "/relative/news", "https://user:secret@example.com/news"):
            path = self.write_payload({"repositories": [{"owner": "Acme", "repo": "Agent", "source_url": source_url}]})
            with self.assertRaisesRegex(ValueError, "http/https"):
                load_and_validate(path)


if __name__ == "__main__":
    unittest.main()
