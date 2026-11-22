#!/usr/bin/env python3
"""为标签选择器索引 App 资产目录，保持资源名与当前构建同步。"""

import argparse
import json
from pathlib import Path


ICON_GROUPS = (
    ("BusinessIcons", "lucide"),
    ("Devicons", "devicon"),
    ("SkillAgents", "skillAgent"),
    ("AIProviders", "aiProvider"),
)


def catalog_entries(asset_catalog: Path) -> list[dict]:
    """使用 imageset 名作为稳定资源名，展示名称可随源素材调整。"""
    entries = []
    for folder, source in ICON_GROUPS:
        image_sets = sorted((asset_catalog / folder).glob("*.imageset"))
        if not image_sets:
            raise ValueError(f"No imagesets found in {asset_catalog / folder}")
        for image_set in image_sets:
            metadata = json.loads((image_set / "Contents.json").read_text(encoding="utf-8"))
            asset_name = image_set.stem
            if source == "lucide":
                name = Path(next(image["filename"] for image in metadata["images"] if "filename" in image)).stem
            else:
                name = asset_name.removeprefix("SkillAgent-")
            entries.append({
                "assetName": asset_name,
                "name": name,
                "source": source,
                "isTemplateAsset": metadata.get("properties", {}).get("template-rendering-intent") == "template",
            })
    if len({entry["assetName"] for entry in entries}) != len(entries):
        raise ValueError("Tag icon asset names must be unique")
    return entries


def main() -> None:
    """验证并写入 App bundle 的索引资源。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset_catalog", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    entries = catalog_entries(args.asset_catalog)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(entries, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Indexed {len(entries)} tag icons")


if __name__ == "__main__":
    main()
