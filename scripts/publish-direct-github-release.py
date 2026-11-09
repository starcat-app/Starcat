#!/usr/bin/env python3
"""用本机 gh 发布 Direct DMG/SHA256，校验完成后才公开 Release。

本模块只负责 GitHub 附件，不构建、不修改 DMG，也不上传 appcast。
草稿允许补齐缺失附件；已有附件必须与本地产物一致，绝不使用 --clobber。
因此上传中断可以续跑，而同一版本重新打包造成的内容变化会明确失败。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPOSITORY = "starcat-app/Starcat"


def gh(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    """固定通过参数数组调用 gh，避免发布说明或路径被 shell 解释。"""
    result = subprocess.run(
        ["gh", *args], capture_output=True, text=True, timeout=900
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "GitHub CLI 执行失败")
    return result


def get_release(tag: str) -> dict | None:
    """Tag 关联 Release 或明确的 404 视为缺失；鉴权、网络错误不能触发创建流程。

    GitHub 对草稿 Release 不暴露 by-tag 端点，即使其 tag_name 指向已有
    Git tag；因此创建后必须回读 Release 列表，并精确匹配 tag_name。
    """
    result = gh("api", f"repos/{REPOSITORY}/releases/tags/{tag}", check=False)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or "无法读取 GitHub Release")
    return json.loads(result.stdout)


def get_release_or_draft(tag: str) -> dict | None:
    """按 tag 查找已发布 Release 或草稿，兼容 GitHub 的草稿查询行为。"""
    release = get_release(tag)
    if release is not None:
        return release
    result = gh("api", f"repos/{REPOSITORY}/releases?per_page=100")
    releases = json.loads(result.stdout)
    matches = [item for item in releases if item.get("tag_name") == tag]
    if not matches:
        return None
    if len(matches) > 1:
        raise RuntimeError(f"GitHub 存在多个 tag 为 {tag} 的 Release，需人工清理")
    return matches[0]


def file_sha256(path: Path) -> str:
    """流式计算摘要，避免把整个 DMG 放入内存。"""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_notes(changelog: Path, version: str, *, allow_pending: bool = False) -> str:
    """正式 Release 拒绝待发布标题；Beta prerelease 可以复用待发布说明。"""
    heading_suffix = r"(?:-待发布)?" if allow_pending else ""
    match = re.search(
        rf"^## {re.escape(version)}{heading_suffix}\s*\n(.*?)(?=^## |\Z)",
        changelog.read_text(encoding="utf-8"),
        re.MULTILINE | re.DOTALL,
    )
    if not match or not match.group(1).strip():
        raise ValueError(f"Changelog 缺少正式版本内容: {version}")
    return match.group(1).strip() + "\n"


def publish(
    version: str,
    dmg: Path,
    checksum: Path,
    changelog: Path,
    *,
    prerelease: bool = False,
    marketing_version: str | None = None,
) -> None:
    """上传草稿、回读实际附件并校验摘要，再按指定发布类型公开。"""
    expected_pattern = r"\d+\.\d+\.\d+-beta\.[1-9]\d*" if prerelease else r"\d+\.\d+\.\d+"
    if not re.fullmatch(expected_pattern, version):
        raise ValueError("正式版本必须是 X.Y.Z；Beta 版本必须是 X.Y.Z-beta.N")
    # tag 使用 Beta 序号，App 与附件仍使用合法的营销版本；两者必须指向同一版本。
    base_version = version.split("-beta.", 1)[0]
    marketing_version = marketing_version or base_version
    if not re.fullmatch(r"\d+\.\d+\.\d+", marketing_version):
        raise ValueError("App 营销版本必须是 X.Y.Z")
    if marketing_version != base_version:
        raise ValueError("App 营销版本必须与发布版本的 X.Y.Z 一致")
    if dmg.name != f"Starcat-{marketing_version}-arm64.dmg" or checksum.name != dmg.name + ".sha256":
        raise ValueError("DMG/SHA256 文件名必须与目标版本一致")
    digest = file_sha256(dmg)
    if not re.fullmatch(
        rf"{digest}\s+\*?{re.escape(dmg.name)}", checksum.read_text().strip()
    ):
        raise ValueError("本地 DMG 与 SHA256 不一致，禁止上传")
    notes = release_notes(changelog, marketing_version, allow_pending=prerelease)
    tag = f"v{version}"
    release = get_release(tag)
    if release and release["prerelease"] != prerelease:
        raise ValueError("目标 tag 的正式版/预发布属性与本次发布策略不一致")

    with tempfile.TemporaryDirectory(prefix="starcat-github-release-") as directory:
        work = Path(directory)
        if release is None:
            notes_path = work / "release-notes.md"
            notes_path.write_text(notes, encoding="utf-8")
            create_args = [
                "release", "create", tag, "--repo", REPOSITORY,
                "--draft", "--verify-tag", "--title",
                f"Starcat {marketing_version} Beta {version.rsplit('.', 1)[1]}" if prerelease else f"Starcat {version}",
                "--notes-file", str(notes_path),
            ]
            if prerelease:
                create_args.append("--prerelease")
            gh(*create_args)
            release = get_release_or_draft(tag)
            if release is None:
                raise RuntimeError("创建草稿后无法回读 Release")

        existing = {asset["name"] for asset in release["assets"]}
        for artifact in (dmg, checksum):
            if artifact.name not in existing:
                if not release["draft"]:
                    raise ValueError(f"已发布 Release 缺少附件，停止修改: {artifact.name}")
                gh("release", "upload", tag, str(artifact), "--repo", REPOSITORY)
            # 下载真实附件校验；不依赖可能缺失的 API digest，也不只检查同名/大小。
            gh(
                "release", "download", tag, "--repo", REPOSITORY,
                "--pattern", artifact.name, "--dir", str(work),
            )
            if file_sha256(work / artifact.name) != file_sha256(artifact):
                raise ValueError(f"GitHub 附件与本地不同，禁止覆盖或发布: {artifact.name}")

        if release["draft"]:
            edit_args = ["release", "edit", tag, "--repo", REPOSITORY, "--draft=false"]
            if prerelease:
                edit_args.append("--prerelease")
            else:
                edit_args.append("--latest")
            gh(*edit_args)
        published = get_release(tag)
        if published is None or published["draft"] or published["prerelease"] != prerelease:
            raise RuntimeError("GitHub Release 状态与发布策略不一致，禁止发布 appcast")
        print(f"GitHub Release 已核验: {published['html_url']}")


def main() -> None:
    """提供给 release-direct.sh 的单一发布入口；失败以非零状态阻断清单上传。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--sha256", required=True, type=Path)
    parser.add_argument("--changelog", required=True, type=Path)
    parser.add_argument("--prerelease", action="store_true")
    parser.add_argument("--marketing-version")
    args = parser.parse_args()
    try:
        publish(
            args.version,
            args.dmg,
            args.sha256,
            args.changelog,
            prerelease=args.prerelease,
            marketing_version=args.marketing_version,
        )
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"[github-release] ERROR: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
