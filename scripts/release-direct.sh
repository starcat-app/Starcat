#!/usr/bin/env bash
#
# release-direct.sh — Starcat Direct 渠道发布编排脚本。
#
# 用途：
#   串联 Direct 本地打包、Sparkle appcast 生成、DMG/appcast 上传和线上可访问性校验。
#
# 设计约束：
#   - 只编排发布动作，不重复实现构建逻辑；本地打包仍由 package-direct.sh 负责。
#   - appcast 必须和本次 DMG 一起上传，避免 Sparkle 读到已发布但下载包缺失的更新项。
#   - 默认发布到 pages/deploy.sh 使用的同一台服务器和目录，减少多套部署约定。
#
# 用法：
#   ./scripts/release-direct.sh 1.0.1
#
# 可选环境变量：
#   STARCAT_RELEASE_HOST       SSH host，默认 aliyun。
#   STARCAT_RELEASE_WEB_DIR    远程站点根目录，默认 /var/www/starcat。
#   STARCAT_DOWNLOAD_BASE_URL  appcast 下载前缀，默认 https://starcat.ink/downloads/。
#   STARCAT_RELEASE_DRY_RUN=1  只打印将执行的上传命令，不实际上传。
#   STARCAT_NOTARIZE=1         透传给 package-direct.sh，正式公开发布时应启用。
#

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "用法: $0 <version>，例如 $0 1.0.1" >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是 X.Y.Z，例如 1.0.1；当前: $VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAGES_DIR="${PROJECT_ROOT}/pages"
DOWNLOADS_DIR="${PROJECT_ROOT}/dist/direct/downloads"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
APPCAST_PATH="${PAGES_DIR}/appcast.xml"

RELEASE_HOST="${STARCAT_RELEASE_HOST:-aliyun}"
REMOTE_WEB_DIR="${STARCAT_RELEASE_WEB_DIR:-/var/www/starcat}"
DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://starcat.ink/downloads/}"
DRY_RUN="${STARCAT_RELEASE_DRY_RUN:-0}"

log() { printf '[release-direct] %s\n' "$1"; }
fail() { printf '[release-direct] ERROR: %s\n' "$1" >&2; exit 1; }

command -v rsync >/dev/null 2>&1 || fail "rsync 不在 PATH"
command -v ssh >/dev/null 2>&1 || fail "ssh 不在 PATH"
command -v curl >/dev/null 2>&1 || fail "curl 不在 PATH"

run_upload() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[release-direct] DRY RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

cd "$PROJECT_ROOT"

log "本地打包并生成 Sparkle appcast: ${VERSION}"
STARCAT_GENERATE_APPCAST=1 \
STARCAT_DOWNLOAD_BASE_URL="$DOWNLOAD_BASE_URL" \
"${SCRIPT_DIR}/package-direct.sh" "$VERSION"

[ -f "$DMG_PATH" ] || fail "未找到 DMG: $DMG_PATH"
[ -f "$SHA_PATH" ] || fail "未找到 SHA256: $SHA_PATH"
[ -f "$APPCAST_PATH" ] || fail "未找到 appcast: $APPCAST_PATH"

if ! grep -q "Starcat-${VERSION}-arm64.dmg" "$APPCAST_PATH"; then
  fail "appcast 未指向本次 DMG: Starcat-${VERSION}-arm64.dmg"
fi

if ! grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$APPCAST_PATH"; then
  fail "appcast 中的 sparkle:shortVersionString 不是 ${VERSION}"
fi

log "准备远程目录: ${RELEASE_HOST}:${REMOTE_WEB_DIR}/downloads"
run_upload ssh "$RELEASE_HOST" "mkdir -p '$REMOTE_WEB_DIR/downloads'"

log "上传 DMG 和 SHA256"
run_upload rsync -avz --progress \
  "$DMG_PATH" \
  "$SHA_PATH" \
  "$RELEASE_HOST:$REMOTE_WEB_DIR/downloads/"

log "上传 appcast.xml"
run_upload rsync -avz --progress \
  "$APPCAST_PATH" \
  "$RELEASE_HOST:$REMOTE_WEB_DIR/appcast.xml"

log "设置远程文件权限"
run_upload ssh "$RELEASE_HOST" "chmod 644 '$REMOTE_WEB_DIR/appcast.xml' '$REMOTE_WEB_DIR/downloads/$(basename "$DMG_PATH")' '$REMOTE_WEB_DIR/downloads/$(basename "$SHA_PATH")'"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN 完成，未执行线上校验"
  exit 0
fi

APPCAST_URL="https://starcat.ink/appcast.xml"
DMG_URL="${DOWNLOAD_BASE_URL%/}/Starcat-${VERSION}-arm64.dmg"

log "校验线上 appcast: $APPCAST_URL"
curl -fsSI "$APPCAST_URL" >/dev/null || fail "appcast 线上不可访问: $APPCAST_URL"

log "校验线上 DMG: $DMG_URL"
curl -fsSI "$DMG_URL" >/dev/null || fail "DMG 线上不可访问: $DMG_URL"

log "完成"
log "appcast: $APPCAST_URL"
log "dmg: $DMG_URL"
