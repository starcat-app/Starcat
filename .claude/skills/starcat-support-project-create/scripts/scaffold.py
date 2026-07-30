#!/usr/bin/env python3
"""生成 Starcat 支撑项目的通用开源治理基线。

脚本只负责确定性的通用文件，不猜测技术栈 CI、部署或发布配置。为避免破坏已存在的
项目，任一目标文件存在时会在写入前整体失败；调用方应人工合并，而不是强制覆盖。
"""

from __future__ import annotations

import argparse
import re
from datetime import datetime, timezone
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_ROOT = SKILL_ROOT / "assets" / "open-source-baseline"
NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
UNRESOLVED_PATTERN = re.compile(r"\{\{[A-Z0-9_]+\}\}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成 Starcat 支撑项目开源基线")
    parser.add_argument("--target", required=True, type=Path, help="目标项目目录")
    parser.add_argument("--name", required=True, help="仓库名，例如 starcat-raycast-extension")
    parser.add_argument("--title-en", required=True, help="英文标题")
    parser.add_argument("--title-zh", required=True, help="中文标题")
    parser.add_argument("--summary-en", required=True, help="英文一句话摘要")
    parser.add_argument("--summary-zh", required=True, help="中文一句话摘要")
    parser.add_argument(
        "--repo-url",
        help="GitHub 仓库 URL；默认 https://github.com/starcat-app/<name>",
    )
    parser.add_argument(
        "--year",
        # macOS/Xcode 仍可能提供 Python 3.9；timezone.utc 比 Python 3.11
        # 才引入的 datetime.UTC 覆盖面更广。
        default=str(datetime.now(timezone.utc).year),
        help="LICENSE 版权年份，默认当前年份",
    )
    parser.add_argument("--dry-run", action="store_true", help="只打印将生成的文件")
    return parser.parse_args()


def template_files() -> list[Path]:
    return sorted(path for path in TEMPLATE_ROOT.rglob("*.tmpl") if path.is_file())


def output_path(target: Path, template: Path) -> Path:
    relative = template.relative_to(TEMPLATE_ROOT)
    return target / relative.with_suffix("")


def render(template: Path, replacements: dict[str, str]) -> str:
    text = template.read_text(encoding="utf-8")
    for key, value in replacements.items():
        text = text.replace("{{" + key + "}}", value)
    unresolved = sorted(set(UNRESOLVED_PATTERN.findall(text)))
    if unresolved:
        raise ValueError(f"{template} 仍有未替换占位符: {', '.join(unresolved)}")
    return text


def validate_args(args: argparse.Namespace) -> None:
    if not NAME_PATTERN.fullmatch(args.name):
        raise ValueError("--name 只能包含小写字母、数字和连字符")
    if args.target.name != args.name:
        raise ValueError("--target 最后一段必须与 --name 一致，避免写错项目目录")
    for field in ("title_en", "title_zh", "summary_en", "summary_zh", "year"):
        if not str(getattr(args, field)).strip():
            raise ValueError(f"--{field.replace('_', '-')} 不能为空")


def main() -> int:
    args = parse_args()
    validate_args(args)
    templates = template_files()
    if not templates:
        raise FileNotFoundError(f"没有找到模板: {TEMPLATE_ROOT}")

    repo_url = args.repo_url or f"https://github.com/starcat-app/{args.name}"
    replacements = {
        "PROJECT_NAME": args.name,
        "TITLE_EN": args.title_en.strip(),
        "TITLE_ZH": args.title_zh.strip(),
        "SUMMARY_EN": args.summary_en.strip(),
        "SUMMARY_ZH": args.summary_zh.strip(),
        "REPO_URL": repo_url.rstrip("/"),
        "YEAR": args.year.strip(),
    }

    outputs = [(template, output_path(args.target, template)) for template in templates]
    conflicts = [destination for _, destination in outputs if destination.exists()]
    if conflicts:
        formatted = "\n".join(f"  - {path}" for path in conflicts)
        raise FileExistsError(f"拒绝覆盖已有文件:\n{formatted}")

    for template, destination in outputs:
        content = render(template, replacements)
        print(f"{'[dry-run] ' if args.dry_run else ''}{destination}")
        if args.dry_run:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")

    print(f"完成: {len(outputs)} 个开源基线文件")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
