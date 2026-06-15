#!/usr/bin/env bash
#
# run-debug.sh — 本地 Debug 构建并启动 Starcat。
#
# 设计要点：
# - 脚本位于 scripts/ 目录，但所有构建产物仍写到项目根的 build/DerivedData；
# - 先根据脚本自身位置定位项目根，再 cd 过去执行 xcodegen / xcodebuild，避免调用者
#   从其它目录手动执行时把 build/ 写到错误位置。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

xcodegen generate

xcodebuild \
  -scheme Starcat \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath build/DerivedData \
  build

open "$PROJECT_ROOT/build/DerivedData/Build/Products/Debug/Starcat.app"
