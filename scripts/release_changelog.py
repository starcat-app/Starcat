#!/usr/bin/env python3
"""从本地工作稿生成发布说明，供 App、GitHub、Sparkle 共用。

工作稿可保留未来版本；发布视图只包含目标版本与更早的已发布历史。
Direct 构建先固定双语快照，续跑不得改用后来编辑的工作稿。
本工具只处理本地文本，不构建、不联网、不发布。
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
from pathlib import Path
from typing import NamedTuple

FILES = ("CHANGELOG.md", "CHANGELOG-ZH.md")
HEADING = re.compile(r"^##\s+\[?(\d+\.\d+\.\d+)\]?([^\n]*)$", re.MULTILINE)
RELEASE_VERSION = re.compile(r"(\d+\.\d+\.\d+)(?:-beta\.([1-9]\d*))?")


class Section(NamedTuple):
    """保留正文与原始标题，避免筛选版本时重排或重写用户条目。"""

    version: str
    suffix: str
    body: str
    start: int
    end: int


def version_key(version: str) -> tuple[int, ...]:
    """按数字比较版本，避免把 1.10.0 排在 1.9.3 之前。"""
    return tuple(int(part) for part in version.split("."))


def release_identity(version: str) -> tuple[str, str]:
    """营销版本用于筛选；Beta 序号只进入发布标题，不混入版本比较。"""
    match = RELEASE_VERSION.fullmatch(version)
    if not match:
        raise ValueError(f"发布版本必须是 X.Y.Z 或 X.Y.Z-beta.N: {version}")
    base, beta = match.groups()
    return base, f"{base} Beta {beta}" if beta else base


def sections(markdown: str) -> list[Section]:
    """仅用二级版本标题切段，三级分类和条目内容保持原样。"""
    matches = list(HEADING.finditer(markdown))
    return [
        Section(
            match[1], match[2],
            markdown[match.end():matches[index + 1].start() if index + 1 < len(matches) else len(markdown)].strip(),
            match.start(), match.end(),
        )
        for index, match in enumerate(matches)
    ]


def target_section(markdown: str, version: str, *, allow_pending: bool = False) -> Section:
    """缺少、重复或空的目标节均阻断发布，绝不回退到顶部未来版本。"""
    base, _ = release_identity(version)
    found = [section for section in sections(markdown) if section.version == base]
    if len(found) != 1 or not found[0].body:
        raise ValueError(f"Changelog 缺少唯一且非空的版本内容: {base}")
    if "待发布" in found[0].suffix and not allow_pending:
        raise ValueError(f"Changelog 目标版本仍标记为待发布: {base}")
    return found[0]


def release_body(markdown: str, version: str, *, allow_pending: bool = False) -> str:
    """GitHub 与 Sparkle 只取本次版本正文，不包含版本标题和其他版本。"""
    return target_section(markdown, version, allow_pending=allow_pending).body + "\n"


def render(
    markdown: str, version: str, *, allow_pending: bool = False, require_target: bool = True
) -> str:
    """生成当前版本加已发布历史；Debug 缺少当前渠道版本时仅显示已发布历史。"""
    base, title = release_identity(version)
    entries = sections(markdown)
    found = [entry for entry in entries if entry.version == base]
    current = target_section(markdown, version, allow_pending=allow_pending) if found or require_target else None
    history = sorted(
        (entry for entry in entries if version_key(entry.version) < version_key(base)
         and "待发布" not in entry.suffix),
        key=lambda entry: version_key(entry.version), reverse=True,
    )
    preamble = markdown[:entries[0].start].strip() if entries else ""
    parts = [preamble] if preamble else []
    if current:
        parts.append(f"## {title}\n\n{current.body}")
    parts.extend(f"## {entry.version}{entry.suffix}\n\n{entry.body}" for entry in history)
    if not current and not history:
        raise ValueError(f"Changelog 没有 {base} 或更早的已发布内容")
    return "\n\n".join(parts) + "\n"


def prepare(source: Path, output: Path, version: str) -> None:
    """先验证两种语言再写快照；正式版仍要求源目标节已经去掉待发布。"""
    allow_pending = "-beta." in version
    rendered = {name: render((source / name).read_text(), version, allow_pending=allow_pending) for name in FILES}
    expected = {**rendered, "release-version.txt": version + "\n"}
    # 同一版本重走新构建入口时，不能在 tag 检查之前覆盖已有产物对应的说明。
    if any((output / name).exists() for name in expected):
        if not all((output / name).is_file() and (output / name).read_text() == text
                   for name, text in expected.items()):
            raise ValueError(f"已有发布说明快照与工作稿不同；请保留原快照并核对发布版本: {output}")
        return
    output.mkdir(parents=True, exist_ok=True)
    for name, text in expected.items():
        (output / name).write_text(text)


def check_snapshot(root: Path, version: str) -> None:
    """续跑校验发布身份和快照内容；缺失时停止，不能从当前工作稿猜测原始说明。"""
    if (root / "release-version.txt").read_text().strip() != version:
        raise ValueError("发布说明快照与本次发布版本不一致")
    for name in FILES:
        text = (root / name).read_text()
        if render(text, version) != text:
            raise ValueError(f"发布说明快照仍含未来版本或待发布区段: {root / name}")


def finalize(source: Path, snapshot: Path, version: str) -> None:
    """发布成功才摘掉源目标标题的待发布；后续工作稿的正文和未来版本不改。"""
    check_snapshot(snapshot, version)
    changes = {}
    for name in FILES:
        path = source / name
        text = path.read_text()
        target = target_section(text, version, allow_pending=True)
        if target.body != target_section((snapshot / name).read_text(), version).body:
            raise ValueError(f"源目标正文已变化，不能自动标记已发布: {path}")
        if "待发布" in target.suffix:
            changes[path] = text[:target.start] + f"## {target.version}" + text[target.end:]
    for path, text in changes.items():
        path.write_text(text)


def bundle(source: Path, output: Path, plist: Path, configuration: str, version: str | None) -> None:
    """在版本写入 Info.plist 后处理资源，保证筛选上限与实际 App 版本相同。"""
    with plist.open("rb") as stream:
        app_version = plistlib.load(stream)["CFBundleShortVersionString"]
    version = version or app_version
    if release_identity(version)[0] != release_identity(app_version)[0]:
        raise ValueError("发布说明版本与 App Info.plist 不一致")
    if configuration != "Debug" and os.environ.get("STARCAT_RELEASE_CHANGELOG_DIR"):
        check_snapshot(source, version)
    rendered = {
        name: render((source / name).read_text(), version,
                     allow_pending=configuration == "Debug", require_target=configuration != "Debug")
        for name in FILES
    }
    output.mkdir(parents=True, exist_ok=True)
    for name, text in rendered.items():
        (output / name).write_text(text)


def main() -> None:
    """命令行只提供构建、固定快照、核验和成功登记四个本地阶段。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "check", "finalize", "bundle"))
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--plist", type=Path)
    parser.add_argument("--configuration", default="Release")
    args = parser.parse_args()
    try:
        if args.action == "bundle":
            if not args.output_root or not args.plist:
                parser.error("bundle 需要 --output-root 和 --plist")
            bundle(args.source_root, args.output_root, args.plist, args.configuration, args.version)
        else:
            if not args.version:
                parser.error("需要 --version")
            if args.action == "check":
                check_snapshot(args.source_root, args.version)
            else:
                if not args.output_root:
                    parser.error("需要 --output-root")
                if args.action == "prepare":
                    prepare(args.source_root, args.output_root, args.version)
                else:
                    finalize(args.source_root, args.output_root, args.version)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"[release-changelog] ERROR: {error}\n")


if __name__ == "__main__":
    main()
