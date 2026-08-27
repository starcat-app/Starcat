#!/usr/bin/env bash
#
# run-tests.sh — 使用固定的测试 DerivedData 执行 Starcat 命令行单元测试。
#
# 为什么不用 mktemp：每次临时目录都会冷编译十几分钟，Agent 会话里一插话就被掐掉。
# 测试缓存必须和 App Store / Direct Debug 分开，所以固定写 build/DerivedData-Tests，
# 用与 Debug 相同的 Xcode/SDK 指纹：工具链变了再清，日常复用增量缓存。
#
# 额外参数原样传给 xcodebuild，例如：
#   ./scripts/run-tests.sh -only-testing:StarcatTests/TagRepositoryTests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/debug-build-environment.sh"

TEST_DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-Tests"

starcat_select_stable_xcode

# testmanagerd 不能同时稳定服务 Xcode IDE 与命令行 test。这里失败得足够早，
# 避免用户等完整编译后才遇到测试 host 无法建立连接。
if pgrep -x Xcode >/dev/null 2>&1; then
  echo "ERROR: 检测到 Xcode IDE 正在运行。"
  echo "       请先 Cmd+Q 退出 Xcode，再执行 make test。"
  exit 1
fi

starcat_prepare_debug_derived_data "$PROJECT_ROOT" "$TEST_DERIVED_DATA" "cli-tests"

cd "$PROJECT_ROOT"

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 使用测试专用缓存执行 Starcat 单测..."
echo "    derived data: $TEST_DERIVED_DATA"
xcodebuild \
  -scheme Starcat \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  test \
  "$@"
