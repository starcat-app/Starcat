#!/usr/bin/env bash
#
# release-direct-development.sh — 发布 Direct Beta 版并更新独立 Sparkle appcast。
#
# Beta 版仍是 Developer ID 签名并经过 Apple 公证的 Release 构建，只是 GitHub Release
# 标记为 prerelease，且只公布到 appcast-development.xml。它不会修改正式 appcast、
# 官网最新版、Homebrew 或其它正式发布元数据；成功后只登记源目标节为已发布。
# 脚本名、环境变量和 feed 地址保留既有标识，避免中断已安装客户端与运维入口。

set -euo pipefail

show_help() {
  cat <<'EOF'
Starcat Direct Beta 版发布脚本

用法:
  ./scripts/release-direct-development.sh <X.Y.Z-beta.N> [--resume]

示例:
  STARCAT_NOTARIZE=1 ./scripts/release-direct-development.sh 1.9.3-beta.1

  # 只检查参数、分支和工作区并打印副作用命令。
  STARCAT_DEVELOPMENT_RELEASE_DRY_RUN=1 \
    ./scripts/release-direct-development.sh 1.9.3-beta.1

  # 已有最终产物：只恢复 GitHub 和 Beta 更新源，允许源码工作区有并行改动。
  ./scripts/release-direct-development.sh 1.9.3-beta.1 --resume

关键约束:
  - 新构建要求 dev 分支和干净工作区；--resume 校验原 tag 和最终产物。
  - 新构建必须设置 STARCAT_NOTARIZE=1；恢复会直接校验已有公证票据。
  - 只创建 GitHub prerelease 并更新 appcast-development.xml。
  - 不更新 appcast.xml、官网最新版或 Homebrew；成功后去掉目标 Changelog 的待发布标记。
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  show_help
  exit 0
fi

DEVELOPMENT_VERSION="${1:-}"
if ! [[ "$DEVELOPMENT_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-beta\.([1-9][0-9]*)$ ]]; then
  echo "Beta 版本号必须是 X.Y.Z-beta.N，例如 1.9.3-beta.1；当前: ${DEVELOPMENT_VERSION:-<empty>}" >&2
  exit 1
fi
MARKETING_VERSION="${BASH_REMATCH[1]}"
if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--resume" ]; }; then
  echo "未知参数；仅支持在版本号后添加 --resume" >&2
  exit 1
fi
if [ "${2:-}" = "--resume" ]; then
  export STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE_ROOT="${STARCAT_SITE_ROOT:-${PROJECT_ROOT}/supports/starcat-site}"
PAGES_DIR="${SITE_ROOT}/direct"
DIST_DIR="${PROJECT_ROOT}/dist/direct-development"
DOWNLOADS_DIR="${DIST_DIR}/downloads"
RELEASE_NOTES_DIR="${DOWNLOADS_DIR}/release-notes-${DEVELOPMENT_VERSION}"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${MARKETING_VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
CURRENT_APPCAST_PATH="${DOWNLOADS_DIR}/appcast-current.xml"
DEVELOPMENT_APPCAST_PATH="${PAGES_DIR}/appcast-development.xml"
TAG_NAME="v${DEVELOPMENT_VERSION}"
DOWNLOAD_BASE_URL="https://github.com/starcat-app/Starcat/releases/download/${TAG_NAME}/"
RELEASE_BRANCH="${STARCAT_DEVELOPMENT_RELEASE_BRANCH:-dev}"
RELEASE_REMOTE="${STARCAT_DEVELOPMENT_RELEASE_REMOTE:-origin}"
RELEASE_HOST="${STARCAT_RELEASE_HOST:-aliyun2}"
RELEASE_SSH_KEY="${STARCAT_RELEASE_SSH_KEY:-${DEPLOY_SSH_KEY:-}}"
REMOTE_WEB_DIR="${STARCAT_RELEASE_WEB_DIR:-/var/www/starcat}"
DRY_RUN="${STARCAT_DEVELOPMENT_RELEASE_DRY_RUN:-0}"
SSH_CMD=(ssh)
RSYNC_SSH="ssh"

if [ -n "$RELEASE_SSH_KEY" ]; then
  SSH_CMD=(ssh -i "$RELEASE_SSH_KEY")
  RSYNC_SSH="ssh -i $RELEASE_SSH_KEY"
fi

log() { printf '[release-direct-development] %s\n' "$1"; }
fail() { printf '[release-direct-development] ERROR: %s\n' "$1" >&2; exit 1; }

run_or_print() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[release-direct-development] DRY RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 不在 PATH"
}

require_release_state() {
  [ -d "$SITE_ROOT/.git" ] || fail "未找到独立官网仓库: $SITE_ROOT"
  [ -d "$PAGES_DIR" ] || fail "未找到 Direct 官网目录: $PAGES_DIR"

  # 只上传已固定的产物时不读取当前源码状态，更不要求提交或 stash 并行改动。
  if [ "${STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS:-0}" = "1" ]; then
    run_or_print python3 "$SCRIPT_DIR/verify-direct-release-artifacts.py" \
      --version "$DEVELOPMENT_VERSION" --dmg "$DMG_PATH" --sha256 "$SHA_PATH" \
      --appcast "$CURRENT_APPCAST_PATH" --remote "$RELEASE_REMOTE"
    # 旧产物缺少说明快照时停止，不能用当前工作稿伪造当次 App 内置说明。
    run_or_print python3 "$SCRIPT_DIR/release_changelog.py" check \
      --source-root "$RELEASE_NOTES_DIR" --version "$DEVELOPMENT_VERSION"
    return
  fi

  local current_branch
  current_branch="$(git branch --show-current)"
  [ "$current_branch" = "$RELEASE_BRANCH" ] \
    || fail "当前分支是 ${current_branch}，Beta 版发布要求在 ${RELEASE_BRANCH}"

  if [ -n "$(git status --porcelain)" ]; then
    git status --short >&2
    fail "工作区不干净；Beta 版必须来自可复现提交"
  fi

  [ "${STARCAT_NOTARIZE:-0}" = "1" ] || [ "$DRY_RUN" = "1" ] \
    || fail "Beta 版外部分发也必须设置 STARCAT_NOTARIZE=1"
}

prepare_release_notes() {
  # 在写 tag 或构建之前验证并固定两种语言，未来版本仍留在源工作稿中。
  run_or_print python3 "$SCRIPT_DIR/release_changelog.py" prepare \
    --source-root "$PAGES_DIR" --output-root "$RELEASE_NOTES_DIR" \
    --version "$DEVELOPMENT_VERSION"
}

create_and_push_tag() {
  if [ "${STARCAT_DEVELOPMENT_RELEASE_SKIP_TAG:-0}" = "1" ]; then
    log "跳过 tag 创建和推送: $TAG_NAME"
    return
  fi

  run_or_print git fetch "$RELEASE_REMOTE" --tags
  if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null; then
    fail "本地 tag 已存在: $TAG_NAME；最终产物已就绪请使用 --resume；尚需打包才设置 STARCAT_DEVELOPMENT_RELEASE_SKIP_TAG=1"
  fi
  run_or_print git tag -a "$TAG_NAME" -m "Starcat ${DEVELOPMENT_VERSION}"
  run_or_print git push "$RELEASE_REMOTE" "$TAG_NAME"
}

package_development() {
  if [ "${STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS:-0}" = "1" ]; then
    log "复用已公证的 Beta 版产物，不重新签名或 staple"
    return
  fi

  run_or_print env \
    STARCAT_NOTARIZE=1 \
    STARCAT_GENERATE_APPCAST=1 \
    STARCAT_RELEASE_VERSION="$DEVELOPMENT_VERSION" \
    STARCAT_RELEASE_CHANGELOG_DIR="$RELEASE_NOTES_DIR" \
    STARCAT_DIRECT_DIST_DIR="$DIST_DIR" \
    STARCAT_DOWNLOAD_BASE_URL="$DOWNLOAD_BASE_URL" \
    "$SCRIPT_DIR/package-direct.sh" "$MARKETING_VERSION"
}

verify_local_artifacts() {
  [ "$DRY_RUN" = "1" ] && return
  [ -f "$DMG_PATH" ] || fail "未找到 Beta 版 DMG: $DMG_PATH"
  [ -f "$SHA_PATH" ] || fail "未找到 Beta 版 SHA256: $SHA_PATH"
  [ -f "$CURRENT_APPCAST_PATH" ] || fail "未找到 Beta 版当前 appcast: $CURRENT_APPCAST_PATH"

  grep -Fq "${DOWNLOAD_BASE_URL}Starcat-${MARKETING_VERSION}-arm64.dmg" "$CURRENT_APPCAST_PATH" \
    || fail "Beta 版 appcast 下载地址与 prerelease tag 不一致"
  grep -Fq "<sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>" "$CURRENT_APPCAST_PATH" \
    || fail "Beta 版 appcast 营销版本不正确"
}

publish_github_prerelease() {
  run_or_print python3 "$SCRIPT_DIR/publish-direct-github-release.py" \
    --version "$DEVELOPMENT_VERSION" \
    --marketing-version "$MARKETING_VERSION" \
    --prerelease \
    --dmg "$DMG_PATH" \
    --sha256 "$SHA_PATH" \
    --changelog "$RELEASE_NOTES_DIR/CHANGELOG.md"
}

merge_development_appcast() {
  [ "$DRY_RUN" = "1" ] && return
  python3 "$SCRIPT_DIR/merge-appcast.py" \
    --base "$DEVELOPMENT_APPCAST_PATH" \
    --incoming "$CURRENT_APPCAST_PATH" \
    --output "$DEVELOPMENT_APPCAST_PATH"
  # 当前 item 在打包时已使用固定快照生成说明；合并保留原说明，不重写历史 item。
}

publish_development_appcast() {
  local dmg_url="${DOWNLOAD_BASE_URL}Starcat-${MARKETING_VERSION}-arm64.dmg"
  # 本机已上传并下载校验附件；服务器到 GitHub 的出口故障不能冒充附件不存在。
  # 仍需公开下载地址成功，且只对网络故障做有限重试。
  run_or_print curl -fsSLI --connect-timeout 15 --max-time 45 --retry 2 \
    --retry-max-time 90 "$dmg_url" >/dev/null
  log "上传 Beta 更新源"
  run_or_print rsync -avz --progress -e "$RSYNC_SSH" \
    "$DEVELOPMENT_APPCAST_PATH" \
    "$RELEASE_HOST:$REMOTE_WEB_DIR/appcast-development.xml"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" \
    "chmod 644 '$REMOTE_WEB_DIR/appcast-development.xml'"
}

verify_development_appcast() {
  [ "$DRY_RUN" = "1" ] && return
  # 用临时文件回读线上清单，失败不覆盖本地已生成的更新源。
  local downloaded
  downloaded="$(mktemp)"
  if ! curl -fsSL --connect-timeout 15 --max-time 45 --retry 2 \
    --retry-max-time 90 "https://starcat.ink/appcast-development.xml" > "$downloaded"; then
    rm -f "$downloaded"
    fail "无法回读线上 Beta 更新源；GitHub Release 已发布，只需恢复更新源"
  fi
  if ! cmp -s "$downloaded" "$DEVELOPMENT_APPCAST_PATH"; then
    rm -f "$downloaded"
    fail "线上 Beta 更新源与本地不同；停止重试并检查缓存或上传结果"
  fi
  rm -f "$downloaded"
  log "线上 Beta 更新源核验通过"
}

main() {
  require_command git
  require_command gh
  require_command python3
  require_command rsync
  require_command ssh
  require_command curl

  cd "$PROJECT_ROOT"
  require_release_state
  run_or_print gh auth status
  if [ "${STARCAT_DEVELOPMENT_RELEASE_REUSE_ARTIFACTS:-0}" != "1" ]; then
    prepare_release_notes
    create_and_push_tag
    package_development
  else
    log "恢复已有产物，仅续传 GitHub 和 Beta 更新源"
  fi
  verify_local_artifacts
  publish_github_prerelease
  merge_development_appcast
  publish_development_appcast
  verify_development_appcast
  run_or_print python3 "$SCRIPT_DIR/release_changelog.py" finalize \
    --source-root "$PAGES_DIR" --output-root "$RELEASE_NOTES_DIR" \
    --version "$DEVELOPMENT_VERSION"
  log "Beta 版发布完成: $DEVELOPMENT_VERSION"
}

main
