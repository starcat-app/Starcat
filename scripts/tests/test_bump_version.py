"""验证 Git 版本写入、worktree 解析与最终产物版本回退门禁。

仅使用临时 Git 仓库和 plist，不构建 App，也不修改真实版本或用户数据。
"""

import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/bump-version.sh"


class BumpVersionTests(unittest.TestCase):
    """覆盖版本来源与 Xcode 再生成 plist 后必须拒绝启动的约束。"""

    def setUp(self):
        """创建独立提交，避免测试依赖主仓库随时变化的 tag 和提交数。"""
        self.temporary = tempfile.TemporaryDirectory(prefix="starcat-version-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("-c", "user.name=Version Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture")
        self.hash = self.git("rev-parse", "--short=7", "HEAD")
        self.plist = self.root / "product" / "Info.plist"
        self.plist.parent.mkdir()
        self.write_plist()

    def git(self, *args):
        """通过真实 Git 验证 worktree 的 .git 文件与普通目录具有相同行为。"""
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], text=True
        ).strip()

    def write_plist(self, **updates):
        """模拟 Xcode 初次生成或重写产物，保留无关产品字段。"""
        data = {
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "CFBundleIdentifier": "test.starcat.version",
        }
        data.update(updates)
        self.plist.write_bytes(plistlib.dumps(data))

    def run_script(self, *args, source=None, **overrides):
        """隔离调用者的 Xcode/发布覆盖变量，并允许逐用例显式注入。"""
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("STARCAT_")}
        env.update(
            SRCROOT=str(source or self.repo),
            TARGET_BUILD_DIR=str(self.plist.parent),
            INFOPLIST_PATH=self.plist.name,
        )
        env.update(overrides)
        result = subprocess.run(["bash", str(SCRIPT), *args],
                                env=env, capture_output=True, text=True)
        return result

    def bump(self, **kwargs):
        """写入后立即读取真实 plist，失败时提供脚本诊断。"""
        result = self.run_script(**kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return plistlib.loads(self.plist.read_bytes())

    def test_tag_and_repeated_build(self):
        """有 tag 时重复构建也应恢复全部字段，且不改变无关元数据。"""
        self.git("tag", "v1.9.4-beta.1")
        for _ in range(2):
            data = self.bump()
            self.assertEqual(data["CFBundleShortVersionString"], "1.9.4-beta.1")
            self.assertEqual(data["CFBundleVersion"], "1")
            self.assertEqual(data["GitCommitHash"], self.hash)
            self.assertEqual(data["CFBundleIdentifier"], "test.starcat.version")
            self.assertEqual(self.run_script("--verify", str(self.plist)).returncode, 0)

    def test_worktree(self):
        """独立 worktree 必须能读取共享仓库的 tag 与当前提交。"""
        self.git("tag", "v1.9.4-beta.1")
        worktree = self.root / "worktree"
        self.git("worktree", "add", "--detach", str(worktree), "HEAD")
        self.assertTrue((worktree / ".git").is_file())
        data = self.bump(source=worktree)
        self.assertEqual(data["CFBundleShortVersionString"], "1.9.4-beta.1")
        self.assertEqual(data["GitCommitHash"], self.hash)

    def test_no_tag_preserves_existing_version(self):
        """无 tag 构建沿用工程值，不制造伪版本。"""
        self.write_plist(CFBundleShortVersionString="2.3.4")
        self.assertEqual(self.bump()["CFBundleShortVersionString"], "2.3.4")

    def test_release_overrides(self):
        """显式发布版本与 Direct 时间戳优先于 Git，校验采用相同来源。"""
        self.git("tag", "v1.9.4-beta.1")
        overrides = {
            "STARCAT_MARKETING_VERSION_OVERRIDE": "1.9.5",
            "STARCAT_BUILD_VERSION_OVERRIDE": "202611101700",
        }
        data = self.bump(**overrides)
        self.assertEqual(data["CFBundleShortVersionString"], "1.9.5")
        self.assertEqual(data["CFBundleVersion"], "202611101700")
        self.assertEqual(self.run_script("--verify", str(self.plist), **overrides).returncode, 0)

    def test_verify_rejects_regenerated_or_inconsistent_plist(self):
        """重现版本回退和扩展字段丢失，门禁必须失败且不得修补签名产物。"""
        self.git("tag", "v1.9.4-beta.1")
        expected = self.bump()
        for key, value in [
            ("CFBundleShortVersionString", "1.0.0"),
            ("CFBundleVersion", "999"),
            ("GitCommitHash", None),
        ]:
            with self.subTest(key=key):
                broken = dict(expected)
                if value is None:
                    broken.pop(key)
                else:
                    broken[key] = value
                self.plist.write_bytes(plistlib.dumps(broken))
                original = self.plist.read_bytes()
                result = self.run_script("--verify", str(self.plist))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)
                self.assertEqual(self.plist.read_bytes(), original)

    def test_verify_requires_all_products(self):
        """宿主通过但扩展缺失时，仍须阻断整个入口。"""
        self.bump()
        result = self.run_script("--verify", str(self.plist), str(self.root / "missing.plist"))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(self.run_script("--verify").returncode, 0)

    def test_all_version_phases_wait_for_processed_plist(self):
        """防止仅调整 phase 位置而再次遗漏 ProcessInfoPlistFile 依赖。"""
        spec = (ROOT / "project.yml").read_text()
        phases = spec.split('      - name: "Auto Bump Version (from git)"')[1:]
        self.assertEqual(len(phases), 5)
        for phase in phases:
            block = phase.split("basedOnDependencyAnalysis: false", 1)[0]
            self.assertIn('inputFiles:\n          - "$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"', block)


if __name__ == "__main__":
    unittest.main()
