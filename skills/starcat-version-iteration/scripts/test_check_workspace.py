#!/usr/bin/env python3
"""在临时 Git 仓库验证只读采集，所有分支、合并及远端均局限于测试目录。

检查实际 Git 状态和 index/refs 不变，避免用模拟成功替代跨仓与 worktree 行为。
"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import check_workspace as checker


class WorkspaceAuditTests(unittest.TestCase):
    """用真实仓库覆盖多项目发现、阻断事实、版本匹配和无写入约束。"""

    def setUp(self):
        """每例独立，禁用签名和 hooks，不访问真实项目的 Git 状态。"""
        self.temp = tempfile.TemporaryDirectory(prefix="starcat-iteration-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "Starcat"
        self.create_repo(self.root)

    def run_git(self, repo, *args, check=True):
        """测试写操作只面向临时路径，不使用用户项目或网络远端。"""
        return subprocess.run(["git", "-C", str(repo), *args], check=check,
                              capture_output=True, text=True)

    def create_repo(self, path, branch="dev"):
        """建立含提交的仓库，确保后续测试的是有效基线而非空库特例。"""
        path.mkdir(parents=True)
        self.run_git(path, "init", "-b", branch)
        for key, value in (("user.name", "Fixture"), ("user.email", "fixture@example.invalid"),
                           ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")):
            self.run_git(path, "config", key, value)
        (path / "tracked.txt").write_text("base\n")
        self.run_git(path, "add", "tracked.txt")
        self.run_git(path, "commit", "-m", "fixture")
        if branch != "main":
            self.run_git(path, "branch", "main")

    def snapshot(self, repo):
        """index 字节及修改时间、HEAD、配置和 refs 必须全部保持原样。"""
        directory = Path(self.run_git(repo, "rev-parse", "--absolute-git-dir").stdout.strip())
        files = {name: ((directory / name).read_bytes(), (directory / name).stat().st_mtime_ns)
                 for name in ("index", "HEAD", "config") if (directory / name).is_file()}
        return files, self.run_git(repo, "for-each-ref", "--format=%(refname) %(objectname)").stdout

    def test_inventory_includes_hidden_nested_missing_and_archived(self):
        """登记缺失项不能消失，额外仓库须待确认，不能替用户选参与范围。"""
        supports = self.root / "supports"
        supports.mkdir()
        (supports / "clone-all.sh").write_text('''PROJECTS=(
  "alpha|https://example.invalid/alpha|维护项目"
  ".github|https://example.invalid/meta|组织项目"
  "extensions/plugin|https://example.invalid/plugin|扩展"
  "starcat-pro|https://example.invalid/pro|已归档"
  "missing|https://example.invalid/missing|尚未克隆"
)
''')
        for name in ("alpha", ".github", "extensions/plugin", "starcat-pro", "extra"):
            self.create_repo(supports / name)
        configs = self.root / "Configs"
        configs.mkdir()
        (configs / "Secrets.xcconfig").write_text("SENTINEL_SECRET_MUST_NOT_APPEAR")
        paths = [self.root, supports / "alpha", supports / ".github", supports / "extensions/plugin"]
        before = [self.snapshot(path) for path in paths]
        report = checker.audit(self.root, "1.9.8")
        repos = {Path(item["path"]).name: item for item in report["repositories"]}
        self.assertEqual(len(repos), 6)
        self.assertEqual(repos["extra"]["scope_hint"], "review")
        self.assertEqual(repos["starcat-pro"]["scope_hint"], "archived")
        self.assertEqual(Path(report["missing_repositories"][0]["path"]).name, "missing")
        self.assertTrue(report["environment"]["files_present"]["Configs/Secrets.xcconfig"])
        self.assertNotIn("SENTINEL_SECRET", json.dumps(report))
        self.assertEqual(before, [self.snapshot(path) for path in paths])

    def test_staged_unstaged_and_untracked_are_separate(self):
        """同一文件可同时有暂存和未暂存改动，不能只显示一种状态。"""
        (self.root / "tracked.txt").write_text("staged\n")
        self.run_git(self.root, "add", "tracked.txt")
        (self.root / "tracked.txt").write_text("unstaged\n")
        (self.root / "new.txt").write_text("untracked\n")
        before = self.snapshot(self.root)
        state = checker.audit(self.root, "1.9.8")["repositories"][0]["state"]
        self.assertEqual(state["staged"], ["tracked.txt"])
        self.assertEqual(state["unstaged"], ["tracked.txt"])
        self.assertEqual(state["untracked"], ["new.txt"])
        self.assertEqual(before, self.snapshot(self.root))

    def test_conflict_and_incomplete_merge_remain_untouched(self):
        """报告真实冲突和未完成 merge，检查过程不得尝试修复或结束合并。"""
        self.run_git(self.root, "switch", "-c", "topic")
        (self.root / "tracked.txt").write_text("topic\n")
        self.run_git(self.root, "commit", "-am", "topic")
        self.run_git(self.root, "switch", "dev")
        (self.root / "tracked.txt").write_text("dev\n")
        self.run_git(self.root, "commit", "-am", "dev")
        self.assertEqual(self.run_git(self.root, "merge", "topic", check=False).returncode, 1)
        before = self.snapshot(self.root)
        state = checker.audit(self.root, "1.9.8")["repositories"][0]["state"]
        self.assertEqual(state["conflicts"], ["tracked.txt"])
        self.assertIn("MERGE_HEAD", state["operations"])
        self.assertEqual(before, self.snapshot(self.root))

    def test_linked_worktree_is_one_repo_with_target_occupancy(self):
        """.git 文件与带空格路径必须被识别，同一仓库不能重复计划建分支。"""
        linked = self.root / "supports/linked checkout"
        linked.parent.mkdir()
        self.run_git(self.root, "worktree", "add", "-b", "feature/1.9.8", str(linked), "dev")
        (linked / "pending.txt").write_text("pending\n")
        before = self.snapshot(self.root), self.snapshot(linked)
        repos = checker.audit(self.root, "1.9.8")["repositories"]
        self.assertEqual(len(repos), 1)
        self.assertIn(str(linked), repos[0]["detected_paths"])
        target = next(item for item in repos[0]["worktrees"] if item.get("branch") == "refs/heads/feature/1.9.8")
        self.assertEqual(target["state"]["untracked"], ["pending.txt"])
        self.assertEqual(repos[0]["target_vs_dev"]["ahead"], 0)
        self.assertEqual(before, (self.snapshot(self.root), self.snapshot(linked)))

    def test_missing_dev_detached_head_and_unmerged_iteration(self):
        """缺少 dev 和未收口旧迭代必须显式报告，不替换基线。"""
        self.create_repo(self.root / "supports/only-main", branch="main")
        self.run_git(self.root, "switch", "-c", "feature/1.9.7")
        (self.root / "tracked.txt").write_text("old work\n")
        self.run_git(self.root, "commit", "-am", "old work")
        self.run_git(self.root, "switch", "--detach", "dev")
        repos = checker.audit(self.root, "1.9.8")["repositories"]
        self.assertIsNone(repos[0]["state"]["branch"])
        self.assertEqual(repos[0]["unmerged_version_branches"], ["feature/1.9.7"])
        self.assertIsNone(repos[1]["dev"])

    def test_live_remote_detects_stale_cache_without_fetch(self):
        """仅访问临时本地 bare 远端，验证实时读取不会刷新 origin/dev。"""
        remote = Path(self.temp.name) / "remote.git"
        self.run_git(Path(self.temp.name), "clone", "--bare", str(self.root), str(remote))
        base = checker.commit(self.root, "dev")
        self.run_git(self.root, "remote", "add", "origin", str(remote))
        self.run_git(self.root, "config", "branch.dev.remote", "origin")
        self.run_git(self.root, "config", "branch.dev.merge", "refs/heads/dev")
        self.run_git(self.root, "update-ref", "refs/remotes/origin/dev", base)
        (self.root / "tracked.txt").write_text("new\n")
        self.run_git(self.root, "commit", "-am", "new")
        self.run_git(remote, "fetch", str(self.root), "dev:dev")
        before = self.snapshot(self.root)
        record = checker.audit(self.root, "1.9.8", check_remote=True)["repositories"][0]
        self.assertEqual(record["live_remote_dev"]["status"], "VERIFIED")
        self.assertFalse(record["live_remote_dev"]["cached_ref_current"])
        self.assertEqual(record["dev_vs_cached"]["ahead"], 1)
        self.assertEqual(before, self.snapshot(self.root))
        self.run_git(self.root, "config", "remote.origin.url", str(remote / "missing"))
        record = checker.audit(self.root, "1.9.8", check_remote=True)["repositories"][0]
        self.assertEqual(record["live_remote_dev"]["status"], "NOT VERIFIED")

    def test_exact_version_headings_duplicates_and_bilingual_mismatch(self):
        """正文提及或 1.9.80 不能算 1.9.8；不同 Beta 标题也不是重复节。"""
        text = "正文提及 1.9.8\n## 1.9.80\n## 1.9.8-待发布\n## 1.9.8-待发布\n## 1.9.8 Beta 1\n## 1.9.8 Beta 2\n"
        for channel in ("appstore", "direct"):
            for name in ("CHANGELOG.md", "CHANGELOG-ZH.md"):
                path = self.root / "supports/starcat-site" / channel / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text if channel == "appstore" or name == "CHANGELOG.md" else "## 1.9.8\n")
        plans = self.root / "docs/4-工程进度/版本迭代"
        plans.mkdir(parents=True)
        (plans / "1.9.8-迭代计划.md").write_text("# 1.9.8\n> 状态：开发中\n")
        documents = checker.version_documents(self.root, "1.9.8")
        self.assertEqual(documents["changelogs"][0]["duplicate_titles"], ["1.9.8-待发布"])
        self.assertEqual(len(documents["changelogs"][0]["target_titles"]), 4)
        self.assertEqual(documents["bilingual_title_mismatches"], ["direct"])
        self.assertTrue(documents["plans"][0]["is_target"])

    def test_invalid_version_rejected_before_audit(self):
        """版本号不能被当成路径或分支片段；失败不触发任何 Git 写入。"""
        before = self.snapshot(self.root)
        result = subprocess.run([sys.executable, "-B", checker.__file__, "--root", str(self.root),
                                 "--version", "../1.9.8"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(before, self.snapshot(self.root))


if __name__ == "__main__":
    unittest.main()
