#!/usr/bin/env python3
"""只读采集版本启动事实；不切分支、不更新 refs、不写配置，也不判定业务验收。

登记清单只作为数据读取，绝不执行 clone-all.sh。Git 禁用可选锁，避免 status
顺带刷新 index；远端最新状态必须显式请求，缓存比较始终单独标记。
"""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def git(repo, *args, check=True):
    """仅运行调用方指定的只读 Git 命令，非交互失败留给报告处理。"""
    return subprocess.run(
        ["git", "--no-optional-locks", "-C", str(repo), *args],
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"},
        capture_output=True, text=True, check=check, timeout=20,
    )


def commit(repo, ref):
    """不存在的 ref 与有效 commit 分开表示，不用空结果冒充可用基线。"""
    result = git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}", check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def relation(repo, left, right):
    """返回左侧 ref 相对右侧的领先/落后；缺少任一端时保留未核实。"""
    if not commit(repo, left) or not commit(repo, right):
        return None
    ahead, behind = git(repo, "rev-list", "--left-right", "--count", left + "..." + right).stdout.split()
    return {"left": left, "right": right, "ahead": int(ahead), "behind": int(behind)}


def checkout_state(repo):
    """分别记录暂存、未暂存、未跟踪和冲突；只报告路径，不读取文件正文。"""
    lines = git(repo, "status", "--porcelain=v1", "--untracked-files=all").stdout.splitlines()
    git_dir = Path(git(repo, "rev-parse", "--absolute-git-dir").stdout.strip())
    operations = [name for name in (
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
    ) if (git_dir / name).exists()]
    return {
        "branch": git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False).stdout.strip() or None,
        "head": commit(repo, "HEAD"),
        "staged": [line[3:] for line in lines if line[0] not in " ?"],
        "unstaged": [line[3:] for line in lines if line[1] not in " ?"],
        "untracked": [line[3:] for line in lines if line.startswith("??")],
        "conflicts": [line[3:] for line in lines if line[:2] in {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}],
        "operations": operations,
    }


def worktrees(repo):
    """读取 NUL 分隔的 worktree 记录，路径含空格时也能正确关联状态。"""
    records, current = [], {}
    for field in git(repo, "worktree", "list", "--porcelain", "-z").stdout.split("\0"):
        if not field:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = field.partition(" ")
        current[key] = value or True
    for record in records:
        path = Path(record["worktree"])
        if path.is_dir() and not record.get("bare"):
            record["state"] = checkout_state(path)
        else:
            record["state"] = None
    return records


def inventory(root):
    """合并登记清单与磁盘仓库；遇到仓库边界后不遍历其依赖或 vendored 副本。"""
    manifest = root / "supports/clone-all.sh"
    entries = re.findall(r'^\s*"([^"|]+)\|[^"\n]*\|([^"\n]*)"\s*$', manifest.read_text() if manifest.exists() else "", re.M)
    declared = {root / "supports" / name: description for name, description in entries}
    candidates = {root, *declared}
    excluded_dirs = {".git", "node_modules", ".build", "build", "vendor", ".venv", "__pycache__"}
    supports = root / "supports"
    if supports.is_dir():
        for directory, names, _ in os.walk(supports, followlinks=False):
            base = Path(directory)
            if (base / ".git").exists():
                candidates.add(base)
                names[:] = []
                continue
            for name in list(names):
                child = base / name
                if name in excluded_dirs:
                    names.remove(name)
                elif (child / ".git").exists():
                    candidates.add(child)
                    names.remove(name)
    return declared, sorted(candidates, key=lambda p: (p != root, str(p)))


def remote_dev(repo, remote, cached_sha, enabled):
    """用 ls-remote 核对实时 dev，不 fetch 对象或更新缓存 refs，也不输出远端 URL。"""
    if not enabled or not remote:
        return {"status": "NOT RUN", "reason": "未请求实时检查" if remote else "没有可用远端"}
    try:
        result = git(repo, "ls-remote", "--exit-code", remote, "refs/heads/dev", check=False)
        if result.returncode == 2:
            return {"status": "MISSING", "reason": "远端没有 dev"}
        if result.returncode != 0:
            return {"status": "NOT VERIFIED", "reason": "远端读取失败，未输出可能含凭据的错误正文"}
        sha = result.stdout.split()[0]
        return {"status": "VERIFIED", "sha": sha, "cached_ref_current": sha == cached_sha}
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "NOT VERIFIED", "reason": "远端读取不可用或超时"}


