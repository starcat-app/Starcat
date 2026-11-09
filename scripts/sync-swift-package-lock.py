#!/usr/bin/env python3
"""把受版本控制的 SwiftPM 锁文件同步到 XcodeGen 生成目录。

生成工程仍不入 Git；Configs/SwiftPackages.resolved 是完整依赖组合的唯一锁定源。
restore 在生成工程后恢复它，check 则检查解析或构建是否偷偷改变了依赖版本。
升级时直接审阅并修改源锁文件，再通过标准构建入口验证，不从本机缓存自动反向覆盖。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE_LOCK = PROJECT_ROOT / "Configs/SwiftPackages.resolved"
GENERATED_LOCK = (
    PROJECT_ROOT
    / "Starcat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)


def read_pins(path: Path) -> list[dict]:
    """读取实际版本身份；Xcode 写回的格式号、originHash 与排序不代表版本变化。"""
    data = json.loads(path.read_text())
    pins = data["pins"]
    if not pins:
        raise ValueError(f"锁文件没有依赖：{path}")
    return sorted(pins, key=lambda pin: pin["identity"])


def synchronize(source: Path, generated: Path, *, check: bool) -> None:
    """先验证源文件，再恢复或检查；检查失败时保留现场，避免掩盖解析漂移。"""
    expected = read_pins(source)
    if check:
        if read_pins(generated) != expected:
            raise ValueError("SwiftPM 解析版本偏离 Configs/SwiftPackages.resolved")
    else:
        contents = source.read_bytes()
        generated.parent.mkdir(parents=True, exist_ok=True)
        if not generated.exists() or generated.read_bytes() != contents:
            generated.write_bytes(contents)


def main() -> int:
    """提供 XcodeGen 恢复入口和构建结束后的只读校验入口。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("restore", "check"))
    args = parser.parse_args()
    synchronize(SOURCE_LOCK, GENERATED_LOCK, check=args.action == "check")
    print(f"[swift-package-lock] {args.action}: {len(read_pins(SOURCE_LOCK))} pins")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"[swift-package-lock] {error}", file=sys.stderr)
        raise SystemExit(1)
