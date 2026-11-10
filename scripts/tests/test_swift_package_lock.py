#!/usr/bin/env python3
"""验证锁文件在首次生成、重复生成和依赖漂移时的行为，不访问真实工程或网络。"""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "swift_package_lock",
    Path(__file__).resolve().parents[1] / "sync-swift-package-lock.py",
)
LOCK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCK)


class SwiftPackageLockTests(unittest.TestCase):
    """用隔离目录证明生成工程可恢复锁文件，校验操作不会吞掉版本变化。"""

    def setUp(self):
        """每个测试建立独立锁文件，避免依赖开发机的生成工程状态。"""
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.source = root / "Configs/SwiftPackages.resolved"
        self.generated = root / "Generated/swiftpm/Package.resolved"
        self.source.parent.mkdir(parents=True)
        self.pins = [
            {
                "identity": "example",
                "kind": "remoteSourceControl",
                "location": "https://github.com/example/package",
                "state": {"revision": "a" * 40, "version": "1.0.0"},
            }
        ]
        self.source.write_text(json.dumps({"version": 2, "pins": self.pins}))

    def test_restore_creates_generated_directory_and_is_idempotent(self):
        """干净 checkout 可恢复，重复生成不触碰已一致文件的时间戳。"""
        LOCK.synchronize(self.source, self.generated, check=False)
        modified = self.generated.stat().st_mtime_ns
        LOCK.synchronize(self.source, self.generated, check=False)
        self.assertEqual(self.source.read_bytes(), self.generated.read_bytes())
        self.assertEqual(modified, self.generated.stat().st_mtime_ns)

    def test_check_rejects_revision_drift_without_overwriting_it(self):
        """相同 version 的 revision 漂移也必须被发现，并保留失败现场。"""
        LOCK.synchronize(self.source, self.generated, check=False)
        changed = json.loads(self.generated.read_text())
        changed["pins"][0]["state"]["revision"] = "b" * 40
        self.generated.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            LOCK.synchronize(self.source, self.generated, check=True)
        self.assertEqual(json.loads(self.generated.read_text()), changed)

    def test_check_ignores_xcode_metadata_but_rejects_missing_packages(self):
        """Xcode 元数据不影响身份判断，缺包仍算解析漂移。"""
        self.generated.parent.mkdir(parents=True)
        self.generated.write_text(
            json.dumps({"version": 3, "originHash": "generated", "pins": self.pins})
        )
        LOCK.synchronize(self.source, self.generated, check=True)
        self.generated.write_text(json.dumps({"version": 2, "pins": []}))
        with self.assertRaises(ValueError):
            LOCK.synchronize(self.source, self.generated, check=True)

    def test_invalid_source_does_not_replace_generated_lock(self):
        """损坏源文件不能覆盖仍可用的生成目录锁文件。"""
        LOCK.synchronize(self.source, self.generated, check=False)
        original = self.generated.read_bytes()
        self.source.write_text("{")
        with self.assertRaises(ValueError):
            LOCK.synchronize(self.source, self.generated, check=False)
        self.assertEqual(original, self.generated.read_bytes())


if __name__ == "__main__":
    unittest.main()