def inspect_repo(repo, root, description, version, check_remote):
    """汇总一个逻辑仓库及全部检出目录；只提供事实，不擅自选参与名单。"""
    common = Path(git(repo, "rev-parse", "--git-common-dir").stdout.strip())
    common = (repo / common).resolve() if not common.is_absolute() else common.resolve()
    target = "feature/" + version
    upstream = git(repo, "for-each-ref", "--format=%(upstream)", "refs/heads/dev").stdout.strip()
    remote = git(repo, "config", "--get", "branch.dev.remote", check=False).stdout.strip()
    remotes = git(repo, "remote").stdout.splitlines()
    if not remote and "origin" in remotes:
        remote = "origin"
    cached_ref = upstream or ("refs/remotes/" + remote + "/dev" if remote and remote != "." else None)
    cached_sha = commit(repo, cached_ref) if cached_ref else None
    old_versions = []
    for branch in git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/feature/").stdout.splitlines():
        if re.fullmatch(r"feature/\d+\.\d+\.\d+", branch) and branch != target and commit(repo, "dev"):
            result = git(repo, "merge-base", "--is-ancestor", branch, "dev", check=False)
            if result.returncode == 1:
                old_versions.append(branch)
            elif result.returncode != 0:
                result.check_returncode()
    return {
        "path": str(repo), "detected_paths": [str(repo)], "common_git_dir": str(common),
        "description": description,
        "scope_hint": "archived" if "已归档" in description else ("active" if description or repo == root else "review"),
        "state": checkout_state(repo), "worktrees": worktrees(repo),
        "dev": commit(repo, "refs/heads/dev"), "dev_upstream": upstream or None,
        "cached_dev_ref": cached_ref, "cached_dev_sha": cached_sha,
        "dev_vs_cached": relation(repo, "dev", cached_ref) if cached_ref else None,
        "dev_vs_main": relation(repo, "dev", "main"),
        "live_remote_dev": remote_dev(repo, remote, cached_sha, check_remote),
        "target_branch": target, "target_commit": commit(repo, "refs/heads/" + target),
        "target_vs_dev": relation(repo, target, "dev"), "unmerged_version_branches": old_versions,
        "local_target_tags": [tag for tag in git(repo, "tag", "--list").stdout.splitlines()
                              if re.fullmatch(r"v?" + re.escape(version) + r"(?:[-+].*)?", tag)],
    }


def version_documents(root, version):
    """精确匹配标题而非正文提及，区分目标节、重复标题与双语状态差异。"""
    changelogs = []
    for channel in ("appstore", "direct"):
        for name in ("CHANGELOG.md", "CHANGELOG-ZH.md"):
            path = root / "supports/starcat-site" / channel / name
            titles = re.findall(r"^##[ \t]+([^\r\n]+)", path.read_text() if path.exists() else "", re.M)
            target = [title.strip() for title in titles if re.match(r"v?" + re.escape(version) + r"(?=$|[- +])", title.strip())]
            changelogs.append({
                "path": str(path.relative_to(root)), "exists": path.is_file(), "target_titles": target,
                "duplicate_titles": [title for title, count in Counter(target).items() if count > 1],
            })
    plans_dir = root / "docs/4-工程进度/版本迭代"
    plans = []
    for path in sorted(plans_dir.glob("*-迭代计划.md")):
        text = path.read_text()
        status = re.search(r"^> 状态：[ \t]*(.+)$", text, re.M)
        plans.append({"path": str(path.relative_to(root)), "status": status.group(1) if status else None,
                      "is_target": path.name == version + "-迭代计划.md"})
    project = root / "project.yml"
    configured = re.findall(r'''^\s*MARKETING_VERSION:\s*["']?([0-9]+\.[0-9]+\.[0-9]+)''', project.read_text() if project.exists() else "", re.M)
    mismatches = [channel for channel, en, zh in (
        ("appstore", changelogs[0], changelogs[1]), ("direct", changelogs[2], changelogs[3]),
    ) if sorted(en["target_titles"]) != sorted(zh["target_titles"])]
    return {"changelogs": changelogs, "bilingual_title_mismatches": mismatches,
            "plans": plans, "configured_app_versions": sorted(set(configured))}


def audit(root, version, check_remote=False):
    """生成可复核的 JSON；采集失败独立保留，不能用其它仓库的成功掩盖。"""
    declared, candidates = inventory(root)
    repos, missing, failures, by_common = [], [], [], {}
    for repo in candidates:
        if not (repo / ".git").exists():
            missing.append({"path": str(repo), "description": declared.get(repo, ""), "reason": "缺少独立 .git 标记"})
            continue
        try:
            common = git(repo, "rev-parse", "--git-common-dir").stdout.strip()
            identity = str((repo / common).resolve())
            if identity in by_common:
                by_common[identity]["detected_paths"].append(str(repo))
                continue
            record = inspect_repo(repo, root, declared.get(repo, ""), version, check_remote)
            by_common[identity] = record
            repos.append(record)
        except (OSError, subprocess.SubprocessError):
            failures.append({"path": str(repo), "reason": "Git 采集失败或超时，需单独核实"})
    return {
        "root": str(root), "version": version, "target_branch": "feature/" + version,
        "remote_check_requested": check_remote, "manifest_present": (root / "supports/clone-all.sh").is_file(),
        "repositories": repos, "missing_repositories": missing, "inspection_failures": failures,
        "documents": version_documents(root, version),
        "environment": {
            "files_present": {path: (root / path).is_file() for path in (
                "Configs/Secrets.xcconfig", "Configs/SwiftPackages.resolved", "Makefile", "BRANCH.md",
            )},
            "tools_present": {name: shutil.which(name) is not None for name in ("git", "python3", "make", "xcodegen", "rtk")},
            "stable_xcode_present": Path("/Applications/Xcode.app/Contents/Developer").is_dir(),
        },
    }


def main():
    """CLI 只接受基础版本；正常退出表示报告生成，不代表工作区全部通过。"""
    parser = argparse.ArgumentParser(description="只读检查 Starcat 版本迭代工作区，输出 JSON，不修改文件或 refs。")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3], help="Starcat 根目录")
    parser.add_argument("--version", required=True, help="目标基础版本，例如 1.9.8")
    parser.add_argument("--check-remote", action="store_true", help="通过 ls-remote 实时读取 dev，不 fetch")
    args = parser.parse_args()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", args.version):
        parser.error("--version 必须为 X.Y.Z 基础版本，不含 v 前缀或 Beta 序号")
    root = args.root.resolve()
    if not (root / ".git").exists() or not shutil.which("git"):
        parser.error("--root 必须是含独立 .git 标记的项目根目录，且 git 可用")
    print(json.dumps(audit(root, args.version, args.check_remote), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
