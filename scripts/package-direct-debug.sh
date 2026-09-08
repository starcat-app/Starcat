#!/usr/bin/env bash
#
# package-direct-debug.sh — 生成只供本地测试的 Starcat Direct Debug DMG。
#
# 这个入口复用 `run-debug-direct.sh --build-only`，确保测试包与日常 Direct Debug
# 使用相同的非沙箱、测试 License API、独立 bundle id 和签名校验。它不会公证、
# 生成 appcast、创建 tag 或上传任何内容，也不能替代正式 `package-direct.sh`。

set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是 X.Y.Z，例如 1.6.1；当前: ${VERSION:-<empty>}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-NoSandbox"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug/Starcat.app"
SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/Starcat"
DIST_DIR="$PROJECT_ROOT/dist/direct-debug"
STAGING_DIR="$DIST_DIR/staging"
DOWNLOADS_DIR="$DIST_DIR/downloads"
STAGED_APP="$STAGING_DIR/Starcat Debug.app"
DMG_PATH="$DOWNLOADS_DIR/Starcat-${VERSION}-debug-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
DIRECT_DEBUG_BUNDLE_ID="com.starcat.app.direct.debug"

log() { printf '[direct-debug] %s\n' "$1"; }
fail() { printf '[direct-debug] ERROR: %s\n' "$1" >&2; exit 1; }

command -v hdiutil >/dev/null 2>&1 || fail "hdiutil 不在 PATH"
command -v shasum >/dev/null 2>&1 || fail "shasum 不在 PATH"

cd "$PROJECT_ROOT"

log "构建并校验 StarcatDirect Debug（不会启动 App）"
# marketing version 必须显式覆盖最新正式 tag；否则 Debug 产物仍会显示 1.6.0。
STARCAT_MARKETING_VERSION_OVERRIDE="$VERSION" \
  bash "$SCRIPT_DIR/run-debug-direct.sh" --build-only

[ -d "$SOURCE_APP" ] || fail "未找到 Direct Debug App: $SOURCE_APP"
[ -x "$SOURCE_EXECUTABLE" ] || fail "Direct Debug 可执行文件不存在或不可执行"

APP_VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$APP_VERSION" = "$VERSION" ] || \
  fail "CFBundleShortVersionString 应为 $VERSION，实际为 ${APP_VERSION:-<missing>}"

BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$BUNDLE_ID" = "$DIRECT_DEBUG_BUNDLE_ID" ] || \
  fail "Direct Debug bundle id 应为 $DIRECT_DEBUG_BUNDLE_ID，实际为 ${BUNDLE_ID:-<missing>}"

DIST_VALUE=$(/usr/libexec/PlistBuddy \
  -c "Print :STARCAT_DISTRIBUTION" \
  "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$DIST_VALUE" = "direct" ] || \
  fail "STARCAT_DISTRIBUTION 应为 direct，实际为 ${DIST_VALUE:-<missing>}"

LICENSE_API_ENV=$(/usr/libexec/PlistBuddy \
  -c "Print :STARCAT_LICENSE_API_ENVIRONMENT" \
  "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$LICENSE_API_ENV" = "test" ] || \
  fail "Direct Debug 必须连接测试 License API，实际为 ${LICENSE_API_ENV:-<missing>}"

[ -d "$SOURCE_APP/Contents/Frameworks/Sparkle.framework" ] || \
  fail "Direct Debug 包缺少 Sparkle.framework"

ENTITLEMENTS="$(codesign -d --entitlements :- "$SOURCE_APP" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<<"$ENTITLEMENTS"; then
  fail "Direct Debug 包检测到 sandbox entitlement"
fi

codesign --verify --deep --strict "$SOURCE_APP" || \
  fail "Direct Debug App 签名校验失败"

# 菜单标题是 DebugMenuCommands 中的稳定字面量；直接检查实际 Mach-O，避免只凭
# `-configuration Debug` 就误报测试包包含调试菜单。这里不用 `strings | grep -q`：
# `set -o pipefail` 下 grep 提前退出会让 strings 收到 SIGPIPE，反而把真实命中误判失败。
if ! grep -aFq "Who's Your Daddy" "$SOURCE_EXECUTABLE"; then
  fail "Mach-O 中未找到 Debug 菜单，拒绝生成测试 DMG"
fi

log "生成本地测试 DMG"
mkdir -p "$DIST_DIR" "$DOWNLOADS_DIR"
rm -rf "$STAGING_DIR"
rm -f "$DMG_PATH" "$SHA_PATH"
mkdir -p "$STAGING_DIR"
ditto "$SOURCE_APP" "$STAGED_APP"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Starcat ${VERSION} Debug" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null || fail "DMG 校验失败"
(
  cd "$DOWNLOADS_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" >"$(basename "$SHA_PATH")"
)

# 最后实际挂载一次并复核包内 App，证明生成的 DMG 可读且没有漏装目标产物。
MOUNT_POINT="$(mktemp -d /tmp/starcat-direct-debug-mount.XXXXXX)"
DMG_ATTACHED=0
cleanup_mount() {
  if [ "$DMG_ATTACHED" -eq 1 ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT

hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=1
MOUNTED_APP="$MOUNT_POINT/Starcat Debug.app"
[ -d "$MOUNTED_APP" ] || fail "DMG 中缺少 Starcat Debug.app"
codesign --verify --deep --strict "$MOUNTED_APP" || fail "DMG 内 App 签名校验失败"

MOUNTED_VERSION=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" \
  "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$MOUNTED_VERSION" = "$VERSION" ] || \
  fail "DMG 内 App 版本应为 $VERSION，实际为 ${MOUNTED_VERSION:-<missing>}"

hdiutil detach "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=0
rmdir "$MOUNT_POINT"
trap - EXIT

log "测试包生成成功"
echo "    DMG: $DMG_PATH"
echo "    SHA: $SHA_PATH"
echo "    version: $VERSION"
echo "    bundle id: $DIRECT_DEBUG_BUNDLE_ID"
echo "    license api: test"
echo "    notarization: NOT RUN"
