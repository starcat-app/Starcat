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
#   - App Store 正式包只允许使用 `/Applications/Xcode.app` 中的正式版 Xcode；
#     Beta、RC、Preview 或其他路径在删除旧产物前直接拒绝。
#   - 默认只产出 `.xcarchive`；设置 STARCAT_APPSTORE_EXPORT=1 时额外本地导出 `.pkg`，绝不上传。
#   - Automatic Signing 的 archive 可以使用开发签名；Xcode 在 app-store-connect export
#     阶段才会为主 App 与 Extension 统一换成 Distribution 签名和 Store profile。
#   - 如果本机没有完整 App Store 签名配置，archive 可能失败；这是签名环境问题，不是脚本逻辑问题。
#
# 可选环境变量：
#   STARCAT_DEVELOPMENT_TEAM=8WCUMGCWMB
#       正式 Apple Developer Team ID。设置后 archive 显式使用该 Team。
#   STARCAT_APPSTORE_SIGN_IDENTITY="Apple Distribution: liwen gong (8WCUMGCWMB)"
#       archive 后重签 codebase.bin 与主 App 资源封签时使用。默认 `Apple Distribution`。
#   STARCAT_APPSTORE_EXPORT=1
#       使用 app-store-connect + destination=export 本地生成 `.pkg`，不会上传 App Store Connect。
#   STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES=1
#       export 时允许 Xcode 获取或创建 Distribution provisioning profile。
#   STARCAT_APPSTORE_SKIP_OPEN=1
#       只打包和检查，不自动打开 archive。CI 或批处理环境可设置。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist/appstore"
ARCHIVE_PATH="${DIST_DIR}/Starcat-AppStore.xcarchive"
BUILD_LOG="${DIST_DIR}/xcodebuild-appstore.log"
EXPORT_DIR="${DIST_DIR}/export"
EXPORT_LOG="${DIST_DIR}/xcodebuild-appstore-export.log"
EXPORT_OPTIONS_PATH="${DIST_DIR}/ExportOptions.generated.plist"
DEVELOPMENT_TEAM_ID="${STARCAT_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
APPSTORE_SIGN_IDENTITY="${STARCAT_APPSTORE_SIGN_IDENTITY:-Apple Distribution}"
APPSTORE_ENTITLEMENTS_PATH="${PROJECT_ROOT}/Starcat/Starcat.entitlements"
FORMAL_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

log() { printf '[appstore] %s\n' "$1"; }
fail() { printf '[appstore] ERROR: %s\n' "$1" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen 未安装"
command -v xcrun >/dev/null 2>&1 || fail "xcrun 不在 PATH"

verify_formal_xcode() {
  local xcodebuild_path
  local developer_dir
  local xcode_app_path
  local xcode_version
  local xcode_build
  local xcode_icon_name

  xcodebuild_path="$(xcrun --find xcodebuild 2>/dev/null || true)"
  [ -n "$xcodebuild_path" ] || fail "无法通过 xcrun 定位 xcodebuild"

  developer_dir="${xcodebuild_path%/usr/bin/xcodebuild}"
  xcode_app_path="${developer_dir%/Contents/Developer}"
  xcode_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$xcode_app_path/Contents/Info.plist" 2>/dev/null || true)"
  xcode_build="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$xcode_app_path/Contents/version.plist" 2>/dev/null || true)"
  xcode_icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$xcode_app_path/Contents/Info.plist" 2>/dev/null || true)"

  # App Store Connect 会拒绝 Beta Xcode 生成的构建。固定正式版安装路径，
  # 并检查 Beta 图标标记和 seed build 后缀，避免只修改 app 名称后绕过门禁。
  [ "$developer_dir" = "$FORMAL_XCODE_DEVELOPER_DIR" ] || \
    fail "App Store 正式包只允许使用 ${FORMAL_XCODE_DEVELOPER_DIR}；当前为 ${developer_dir}。请显式设置 DEVELOPER_DIR=${FORMAL_XCODE_DEVELOPER_DIR}"
  [ -n "$xcode_version" ] || fail "无法读取正式版 Xcode 版本"
  [ -n "$xcode_build" ] || fail "无法读取正式版 Xcode build"
  if [[ "$xcode_icon_name" =~ [Bb]eta|[Pp]review|[Rr]elease[Cc]andidate ]] || [[ "$xcode_build" =~ [a-z]$ ]]; then
    fail "App Store 正式包禁止使用 Beta/RC/Preview Xcode；当前为 Xcode ${xcode_version} (${xcode_build})"
  fi

  XCODEBUILD_BIN="$xcodebuild_path"
  log "Xcode 正式版门禁通过: Xcode ${xcode_version} (${xcode_build})"
}

