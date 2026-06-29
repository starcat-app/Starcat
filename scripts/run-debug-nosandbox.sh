#!/usr/bin/env bash
#
# run-debug-nosandbox.sh — 本地 Debug 构建并启动 Starcat（非沙箱模式）。
#
# 这个入口用于验证非 App Store / 非沙箱分发行为。它会显式移除
# CODE_SIGN_ENTITLEMENTS，运行时会读取普通用户域偏好，不会使用 app container。
#
# 关键约束：
# - 非沙箱模式不等价于 App Store 行为；不要用它判断 security-scoped bookmark。
# - 使用 ad-hoc 签名即可本机调试。
# - 显式关闭 ENABLE_DEBUG_DYLIB，避免需要构建后 deep re-sign。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-NoSandbox"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Starcat.app"

cd "$PROJECT_ROOT"

echo "==> 关闭已运行的 Starcat（如有）..."
pkill -x Starcat 2>/dev/null || true
sleep 0.3

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 构建 Starcat Debug（非沙箱模式）..."
xcodebuild \
  -scheme Starcat \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_IDENTITY=- \
  ENABLE_DEBUG_DYLIB=NO \
  build

echo "==> 校验非沙箱 entitlements..."
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
  echo "ERROR: 检测到沙箱 entitlement，非沙箱脚本拒绝启动。"
  exit 1
fi

echo "==> 签名摘要:"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n '1,12p'
echo "==> 当前模式: no-sandbox"
echo "    preferences: ~/Library/Preferences/com.starcat.app.plist"
echo "    app: $APP_PATH"

open "$APP_PATH"
