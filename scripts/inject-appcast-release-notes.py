#!/usr/bin/env python3
"""把中英文 CHANGELOG 版本节注入 Sparkle appcast 的 <description> CDATA。

为什么做：
  Sparkle 标准更新窗只有在 appcast item 带 release notes 时才会展开说明区。
  generate_appcast 只根据 DMG 生成签名与 enclosure，不会读取仓库 Changelog。

关键约束：
  - 两种语言必须包含同一目标版本，不能静默发布缺少中文的说明。
  - 标准 description 供 Sparkle 按系统语言选择；扩展字段保留双语，供应用语言覆盖使用。
  - 只改 appcast XML，不改 DMG / 签名。
  - 内嵌 HTML（description），避免额外上传同名 .html 到 downloads/。
  - 去掉截图：更新窗 WebView 很窄，大图会把要点挤没。
  - ElementTree 不原生支持 CDATA，写出时走 appcast_xml_util.write_appcast_xml。
"""

from __future__ import annotations

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# 允许直接 `python3 scripts/inject-appcast-release-notes.py` 找到同目录工具模块。
sys.path.insert(0, str(Path(__file__).resolve().parent))

from appcast_xml_util import SPARKLE_NS, STARCAT_NS, write_appcast_xml
from release_changelog import release_body

SPARKLE_SHORT_VERSION = f"{{{SPARKLE_NS}}}shortVersionString"
ET.register_namespace("sparkle", SPARKLE_NS)

IMAGE_LINE_RE = re.compile(r"^\s*!\[([^\]]*)\]\(([^)]+)\)\s*$")
IMAGE_INLINE_RE = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
VERSION_HEADING_RE = re.compile(r"^##\s+(?:\[)?(?P<version>\d+\.\d+\.\d+)(?:\])?(?:\s|[—–-]|$).*")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inject Sparkle release notes HTML into appcast.xml from CHANGELOG markdown."
    )
    parser.add_argument("--appcast", required=True, type=Path, help="目标 appcast.xml")
    parser.add_argument(
        "--changelog-en",
        type=Path,
        help="英文 CHANGELOG 或当次发布快照",
    )
    parser.add_argument(
        "--changelog-zh",
        type=Path,
        help="中文 CHANGELOG，默认读取英文文件同目录的 CHANGELOG-ZH.md",
    )
    parser.add_argument(
        "--version",
        help="只注入该 X.Y.Z；省略则按 appcast 内全部 shortVersionString 回填",
    )
    parser.add_argument(
        "--more-url-en",
        default="https://starcat.ink/changelog.html",
        help="英文完整更新记录链接",
    )
    parser.add_argument(
        "--more-url-zh",
        default="https://starcat.ink/changelog-zh.html",
        help="中文完整更新记录链接",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="只打印将注入的版本，不写文件",
    )
    return parser.parse_args()


def extract_version_section(markdown: str, version: str) -> str | None:
    """提取目标版本正文，排除版本标题和其他版本内容。"""

    try:
        # 兼容读取历史工作稿，但只渲染正文，不把待发布标题带进 Sparkle。
        return release_body(markdown, version, allow_pending=True).strip()
    except ValueError:
        return None


def _inline_to_html(text: str) -> str:
    """Changelog 用到的一小撮 inline Markdown → HTML。"""

    text = IMAGE_INLINE_RE.sub("", text)
    parts: list[str] = []
    cursor = 0
    for match in LINK_RE.finditer(text):
        parts.append(html.escape(text[cursor:match.start()]))
        label = html.escape(match.group(1))
        url = html.escape(match.group(2), quote=True)
        # Sparkle WebView 内链用 target=_blank，才会落到系统浏览器。
        parts.append(f'<a href="{url}" target="_blank" rel="noopener">{label}</a>')
        cursor = match.end()
    parts.append(html.escape(text[cursor:]))
    rendered = "".join(parts)
    rendered = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", rendered)
    rendered = re.sub(r"`([^`]+)`", r"<code>\1</code>", rendered)
    return rendered.strip()