# Archive 会把主仓库 Changelog 原样签进 App；必须在删除旧产物和开始构建前
# 阻断仍处于“待发布”的标题，否则事后无法在不破坏签名的前提下修正。
verify_release_changelogs() {
  local tag
  local version
  local changelog

  tag="$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  version="${tag#v}"
  version="${version#V}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "无法从最新 git tag 解析 App Store 发布版本；当前 tag: ${tag:-missing}"

  for changelog in "$PROJECT_ROOT/CHANGELOG.md" "$PROJECT_ROOT/CHANGELOG-ZH.md"; do
    [ -f "$changelog" ] || fail "缺少 App Store Changelog: $changelog"
    if grep -Fqx "## ${version}-待发布" "$changelog"; then
      fail "App Store ${version} Changelog 仍标记为待发布: $changelog"
    fi
    grep -Fqx "## ${version}" "$changelog" || \
      fail "App Store ${version} Changelog 缺少正式版本标题: $changelog"
  done

  log "Changelog 正式版本门禁通过: ${version}"
}

verify_formal_xcode
verify_release_changelogs

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
"$XCODEBUILD_BIN" \
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
  printf '%s\n' "$APPSTORE_SIGN_IDENTITY"
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

verify_apple_distribution_signature() {
  local target_path="$1"
  local target_label="$2"
  local authority
  authority="$(codesign -dv --verbose=4 "$target_path" 2>&1 | sed -n 's/^Authority=\(Apple Distribution:.*\)$/\1/p' | head -1)"
  [ -n "$authority" ] || fail "$target_label 未使用 Apple Distribution 签名: $target_path"
  log "$target_label 签名: $authority"
}

verify_appstore_provisioning_profile() {
  local bundle_path="$1"
  local profile_path="$2"
  local target_label="$3"
  local profile_plist
  profile_plist="$(mktemp)"

  if ! security cms -D -i "$profile_path" >"$profile_plist" 2>/dev/null; then
    rm -f "$profile_plist"
    fail "$target_label 无法解析 provisioning profile: $profile_path"
  fi

  # 最终 export 的 App Store distribution profile 不能绑定开发设备，也不能使用
  # Developer ID 的 ProvisionsAllDevices。archive 的开发 profile 不在这里检查，
  # 因为 Xcode 会在 app-store-connect export 阶段统一替换它们。
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$profile_plist" >/dev/null 2>&1; then
    rm -f "$profile_plist"
    fail "$target_label provisioning profile 仍包含 ProvisionedDevices"
  fi
  if /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile_plist" >/dev/null 2>&1; then
    rm -f "$profile_plist"
    fail "$target_label provisioning profile 不应包含 ProvisionsAllDevices"
  fi

  local get_task_allow
  get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$profile_plist" 2>/dev/null || true)"
  if [ "$get_task_allow" = "true" ]; then
    rm -f "$profile_plist"
    fail "$target_label provisioning profile 开启了 get-task-allow"
  fi

  local bundle_id
  local team_id
  local profile_app_id
  local profile_name
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle_path/Contents/Info.plist")"
  team_id="$(codesign -dv --verbose=4 "$bundle_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)"
  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist" 2>/dev/null || true)"
  rm -f "$profile_plist"

  [ -n "$team_id" ] || fail "$target_label 签名缺少 TeamIdentifier"
  [ "$profile_app_id" = "${team_id}.${bundle_id}" ] || \
    fail "$target_label provisioning profile 与 bundle id 不匹配: ${profile_app_id:-missing}"
  log "$target_label provisioning profile: ${profile_name:-unknown}"
}

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

  ARCHIVE_SIGN_IDENTITY="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:SigningIdentity' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
  case "$ARCHIVE_SIGN_IDENTITY" in
    Apple\ Development:*|Apple\ Distribution:*) ;;
    *) fail "archive 元数据不是可识别的 Apple 签名: ${ARCHIVE_SIGN_IDENTITY:-missing}" ;;
  esac
  log "Archive 原始 signing identity: $ARCHIVE_SIGN_IDENTITY"

  WIDGET_PATH="${APP_PATH}/Contents/PlugIns/StarcatWidgets.appex"
  [ -d "$WIDGET_PATH" ] || fail "archive 中缺少 StarcatWidgets.appex"

  # codebase.bin 位于 Resources，Xcode export 不会把它当独立 target 管理，因此先用
  # Distribution 证书签好，再重签主 App 的资源封签。Widget 保持 archive 原始签名，
  # 由 app-store-connect export 与主 App 一起统一重签。
  verify_apple_distribution_signature "$APP_PATH" "主 App（archive 后处理）"
  WIDGET_ARCHIVE_AUTHORITY="$(codesign -dv --verbose=4 "$WIDGET_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  case "$WIDGET_ARCHIVE_AUTHORITY" in
    Apple\ Development:*|Apple\ Distribution:*) ;;
    *) fail "Widget archive 签名不可识别: ${WIDGET_ARCHIVE_AUTHORITY:-missing}" ;;
  esac
  log "Widget archive signing identity: $WIDGET_ARCHIVE_AUTHORITY"

  ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
  if ! grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
    fail "App Store 包缺少 sandbox entitlement"
  fi
  log "主 App sandbox entitlement: OK"

  WIDGET_ENTITLEMENTS="$(codesign -d --entitlements :- "$WIDGET_PATH" 2>/dev/null || true)"
  if ! grep -q "com.apple.security.app-sandbox" <<<"$WIDGET_ENTITLEMENTS"; then
    fail "Widget 缺少 sandbox entitlement"
  fi
  log "Widget sandbox entitlement: OK"

  CODEBASE_BIN="${APP_PATH}/Contents/Resources/codebase.bin"
  if [ -f "$CODEBASE_BIN" ]; then
    verify_apple_distribution_signature "$CODEBASE_BIN" "codebase.bin"
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

  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  log "codesign deep strict: OK"
}

