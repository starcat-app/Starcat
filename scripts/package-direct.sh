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
#   STARCAT_DMG_TOOL=create-dmg|hdiutil
#                                     默认 create-dmg；仅显式设置 hdiutil 时生成裸 DMG。
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
[ -n "$VERSION" ] || VERSION="1.0.0"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是 X.Y.Z，例如 1.0.0；当前: $VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist/direct"
DERIVED_DIR="${DIST_DIR}/DerivedData"
STAGING_DIR="${DIST_DIR}/staging"
DOWNLOADS_DIR="${DIST_DIR}/downloads"
DMG_ASSETS_DIR="${DIST_DIR}/dmg-assets"
APPCAST_INPUT_DIR="${DIST_DIR}/appcast-input"
APP_PATH="${DERIVED_DIR}/Build/Products/Release/Starcat.app"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
DMG_BACKGROUND_PATH="${DMG_ASSETS_DIR}/background.png"
BUILD_LOG="${DIST_DIR}/xcodebuild-direct.log"
BUILD_NUMBER="${STARCAT_DIRECT_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DMG_TOOL="${STARCAT_DMG_TOOL:-create-dmg}"

log() { printf '[direct] %s\n' "$1"; }
fail() { printf '[direct] ERROR: %s\n' "$1" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 未安装"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 不在 PATH"
case "$DMG_TOOL" in
  create-dmg)
    command -v create-dmg >/dev/null 2>&1 || fail "create-dmg 未安装，请先执行: brew install create-dmg"
    command -v python3 >/dev/null 2>&1 || fail "python3 未安装，无法生成 DMG 背景图"
    ;;
  hdiutil)
    command -v hdiutil >/dev/null 2>&1 || fail "hdiutil 不在 PATH"
    ;;
  *)
    fail "STARCAT_DMG_TOOL 只能是 create-dmg 或 hdiutil，当前: $DMG_TOOL"
    ;;
esac

generate_dmg_background() {
  mkdir -p "$DMG_ASSETS_DIR"
  python3 - "$DMG_BACKGROUND_PATH" <<'PY'
import math
import random
import struct
import sys
import zlib
from pathlib import Path

output = Path(sys.argv[1])
width, height = 660, 420

random.seed(42)
stars = [(random.randint(24, width - 24), random.randint(22, height - 24), random.randint(18, 58)) for _ in range(64)]

def clamp(value):
    return max(0, min(255, int(value)))

def blend(base, color, alpha):
    t = alpha / 255
    return tuple(clamp(base[i] * (1 - t) + color[i] * t) for i in range(3))

def line_alpha(px, py, ax, ay, bx, by, thickness):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    length_sq = vx * vx + vy * vy
    if length_sq == 0:
        distance = math.hypot(px - ax, py - ay)
    else:
        t = max(0, min(1, (wx * vx + wy * vy) / length_sq))
        distance = math.hypot(px - (ax + t * vx), py - (ay + t * vy))
    return max(0, min(1, (thickness - distance) / thickness))

raw = bytearray()
for y in range(height):
    raw.append(0)
    vertical = y / max(height - 1, 1)
    for x in range(width):
        top = (17, 22, 33)
        bottom = (7, 9, 14)
        base = tuple(top[i] + (bottom[i] - top[i]) * vertical for i in range(3))

        # 背景只提供品牌氛围和拖拽方向，避免抢走 Finder 里 App 图标的注意力。
        glow_top = max(0, 1 - math.hypot((x - width * 0.50) / 260, (y + 48) / 170))
        glow_right = max(0, 1 - math.hypot((x - width * 0.90) / 260, (y - height * 0.96) / 180))
        color = (
            base[0] + glow_top * 24 + glow_right * 26,
            base[1] + glow_top * 42 + glow_right * 22,
            base[2] + glow_top * 62 + glow_right * 6,
        )

        for sx, sy, alpha in stars:
            distance = math.hypot(x - sx, y - sy)
            if distance < 1.8:
                color = blend(color, (255, 255, 255), alpha * (1 - distance / 1.8))

        arrow = max(
            line_alpha(x, y, 244, 214, 416, 214, 2.6),
            line_alpha(x, y, 416, 214, 396, 198, 2.6),
            line_alpha(x, y, 416, 214, 396, 230, 2.6),
        )
        if arrow > 0:
            color = blend(color, (255, 255, 255), 62 * arrow)

        raw.extend((clamp(color[0]), clamp(color[1]), clamp(color[2]), 255))

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

png = bytearray(b"\x89PNG\r\n\x1a\n")
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")
output.write_bytes(png)
PY
}

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR" "$DOWNLOADS_DIR"
rm -rf "$DERIVED_DIR" "$STAGING_DIR" "$APPCAST_INPUT_DIR"
rm -f "$DMG_PATH" "$SHA_PATH"

log "同步 Xcode 工程"
xcodegen generate >/dev/null

log "构建 Direct Release app"
BUILD_SETTINGS=(
  STARCAT_DISTRIBUTION=direct
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  STARCAT_MARKETING_VERSION_OVERRIDE="$VERSION"
  STARCAT_BUILD_VERSION_OVERRIDE="$BUILD_NUMBER"
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

APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
[ "$APP_VERSION" = "$VERSION" ] || fail "CFBundleShortVersionString 应为 $VERSION，实际为 $APP_VERSION"

APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
[ "$APP_BUILD" = "$BUILD_NUMBER" ] || fail "CFBundleVersion 应为 $BUILD_NUMBER，实际为 $APP_BUILD"

ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
  fail "Direct 包检测到 sandbox entitlement；Direct / 非 App Store 包必须按非沙箱运行"
fi

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

if [ "$DMG_TOOL" = "create-dmg" ]; then
  generate_dmg_background
  create-dmg \
    --volname "Starcat ${VERSION}" \
    --background "$DMG_BACKGROUND_PATH" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --text-size 13 \
    --icon-size 104 \
    --icon "Starcat.app" 185 218 \
    --hide-extension "Starcat.app" \
    --app-drop-link 475 218 \
    --app-drop-link-name "Applications" \
    --no-internet-enable \
    --format UDZO \
    --overwrite \
    "$DMG_PATH" \
    "$STAGING_DIR" >/dev/null
else
  ln -s /Applications "$STAGING_DIR/Applications"
  hdiutil create \
    -volname "Starcat ${VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
fi

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
  # generate_appcast 会扫描输入目录里的所有历史包。测试单个更新包时使用干净目录，
  # 避免旧 DMG 被重新写入 appcast，导致 Sparkle 看到过期或未签名的更新项。
  mkdir -p "$APPCAST_INPUT_DIR"
  cp "$DMG_PATH" "$APPCAST_INPUT_DIR/"
  "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_BASE_URL" "$APPCAST_INPUT_DIR"
  cp "$APPCAST_INPUT_DIR/appcast.xml" "$PROJECT_ROOT/pages/appcast.xml"
  cp "$APPCAST_INPUT_DIR/appcast.xml" "$DOWNLOADS_DIR/appcast.xml"
else
  log "跳过 appcast 生成；需要时设置 STARCAT_GENERATE_APPCAST=1"
fi

rm -rf "$STAGING_DIR" "$APPCAST_INPUT_DIR"

log "完成"
log "dmg: $DMG_PATH"
log "sha256: $SHA_PATH"
log "log: $BUILD_LOG"
