#!/usr/bin/env python3
"""Sparkle appcast XML 读写辅助：把 <description> 序列化为 CDATA。

ElementTree 解析 CDATA 后只保留文本；再 `tostring` 会把 `<` 转义成 `&lt;`，
Sparkle 更新窗就无法当 HTML 渲染。发版合并 / 注入更新说明时必须走这里。
"""

from __future__ import annotations

import html
import re
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
_PLACEHOLDER_PREFIX = "__STARCAT_APPCAST_DESC__"

ET.register_namespace("sparkle", SPARKLE_NS)


def write_appcast_xml(path: Path, root: ET.Element) -> None:
    """写出 appcast，并将所有 description 正文包进 CDATA。"""

    cdata_map: dict[str, str] = {}
    for index, description in enumerate(root.iter("description")):
        text = description.text
        if text is None:
            continue
        placeholder = f"{_PLACEHOLDER_PREFIX}{index}__"
        if placeholder in text:
            raise RuntimeError("description 正文意外包含内部占位符")
        cdata_map[placeholder] = text
        description.text = placeholder

    tree = ET.ElementTree(root)
    ET.indent(tree, space="    ")
    xml_body = ET.tostring(tree.getroot(), encoding="unicode")

    for placeholder, text in cdata_map.items():
        safe = text.replace("]]>", "]]]]><![CDATA[>")
        escaped_placeholder = html.escape(placeholder)
        replaced = False
        for token in (placeholder, escaped_placeholder):
            pattern = re.compile(
                rf"(<description\b[^>]*>){re.escape(token)}(</description>)"
            )
            xml_body, count = pattern.subn(rf"\1<![CDATA[{safe}]]>\2", xml_body)
            if count:
                replaced = True
        if not replaced:
            raise RuntimeError(f"未能把 description 占位符写成 CDATA: {placeholder}")

    if _PLACEHOLDER_PREFIX in xml_body:
        raise RuntimeError("仍有未替换的 description 占位符")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f'<?xml version="1.0" standalone="yes"?>\n{xml_body}\n',
        encoding="utf-8",
    )
