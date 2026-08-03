#!/usr/bin/env python3
"""Merge one freshly generated Sparkle appcast item into the persistent appcast.

Release builds only need the current DMG locally. Older DMGs may already live on
the web server, so the persistent `supports/starcat-site/direct/appcast.xml` is treated as the source of
historical update metadata. This script replaces the same version item when
re-publishing and otherwise inserts the new item while keeping older items.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# 允许直接 `python3 scripts/merge-appcast.py` 找到同目录工具模块。
sys.path.insert(0, str(Path(__file__).resolve().parent))

from appcast_xml_util import SPARKLE_NS, write_appcast_xml

SPARKLE_SHORT_VERSION = f"{{{SPARKLE_NS}}}shortVersionString"
ET.register_namespace("sparkle", SPARKLE_NS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge current Sparkle appcast into persistent appcast.")
    parser.add_argument("--base", required=True, type=Path, help="Persistent appcast.xml path.")
    parser.add_argument("--incoming", required=True, type=Path, help="Current-version appcast.xml path.")
    parser.add_argument("--output", required=True, type=Path, help="Output appcast.xml path.")
    return parser.parse_args()


def version_key(version: str) -> tuple[int, ...]:
    """Sort semantic versions numerically, newest first."""

    parts = [int(part) for part in re.findall(r"\d+", version)]
    return tuple(parts or [0])


def short_version(item: ET.Element) -> str:
    value = item.findtext(SPARKLE_SHORT_VERSION)
    if not value:
        raise ValueError("appcast item 缺少 sparkle:shortVersionString")
    return value


def load_channel(path: Path) -> ET.Element:
    if path.exists() and path.stat().st_size > 0:
        root = ET.parse(path).getroot()
        channel = root.find("channel")
        if channel is None:
            raise ValueError(f"{path} 缺少 channel 节点")
        return channel

    root = ET.Element("rss", {"version": "2.0"})
    root.set(f"xmlns:sparkle", SPARKLE_NS)
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Starcat"
    return channel


def load_incoming_item(path: Path) -> ET.Element:
    root = ET.parse(path).getroot()
    channel = root.find("channel")
    if channel is None:
        raise ValueError(f"{path} 缺少 channel 节点")
    items = channel.findall("item")
    if len(items) != 1:
        raise ValueError(f"{path} 应只包含当前版本的 1 个 item，实际: {len(items)}")
    return items[0]


def build_root_with_items(base_channel: ET.Element, items: list[ET.Element]) -> ET.Element:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")

    has_title = False
    for child in list(base_channel):
        if child.tag == "item":
            continue
        if child.tag == "title":
            has_title = True
        channel.append(child)

    if not has_title:
        ET.SubElement(channel, "title").text = "Starcat"

    for item in items:
        channel.append(item)
    return root


def main() -> None:
    args = parse_args()

    base_channel = load_channel(args.base)
    incoming_item = load_incoming_item(args.incoming)
    incoming_version = short_version(incoming_item)

    items_by_version: dict[str, ET.Element] = {}
    for item in base_channel.findall("item"):
        items_by_version[short_version(item)] = item
    items_by_version[incoming_version] = incoming_item

    merged_items = sorted(
        items_by_version.values(),
        key=lambda item: version_key(short_version(item)),
        reverse=True,
    )
    root = build_root_with_items(base_channel, merged_items)
    # description 含 HTML；必须走 CDATA 写出，否则下次合并会把 < 转义掉。
    write_appcast_xml(args.output, root)
    print(f"Merged {incoming_version} into {args.output}")


if __name__ == "__main__":
    main()
