#!/usr/bin/env bash
#
# package-direct.sh — Starcat Direct 渠道打包入口。
#
# 用途：
#   构建 `StarcatDirect` Release 包，生成 DMG 和 SHA256，并可选执行 notarization、
#   staple、Sparkle appcast 生成。
#
# 可选环境变量：
#   STARCAT_SPARKLE_PUBLIC_ED_KEY      注入 Direct 包 Info.plist 的 Sparkle EdDSA 公钥。
#   STARCAT_NOTARIZE=1                 生成 DMG 后提交 Apple Notary。
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD
#                                     notarytool 凭证。
#   STARCAT_GENERATE_APPCAST=1         使用 Sparkle generate_appcast 更新 pages/appcast.xml。
#   STARCAT_DOWNLOAD_BASE_URL          appcast 下载前缀，默认 https://starcat.ink/downloads/。
#
# 设计约束：
#   - Direct 包必须包含 Sparkle.framework。
#   - 默认不强制 notarize/appcast，方便本地开发和 CI 分阶段接入。
#   - 正式公开分发前必须配置 Sparkle 公钥并启用 notarization。
#

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${TAG#v}"
fi
[ -n "$VERSION" ] || VERSION="0.0.1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是 X.Y.Z，例如 0.1.0；当前: $VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist/direct"
DERIVED_DIR="${DIST_DIR}/DerivedData"
STAGING_DIR="${DIST_DIR}/staging"
DOWNLOADS_DIR="${DIST_DIR}/downloads"
APP_PATH="${DERIVED_DIR}/Build/Products/Release/Starcat.app"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
BUILD_LOG="${DIST_DIR}/xcodebuild-direct.log"

log() { printf '[direct] %s\n' "$1"; }
fail() { printf '[direct] ERROR: %s\n' "$1" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 未安装"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 不在 PATH"
command -v hdiutil >/dev/null 2>&1 || fail "hdiutil 不在 PATH"

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR" "$DOWNLOADS_DIR"
rm -rf "$DERIVED_DIR" "$STAGING_DIR"
rm -f "$DMG_PATH" "$SHA_PATH"

log "同步 Xcode 工程"
xcodegen generate >/dev/null

log "构建 Direct Release app"
BUILD_SETTINGS=(
  STARCAT_DISTRIBUTION=direct
)
if [ -n "${STARCAT_SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  BUILD_SETTINGS+=("STARCAT_SPARKLE_PUBLIC_ED_KEY=${STARCAT_SPARKLE_PUBLIC_ED_KEY}")
fi

set +e
xcodebuild \
  -quiet \
  -scheme StarcatDirect \
  -configuration Release \
  -sdk macosx \
  -arch arm64 \
  -derivedDataPath "$DERIVED_DIR" \
  "${BUILD_SETTINGS[@]}" \
  clean build \
  >"$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
  tail -80 "$BUILD_LOG" >&2
  fail "Direct build 失败，完整日志: $BUILD_LOG"
fi

[ -d "$APP_PATH" ] || fail "未找到 Direct app: $APP_PATH"
[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ] || fail "Direct 包缺少 Sparkle.framework"

DIST_VALUE=$(/usr/libexec/PlistBuddy -c 'Print :STARCAT_DISTRIBUTION' "$APP_PATH/Contents/Info.plist")
[ "$DIST_VALUE" = "direct" ] || fail "STARCAT_DISTRIBUTION 应为 direct，实际为 $DIST_VALUE"

log "重新签名 Direct app"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_PATH" >/dev/null
else
  codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp "$APP_PATH" >/dev/null
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

log "生成 DMG"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "Starcat ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$DMG_PATH")" > "$SHA_PATH"

if [ "${STARCAT_NOTARIZE:-0}" = "1" ]; then
  [ -n "${APPLE_ID:-}" ] || fail "STARCAT_NOTARIZE=1 需要 APPLE_ID"
  [ -n "${APPLE_TEAM_ID:-}" ] || fail "STARCAT_NOTARIZE=1 需要 APPLE_TEAM_ID"
  [ -n "${APPLE_APP_PASSWORD:-}" ] || fail "STARCAT_NOTARIZE=1 需要 APPLE_APP_PASSWORD"

  log "提交 notarization"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  log "staple DMG"
  xcrun stapler staple "$DMG_PATH"
  spctl --assess --type open --verbose "$DMG_PATH"
else
  log "跳过 notarization；正式公开分发前请设置 STARCAT_NOTARIZE=1"
fi

if [ "${STARCAT_GENERATE_APPCAST:-0}" = "1" ]; then
  GENERATE_APPCAST="$(find "$DERIVED_DIR" -path '*/Sparkle/bin/generate_appcast' -type f | head -1)"
  [ -n "$GENERATE_APPCAST" ] || fail "未找到 Sparkle generate_appcast"
  DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://starcat.ink/downloads/}"
  log "生成 appcast: pages/appcast.xml"
  "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_BASE_URL" "$DOWNLOADS_DIR"
  cp "$DOWNLOADS_DIR/appcast.xml" "$PROJECT_ROOT/pages/appcast.xml"
else
  log "跳过 appcast 生成；需要时设置 STARCAT_GENERATE_APPCAST=1"
fi

rm -rf "$STAGING_DIR"

log "完成"
log "dmg: $DMG_PATH"
log "sha256: $SHA_PATH"
log "log: $BUILD_LOG"
