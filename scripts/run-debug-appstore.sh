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
STABLE_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# 正式 Apple Developer Team ID。后续如果换账号，可用环境变量覆盖：
#   STARCAT_DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/run-debug-appstore.sh
DEVELOPMENT_TEAM_ID="${STARCAT_DEVELOPMENT_TEAM:-8WCUMGCWMB}"

# App Store 日常调试固定使用稳定版 Xcode，避免系统当前选中 Xcode Beta 时继承其
# 未安装的可选 Metal Toolchain。必须在关闭现有 App 前完成前置检查，否则一次
# 工具链配置错误也会中断正在运行的调试实例。
if [ ! -x "$STABLE_XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "ERROR: 未找到稳定版 Xcode：$STABLE_XCODE_DEVELOPER_DIR"
  echo "       请确认 /Applications/Xcode.app 已安装且可用。"
  exit 1
fi
export DEVELOPER_DIR="$STABLE_XCODE_DEVELOPER_DIR"
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "ERROR: 稳定版 Xcode 的 Metal Toolchain 不可用，无法编译 .metal 文件。"
  echo "       请在 Xcode > Settings > Components 中安装 Metal Toolchain。"
  exit 1
fi

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
