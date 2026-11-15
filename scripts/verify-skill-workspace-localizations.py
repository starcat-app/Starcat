#!/usr/bin/env python3
"""只读核对 Skill 工作台全语言文案与双渠道编译资源，不改写 Catalog 或审核状态。"""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
FORMAT_ARGUMENT = re.compile(r"%(?:\d+\$)?(@|(?:hh|ll|[hlLqztj])?[diuoxXfFeEgGaAcCsSp])")


def load_json(location):
    """Catalog 和独立仓库语言表均直接读取，避免构造第二份人工语言集合。"""
    return json.loads(location.read_text(encoding="utf-8"))


def format_arguments(value):
    """忽略转义百分号并比较参数类型；不同语言允许调整带序号参数的顺序。"""
    return Counter(FORMAT_ARGUMENT.findall(value.replace("%%", "")))


def verify(locale_manifest, check_compiled):
    """语言集合来自 AppLocale 与独立语言表；翻译初稿和人工审核状态分别报告。"""
    locales = {item["id"] for item in load_json(locale_manifest)["locales"]}
    locale_source = (ROOT / "Starcat/Core/Settings/LocaleStore.swift").read_text(encoding="utf-8")
    enum_body = locale_source.split("enum AppLocale:", 1)[1].split("var id:", 1)[0]
    app_locales = set(re.findall(r'case \w+ = "([^"]+)"', enum_body))
    if locales != app_locales:
        raise ValueError("AppLocale 与 locales.json 的语言集合不一致")
    catalog = load_json(ROOT / "Starcat/Resources/Localizable.xcstrings")
    entries = {key: item for key, item in catalog["strings"].items() if key.startswith("skills.")}
    if not entries:
        raise ValueError("没有找到 Skill 工作台文案")
    states = Counter()
    for key, entry in entries.items():
        translations = entry.get("localizations", {})
        if set(translations) != locales:
            raise ValueError(f"{key}: 语言覆盖不一致")
        original_arguments = format_arguments(translations["en"]["stringUnit"]["value"])
        for locale, translation in translations.items():
            unit = translation["stringUnit"]
            if not unit["value"].strip():
                raise ValueError(f"{key}/{locale}: 文案为空")
            if format_arguments(unit["value"]) != original_arguments:
                raise ValueError(f"{key}/{locale}: 格式参数不一致")
            states[unit["state"]] += 1
    print(f"Catalog: {len(entries)} key × {len(locales)} 语言；审核状态 {dict(states)}")
    if not check_compiled:
        return
    # 比较实际 bundle，单纯检查 Catalog 不代表构建已包含对应本地化资源。
    for cache in ("DerivedData-NoSandbox", "DerivedData-Sandbox"):
        resources = ROOT / "build" / cache / "Build/Products/Debug/Starcat.app/Contents/Resources"
        for locale in sorted(locales):
            strings = resources / f"{locale}.lproj/Localizable.strings"
            compiled = json.loads(subprocess.check_output(
                ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(strings)], text=True
            ))
            for key, entry in entries.items():
                if compiled.get(key) != entry["localizations"][locale]["stringUnit"]["value"]:
                    raise ValueError(f"{cache}/{key}/{locale}: 编译资源与 Catalog 不一致")
        print(f"{cache}: {len(entries)} key × {len(locales)} 语言编译资源一致")


def main():
    """worktree 未拉取独立本地化仓库时，允许显式指定现有语言表，不隐式访问其他工作区。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--locales", type=Path, default=ROOT / "supports/starcat-localization/locales.json",
        help="独立本地化仓库的 locales.json 路径",
    )
    parser.add_argument("--check-compiled", action="store_true", help="同时检查已构建的两个 Debug bundle")
    arguments = parser.parse_args()
    if not arguments.locales.is_file():
        parser.error("语言表不存在；请用 --locales 显式指定 locales.json")
    try:
        verify(arguments.locales, arguments.check_compiled)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Skill 文案校验失败：{error}\n")


if __name__ == "__main__":
    main()
