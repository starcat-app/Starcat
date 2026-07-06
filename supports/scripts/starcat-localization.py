#!/usr/bin/env python3
"""导出和导入 Starcat 本地化语言包。

这个脚本用于在两个结构之间同步本地化内容：
  - Starcat 应用内仍以 `Starcat/Resources/Localizable.xcstrings` 作为运行时来源。
  - 公开的 `supports/starcat-localization` 仓库按语言维护 `.xcloc` 包。

默认路径：
  - 应用 String Catalog：`Starcat/Resources/Localizable.xcstrings`
  - 公开本地化仓库：`supports/starcat-localization`
  - 语言包输出目录：`supports/starcat-localization/Translation Packages/`

常用命令：
  从应用的 String Catalog 导出所有语言包：

      supports/scripts/starcat-localization.py export

  只导出指定语言：

      supports/scripts/starcat-localization.py export --locale en --locale zh-Hans

  将单个已审核语言包倒回应用的 String Catalog：

      supports/scripts/starcat-localization.py import \\
        --package "supports/starcat-localization/Translation Packages/zh-Hans.xcloc"

  将公开本地化仓库里的全部语言包倒回应用：

      supports/scripts/starcat-localization.py import-all

  测试或跨 checkout 操作时，可以指定自定义路径：

      supports/scripts/starcat-localization.py \\
        --catalog /tmp/Localizable.xcstrings \\
        --repo /tmp/starcat-localization \\
        export

仓库规则：
  公开本地化仓库只维护“每种语言一个 `.xcloc` 包”。不要把完整的
  `Localizable.xcstrings` 提交到公开本地化仓库。
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


PROJECT_NAME = "Starcat"
CATALOG_RELATIVE_PATH = Path("Starcat/Resources/Localizable.xcstrings")
PACKAGE_DIR_NAME = "Translation Packages"
XLIFF_NAMESPACE = "urn:oasis:names:tc:xliff:document:1.2"


def repo_root() -> Path:
    """Return the Starcat repository root based on this script location."""
    return Path(__file__).resolve().parents[2]


def default_catalog_path() -> Path:
    return repo_root() / CATALOG_RELATIVE_PATH


def default_localization_repo() -> Path:
    return repo_root() / "supports" / "starcat-localization"


def load_catalog(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_catalog(path: Path, catalog: dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def display_path(path: Path) -> str:
    """Prefer repo-relative paths, but keep external test paths printable."""
    try:
        return str(path.relative_to(repo_root()))
    except ValueError:
        return str(path)


def string_unit(localization: dict[str, Any] | None) -> dict[str, Any] | None:
    if not localization:
        return None
    unit = localization.get("stringUnit")
    return unit if isinstance(unit, dict) else None


def localized_value(entry: dict[str, Any], locale: str) -> str | None:
    localizations = entry.get("localizations", {})
    unit = string_unit(localizations.get(locale))
    if not unit:
        return None
    value = unit.get("value")
    return value if isinstance(value, str) else None


def localized_state(entry: dict[str, Any], locale: str) -> str:
    localizations = entry.get("localizations", {})
    unit = string_unit(localizations.get(locale))
    if unit and isinstance(unit.get("state"), str):
        return unit["state"]
    return "needs-translation"


def all_locales(catalog: dict[str, Any]) -> list[str]:
    locales = {catalog.get("sourceLanguage", "en")}
    for entry in catalog.get("strings", {}).values():
        locales.update(entry.get("localizations", {}).keys())
    return sorted(locale for locale in locales if locale)


def write_contents_json(package_path: Path, source_language: str, locale: str) -> None:
    contents = {
        "developmentRegion": source_language,
        "project": f"{PROJECT_NAME}.xcodeproj",
        "targetLocale": locale,
        "toolInfo": {
            "toolID": "com.starcat.localization-script",
            "toolName": "starcat-localization.py",
            "toolVersion": "1.0",
        },
        "version": "1.0",
    }
    with (package_path / "contents.json").open("w", encoding="utf-8") as handle:
        json.dump(contents, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def build_xliff(catalog: dict[str, Any], locale: str) -> ET.ElementTree:
    source_language = catalog.get("sourceLanguage", "en")
    ET.register_namespace("", XLIFF_NAMESPACE)

    root = ET.Element(f"{{{XLIFF_NAMESPACE}}}xliff", {"version": "1.2"})
    file_node = ET.SubElement(
        root,
        f"{{{XLIFF_NAMESPACE}}}file",
        {
            "original": str(CATALOG_RELATIVE_PATH),
            "source-language": source_language,
            "target-language": locale,
            "datatype": "plaintext",
        },
    )
    body = ET.SubElement(file_node, f"{{{XLIFF_NAMESPACE}}}body")

    for key in sorted(catalog.get("strings", {}).keys()):
        entry = catalog["strings"][key]
        source_text = localized_value(entry, source_language) or key
        target_text = localized_value(entry, locale) or ""
        state = localized_state(entry, locale)

        unit = ET.SubElement(body, f"{{{XLIFF_NAMESPACE}}}trans-unit", {"id": key})
        ET.SubElement(unit, f"{{{XLIFF_NAMESPACE}}}source").text = source_text
        target = ET.SubElement(unit, f"{{{XLIFF_NAMESPACE}}}target", {"state": state})
        target.text = target_text

        comment = entry.get("comment")
        if isinstance(comment, str) and comment:
            ET.SubElement(unit, f"{{{XLIFF_NAMESPACE}}}note").text = comment

    ET.indent(root, space="  ")
    return ET.ElementTree(root)


def export_packages(args: argparse.Namespace) -> int:
    catalog_path = Path(args.catalog).resolve()
    localization_repo = Path(args.repo).resolve()
    package_root = localization_repo / PACKAGE_DIR_NAME
    catalog = load_catalog(catalog_path)
    source_language = catalog.get("sourceLanguage", "en")
    locales = args.locale or all_locales(catalog)

    if package_root.exists():
        shutil.rmtree(package_root)
    package_root.mkdir(parents=True, exist_ok=True)

    for locale in locales:
        package_path = package_root / f"{locale}.xcloc"
        localized_contents = package_path / "Localized Contents"
        source_contents = package_path / "Source Contents" / PROJECT_NAME / "Localizable"
        localized_contents.mkdir(parents=True, exist_ok=True)
        source_contents.mkdir(parents=True, exist_ok=True)

        shutil.copy2(catalog_path, source_contents / "Localizable.xcstrings")
        build_xliff(catalog, locale).write(
            localized_contents / f"{locale}.xliff",
            encoding="utf-8",
            xml_declaration=True,
        )
        write_contents_json(package_path, source_language, locale)
        print(f"exported {display_path(package_path)}")

    return 0


def read_package_locale(package_path: Path) -> str:
    contents_path = package_path / "contents.json"
    if contents_path.exists():
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
        locale = contents.get("targetLocale")
        if isinstance(locale, str) and locale:
            return locale
    return package_path.name.removesuffix(".xcloc")


def read_xliff_targets(package_path: Path, locale: str) -> dict[str, str]:
    xliff_path = package_path / "Localized Contents" / f"{locale}.xliff"
    if not xliff_path.exists():
        raise FileNotFoundError(f"missing XLIFF file: {xliff_path}")

    tree = ET.parse(xliff_path)
    namespace = {"x": XLIFF_NAMESPACE}
    updates: dict[str, str] = {}
    for unit in tree.findall(".//x:trans-unit", namespace):
        key = unit.attrib.get("id")
        target = unit.find("x:target", namespace)
        if not key or target is None or target.text is None:
            continue
        updates[key] = target.text
    return updates


def import_packages(args: argparse.Namespace) -> int:
    catalog_path = Path(args.catalog).resolve()
    catalog = load_catalog(catalog_path)
    package_paths = [Path(path).resolve() for path in args.package]

    changed = 0
    for package_path in package_paths:
        locale = read_package_locale(package_path)
        updates = read_xliff_targets(package_path, locale)
        for key, value in updates.items():
            if key not in catalog.get("strings", {}):
                print(f"skip unknown key: {key}", file=sys.stderr)
                continue
            entry = catalog["strings"][key]
            localizations = entry.setdefault("localizations", {})
            localization = localizations.setdefault(locale, {})
            unit = localization.setdefault("stringUnit", {})
            if unit.get("value") == value and unit.get("state") == "translated":
                continue
            unit["state"] = "translated"
            unit["value"] = value
            changed += 1
        print(f"imported {len(updates)} strings from {package_path}")

    if changed:
        save_catalog(catalog_path, catalog)
    print(f"updated {changed} localization values in {display_path(catalog_path)}")
    return 0


def list_packages(repo: Path) -> list[Path]:
    package_root = repo / PACKAGE_DIR_NAME
    return sorted(package_root.glob("*.xcloc"))


def import_all_packages(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    packages = list_packages(repo)
    if not packages:
        raise FileNotFoundError(f"no .xcloc packages found under {repo / PACKAGE_DIR_NAME}")
    args.package = [str(path) for path in packages]
    return import_packages(args)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Export/import Starcat localization .xcloc packages.",
    )
    parser.add_argument(
        "--catalog",
        default=str(default_catalog_path()),
        help="Path to Starcat/Resources/Localizable.xcstrings.",
    )
    parser.add_argument(
        "--repo",
        default=str(default_localization_repo()),
        help="Path to supports/starcat-localization.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export", help="Export per-language .xcloc packages.")
    export_parser.add_argument(
        "--locale",
        action="append",
        help="Locale to export. Repeat for multiple locales. Defaults to all locales in the catalog.",
    )
    export_parser.set_defaults(func=export_packages)

    import_parser = subparsers.add_parser("import", help="Import one or more .xcloc packages.")
    import_parser.add_argument("--package", action="append", required=True, help="Path to a .xcloc package.")
    import_parser.set_defaults(func=import_packages)

    import_all_parser = subparsers.add_parser("import-all", help="Import all packages from the localization repo.")
    import_all_parser.set_defaults(func=import_all_packages)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
