#!/usr/bin/env python3
"""隔离验证 Codebase 下载校验与替换边界，不联网、不触碰真实 Bundle 资源。"""

import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


class CodebaseFetchTests(unittest.TestCase):
    """用真实归档和可控 curl 替身验证哈希或版本失败时保留已有资源。"""

    def setUp(self):
        """每项测试复制脚本到临时工程，让脚本自身的相对根目录也处于隔离范围。"""
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "fetch-codebase-binary.sh"
        shutil.copyfile(Path(__file__).resolve().parents[1] / self.script.name, self.script)
        self.target = self.root / "Starcat/Resources/Codebase/codebase.bin"
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"existing-binary")
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        commands = self.root / "commands"
        commands.mkdir()
        curl = commands / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\n"
            "import os, shutil, sys\n"
            "from pathlib import Path\n"
            "output = sys.argv[sys.argv.index('-o') + 1]\n"
            "source = Path(os.environ['STARCAT_FIXTURE_DOWNLOADS']) / sys.argv[-1].rsplit('/', 1)[-1]\n"
            "shutil.copyfile(source, output)\n"
        )
        curl.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment["PATH"] = str(commands) + os.pathsep + self.environment["PATH"]
        self.environment["STARCAT_FIXTURE_DOWNLOADS"] = str(self.downloads)

    def prepare_archive(self, binary_version="77.88.99", *, corrupt_checksum=False):
        """归档校验与程序版本独立控制，避免用一个假哈希同时模拟两种身份。"""
        binary = self.root / "codebase-memory-mcp-ui"
        binary.write_text(f"#!/bin/sh\necho 'codebase-memory-mcp {binary_version}'\n")
        binary.chmod(0o755)
        asset = self.downloads / "codebase-memory-mcp-ui-darwin-arm64.tar.gz"
        with tarfile.open(asset, "w:gz") as archive:
            archive.add(binary, arcname=binary.name)
        checksum = hashlib.sha256(asset.read_bytes()).hexdigest()
        if corrupt_checksum:
            checksum = "0" * 64
        (self.downloads / "checksums.txt").write_text(f"{checksum}  {asset.name}\n")
        return checksum

    def run_fetch(self):
        """只运行隔离副本，生产脚本与真实资源目录始终不作为执行目标。"""
        return subprocess.run(
            ["bash", str(self.script), "v77.88.99"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def test_valid_archive_records_both_checksums(self):
        """成功时记录归档与二进制各自的哈希及明确版本。"""
        archive_checksum = self.prepare_archive()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stdout)
        metadata = (self.target.parent / "CODEBASE-INTEGRATION.md").read_text()
        self.assertIn(archive_checksum, metadata)
        self.assertIn(hashlib.sha256(self.target.read_bytes()).hexdigest(), metadata)
        self.assertIn("fetch-codebase-binary.sh v77.88.99", metadata)

    def test_archive_checksum_failure_keeps_existing_binary(self):
        """下载字节不匹配 release 校验时不能替换已有二进制。"""
        self.prepare_archive(corrupt_checksum=True)
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stdout)
        self.assertEqual(self.target.read_bytes(), b"existing-binary")

    def test_binary_version_failure_keeps_existing_binary(self):
        """即使归档哈希正确，程序实际版本错误也必须在安装前失败。"""
        self.prepare_archive(binary_version="0.0.0")
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version does not match", result.stdout)
        self.assertEqual(self.target.read_bytes(), b"existing-binary")


if __name__ == "__main__":
    unittest.main()
