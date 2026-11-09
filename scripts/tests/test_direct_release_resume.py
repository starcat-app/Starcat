#!/usr/bin/env python3
"""验证正式/Beta 产物恢复，不访问生产 GitHub、Apple 或服务器。

文件校验使用真实临时 DMG/XML；外部签名检查使用替身。完整 Shell 入口在隔离
目录运行，所有外部命令均记录参数，构建、tag 写操作或意外联网会令测试失败。
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "release_artifacts", ROOT / "scripts/verify-direct-release-artifacts.py"
)
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)


def fixture_files(root: Path, version: str) -> tuple[Path, Path, Path]:
    """生成同版本固定产物，供校验器与 Shell 编排共用。"""
    root.mkdir(parents=True, exist_ok=True)
    marketing = version.split("-beta.", 1)[0]
    dmg = root / f"Starcat-{marketing}-arm64.dmg"
    dmg.write_bytes(b"notarized DMG fixture")
    checksum = root / (dmg.name + ".sha256")
    checksum.write_text(f"{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}\n")
    appcast = root / "appcast-current.xml"
    appcast.write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item>
<sparkle:shortVersionString>{marketing}</sparkle:shortVersionString>
<sparkle:version>202611091418</sparkle:version>
<description><![CDATA[release notes]]></description>
<enclosure url="https://github.com/starcat-app/Starcat/releases/download/v{version}/{dmg.name}"
length="{dmg.stat().st_size}" sparkle:edSignature="fixture-signature" />
</item></channel></rss>''')
    return dmg, checksum, appcast


class ArtifactValidationTests(unittest.TestCase):
    """摘要、清单、tag 与公证门禁全部在上传之前运行。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.version = "9.9.9-beta.1"
        self.dmg, self.sha, self.appcast = fixture_files(self.root, self.version)
        self.calls = []
        self.remote_tag = "a" * 40

        def checked(*args):
            self.calls.append(args)
            if args[:2] == ("git", "rev-parse"):
                return "b" * 40 if args[-1].endswith("^{commit}") else "a" * 40
            if args[:2] == ("git", "ls-remote"):
                return f"{self.remote_tag}\trefs/tags/v{self.version}"
            return ""

        self.checked = checked
        mock = patch.object(artifacts, "checked_command", side_effect=checked)
        mock.start()
        self.addCleanup(mock.stop)

    def verify(self):
        """调用与真实 Shell 完全相同的验证入口。"""
        return artifacts.verify(self.version, self.dmg, self.sha, self.appcast, "origin")

    def test_valid_artifacts_are_read_only(self):
        before = [p.read_bytes() for p in (self.dmg, self.sha, self.appcast)]
        self.assertEqual(self.verify(), "b" * 40)
        self.assertEqual(before, [p.read_bytes() for p in (self.dmg, self.sha, self.appcast)])
        self.assertIn(("xcrun", "stapler", "validate", str(self.dmg)), self.calls)
        self.assertFalse(any("staple" in call or "status" in call or "HEAD" in call for call in self.calls))

    def test_invalid_inputs_stop_before_external_commands(self):
        """坏摘要或清单不能先访问 Git/Apple，更不能进入上传。"""
        original = self.appcast.read_text()
        cases = [
            (original.replace("v9.9.9-beta.1/", "v9.9.9-beta.2/"), "发布 tag"),
            (original.replace(">9.9.9<", ">9.9.8<"), "营销版本"),
            (original.replace(f'length="{self.dmg.stat().st_size}"', 'length="1"'), "大小"),
            (original.replace('sparkle:edSignature="fixture-signature"', ""), "签名"),
            (original.replace("202611091418", "invalid"), "构建号"),
            (original.replace("release notes", ""), "更新说明"),
            (original.replace("</channel>", original.split("<channel>")[1].split("</channel>")[0] + "</channel>"), "一个 item"),
        ]
        for content, message in cases:
            with self.subTest(message=message):
                self.appcast.write_text(content)
                with self.assertRaisesRegex(ValueError, message):
                    self.verify()
                self.assertEqual(self.calls, [])
        self.appcast.write_text(original)
        self.dmg.write_bytes(b"changed DMG")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.verify()
        self.assertEqual(self.calls, [])

    def test_remote_tag_mismatch_blocks_notary_checks(self):
        self.remote_tag = "c" * 40
        with self.assertRaisesRegex(ValueError, "远端 tag"):
            self.verify()
        self.assertTrue(all(call[0] == "git" for call in self.calls))

    def test_notary_failure_is_not_retried(self):
        def failed(*args):
            if args[0] == "xcrun":
                self.calls.append(args)
                raise RuntimeError("ticket invalid")
            return self.checked(*args)

        with patch.object(artifacts, "checked_command", side_effect=failed):
            with self.assertRaisesRegex(RuntimeError, "ticket invalid"):
                self.verify()
        self.assertEqual(sum(call[0] == "xcrun" for call in self.calls), 1)
        self.assertFalse(any(call[0] == "spctl" for call in self.calls))


