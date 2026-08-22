#!/usr/bin/env python3
"""submit_import.py 的离线边界测试。"""

from __future__ import annotations

import argparse
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from submit_import import PRODUCTION_BASE_URL, api_request, load_and_validate, resolve_runtime_config


class SubmitImportTests(unittest.TestCase):
    def write_payload(self, payload: dict) -> str:
        path = Path(tempfile.mkdtemp()) / "input.json"
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return str(path)

    def write_env(self, content: str) -> Path:
        path = Path(tempfile.mkdtemp()) / ".env"
        path.write_text(content, encoding="utf-8")
        return path

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

    def test_production_mode_uses_fixed_url_and_starcat_api_weekly_key(self) -> None:
        env_file = self.write_env('WEEKLY_ADMIN_API_KEYS="prod-first, prod-second"\n')
        args = argparse.Namespace(test=False, base_url="")

        base_url, key = resolve_runtime_config(
            args,
            environ={"STARCAT_WEEKLY_ADMIN_KEY": "must-not-win"},
            production_env_file=env_file,
        )

        self.assertEqual(base_url, PRODUCTION_BASE_URL)
        self.assertEqual(base_url, "https://starcat-api.fly.dev")
        self.assertEqual(key, "prod-first")

    def test_production_mode_rejects_base_url_override(self) -> None:
        args = argparse.Namespace(test=False, base_url="http://127.0.0.1:5003")
        with self.assertRaisesRegex(ValueError, "仅允许和 --test"):
            resolve_runtime_config(args, production_env_file=self.write_env("WEEKLY_ADMIN_API_KEYS=prod-key\n"))

    def test_test_mode_uses_explicit_test_environment(self) -> None:
        args = argparse.Namespace(test=True, base_url="")

        base_url, key = resolve_runtime_config(
            args,
            environ={
                "STARCAT_WEEKLY_BASE_URL": "http://127.0.0.1:5003",
                "STARCAT_WEEKLY_ADMIN_KEY": "test-key",
            },
            production_env_file=Path("/must/not/be/read"),
        )

        self.assertEqual(base_url, "http://127.0.0.1:5003")
        self.assertEqual(key, "test-key")

    def test_production_mode_requires_admin_key(self) -> None:
        args = argparse.Namespace(test=False, base_url="")
        with self.assertRaisesRegex(ValueError, "缺少非空 WEEKLY_ADMIN_API_KEYS"):
            resolve_runtime_config(args, production_env_file=self.write_env("API_KEYS=public-key\n"))

    def test_api_request_routes_to_weekly_service(self) -> None:
        with patch("submit_import.urllib.request.urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value.read.return_value = b'{"data": []}'

            api_request("https://starcat-api.fly.dev", "admin-key", "GET", "/internal/sources")

        request = urlopen.call_args.args[0]
        headers = dict(request.header_items())
        self.assertEqual(headers["X-sc-svc"], "weekly")


if __name__ == "__main__":
    unittest.main()
