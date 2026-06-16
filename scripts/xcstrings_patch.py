#!/usr/bin/env python3
"""
批量修改 String Catalog (`Localizable.xcstrings`) 的本地化 value。

用法:
    # 1. 单 key 改双语 (en + zh-Hans 同时改)
    python3 scripts/xcstrings_patch.py set \\
        --key "weekly.filter.allLanguages" \\
        --value "All Languages" \\
        --apply

    # 2. 单 key 仅改某一种 locale
    python3 scripts/xcstrings_patch.py set \\
        --key "weekly.filter.language" \\
        --value "Language" --locales en \\
        --apply

    # 3. 批量从 JSON 文件
    python3 scripts/xcstrings_patch.py set-batch \\
        --patches /tmp/patches.json \\
        --apply
    # patches.json 格式:
    # {
    #   "weekly.filter.allLanguages": "All Languages",
    #   "trending.language.uncategorized": "Uncategorized"
    # }

    # 4. 批量 inline JSON (适合小批量直接拼)
    python3 scripts/xcstrings_patch.py set-batch \\
        --patches-inline '{"k1":"v1","k2":"v2"}' \\
        --apply

    # 5. 查询当前 value (审计用, 模糊匹配 key)
    python3 scripts/xcstrings_patch.py show --pattern "uncategorized"

设计要点:
    - dry-run 默认开 -- 必须显式加 `--apply` 才真的写盘 (防误操作)
    - 找不到 key 时不静默跳过, 打印 `MISSING key X` 并退出码非 0
    - 写入 `state="translated"` (不是 `needs_review`)
    - JSON 格式 `indent=2 + ensure_ascii=False + 末尾换行`,
      与 Xcode 自身 save 时格式一致, 避免 git diff 噪音

依赖:
    - Python 3.9+
    - 仅 stdlib (argparse / json / sys / pathlib)

退出码:
    0 = 成功 (含 dry-run)
    1 = 输入参数错误
    2 = 任意 key 找不到 (set / set-batch)
    3 = JSON 解析失败 / 文件 IO 失败
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# ============================================================================
# 常量
# ============================================================================

DEFAULT_XCSTRINGS = Path("Starcat/Resources/Localizable.xcstrings")
DEFAULT_LOCALES = ("en", "zh-Hans")
TRANSLATED_STATE = "translated"


# ============================================================================
# I/O 辅助
# ============================================================================


def load_xcstrings(path: Path) -> dict[str, Any]:
    """读 xcstrings JSON, 失败 exit(3)."""
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        sys.exit(3)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(3)


def save_xcstrings(path: Path, data: dict[str, Any]) -> None:
    """写回 xcstrings JSON, 与 Xcode save 格式对齐 (indent=2 + 末尾换行)."""
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


# ============================================================================
# 核心 patch 逻辑
# ============================================================================


def apply_patch(
    data: dict[str, Any],
    key: str,
    value: str,
    locales: tuple[str, ...],
) -> str | None:
    """
    应用单条 patch 到 data (in-place).

    返回 None 表示成功, 否则返回错误说明字符串.
    """
    entry = data.get("strings", {}).get(key)
    if not entry:
        return f"MISSING key {key!r}"

    locs = entry.setdefault("localizations", {})
    for lang in locales:
        loc = locs.setdefault(lang, {})
        unit = loc.setdefault("stringUnit", {})
        unit["value"] = value
        unit["state"] = TRANSLATED_STATE
    return None


def format_diff_line(key: str, value: str, locales: tuple[str, ...], applied: bool) -> str:
    """格式化 dry-run / apply 时的单条变更行."""
    locs = "+".join(locales)
    prefix = "[APPLY]" if applied else "[DRY-RUN]"
    return f"  {prefix} {key} -> {value!r} ({locs})"


# ============================================================================
# 子命令: set
# ============================================================================


def cmd_set(args: argparse.Namespace) -> int:
    path = Path(args.xcstrings)
    data = load_xcstrings(path)

    locales = tuple(args.locales) if args.locales else DEFAULT_LOCALES

    err = apply_patch(data, args.key, args.value, locales)
    if err:
        print(err, file=sys.stderr)
        return 2

    print(format_diff_line(args.key, args.value, locales, applied=args.apply))

    if args.apply:
        save_xcstrings(path, data)
        print(f"  written: {path}")
    else:
        print("  (dry-run; pass --apply to write)")
    return 0


# ============================================================================
# 子命令: set-batch
# ============================================================================


def cmd_set_batch(args: argparse.Namespace) -> int:
    path = Path(args.xcstrings)

    if args.patches and args.patches_inline:
        print("ERROR: --patches and --patches-inline are mutually exclusive",
              file=sys.stderr)
        return 1
    if not args.patches and not args.patches_inline:
        print("ERROR: must provide --patches or --patches-inline", file=sys.stderr)
        return 1

    if args.patches:
        try:
            with Path(args.patches).open("r", encoding="utf-8") as f:
                patches = json.load(f)
        except FileNotFoundError:
            print(f"ERROR: patches file not found: {args.patches}", file=sys.stderr)
            return 3
        except json.JSONDecodeError as e:
            print(f"ERROR: invalid JSON in patches file: {e}", file=sys.stderr)
            return 3
    else:
        try:
            patches = json.loads(args.patches_inline)
        except json.JSONDecodeError as e:
            print(f"ERROR: invalid inline JSON: {e}", file=sys.stderr)
            return 3

    if not isinstance(patches, dict):
        print("ERROR: patches must be a JSON object {key: value}", file=sys.stderr)
        return 1

    locales = tuple(args.locales) if args.locales else DEFAULT_LOCALES
    data = load_xcstrings(path)

    missing: list[str] = []
    for key, value in patches.items():
        if not isinstance(value, str):
            print(f"ERROR: value for {key!r} must be string, got {type(value).__name__}",
                  file=sys.stderr)
            return 1
        err = apply_patch(data, key, value, locales)
        if err:
            missing.append(err)
        else:
            print(format_diff_line(key, value, locales, applied=args.apply))

    if missing:
        print("\n--- missing keys ---", file=sys.stderr)
        for m in missing:
            print(m, file=sys.stderr)
        return 2

    if args.apply:
        save_xcstrings(path, data)
        print(f"\n  written: {path}")
    else:
        print(f"\n  (dry-run; pass --apply to write {len(patches)} patches)")
    return 0


# ============================================================================
# 子命令: show
# ============================================================================


def cmd_show(args: argparse.Namespace) -> int:
    path = Path(args.xcstrings)
    data = load_xcstrings(path)
    pattern = args.pattern.lower() if args.pattern else None

    matched = 0
    for key in sorted(data.get("strings", {})):
        if pattern and pattern not in key.lower():
            continue
        matched += 1
        entry = data["strings"][key]
        locs = entry.get("localizations", {})
        print(f"  {key}")
        for lang in sorted(locs.keys()):
            unit = locs[lang].get("stringUnit", {})
            value = unit.get("value", "<NO_VALUE>")
            state = unit.get("state", "<NO_STATE>")
            print(f"    [{lang:8s}] ({state}) {value!r}")

    if matched == 0:
        print(f"  no key matched pattern {args.pattern!r}", file=sys.stderr)
        return 0  # show 找不到不算错, 只是空结果

    print(f"\n  total: {matched} key(s)")
    return 0


# ============================================================================
# CLI 入口
# ============================================================================


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="批量修改 String Catalog (Localizable.xcstrings) 的本地化 value",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--xcstrings",
        default=str(DEFAULT_XCSTRINGS),
        help=f"xcstrings 路径 (默认: {DEFAULT_XCSTRINGS})",
    )

    sub = parser.add_subparsers(dest="cmd", required=True)

    # set
    p_set = sub.add_parser("set", help="单 key 改 value")
    p_set.add_argument("--key", required=True, help="i18n key, 如 weekly.filter.allLanguages")
    p_set.add_argument("--value", required=True, help="新的本地化 value")
    p_set.add_argument(
        "--locales", nargs="+", metavar="LOCALE",
        help=f"指定 locale (默认 {' + '.join(DEFAULT_LOCALES)})",
    )
    p_set.add_argument("--apply", action="store_true", help="真的写盘 (默认 dry-run)")
    p_set.set_defaults(func=cmd_set)

    # set-batch
    p_batch = sub.add_parser("set-batch", help="批量改 value (从 JSON 文件或 inline JSON)")
    p_batch.add_argument("--patches", metavar="PATH", help="JSON 文件路径")
    p_batch.add_argument("--patches-inline", metavar="JSON", help='inline JSON 如 \'{"k":"v"}\'')
    p_batch.add_argument(
        "--locales", nargs="+", metavar="LOCALE",
        help=f"指定 locale (默认 {' + '.join(DEFAULT_LOCALES)})",
    )
    p_batch.add_argument("--apply", action="store_true", help="真的写盘 (默认 dry-run)")
    p_batch.set_defaults(func=cmd_set_batch)

    # show
    p_show = sub.add_parser("show", help="查询当前 value (key 模糊匹配)")
    p_show.add_argument("--pattern", help="key 子串匹配 (大小写不敏感, 不传则全量)")
    p_show.set_defaults(func=cmd_show)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
