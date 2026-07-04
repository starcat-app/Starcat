#!/usr/bin/env bash
#
# package-appstore.sh — Starcat App Store 渠道打包入口。
#
# 用途：
#   生成 Starcat App Store target 的 Release archive，并做渠道隔离自检。
#   App Store 包必须不包含 Sparkle.framework、Direct license/payment 入口和 Direct bundle id。
#
# 设计约束：
#   - 只构建 `Starcat` scheme，不碰 `StarcatDirect`。
#   - 默认只产出 `.xcarchive`；是否 export/upload 交给 Xcode Organizer 或 CI 处理。
#   - 如果本机没有完整 App Store 签名配置，archive 可能失败；这是签名环境问题，不是脚本逻辑问题。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist/appstore"
ARCHIVE_PATH="${DIST_DIR}/Starcat-AppStore.xcarchive"
BUILD_LOG="${DIST_DIR}/xcodebuild-appstore.log"

log() { printf '[appstore] %s\n' "$1"; }
fail() { printf '[appstore] ERROR: %s\n' "$1" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 未安装"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 不在 PATH"

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR"
rm -rf "$ARCHIVE_PATH"

log "同步 Xcode 工程"
xcodegen generate >/dev/null

log "构建 App Store archive: $ARCHIVE_PATH"
set +e
xcodebuild \
  -quiet \
  -scheme Starcat \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  clean archive \
  >"$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
  tail -80 "$BUILD_LOG" >&2
  fail "archive 失败，完整日志: $BUILD_LOG"
fi

APP_PATH="${ARCHIVE_PATH}/Products/Applications/Starcat.app"
[ -d "$APP_PATH" ] || fail "archive 中未找到 Starcat.app"

log "渠道自检：App Store 包不能包含 Sparkle"
if find "$APP_PATH" -iname '*Sparkle*' -print -quit | grep -q .; then
  find "$APP_PATH" -iname '*Sparkle*' -print >&2
  fail "App Store 包包含 Sparkle 相关文件"
fi

if otool -L "$APP_PATH/Contents/MacOS/Starcat" "$APP_PATH/Contents/MacOS/Starcat.debug.dylib" 2>/dev/null | grep -qi Sparkle; then
  fail "App Store 包动态链接了 Sparkle"
fi

DIST_VALUE=$(/usr/libexec/PlistBuddy -c 'Print :STARCAT_DISTRIBUTION' "$APP_PATH/Contents/Info.plist")
[ "$DIST_VALUE" = "appstore" ] || fail "STARCAT_DISTRIBUTION 应为 appstore，实际为 $DIST_VALUE"

log "完成"
log "archive: $ARCHIVE_PATH"
log "log: $BUILD_LOG"
