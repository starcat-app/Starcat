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
#   STARCAT_DIRECT_SIGN_IDENTITY       Direct 公开发布用签名身份，优先级高于 CODE_SIGN_IDENTITY。
#                                     未设置时默认使用本机 Starcat Developer ID 证书。
#   STARCAT_NOTARIZE=1                 生成 DMG 后提交 Apple Notary。
#   STARCAT_NOTARY_PROFILE             notarytool Keychain profile，推荐值 starcat-notary。
#   *.notary-submission-id             脚本在等待超时时写入 Submission ID，供 release-direct.sh 断点续跑。
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD
#                                     未配置 STARCAT_NOTARY_PROFILE 时的兼容凭证。
#   STARCAT_GENERATE_APPCAST=1         使用 Sparkle generate_appcast 生成当前版本 appcast。
#   STARCAT_DOWNLOAD_BASE_URL          appcast 下载前缀，默认 https://starcat.ink/downloads/。
#   STARCAT_DMG_TOOL=create-dmg|hdiutil
#                                     默认 create-dmg；仅显式设置 hdiutil 时生成裸 DMG。
#   STARCAT_DMG_APPLESCRIPT_TIMEOUT_SECONDS
#                                     create-dmg Finder 美化 AppleScript 超时时间，默认 600 秒。
#   STARCAT_DMG_RETRY_COUNT           create-dmg 失败重试次数，默认 3。
#   STARCAT_DMG_RETRY_SLEEP_SECONDS   create-dmg 失败后重试等待秒数，默认 60。
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
APPCAST_INPUT_DIR="${DIST_DIR}/appcast-input"
APP_PATH="${DERIVED_DIR}/Build/Products/Release/Starcat.app"
CODEBASE_BINARY_PATH="${APP_PATH}/Contents/Resources/codebase.bin"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
CURRENT_APPCAST_PATH="${DOWNLOADS_DIR}/appcast-current.xml"
NOTARY_SUBMISSION_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.notary-submission-id"
NOTARY_OUTPUT_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.notary-submit.log"
DMG_BACKGROUND_PATH="${PROJECT_ROOT}/scripts/assets/dmg-background.png"
BUILD_LOG="${DIST_DIR}/xcodebuild-direct.log"
BUILD_NUMBER="${STARCAT_DIRECT_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DMG_TOOL="${STARCAT_DMG_TOOL:-create-dmg}"
DEFAULT_DIRECT_SIGN_IDENTITY="Developer ID Application: liwen gong (8WCUMGCWMB)"

log() { printf '[direct] %s\n' "$1"; }
fail() { printf '[direct] ERROR: %s\n' "$1" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 未安装"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 不在 PATH"
case "$DMG_TOOL" in
  create-dmg)
    command -v create-dmg >/dev/null 2>&1 || fail "create-dmg 未安装，请先执行: brew install create-dmg"
    [ -f "$DMG_BACKGROUND_PATH" ] || fail "缺少 DMG 背景图: $DMG_BACKGROUND_PATH"
    ;;
  hdiutil)
    command -v hdiutil >/dev/null 2>&1 || fail "hdiutil 不在 PATH"
    ;;
  *)
    fail "STARCAT_DMG_TOOL 只能是 create-dmg 或 hdiutil，当前: $DMG_TOOL"
    ;;
