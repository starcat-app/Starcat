#!/usr/bin/env bash
#
# run-debug.sh — 本地 Debug 构建并启动 Starcat。
#
# 设计要点：
# - 脚本位于 scripts/ 目录，但所有构建产物仍写到项目根的 build/DerivedData；
# - 先根据脚本自身位置定位项目根，再 cd 过去执行 xcodegen / xcodebuild，避免调用者
#   从其它目录手动执行时把 build/ 写到错误位置；
# - 构建前先 kill 掉已在运行的 Starcat —— macOS `open` 命令对已运行的同 bundle id
#   应用默认行为是 activate 而非 relaunch，会出现「代码改了但启动的还是旧进程」
#   的诡异现象，对 Debug 迭代循环非常致命。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# 关闭已在运行的 Starcat。
# - `pkill -x Starcat` 精确匹配进程名，不会误伤包含 "Starcat" 字样的子进程
#   （比如 Xcode 里 "Starcat.app/Contents/MacOS/Starcat" 的执行名就是 "Starcat"）；
# - `|| true` —— pkill 在「没匹配到任何进程」时退出码为 1，配合 `set -e` 会让脚本中止，
#   但「Starcat 没在跑」就是正常情况，不应视为错误；
# - `2>/dev/null` 隐藏权限问题等噪声，关进程不是这个脚本的核心职责，失败也不阻塞构建。
echo "==> 关闭已运行的 Starcat（如有）..."
pkill -x Starcat 2>/dev/null || true

# 给 LaunchServices / Dock 短暂时间回收旧进程的 bundle 注册，
# 避免后续 `open` 撞上「正在退出但还没退出干净」的旧实例。
sleep 0.3

xcodegen generate

xcodebuild \
  -scheme Starcat \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath build/DerivedData \
  build

open "$PROJECT_ROOT/build/DerivedData/Build/Products/Debug/Starcat.app"
