#!/usr/bin/env bash
#
# run-debug-appstore.sh — 本地 Debug 构建并启动 Starcat（App Store / 沙箱模式）。
#
# 这个入口用于验证 App Store / sandbox 真实行为：UserDefaults、security-scoped
# bookmark、Keychain、NSWorkspace 等都应和 Xcode Run 保持同一权限模型。
#
# 关键约束：
# - 使用 Apple Development 签名并保留 Starcat.entitlements。
# - 显式关闭 ENABLE_DEBUG_DYLIB，避免再通过 deep ad-hoc re-sign 修复 open 启动。
# - 绝不在构建后 `codesign --deep --sign -`，否则会清空 entitlements，变成非沙箱 app。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-Sandbox"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Starcat.app"

# 正式 Apple Developer Team ID。后续如果换账号，可用环境变量覆盖：
#   STARCAT_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/run-debug-appstore.sh
DEVELOPMENT_TEAM_ID="${STARCAT_DEVELOPMENT_TEAM:-8WCUMGCWMB}"

cd "$PROJECT_ROOT"

echo "==> 关闭已运行的 Starcat（如有）..."
pkill -x Starcat 2>/dev/null || true
sleep 0.3

echo "==> 生成 Xcode 工程..."
xcodegen generate

echo "==> 构建 Starcat Debug（沙箱模式）..."
xcodebuild \
  -scheme Starcat \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_DEBUG_DYLIB=NO \
  build

echo "==> 校验沙箱 entitlements..."
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
  echo "ERROR: 沙箱 entitlement 缺失，拒绝启动。"
  exit 1
fi
if ! grep -q "com.apple.security.files.user-selected.read-write" <<<"$ENTITLEMENTS"; then
  echo "ERROR: user-selected read/write entitlement 缺失，拒绝启动。"
  exit 1
fi

echo "==> 签名摘要:"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n '1,12p'
echo "==> 当前模式: sandbox"
echo "    preferences: ~/Library/Containers/com.starcat.app.store/Data/Library/Preferences/com.starcat.app.plist"
echo "    data: ~/Library/Containers/com.starcat.app.store/Data"
echo "    app support: ~/Library/Containers/com.starcat.app.store/Data/Library/Application Support/com.starcat.app"
echo "    app: $APP_PATH"

open "$APP_PATH"