verify_appstore_archive

export_appstore_package() {
  [ -n "$DEVELOPMENT_TEAM_ID" ] || fail "本地导出 App Store pkg 时必须设置 STARCAT_DEVELOPMENT_TEAM"
  command -v pkgutil >/dev/null 2>&1 || fail "pkgutil 不在 PATH"
  command -v security >/dev/null 2>&1 || fail "security 不在 PATH"

  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  plutil -create xml1 "$EXPORT_OPTIONS_PATH"
  plutil -insert method -string app-store-connect "$EXPORT_OPTIONS_PATH"
  plutil -insert destination -string export "$EXPORT_OPTIONS_PATH"
  plutil -insert signingStyle -string automatic "$EXPORT_OPTIONS_PATH"
  plutil -insert teamID -string "$DEVELOPMENT_TEAM_ID" "$EXPORT_OPTIONS_PATH"
  plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS_PATH"

  EXPORT_COMMAND=(
    "$XCODEBUILD_BIN"
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"
  )
  if [ "${STARCAT_APPSTORE_ALLOW_PROVISIONING_UPDATES:-0}" = "1" ]; then
    EXPORT_COMMAND+=(-allowProvisioningUpdates)
  fi

  log "本地导出 App Store pkg（destination=export，不上传）"
  set +e
  "${EXPORT_COMMAND[@]}" >"$EXPORT_LOG" 2>&1
  EXPORT_EXIT=$?
  set -e
  if [ "$EXPORT_EXIT" -ne 0 ]; then
    tail -80 "$EXPORT_LOG" >&2
    fail "App Store pkg export 失败，完整日志: $EXPORT_LOG"
  fi

  EXPORTED_PKG="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.pkg' -print -quit)"
  [ -n "$EXPORTED_PKG" ] || fail "export 成功但未找到 pkg: $EXPORT_DIR"

  PKG_SIGNATURE="$(pkgutil --check-signature "$EXPORTED_PKG" 2>&1)"
  if ! grep -Eq '3rd Party Mac Developer Installer:|Mac Installer Distribution:' <<<"$PKG_SIGNATURE"; then
    printf '%s\n' "$PKG_SIGNATURE" >&2
    fail "App Store pkg 未使用 Mac Installer Distribution 证书"
  fi
  INSTALLER_AUTHORITY="$(grep -E '3rd Party Mac Developer Installer:|Mac Installer Distribution:' <<<"$PKG_SIGNATURE" | head -1 | sed 's/^[[:space:]]*//')"
  log "Installer 签名: $INSTALLER_AUTHORITY"

  # 展开最终 pkg 再检查内部 App。只看 archive 会把 Automatic Signing 的开发签名
  # 误判为发布失败；最终分发签名、Store profile 与嵌套组件一致性必须以 export 为准。
  EXPANDED_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/starcat-appstore-pkg.XXXXXX")"
  EXPANDED_DIR="${EXPANDED_ROOT}/expanded"
  pkgutil --expand-full "$EXPORTED_PKG" "$EXPANDED_DIR"
  EXPORTED_APP="$(find "$EXPANDED_DIR" -type d -name 'Starcat.app' -print -quit)"
  [ -n "$EXPORTED_APP" ] || fail "pkg 中未找到 Starcat.app"
  EXPORTED_WIDGET="${EXPORTED_APP}/Contents/PlugIns/StarcatWidgets.appex"
  EXPORTED_CODEBASE="${EXPORTED_APP}/Contents/Resources/codebase.bin"
  [ -d "$EXPORTED_WIDGET" ] || fail "pkg 中未找到 StarcatWidgets.appex"
  [ -f "$EXPORTED_CODEBASE" ] || fail "pkg 中未找到 codebase.bin"

  verify_apple_distribution_signature "$EXPORTED_APP" "主 App（export）"
  verify_apple_distribution_signature "$EXPORTED_WIDGET" "Widget（export）"
  verify_apple_distribution_signature "$EXPORTED_CODEBASE" "codebase.bin（export）"
  verify_appstore_provisioning_profile \
    "$EXPORTED_APP" \
    "$EXPORTED_APP/Contents/embedded.provisionprofile" \
    "主 App（export）"
  verify_appstore_provisioning_profile \
    "$EXPORTED_WIDGET" \
    "$EXPORTED_WIDGET/Contents/embedded.provisionprofile" \
    "Widget（export）"
  codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP"
  rm -rf "$EXPANDED_ROOT"

  log "App Store pkg codesign deep strict: OK"
  log "pkg: $EXPORTED_PKG"
  log "export log: $EXPORT_LOG"
}

if [ "${STARCAT_APPSTORE_EXPORT:-0}" = "1" ]; then
  export_appstore_package
fi

if [ "${STARCAT_APPSTORE_SKIP_OPEN:-0}" != "1" ]; then
  log "检查通过，打开 Xcode Organizer archive"
  open "$ARCHIVE_PATH"
fi

log "完成"
log "archive: $ARCHIVE_PATH"
log "log: $BUILD_LOG"