esac

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR" "$DOWNLOADS_DIR"
rm -rf "$DERIVED_DIR" "$STAGING_DIR" "$APPCAST_INPUT_DIR"
rm -f "$DMG_PATH" "$SHA_PATH" "$CURRENT_APPCAST_PATH" "$NOTARY_SUBMISSION_PATH" "$NOTARY_OUTPUT_PATH"

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
[ -f "$CODEBASE_BINARY_PATH" ] || fail "Direct 包缺少 CodebaseMemory 二进制: $CODEBASE_BINARY_PATH"

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
# Direct 正式分发固定使用 Starcat 当前 Developer ID 证书作为默认值；
# 仍保留环境变量覆盖，方便未来换 Apple Team 或 CI 使用不同 keychain。
SIGN_IDENTITY="${STARCAT_DIRECT_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-$DEFAULT_DIRECT_SIGN_IDENTITY}}"
if [ "${STARCAT_NOTARIZE:-0}" = "1" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    fail "STARCAT_NOTARIZE=1 时 CODE_SIGN_IDENTITY 不能是 ad-hoc，请使用 Developer ID Application"
  fi
  if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    fail "STARCAT_NOTARIZE=1 需要 Developer ID Application 签名，当前: $SIGN_IDENTITY"
  fi
fi

# `codebase.bin` 位于 Resources，不属于 codesign --deep 稳定识别的嵌套代码目录。
# 必须先单独签名，再让 App 外层资源封条绑定它；否则下载后的 Direct App 首次启动
# 子进程时可能被 Gatekeeper 拦截，而 Runner 的启动过程又会因此卡住。
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$CODEBASE_BINARY_PATH" >/dev/null
  codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_PATH" >/dev/null
else
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp "$CODEBASE_BINARY_PATH" >/dev/null
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --timestamp "$APP_PATH" >/dev/null
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$CODEBASE_BINARY_PATH"

if [ "$SIGN_IDENTITY" != "-" ]; then
  CODEBASE_SIGNATURE="$(codesign -dvvv "$CODEBASE_BINARY_PATH" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<<"$CODEBASE_SIGNATURE" \
    || fail "CodebaseMemory 二进制未使用 Developer ID Application 签名"
  grep -q 'flags=.*runtime' <<<"$CODEBASE_SIGNATURE" \
    || fail "CodebaseMemory 二进制未启用 hardened runtime"
fi

log "生成 DMG"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

if [ "$DMG_TOOL" = "create-dmg" ]; then
  "${SCRIPT_DIR}/create-dmg-with-retry.sh" \
    --volname "Starcat ${VERSION}" \
    --background "$DMG_BACKGROUND_PATH" \
    --window-pos 200 120 \
    --window-size 820 520 \
    --text-size 13 \
    --icon-size 112 \
    --icon "Starcat.app" 235 220 \
    --hide-extension "Starcat.app" \
    --app-drop-link 585 220 \
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
  log "提交 notarization"
  NOTARY_PROFILE="${STARCAT_NOTARY_PROFILE:-}"
  if [ -z "$NOTARY_PROFILE" ] \
    && [ -z "${APPLE_ID:-}" ] \
    && [ -z "${APPLE_TEAM_ID:-}" ] \
    && [ -z "${APPLE_APP_PASSWORD:-}" ]; then
    # dong4j 本机已用 notarytool 将该 profile 保存到 Keychain。
    # 这里提供默认值，让正式发布命令只需要开启 STARCAT_NOTARIZE=1。
    NOTARY_PROFILE="starcat-notary"
  fi

  if [ -n "$NOTARY_PROFILE" ]; then
    set +e
    xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait 2>&1 | tee "$NOTARY_OUTPUT_PATH"
    NOTARY_EXIT=${PIPESTATUS[0]}
    set -e
  else
    [ -n "${APPLE_ID:-}" ] || fail "STARCAT_NOTARIZE=1 需要 STARCAT_NOTARY_PROFILE 或 APPLE_ID"
    [ -n "${APPLE_TEAM_ID:-}" ] || fail "STARCAT_NOTARIZE=1 需要 STARCAT_NOTARY_PROFILE 或 APPLE_TEAM_ID"
    [ -n "${APPLE_APP_PASSWORD:-}" ] || fail "STARCAT_NOTARIZE=1 需要 STARCAT_NOTARY_PROFILE 或 APPLE_APP_PASSWORD"
    set +e
    xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait 2>&1 | tee "$NOTARY_OUTPUT_PATH"
    NOTARY_EXIT=${PIPESTATUS[0]}
    set -e
  fi

  SUBMISSION_ID="$(sed -n 's/^[[:space:]]*id:[[:space:]]*//p' "$NOTARY_OUTPUT_PATH" | head -1)"
  if [ -n "$SUBMISSION_ID" ]; then
    printf '%s\n' "$SUBMISSION_ID" > "$NOTARY_SUBMISSION_PATH"
    log "notarization submission id: $SUBMISSION_ID"
  fi

  if [ "$NOTARY_EXIT" -ne 0 ]; then
    if [ -n "$SUBMISSION_ID" ]; then
      fail "notarization 等待失败；Submission ID 已保存到 $NOTARY_SUBMISSION_PATH。Accepted 后可用 STARCAT_NOTARY_SUBMISSION_ID=$SUBMISSION_ID 续跑 release-direct.sh"
    fi
    fail "notarization 提交或等待失败，完整输出: $NOTARY_OUTPUT_PATH"
  fi

  log "staple DMG"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --verbose "$DMG_PATH"
else
  log "跳过 notarization；正式公开分发前请设置 STARCAT_NOTARIZE=1"
fi

if [ "${STARCAT_GENERATE_APPCAST:-0}" = "1" ]; then
  GENERATE_APPCAST="$(find "$DERIVED_DIR" -path '*/Sparkle/bin/generate_appcast' -type f | head -1)"
  [ -n "$GENERATE_APPCAST" ] || fail "未找到 Sparkle generate_appcast"
  DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://starcat.ink/downloads/}"
  log "生成当前版本 appcast: $CURRENT_APPCAST_PATH"
  # 这里只生成当前版本 item。历史版本由 release-direct.sh 增量合并进
  # pages/direct/appcast.xml，避免发布机必须保存所有旧 DMG。
  mkdir -p "$APPCAST_INPUT_DIR"
  cp "$DMG_PATH" "$APPCAST_INPUT_DIR/"
  "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_BASE_URL" "$APPCAST_INPUT_DIR"
  cp "$APPCAST_INPUT_DIR/appcast.xml" "$CURRENT_APPCAST_PATH"
else
  log "跳过 appcast 生成；需要时设置 STARCAT_GENERATE_APPCAST=1"
fi

rm -rf "$STAGING_DIR" "$APPCAST_INPUT_DIR"

log "完成"
log "dmg: $DMG_PATH"
log "sha256: $SHA_PATH"
if [ "${STARCAT_GENERATE_APPCAST:-0}" = "1" ]; then
  log "current appcast: $CURRENT_APPCAST_PATH"
fi
log "log: $BUILD_LOG"
