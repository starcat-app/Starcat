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
SPARKLE_FRAMEWORK_PATH="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
SPARKLE_CURRENT_PATH="${SPARKLE_FRAMEWORK_PATH}/Versions/Current"
SWIFT_COMPATIBILITY_PATH="${APP_PATH}/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
PLUGINS_DIR="${APP_PATH}/Contents/PlugIns"
# Direct Widget 仍是独立沙箱扩展；重新签名时必须用这份正式 entitlement，
# 不能 --preserve-metadata=entitlements，否则会把开发签名注入的 get-task-allow 带进公证包。
DIRECT_WIDGET_ENTITLEMENTS="${PROJECT_ROOT}/Starcat/Resources/Widget/StarcatDirectWidgets.entitlements"
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
[ -d "$SPARKLE_FRAMEWORK_PATH" ] || fail "Direct 包缺少 Sparkle.framework"
[ -f "$CODEBASE_BINARY_PATH" ] || fail "Direct 包缺少 CodebaseMemory 二进制: $CODEBASE_BINARY_PATH"

SPARKLE_NESTED_CODE=(
  "$SPARKLE_CURRENT_PATH/XPCServices/Downloader.xpc"
  "$SPARKLE_CURRENT_PATH/XPCServices/Installer.xpc"
  "$SPARKLE_CURRENT_PATH/Updater.app"
  "$SPARKLE_CURRENT_PATH/Autoupdate"
)
for COMPONENT_PATH in "${SPARKLE_NESTED_CODE[@]}"; do
  [ -e "$COMPONENT_PATH" ] || fail "Sparkle.framework 缺少待签名组件: $COMPONENT_PATH"
done

DIST_VALUE=$(/usr/libexec/PlistBuddy -c 'Print :STARCAT_DISTRIBUTION' "$APP_PATH/Contents/Info.plist")
[ "$DIST_VALUE" = "direct" ] || fail "STARCAT_DISTRIBUTION 应为 direct，实际为 $DIST_VALUE"

LICENSE_API_ENV=$(/usr/libexec/PlistBuddy -c 'Print :STARCAT_LICENSE_API_ENVIRONMENT' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$LICENSE_API_ENV" = "live" ] || fail "Direct Release 必须连接生产 License API，实际 STARCAT_LICENSE_API_ENVIRONMENT=$LICENSE_API_ENV"

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

sign_nested_code() {
  local target_path="$1"

  # Sparkle 的 XPC / helper 需要保留各自 identifier 与 entitlement；但不能保留
  # Xcode 生成的 Apple Development designated requirement，否则换成 Developer ID
  # 后签名自身会无法满足旧 requirement。
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --preserve-metadata=identifier,entitlements "$target_path" >/dev/null
  else
    codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp \
      --preserve-metadata=identifier,entitlements "$target_path" >/dev/null
  fi
}

sign_distribution_code() {
  local target_path="$1"

  # App 外层与普通二进制故意不保留构建期 entitlement，避免把开发签名中的
  # get-task-allow 或 App Sandbox 带入 Direct 分发包。
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$target_path" >/dev/null
  else
    codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp "$target_path" >/dev/null
  fi
}

sign_appex_code() {
  local target_path="$1"
  local entitlements_path="$2"

  [ -f "$entitlements_path" ] || fail "缺少 appex entitlement 文件: $entitlements_path"

  # Widget appex 必须保留 app-sandbox / app group，同时换上 Developer ID + 安全时间戳。
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --entitlements "$entitlements_path" "$target_path" >/dev/null
  else
    codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp \
      --entitlements "$entitlements_path" "$target_path" >/dev/null
  fi
}

sign_dmg_container() {
  # DMG 是用户实际下载并由 Gatekeeper 首先检查的外层容器。它必须在提交
  # notarization 之前签名；公证或 staple 之后再签会改变容器并使票据失效。
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DMG_PATH" >/dev/null
  else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH" >/dev/null
  fi
}

write_dmg_sha256() {
  local sha256
  sha256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  printf '%s  %s\n' "$sha256" "$(basename "$DMG_PATH")" > "$SHA_PATH"
}

verify_developer_id_code() {
  local component_name="$1"
  local target_path="$2"
  local signature_output
  signature_output="$(codesign -dvvv "$target_path" 2>&1)"

  grep -q '^Authority=Developer ID Application:' <<<"$signature_output" \
    || fail "$component_name 未使用 Developer ID Application 签名"
  grep -q 'flags=.*runtime' <<<"$signature_output" \
    || fail "$component_name 未启用 hardened runtime"
  grep -q '^Timestamp=' <<<"$signature_output" \
    || fail "$component_name 缺少安全时间戳"
}

# `codesign --deep` 适合做最终递归校验，但不适合作为签名策略：它不会可靠地
# 修复已有错误签名的嵌套代码。必须严格按最内层 helper -> framework -> app
# 的顺序签名，确保外层资源封条绑定的始终是最终签名。
for COMPONENT_PATH in "${SPARKLE_NESTED_CODE[@]}"; do
  sign_nested_code "$COMPONENT_PATH"
done
sign_nested_code "$SPARKLE_FRAMEWORK_PATH"

if [ -f "$SWIFT_COMPATIBILITY_PATH" ]; then
  sign_distribution_code "$SWIFT_COMPATIBILITY_PATH"
fi

# `codebase.bin` 位于 Resources，不属于 codesign 稳定识别的嵌套代码目录，
# 因此要在 App 外层签名之前单独处理。
sign_distribution_code "$CODEBASE_BINARY_PATH"

# PlugIns/*.appex 必须在外层 App 之前单独换签。Xcode Automatic 签名常留下
# Apple Development + get-task-allow，公证会直接 Invalid（1.3.0 首次提交已踩坑）。
APPEX_PATHS=()
if [ -d "$PLUGINS_DIR" ]; then
  while IFS= read -r -d '' APPEX_PATH; do
    APPEX_PATHS+=("$APPEX_PATH")
  done < <(find "$PLUGINS_DIR" -maxdepth 1 -type d -name '*.appex' -print0 | sort -z)
fi
for APPEX_PATH in "${APPEX_PATHS[@]+"${APPEX_PATHS[@]}"}"; do
  case "$(basename "$APPEX_PATH")" in
    StarcatDirectWidgets.appex)
      sign_appex_code "$APPEX_PATH" "$DIRECT_WIDGET_ENTITLEMENTS"
      ;;
    *)
      fail "未配置 entitlement 映射的 Direct appex: $(basename "$APPEX_PATH")"
      ;;
  esac
