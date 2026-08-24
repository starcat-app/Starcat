#!/usr/bin/env bash
#
# test-debug-build-environment.sh — 验证 Debug 构建缓存的所有权与失效边界。
#
# 测试使用临时目录和注入指纹，不依赖本机 Xcode，也不会触碰真实 DerivedData。
# 重点覆盖：首次接管、同环境增量复用、工具链变化清理，以及拒绝越界路径。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPOSITORY_ROOT/scripts/lib/debug-build-environment.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/starcat-debug-build-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PROJECT_ROOT="$TEST_ROOT/project"
DIRECT_DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-NoSandbox"
STAMP_PATH="$DIRECT_DERIVED_DATA/.starcat-build-environment"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"
  grep -Fq "$expected" "$file_path" || fail "$file_path 缺少：$expected"
}

mkdir -p "$DIRECT_DERIVED_DATA"
touch "$DIRECT_DERIVED_DATA/foreign-cache"
starcat_prepare_debug_derived_data \
  "$PROJECT_ROOT" \
  "$DIRECT_DERIVED_DATA" \
  "direct-debug" \
  $'format=1\nowner=direct-debug\nxcode=Xcode-A'

[ ! -e "$DIRECT_DERIVED_DATA/foreign-cache" ] || fail "首次接管未清理无指纹缓存"
assert_file_contains "$STAMP_PATH" "xcode=Xcode-A"

touch "$DIRECT_DERIVED_DATA/reusable-cache"
starcat_prepare_debug_derived_data \
  "$PROJECT_ROOT" \
  "$DIRECT_DERIVED_DATA" \
  "direct-debug" \
  $'format=1\nowner=direct-debug\nxcode=Xcode-A'
[ -e "$DIRECT_DERIVED_DATA/reusable-cache" ] || fail "相同指纹不应清理增量缓存"

starcat_prepare_debug_derived_data \
  "$PROJECT_ROOT" \
  "$DIRECT_DERIVED_DATA" \
  "direct-debug" \
  $'format=1\nowner=direct-debug\nxcode=Xcode-B'
[ ! -e "$DIRECT_DERIVED_DATA/reusable-cache" ] || fail "工具链变化后未清理旧缓存"
assert_file_contains "$STAMP_PATH" "xcode=Xcode-B"

if starcat_prepare_debug_derived_data \
  "$PROJECT_ROOT" \
  "$PROJECT_ROOT/not-allowed" \
  "direct-debug" \
  "invalid" >/dev/null 2>&1; then
  fail "未登记路径不应被构建缓存工具管理"
fi

echo "PASS: Debug 构建环境缓存边界测试通过"

