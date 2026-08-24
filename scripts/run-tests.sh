#!/usr/bin/env bash
#
# run-tests.sh — 使用隔离 DerivedData 执行 Starcat 命令行单元测试。
#
# Xcode IDE、App Store Debug、Direct Debug 和命令行测试不能共享编译缓存。
# 每次测试创建独立临时目录并在退出时清理，避免不同 scheme 或 Xcode 版本留下的
# PCM / dependency graph 污染下一次构建。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/debug-build-environment.sh"

starcat_select_stable_xcode

# testmanagerd 不能同时稳定服务 Xcode IDE 与命令行 test。这里失败得足够早，
# 避免用户等完整编译后才遇到测试 host 无法建立连接。
if pgrep -x Xcode >/dev/null 2>&1; then
  echo "ERROR: 检测到 Xcode IDE 正在运行。"
  echo "       请先 Cmd+Q 退出 Xcode，再执行 make test。"
  exit 1
fi

TEST_DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/starcat-tests-derived-data.XXXXXX")"
trap 'rm -rf "$TEST_DERIVED_DATA"' EXIT

cd "$PROJECT_ROOT"

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 使用隔离缓存执行 Starcat 全量单测..."
echo "    derived data: $TEST_DERIVED_DATA"
xcodebuild \
  -scheme Starcat \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  test

