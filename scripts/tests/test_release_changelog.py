#!/usr/bin/env python3
"""隔离验证发布说明裁剪、双语快照、成功登记和实际 Xcode 资源阶段。

所有文件位于临时目录，执行的 Shell 仅为资源处理阶段，不运行打包或上传入口。
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release_changelog as changelog

WORKING = """# Release Notes

## 2.0.0-待发布

### New

- Future: Not public.

## 1.9.4-待发布

### Fixes

- Later: Not in this build.

## 1.9.3-待发布

### New

- Graph: Explore relationships.

## 1.9.2-待发布

- Draft: Not public history.

## 1.9.1

### Fixes

- Previous: Published history.
"""


class ReleaseChangelogTests(unittest.TestCase):
    """使用真实文件确认源稿保留、发布输出与续跑身份，而非匹配实现代码。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.snapshot = self.root / "snapshot"
        self.source.mkdir()
        for name in changelog.FILES:
            (self.source / name).write_text(WORKING)

    def test_beta_view_excludes_future_and_pending_history(self):
        output = changelog.render(WORKING, "1.9.3-beta.1", allow_pending=True)
        self.assertIn("## 1.9.3 Beta 1\n", output)
        self.assertIn("## 1.9.1\n", output)
        for forbidden in ("2.0.0", "1.9.4", "1.9.2", "待发布"):
            self.assertNotIn(forbidden, output)

    def test_missing_duplicate_empty_and_formal_pending_targets_fail(self):
        for text in (WORKING.replace("1.9.3", "1.9.5"),
                     WORKING + "\n## 1.9.3\n\nDuplicate.\n",
                     "## 1.9.3\n\n", WORKING):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    changelog.render(text, "1.9.3")

    def test_numeric_ordering_and_published_history_titles(self):
        text = "## 1.10.0\n\nNow.\n\n## 1.9.3 Beta 1\n\nBeta history.\n\n## 1.8.0\n\nOld.\n"
        output = changelog.render(text, "1.10.0")
        self.assertEqual(output, text)
        self.assertNotIn("1.10.0", changelog.render(text, "1.9.3"))

    def test_two_languages_validate_before_snapshot_writes(self):
        (self.source / "CHANGELOG-ZH.md").write_text("## 2.0.0-待发布\n\nFuture.\n")
        with self.assertRaises(ValueError):
            changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        self.assertFalse(self.snapshot.exists())

    def test_resume_uses_original_snapshot_after_working_copy_changes(self):
        changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        original = {name: (self.source / name).read_text() for name in changelog.FILES}
        frozen = (self.snapshot / "CHANGELOG.md").read_text()
        self.assertEqual(original["CHANGELOG.md"], WORKING)
        (self.source / "CHANGELOG.md").write_text(WORKING.replace("Explore relationships", "Edited later"))
        changelog.check_snapshot(self.snapshot, "1.9.3-beta.1")
        self.assertEqual((self.snapshot / "CHANGELOG.md").read_text(), frozen)
        with self.assertRaises(ValueError):
            changelog.check_snapshot(self.snapshot, "1.9.3-beta.2")
        with self.assertRaises(ValueError):
            changelog.finalize(self.source, self.snapshot, "1.9.3-beta.1")
        # 一种语言冲突时，另一种语言也不能提前被标记为已发布。
        self.assertEqual((self.source / "CHANGELOG-ZH.md").read_text(), original["CHANGELOG-ZH.md"])

    def test_repeated_prepare_preserves_existing_snapshot(self):
        changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        original = {path.name: path.read_text() for path in self.snapshot.iterdir()}
        (self.source / "CHANGELOG.md").write_text(WORKING.replace("Explore relationships", "Edited later"))
        with self.assertRaises(ValueError):
            changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        self.assertEqual({path.name: path.read_text() for path in self.snapshot.iterdir()}, original)

    def test_finalize_removes_only_released_target_marker_and_is_idempotent(self):
        changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        changelog.finalize(self.source, self.snapshot, "1.9.3-beta.1")
        changelog.finalize(self.source, self.snapshot, "1.9.3-beta.1")
        for name in changelog.FILES:
            self.assertEqual((self.source / name).read_text(),
                             WORKING.replace("## 1.9.3-待发布", "## 1.9.3"))

    def test_app_github_and_sparkle_use_the_same_body(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("sparkle_notes", ROOT / "scripts/inject-appcast-release-notes.py")
        sparkle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sparkle)
        spec = importlib.util.spec_from_file_location("github_notes", ROOT / "scripts/publish-direct-github-release.py")
        github = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(github)
        changelog.prepare(self.source, self.snapshot, "1.9.3-beta.1")
        text = (self.snapshot / "CHANGELOG.md").read_text()
        body = changelog.release_body(text, "1.9.3")
        self.assertEqual(sparkle.extract_version_section(text, "1.9.3"), body.strip())
        self.assertEqual(github.release_notes(self.snapshot / "CHANGELOG.md", "1.9.3"), body)
        self.assertIn("Graph: Explore relationships.", body)
        self.assertNotIn("Future", body)
        self.assertNotIn("Previous", body)

    def test_xcode_resource_phases_filter_using_actual_app_version(self):
        project = (ROOT / "project.yml").read_text()
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/release_changelog.py", self.root / "scripts")
        for target, channel in (("StarcatDirect", "direct"), ("Starcat", "appstore")):
            with self.subTest(target=target):
                target_block = re.search(rf"(?ms)^  {target}:\n(.*?)(?=^  \S|\Z)", project)[1]
                self.assertLess(target_block.index('name: "Auto Bump Version (from git)"'),
                                target_block.index('name: "Copy Changelog Resource"'))
                source = self.root / "supports/starcat-site" / channel
                source.mkdir(parents=True)
                for name in changelog.FILES:
                    (source / name).write_text(WORKING)
                products = self.root / target
                plist = products / "Starcat.app/Contents/Info.plist"
                plist.parent.mkdir(parents=True)
                plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.9.3"}))
                env = {key: value for key, value in os.environ.items() if not key.startswith("STARCAT_")}
                env.update(SRCROOT=str(self.root), TARGET_BUILD_DIR=str(products),
                           INFOPLIST_PATH="Starcat.app/Contents/Info.plist",
                           UNLOCALIZED_RESOURCES_FOLDER_PATH="Starcat.app/Contents/Resources",
                           CONFIGURATION="Release", STARCAT_RELEASE_VERSION="1.9.3-beta.1")
                changelog.prepare(source, self.snapshot, "1.9.3-beta.1")
                env["STARCAT_RELEASE_CHANGELOG_DIR"] = str(self.snapshot)
                script = textwrap.dedent(re.search(
                    r'(?ms)name: "Copy Changelog Resource"\n        script: \|\n(.*?)(?=^        runOnlyWhenInstalling:)',
                    target_block)[1])
                result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in changelog.FILES:
                    actual = (plist.parent / "Resources" / name).read_text()
                    self.assertEqual(actual, (self.snapshot / name).read_text())
                    self.assertNotIn("待发布", actual)

    def test_debug_channel_without_target_only_shows_published_history(self):
        text = WORKING.replace("## 1.9.3-待发布", "## 1.9.5-待发布")
        output = changelog.render(text, "1.9.3", require_target=False)
        self.assertIn("## 1.9.1", output)
        self.assertNotIn("1.9.5", output)
        with self.assertRaises(ValueError):
            changelog.render(text, "1.9.3")


if __name__ == "__main__":
    unittest.main()