class ResumeEntryTests(unittest.TestCase):
    """执行完整 Shell 入口，外部命令替身使发布副作用保持在临时目录。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.site = self.root / "supports/starcat-site"
        (self.site / ".git").mkdir(parents=True)
        (self.site / "direct").mkdir()
        self.log = self.root / "commands.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("STARCAT_")}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", RESUME_LOG=str(self.log))
        # python3 的校验调用交给真实校验器，其余发布工具只记录，不触达外网。
        replacement = f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["RESUME_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\\n")
if name == "git":
    if args[:2] == ["rev-parse", "--verify"]:
        print("a" * 40)
    elif args[:2] == ["ls-remote", "--exit-code"]:
        print("a" * 40 + "\\t" + args[-1])
    elif args == ["branch", "--show-current"]:
        print(os.environ.get("SOURCE_BRANCH", "unexpected-branch"))
    elif args in (["status", "--porcelain"], ["status", "--short"]):
        print(os.environ.get("SOURCE_DIRTY", ""), end="")
    else:
        sys.exit(97)
elif name == "python3":
    target = Path(args[0]).name
    if target in ("-", "verify-direct-release-artifacts.py"):
        os.execv(sys.executable, [sys.executable] + args)
    if target == "publish-direct-github-release.py":
        sys.exit(int(os.environ.get("PUBLISH_EXIT", "0")))
    if target not in ("merge-appcast.py", "inject-appcast-release-notes.py"):
        sys.exit(97)
elif name == "gh":
    if args != ["auth", "status"]:
        sys.exit(97)
elif name == "curl" and "-fsSL" in args:
    sys.stdout.write(os.environ.get("REMOTE_FEED", Path(os.environ["BETA_FEED"]).read_text()))
'''
        for name in ("git", "gh", "python3", "xcrun", "spctl", "ssh", "rsync", "curl"):
            path = self.bin / name
            path.write_text(replacement)
            path.chmod(0o755)
        shutil.copy(ROOT / "scripts/verify-direct-release-artifacts.py", self.scripts)

    def run_entry(self, beta: bool, *, legacy=False, failure=False, resume=True, damaged=False, extra_args=()):
        """恢复入口不提供构建工具；意外调用任何构建或 Git 写路径都会失败。"""
        version = "9.9.9-beta.1" if beta else "9.9.9"
        name = "release-direct-development.sh" if beta else "release-direct.sh"
        shutil.copy(ROOT / "scripts" / name, self.scripts)
        downloads = self.root / ("dist/direct-development/downloads" if beta else "dist/direct/downloads")
        dmg, _, appcast = fixture_files(downloads, version)
        if damaged:
            dmg.write_bytes(b"changed after notarization")
        for feed in ("appcast.xml", "appcast-development.xml"):
            shutil.copy(appcast, self.site / "direct" / feed)
        self.env["BETA_FEED"] = str(self.site / "direct/appcast-development.xml")
        self.env["PUBLISH_EXIT"] = "23" if failure else "0"
        args = ["bash", str(self.scripts / name), version]
        if legacy:
            self.env["STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS" if beta else "STARCAT_RELEASE_REUSE_ARTIFACTS"] = "1"
        elif resume:
            args.append("--resume")
        args.extend(extra_args)
        return subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=15)

    def commands(self):
        """读取隔离命令日志；参数门禁失败时可以没有任何命令。"""
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_both_channels_resume_without_source_checks_or_building(self):
        for beta in (False, True):
            for legacy in (False, True):
                with self.subTest(beta=beta, legacy=legacy):
                    self.env.pop("STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS", None)
                    self.env.pop("STARCAT_RELEASE_REUSE_ARTIFACTS", None)
                    self.log.unlink(missing_ok=True)
                    result = self.run_entry(beta, legacy=legacy)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    commands = self.commands()
                    writes = [cmd for cmd in commands if cmd[0] == "rsync"]
                    self.assertEqual(len(writes), 1 if beta else 2)
                    self.assertTrue(all("appcast" in cmd[-1] for cmd in writes))
                    if beta:
                        self.assertTrue(all(cmd[-1].endswith("appcast-development.xml") for cmd in writes))
                    self.assertFalse(any("staple" in cmd for cmd in commands))
                    self.assertFalse(any(cmd[0] == "git" and cmd[1] in ("branch", "status") for cmd in commands))
                    self.assertEqual(sum(cmd[0] == "python3" and Path(cmd[1]).name == "publish-direct-github-release.py" for cmd in commands), 1)

    def test_github_failure_stops_before_feed_and_is_not_retried(self):
        for beta in (False, True):
            with self.subTest(beta=beta):
                self.log.unlink(missing_ok=True)
                result = self.run_entry(beta, failure=True)
                self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
                commands = self.commands()
                self.assertFalse(any(cmd[0] in ("rsync", "ssh", "curl") for cmd in commands))
                self.assertEqual(sum(cmd[0] == "python3" and Path(cmd[1]).name == "publish-direct-github-release.py" for cmd in commands), 1)

    def test_invalid_artifacts_stop_before_github_and_feed(self):
        for beta in (False, True):
            with self.subTest(beta=beta):
                self.log.unlink(missing_ok=True)
                result = self.run_entry(beta, damaged=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SHA256", result.stderr)
                commands = self.commands()
                self.assertEqual(len(commands), 1)
                self.assertEqual(Path(commands[0][1]).name, "verify-direct-release-artifacts.py")

    def test_new_build_still_requires_expected_branch_and_clean_source(self):
        """恢复豁免不能泄漏到新构建；检查失败必须早于 tag 和打包。"""
        (self.site / "direct/deploy.sh").touch()
        for beta in (False, True):
            for dirty in (False, True):
                with self.subTest(beta=beta, dirty=dirty):
                    self.log.unlink(missing_ok=True)
                    self.env["SOURCE_BRANCH"] = ("dev" if beta else "main") if dirty else "other-task"
                    self.env["SOURCE_DIRTY"] = " M source.swift\n" if dirty else ""
                    result = self.run_entry(beta, resume=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("工作区不干净" if dirty else "当前分支", result.stderr)
                    self.assertTrue(all(cmd[0] == "git" and cmd[1] in ("branch", "status") for cmd in self.commands()))

    def test_unknown_options_stop_before_external_commands(self):
        for beta in (False, True):
            for args in (("--wrong",), ("--resume", "--resume")):
                with self.subTest(beta=beta, args=args):
                    self.log.unlink(missing_ok=True)
                    result = self.run_entry(beta, resume=False, extra_args=args)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("未知参数", result.stderr)
                    self.assertEqual(self.commands(), [])

    def test_beta_feed_mismatch_stops_without_upload_retry(self):
        self.env["REMOTE_FEED"] = "<rss><channel /></rss>"
        result = self.run_entry(True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("线上 Beta 更新源与本地不同", result.stderr)
        commands = self.commands()
        self.assertEqual(sum(cmd[0] == "rsync" for cmd in commands), 1)
        self.assertNotEqual((self.site / "direct/appcast-development.xml").read_text(), self.env["REMOTE_FEED"])


if __name__ == "__main__":
    unittest.main()
