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
# 可选环境变量：
#   STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB
#       正式 Apple Developer Team ID。设置后 archive 显式使用该 Team。
#   STARCAT_APPSTORE_SIGN_IDENTITY="Apple Distribution: liwen gong (8WCUMGCWMB)"
#       archive 后重签嵌入式可执行文件时使用。未设置时从主 App 签名信息推断。
#   STARCAT_APPSTORE_SKIP_OPEN=1
#       只打包和检查，不自动打开 archive。CI 或批处理环境可设置。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist/appstore"
ARCHIVE_PATH="${DIST_DIR}/Starcat-AppStore.xcarchive"
BUILD_LOG="${DIST_DIR}/xcodebuild-appstore.log"
DEVELOPMENT_TEAM_ID="${STARCAT_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
APPSTORE_ENTITLEMENTS_PATH="${PROJECT_ROOT}/Starcat/Starcat.entitlements"

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
BUILD_SETTINGS=(
  CODE_SIGN_STYLE=Automatic
  STARCAT_DISTRIBUTION=appstore
)
if [ -n "$DEVELOPMENT_TEAM_ID" ]; then
  BUILD_SETTINGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM_ID}")
fi

set +e
xcodebuild \
  -quiet \
  -scheme Starcat \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  "${BUILD_SETTINGS[@]}" \
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

resolve_appstore_sign_identity() {
  if [ -n "${STARCAT_APPSTORE_SIGN_IDENTITY:-}" ]; then
    printf '%s\n' "$STARCAT_APPSTORE_SIGN_IDENTITY"
    return
  fi

  local identity
  identity="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^Authority=\(Apple Distribution:.*\)$/\1/p' | head -1)"
  [ -n "$identity" ] || identity="Apple Distribution"
  printf '%s\n' "$identity"
}

sign_codebase_binary_for_appstore() {
  local binary_path="${APP_PATH}/Contents/Resources/codebase.bin"
  [ -f "$binary_path" ] || return
  [ -f "$APPSTORE_ENTITLEMENTS_PATH" ] || fail "缺少 App Store entitlements: $APPSTORE_ENTITLEMENTS_PATH"

  local sign_identity
  sign_identity="$(resolve_appstore_sign_identity)"
  log "重签 App Store 嵌入式可执行文件: codebase.bin"
  # App Store 上传会逐个检查 bundle 内的 Mach-O 可执行文件。
  # codebase.bin 放在 Resources 中但仍是可执行文件，必须单独带 sandbox entitlement 签名。
  codesign --force \
    --sign "$sign_identity" \
    --options runtime \
    --entitlements "$APPSTORE_ENTITLEMENTS_PATH" \
    "$binary_path"

  local codebase_entitlements
  codebase_entitlements="$(codesign -d --entitlements :- "$binary_path" 2>/dev/null || true)"
  if ! grep -q "com.apple.security.app-sandbox" <<<"$codebase_entitlements"; then
    fail "codebase.bin 重签后仍缺少 sandbox entitlement"
  fi

  if command -v dsymutil >/dev/null 2>&1; then
    log "生成 codebase.bin dSYM"
    mkdir -p "${ARCHIVE_PATH}/dSYMs"
    dsymutil "$binary_path" -o "${ARCHIVE_PATH}/dSYMs/codebase.bin.dSYM" >/dev/null
  else
    log "跳过 codebase.bin dSYM：dsymutil 不在 PATH"
  fi

  log "重签 App Store 主 App 以更新资源封签"
  codesign --force \
    --sign "$sign_identity" \
    --options runtime \
    --entitlements "$APPSTORE_ENTITLEMENTS_PATH" \
    "$APP_PATH"
}

sign_codebase_binary_for_appstore

verify_appstore_archive() {
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
  log "STARCAT_DISTRIBUTION: $DIST_VALUE"

  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
  [ "$BUNDLE_ID" = "com.starcat.app.store" ] || fail "App Store bundle id 应为 com.starcat.app.store，实际为 $BUNDLE_ID"
  log "Bundle ID: $BUNDLE_ID"

  APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
  log "Version: $APP_VERSION"

  ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
  if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
    fail "App Store 包缺少 sandbox entitlement"
  fi
  log "主 App sandbox entitlement: OK"

  CODEBASE_BIN="${APP_PATH}/Contents/Resources/codebase.bin"
  if [ -f "$CODEBASE_BIN" ]; then
    CODEBASE_ENTITLEMENTS="$(codesign -d --entitlements :- "$CODEBASE_BIN" 2>/dev/null || true)"
    if ! grep -q "com.apple.security.app-sandbox" <<<"$CODEBASE_ENTITLEMENTS"; then
      fail "codebase.bin 缺少 sandbox entitlement"
    fi
    log "codebase.bin sandbox entitlement: OK"

    if command -v dwarfdump >/dev/null 2>&1; then
      CODEBASE_DSYM="${ARCHIVE_PATH}/dSYMs/codebase.bin.dSYM"
      CODEBASE_UUID="$(dwarfdump --uuid "$CODEBASE_BIN" 2>/dev/null | awk '{print $2}' | head -1)"
      [ -d "$CODEBASE_DSYM" ] || fail "缺少 codebase.bin dSYM: $CODEBASE_DSYM"
      if [ -n "$CODEBASE_UUID" ] && ! dwarfdump --uuid "$CODEBASE_DSYM" 2>/dev/null | grep -q "$CODEBASE_UUID"; then
        fail "codebase.bin dSYM 缺少匹配 UUID: $CODEBASE_UUID"
      fi
      log "codebase.bin dSYM UUID: ${CODEBASE_UUID:-unknown}"
    fi
  fi
}

verify_appstore_archive

if [ "${STARCAT_APPSTORE_SKIP_OPEN:-0}" != "1" ]; then
  log "检查通过，打开 Xcode Organizer archive"
  open "$ARCHIVE_PATH"
fi

log "完成"
log "archive: $ARCHIVE_PATH"
log "log: $BUILD_LOG"
