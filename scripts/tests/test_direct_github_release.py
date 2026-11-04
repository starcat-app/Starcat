#!/usr/bin/env python3
"""隔离验证 Direct 发布顺序和重试约束，不调用真实 gh、打包或部署脚本。

GitHub 用内存附件模拟；Shell 只提取待测函数并替换外部步骤，临时目录承载全部测试文件。
重点防止损坏附件公开、重试覆盖已发布文件，以及 GitHub 失败后仍发布 appcast。
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "github_release", ROOT / "scripts/publish-direct-github-release.py"
)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class FakeGitHub:
    """模拟草稿和附件状态，保留操作顺序以验证失败边界。"""

    def __init__(self):
        self.draft = None
        self.prerelease = False
        self.assets = {}
        self.events = []
        self.commands = []
        self.fail_upload = None
        self.api_error = None

    def __call__(self, *args, check=True):
        """仅处理发布器使用的命令；未知命令立即失败，禁止落到真实网络。"""
        if args[0] == "api":
            if self.api_error:
                return subprocess.CompletedProcess(args, 1, "", self.api_error)
            if self.draft is None:
                return subprocess.CompletedProcess(args, 1, "", "gh: Not Found (HTTP 404)")
            payload = {
                "draft": self.draft, "prerelease": self.prerelease,
                "assets": [{"name": name} for name in self.assets],
                "html_url": "https://github.com/starcat-app/Starcat/releases/tag/v9.9.9",
            }
            return subprocess.CompletedProcess(args, 0, json.dumps(payload), "")
        assert "--repo" in args and args[args.index("--repo") + 1] == release.REPOSITORY
        assert "--clobber" not in args
        self.commands.append(args)
        action = args[1]
        self.events.append(action)
        if action == "create":
            assert "--draft" in args and "--verify-tag" in args
            self.draft = True
            self.prerelease = "--prerelease" in args
        elif action == "upload":
            artifact = Path(args[3])
            if self.fail_upload == artifact.name:
                raise RuntimeError("模拟上传中断")
            assert artifact.name not in self.assets
            self.assets[artifact.name] = artifact.read_bytes()
        elif action == "download":
            name = args[args.index("--pattern") + 1]
            directory = Path(args[args.index("--dir") + 1])
            (directory / name).write_bytes(self.assets[name])
        elif action == "edit":
            assert "--draft=false" in args
            self.draft = False
        else:
            raise AssertionError(f"未模拟命令: {args}")
        return subprocess.CompletedProcess(args, 0, "", "")


class DirectReleaseTests(unittest.TestCase):
    """用可观察的附件内容和发布事件验证新建、重试、冲突和失败流程。"""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dmg = self.root / "Starcat-9.9.9-arm64.dmg"
        self.dmg.write_bytes(b"final notarized DMG fixture")
        self.sha = self.root / (self.dmg.name + ".sha256")
        self.sha.write_text(f"{release.file_sha256(self.dmg)}  {self.dmg.name}\n")
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text("## 9.9.9\n\n### Fixes\n\n- Download: Faster delivery.\n\n## 9.9.8\n\nOld notes.\n")
        self.github = FakeGitHub()
        self.mock = patch.object(release, "gh", self.github)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def publish(self):
        """所有场景通过相同生产入口，避免测试实现的独立副本。"""
        release.publish("9.9.9", self.dmg, self.sha, self.changelog)

    def test_create_verifies_both_assets_before_publishing(self):
        self.publish()
        self.assertEqual(self.github.events, ["create", "upload", "download", "upload", "download", "edit"])
        self.assertFalse(self.github.draft)

    def test_beta_release_is_published_as_prerelease_without_becoming_latest(self):
        self.changelog.write_text(
            "## 9.9.9-待发布\n\n### New\n\n- Beta: Early access feature.\n"
        )

        release.publish(
            "9.9.9-beta.1",
            self.dmg,
            self.sha,
            self.changelog,
            prerelease=True,
            marketing_version="9.9.9",
        )

        self.assertFalse(self.github.draft)
        self.assertTrue(self.github.prerelease)
        create_command = self.github.commands[0]
        self.assertEqual(create_command[2], "v9.9.9-beta.1")
        self.assertEqual(create_command[create_command.index("--title") + 1], "Starcat 9.9.9 Beta 1")
        self.assertTrue(all("--latest" not in command for command in self.github.commands))

    def test_invalid_beta_versions_stop_before_remote_actions(self):
        """新发布只接受正整数 Beta 序号，历史 dev tag 不再作为新版本输入。"""
        for version in ("9.9.9", "9.9.9-dev.1", "9.9.9-beta.0", "9.9.9-beta.01", "9.9.9-beta.1-extra"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "X.Y.Z-beta.N"):
                release.publish(version, self.dmg, self.sha, self.changelog, prerelease=True)
        self.assertEqual(self.github.events, [])

    def test_beta_rejects_artifacts_from_a_different_marketing_version(self):
        """防止新 Beta tag 误挂另一营销版本的安装包与更新说明。"""
        with self.assertRaisesRegex(ValueError, "必须与发布版本"):
            release.publish(
                "9.9.9-beta.1", self.dmg, self.sha, self.changelog,
                prerelease=True, marketing_version="9.9.8",
            )
        self.assertEqual(self.github.events, [])

    def test_upload_failure_keeps_draft_and_retry_only_fills_missing_asset(self):
        self.github.fail_upload = self.sha.name
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertTrue(self.github.draft)
        self.assertNotIn("edit", self.github.events)
        self.github.fail_upload = None
        self.github.events.clear()
        self.publish()
        self.assertEqual(self.github.events, ["download", "upload", "download", "edit"])

    def test_published_identical_release_is_read_only(self):
        self.publish()
        self.github.events.clear()
        self.publish()
        self.assertEqual(self.github.events, ["download", "download"])

    def test_conflicting_asset_is_never_overwritten_or_published(self):
        self.github.draft = True
        self.github.assets[self.dmg.name] = b"different DMG"
        with self.assertRaisesRegex(ValueError, "GitHub 附件与本地不同"):
            self.publish()
        self.assertEqual(self.github.events, ["download"])
        self.assertTrue(self.github.draft)

    def test_published_release_missing_asset_is_not_modified(self):
        self.github.draft = False
        with self.assertRaisesRegex(ValueError, "已发布 Release 缺少附件"):
            self.publish()
        self.assertEqual(self.github.events, [])

    def test_auth_failure_does_not_create_release(self):
        self.github.api_error = "HTTP 403"
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertEqual(self.github.events, [])

    def test_invalid_checksum_stops_before_remote_actions(self):
        self.dmg.write_bytes(b"changed after signing")
        with self.assertRaisesRegex(ValueError, "本地 DMG 与 SHA256 不一致"):
            self.publish()
        self.assertEqual(self.github.events, [])

    def test_pending_notes_are_not_published(self):
        self.changelog.write_text("## 9.9.9-待发布\n\nDraft notes.\n")
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(self.github.events, [])

    def shell_function(self, name):
        """只提取函数定义，不 source 或运行真实发布脚本。"""
        source = (ROOT / "scripts/release-direct.sh").read_text()
        return re.search(rf"^{name}\(\) \{{.*?^\}}", source, re.MULTILINE | re.DOTALL).group(0)

    def test_pipeline_generates_feed_before_github_and_publishes_feed_last(self):
        for fail_github in (False, True):
            with self.subTest(fail_github=fail_github):
                site = self.root / "site"
                (site / ".git").mkdir(parents=True, exist_ok=True)
                (site / "direct").mkdir(exist_ok=True)
                (site / "direct/deploy.sh").touch()
                stages = ["create_and_push_tag", "package_direct", "verify_local_artifacts",
                          "merge_appcast", "publish_github_release", "deploy_site",
                          "publish_appcast", "verify_remote_urls"]
                stubs = "\n".join(f'{name}() {{ echo {name}; return {23 if fail_github and name == "publish_github_release" else 0}; }}' for name in stages)
                probe = f'''set -eu
PROJECT_ROOT='{self.root}'
STARCAT_SITE_ROOT='{site}'
PAGES_DIR='{site}/direct'
require_command() {{ :; }}
require_branch() {{ :; }}
require_clean_worktree() {{ :; }}
require_notarization_policy() {{ :; }}
run_or_print() {{ :; }}
{stubs}
{self.shell_function("main")}
main
'''
                result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True)
                self.assertEqual(result.returncode, 23 if fail_github else 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), stages[:5] if fail_github else stages)

    def test_server_upload_contains_only_stable_and_development_appcasts(self):
        probe = '''set -eu
DOWNLOAD_BASE_URL=https://github.com/starcat-app/Starcat/releases/download/v9.9.9/
VERSION=9.9.9
APPCAST_PATH=/fixture/appcast.xml
DEVELOPMENT_APPCAST_PATH=/fixture/appcast-development.xml
RELEASE_HOST=fixture-server
REMOTE_WEB_DIR=/fixture/site
SSH_CMD=(ssh)
RSYNC_SSH=ssh
verify_public_url() { :; }
log() { :; }
run_or_print() { printf '%s\\n' "$*"; }
''' + self.shell_function("publish_appcast") + "\npublish_appcast\n"
        result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True, check=True)
        self.assertIn("/fixture/appcast.xml fixture-server:/fixture/site/appcast.xml", result.stdout)
        self.assertIn(
            "/fixture/appcast-development.xml fixture-server:/fixture/site/appcast-development.xml",
            result.stdout,
        )
        self.assertNotIn("/downloads", result.stdout)
        self.assertNotIn(".dmg", result.stdout)
        self.assertNotIn(".sha256", result.stdout)

    def test_beta_release_help_and_version_gate_do_not_publish(self):
        script = ROOT / "scripts/release-direct-development.sh"
        help_result = subprocess.run(
            ["bash", str(script), "--help"], text=True, capture_output=True
        )
        invalid_result = subprocess.run(
            ["bash", str(script), "9.9.9-dev.1"], text=True, capture_output=True
        )

        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("X.Y.Z-beta.N", help_result.stdout)
        self.assertNotEqual(invalid_result.returncode, 0)
        self.assertIn("X.Y.Z-beta.N", invalid_result.stderr)

    def test_beta_version_gate_extracts_marketing_version_without_running_pipeline(self):
        """只执行参数解析段，验证 Beta 输入不会触发打包、tag 或网络。"""
        source = (ROOT / "scripts/release-direct-development.sh").read_text()
        parameter_gate = source.split("\nSCRIPT_DIR=", 1)[0]
        result = subprocess.run(
            ["bash", "-c", parameter_gate + '\nprintf "%s" "$MARKETING_VERSION"',
             "beta-version-gate", "9.9.9-beta.2"],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "9.9.9")

    def test_reuse_does_not_rebuild_or_staple(self):
        probe = '''set -eu
STARCAT_RELEASE_REUSE_ARTIFACTS=1
STARCAT_NOTARIZE=1
DMG_PATH=/fixture/Starcat.dmg
log() { :; }
run_or_print() { printf '%s\\n' "$*"; }
''' + self.shell_function("package_direct") + "\npackage_direct\n"
        result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.splitlines(), [
            "xcrun stapler validate /fixture/Starcat.dmg",
            "spctl --assess --type open --context context:primary-signature --verbose /fixture/Starcat.dmg",
        ])

    def test_reused_appcast_must_match_url_and_final_dmg_size(self):
        appcast = self.root / "appcast-current.xml"
        url = "https://github.com/starcat-app/Starcat/releases/download/v9.9.9/Starcat-9.9.9-arm64.dmg"
        for actual_url, length, valid in [
            (url, self.dmg.stat().st_size, True),
            ("https://starcat.ink/downloads/Starcat-9.9.9-arm64.dmg", self.dmg.stat().st_size, False),
            (url, 1, False),
        ]:
            with self.subTest(url=actual_url, length=length):
                appcast.write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
<description><![CDATA[notes]]></description>
<enclosure url="{actual_url}" length="{length}" />
</item></channel></rss>''')
                probe = f'''set -eu
DRY_RUN=0
VERSION=9.9.9
DMG_PATH='{self.dmg}'
SHA_PATH='{self.sha}'
CURRENT_APPCAST_PATH='{appcast}'
DOWNLOAD_BASE_URL=https://github.com/starcat-app/Starcat/releases/download/v9.9.9/
fail() {{ echo "$*" >&2; exit 1; }}
{self.shell_function("verify_local_artifacts")}
verify_local_artifacts
'''
                result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, valid, result.stderr)


if __name__ == "__main__":
    unittest.main()