def section_to_sparkle_html(
    section: str,
    *,
    version: str,
    more_url: str,
    more_label: str,
) -> str:
    """把单版本 Markdown 收成适合更新窗的轻量 HTML 片段。"""

    lines = section.splitlines()
    body: list[str] = []
    in_list = False

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            body.append("</ul>")
            in_list = False

    for raw in lines:
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            close_list()
            continue
        if IMAGE_LINE_RE.match(stripped):
            continue
        if VERSION_HEADING_RE.match(stripped):
            close_list()
            continue
        if stripped.startswith("### "):
            close_list()
            body.append(f"<h3>{_inline_to_html(stripped[4:])}</h3>")
            continue
        if re.match(r"^- ", stripped):
            if not in_list:
                body.append("<ul>")
                in_list = True
            item = _inline_to_html(stripped[2:])
            if item:
                body.append(f"<li>{item}</li>")
            continue
        close_list()
        paragraph = _inline_to_html(stripped)
        if paragraph:
            body.append(f"<p>{paragraph}</p>")

    close_list()
    if not body:
        body.append(f"<p>Starcat {html.escape(version)}</p>")

    more = html.escape(more_url, quote=True)
    more_text = html.escape(more_label)
    body.append(
        f'<p class="more"><a href="{more}" target="_blank" rel="noopener">{more_text}</a></p>'
    )

    # Sparkle 更新窗里的 WebView 边距很紧、底部易裁切最后一行；
    # 因此内边距尤其是 padding-bottom 要留足，行距也不能按网页密度来。
    # 背景透明以沿用 Sparkle 窗口表面；必须同时声明明暗支持并切换整套前景色，
    # 否则暗色窗口仍会显示浅色主题的深色正文，链接、代码底色和分隔线也需一起适配。
    return (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        "<meta name=\"color-scheme\" content=\"light dark\">"
        "<style>"
        ":root{"
        "color-scheme:light dark;"
        "--text-primary:#1d1d1f;--text-body:#3a3a3c;--link:#0066cc;"
        "--code-background:rgba(0,0,0,0.04);--separator:rgba(0,0,0,0.08);"
        "}"
        "@media (prefers-color-scheme:dark){:root{"
        "--text-primary:#f5f5f7;--text-body:#dedee3;--link:#64b5ff;"
        "--code-background:rgba(255,255,255,0.08);"
        "--separator:rgba(255,255,255,0.16);"
        "}}"
        "html,body{margin:0;padding:0;background:transparent;}"
        "body{"
        "font:12.5px/1.55 -apple-system,BlinkMacSystemFont,'PingFang SC',"
        "'Helvetica Neue',sans-serif;"
        "color:var(--text-primary);"
        "padding:10px 14px 22px;"
        "-webkit-font-smoothing:antialiased;"
        "}"
        "h3{"
        "font-size:12px;font-weight:600;letter-spacing:0.01em;"
        "margin:14px 0 6px;color:var(--text-primary);"
        "}"
        "h3:first-child{margin-top:0;}"
        "p{margin:0 0 10px;color:var(--text-body);}"
        "p:last-child{margin-bottom:0;}"
        "ul{"
        "margin:0 0 4px;padding:0 0 0 1.15em;"
        "list-style:disc;"
        "}"
        "li{"
        "margin:0 0 8px;padding:0;"
        "color:var(--text-body);"
        "}"
        "li:last-child{margin-bottom:0;}"
        "a{color:var(--link);text-decoration:none;}"
        "a:hover{text-decoration:underline;}"
        "code{"
        "font-family:ui-monospace,Menlo,monospace;font-size:11.5px;"
        "background:var(--code-background);padding:1px 4px;border-radius:3px;"
        "}"
        ".more{"
        "margin:14px 0 0;padding-top:10px;"
        "border-top:1px solid var(--separator);"
        "font-size:12px;"
        "}"
        "</style></head><body>"
        f"{''.join(body)}"
        "</body></html>"
    )


def load_optional_markdown(path: Path | None) -> str | None:
    if path is None:
        return None
    if not path.is_file():
        raise FileNotFoundError(f"找不到 CHANGELOG: {path}")
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        raise ValueError(f"CHANGELOG 为空: {path}")
    return text


def short_version(item: ET.Element) -> str | None:
    value = item.findtext(SPARKLE_SHORT_VERSION)
    if value:
        return value.strip()
    return None


def remove_descriptions(item: ET.Element) -> None:
    for child in list(item):
        if child.tag == "description" or child.tag.startswith(f"{{{STARCAT_NS}}}releaseNotes-"):
            item.remove(child)


def insert_descriptions(
    item: ET.Element,
    notes: list[tuple[str | None, str]],
) -> None:
    """插入 description 节点（正文稍后由 write_appcast_xml 包进 CDATA）。"""

    # 插在 enclosure 前，保持「元数据 → 说明 → 下载」阅读顺序。
    enclosure_index = next(
        (index for index, child in enumerate(list(item)) if child.tag == "enclosure"),
        len(list(item)),
    )
    for offset, (lang, html_body) in enumerate(notes):
        element = ET.Element("description")
        if lang:
            element.set("xml:lang", lang)
        element.text = html_body
        item.insert(enclosure_index + offset, element)

    # Sparkle 的 XML 解析器只留下进程首选语言的 description。以不同字段保留
    # 每种正文，让客户端无需改系统语言，也不必另发请求就能跟随应用设置。
    for offset, (lang, html_body) in enumerate(notes, start=len(notes)):
        element = ET.Element(f"{{{STARCAT_NS}}}releaseNotes-{lang}")
        element.text = html_body
        item.insert(enclosure_index + offset, element)