done

sign_distribution_code "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$CODEBASE_BINARY_PATH"

if [ "$SIGN_IDENTITY" != "-" ]; then
  verify_developer_id_code "Starcat.app" "$APP_PATH"
  verify_developer_id_code "CodebaseMemory 二进制" "$CODEBASE_BINARY_PATH"
  verify_developer_id_code "Sparkle.framework" "$SPARKLE_FRAMEWORK_PATH"
  for COMPONENT_PATH in "${SPARKLE_NESTED_CODE[@]}"; do
    verify_developer_id_code "$(basename "$COMPONENT_PATH")" "$COMPONENT_PATH"
  done
  if [ -f "$SWIFT_COMPATIBILITY_PATH" ]; then
    verify_developer_id_code "libswiftCompatibilitySpan.dylib" "$SWIFT_COMPATIBILITY_PATH"
  fi
  for APPEX_PATH in "${APPEX_PATHS[@]+"${APPEX_PATHS[@]}"}"; do
    verify_developer_id_code "$(basename "$APPEX_PATH")" "$APPEX_PATH"
    APPEX_ENTITLEMENTS="$(codesign -d --entitlements :- "$APPEX_PATH" 2>/dev/null || true)"
    if grep -q 'com.apple.security.get-task-allow' <<<"$APPEX_ENTITLEMENTS"; then
      fail "$(basename "$APPEX_PATH") 仍包含 get-task-allow entitlement"
    fi
    if ! grep -q 'com.apple.security.app-sandbox' <<<"$APPEX_ENTITLEMENTS"; then
      fail "$(basename "$APPEX_PATH") 缺少 app-sandbox entitlement"
    fi
  done
fi

FINAL_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if grep -Eq 'com\.apple\.security\.(app-sandbox|get-task-allow)' <<<"$FINAL_ENTITLEMENTS"; then
  fail "Direct 包最终签名仍包含 App Sandbox 或 get-task-allow entitlement"
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

log "签名 DMG 容器"
sign_dmg_container
codesign --verify --verbose=2 "$DMG_PATH"
write_dmg_sha256

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
      fail "notarization 等待失败；Submission ID 已保存到 ${NOTARY_SUBMISSION_PATH}。Accepted 后可用 STARCAT_NOTARY_SUBMISSION_ID=$SUBMISSION_ID 续跑 release-direct.sh"
    fi
    fail "notarization 提交或等待失败，完整输出: $NOTARY_OUTPUT_PATH"
  fi

  log "staple DMG"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
  # stapler 会写入 DMG，因此最终发布 SHA 必须在装订票据后重新计算。
  write_dmg_sha256
else
  log "跳过 notarization；正式公开分发前请设置 STARCAT_NOTARIZE=1"
fi

if [ "${STARCAT_GENERATE_APPCAST:-0}" = "1" ]; then
  GENERATE_APPCAST="$(find "$DERIVED_DIR" -path '*/Sparkle/bin/generate_appcast' -type f | head -1)"
  [ -n "$GENERATE_APPCAST" ] || fail "未找到 Sparkle generate_appcast"
  DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://starcat.ink/downloads/}"
  log "生成当前版本 appcast: $CURRENT_APPCAST_PATH"
  # 这里只生成当前版本 item。历史版本由 release-direct.sh 增量合并进
  # supports/starcat-site/direct/appcast.xml，避免发布机必须保存所有旧 DMG。
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
