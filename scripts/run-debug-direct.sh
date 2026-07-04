#!/usr/bin/env bash
#
# run-debug-direct.sh — 本地 Debug 构建并启动 StarcatDirect（Direct / 非 App Store 模式）。
#
# 这个入口用于验证非 App Store / Direct 分发行为。它使用 StarcatDirect
# scheme，覆盖 Direct 独立 bundle id、Info.plist、Sparkle 依赖和 Direct
# entitlements，而不是把 App Store target 临时去沙箱。
#
# 关键约束：
# - 非沙箱模式不等价于 App Store 行为；不要用它判断 security-scoped bookmark。
# - 使用 Apple Development 签名并保留 StarcatDirect.entitlements，确保 Direct
#   签名边界和 App Store target 分离。
# - 显式关闭 ENABLE_DEBUG_DYLIB，避免需要构建后 deep re-sign。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-NoSandbox"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Starcat.app"

# Personal Team 的 Team ID。后续如果换账号，可用环境变量覆盖：
#   STARCAT_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/run-debug-direct.sh
DEVELOPMENT_TEAM_ID="${STARCAT_DEVELOPMENT_TEAM:-6N2V7FYPJ8}"

cd "$PROJECT_ROOT"

echo "==> 关闭已运行的 Starcat（如有）..."
pkill -x Starcat 2>/dev/null || true
sleep 0.3

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 构建 StarcatDirect Debug（Direct / 非 App Store 模式）..."
xcodebuild \
  -scheme StarcatDirect \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_DEBUG_DYLIB=NO \
  build

echo "==> 校验 Direct 构建产物..."
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
  echo "ERROR: 检测到沙箱 entitlement，非沙箱脚本拒绝启动。"
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" | grep -qx "com.starcat.app.direct"; then
  echo "ERROR: bundle id 不是 com.starcat.app.direct，拒绝启动。"
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  echo "ERROR: Direct Info.plist 缺少 SUFeedURL，拒绝启动。"
  exit 1
fi
if [ ! -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
  echo "ERROR: Direct 构建产物缺少 Sparkle.framework，拒绝启动。"
  exit 1
fi

echo "==> 签名摘要:"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n '1,12p'
echo "==> 当前模式: direct"
echo "    preferences: ~/Library/Preferences/com.starcat.app.direct.plist"
echo "    data: ~/Library/Application Support/com.starcat.app"
echo "    app support: ~/Library/Application Support/com.starcat.app"
echo "    app: $APP_PATH"

open "$APP_PATH"