def build_notes_for_version(
    version: str,
    changelog_en: str,
    more_url_en: str,
    changelog_zh: str,
    more_url_zh: str,
) -> list[tuple[str | None, str]]:
    """两种语言均可用才替换说明；完全不在快照中的历史条目保留原样。"""

    section_en = extract_version_section(changelog_en, version)
    section_zh = extract_version_section(changelog_zh, version)
    if not section_en and not section_zh:
        return []
    if not section_en or not section_zh:
        raise ValueError(f"{version} 中英文 CHANGELOG 必须同时包含非空版本正文")
    return [
        (
            "en",
            section_to_sparkle_html(
                section_en,
                version=version,
                more_url=more_url_en,
                more_label="View full changelog",
            ),
        ),
        (
            "zh-Hans",
            section_to_sparkle_html(
                section_zh,
                version=version,
                more_url=more_url_zh,
                more_label="查看完整更新记录",
            ),
        ),
    ]


def inject(
    appcast_path: Path,
    *,
    changelog_en: str,
    changelog_zh: str,
    version: str | None,
    more_url_en: str,
    more_url_zh: str,
    dry_run: bool,
) -> list[str]:
    if not appcast_path.is_file():
        raise FileNotFoundError(f"找不到 appcast: {appcast_path}")

    root = ET.parse(appcast_path).getroot()
    channel = root.find("channel")
    if channel is None:
        raise ValueError(f"{appcast_path} 缺少 channel")

    items = channel.findall("item")
    if not items:
        raise ValueError(f"{appcast_path} 没有任何 item")

    target_versions = {version} if version else None
    updated: list[str] = []

    for item in items:
        item_version = short_version(item)
        if not item_version:
            continue
        if target_versions is not None and item_version not in target_versions:
            continue
        notes = build_notes_for_version(
            item_version,
            changelog_en,
            more_url_en,
            changelog_zh,
            more_url_zh,
        )
        if not notes:
            print(f"skip {item_version}: 双语 CHANGELOG 中没有对应版本节，保留原说明", file=sys.stderr)
            continue
        remove_descriptions(item)
        insert_descriptions(item, notes)
        updated.append(item_version)

    if version and version not in updated:
        raise SystemExit(f"未注入 {version}：appcast 无该版本或 CHANGELOG 缺对应节")

    if dry_run:
        print("dry-run versions:", ", ".join(updated) if updated else "(none)")
        return updated

    write_appcast_xml(appcast_path, root)
    print(f"injected release notes for: {', '.join(updated)}")
    return updated


def resolve_default_changelog(explicit: Path | None, candidates: list[Path]) -> Path | None:
    if explicit is not None:
        return explicit
    for path in candidates:
        if path.is_file():
            return path
    return None


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    supports = project_root / "supports"

    changelog_en_path = resolve_default_changelog(
        args.changelog_en,
        [
            # Direct 渠道 changelog 自 2026-11 起随 starcat-site 同仓维护（Starcat#202）；
            # 主仓库根目录只剩指针文件，不能作为 appcast 更新说明来源。
            supports / "starcat-site" / "direct" / "CHANGELOG.md",
        ],
    )
    if changelog_en_path is None:
        raise SystemExit("未找到英文 CHANGELOG.md，无法生成 Sparkle 更新说明")

    changelog_en = load_optional_markdown(changelog_en_path)
    if changelog_en is None:
        raise SystemExit(f"英文 CHANGELOG 为空: {changelog_en_path}")
    changelog_zh_path = args.changelog_zh or changelog_en_path.with_name("CHANGELOG-ZH.md")
    changelog_zh = load_optional_markdown(changelog_zh_path) if changelog_zh_path.is_file() else None
    if changelog_zh is None:
        raise SystemExit(f"中文 CHANGELOG 缺失或为空: {changelog_zh_path}")
    print(f"changelog-en: {changelog_en_path}")
    print(f"changelog-zh: {changelog_zh_path}")

    inject(
        args.appcast,
        changelog_en=changelog_en,
        changelog_zh=changelog_zh,
        version=args.version,
        more_url_en=args.more_url_en,
        more_url_zh=args.more_url_zh,
        dry_run=args.dry_run,
    )


if __name__ == "__main__":
    main()
