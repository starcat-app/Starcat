#!/usr/bin/env bash
#
# release-direct.sh — Starcat Direct 渠道一键发布脚本。
#
# 用途：
#   从 git tag 到官网部署、Direct DMG 打包、Sparkle appcast 上传和线上校验，
#   串联一次 Direct 渠道发布所需的人工步骤。
#
# 设计约束：
#   - 构建逻辑仍由 package-direct.sh 负责，本脚本只做发布编排。
#   - 默认走完整发布流程；重跑某一段时用 STARCAT_RELEASE_SKIP_* 显式跳过。
#   - 默认要求 main 分支和干净工作区，避免从临时状态打 tag 或发布不可复现产物。
#   - appcast 使用增量合并，历史版本以 pages/direct/appcast.xml 为准，不依赖本地保留旧 DMG。
#

set -euo pipefail

show_help() {
  cat <<'EOF'
Starcat Direct 一键发布脚本

用法:
  ./scripts/release-direct.sh <version>
  ./scripts/release-direct.sh --help

示例:
  # 完整发布 1.0.0：检查 main/干净工作区，创建并推送 v1.0.0 tag，
  # 部署 nginx 和官网，打包 Direct DMG，上传 appcast/DMG/SHA256 并校验线上 URL。
  STARCAT_NOTARIZE=1 ./scripts/release-direct.sh 1.0.0

  # 演练完整流程，不创建 tag、不推送、不上传、不部署、不做线上校验。
  STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh 1.0.0

  # tag 已经存在且已推送，只重跑官网部署、打包、上传和校验。
  STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh 1.0.0

  # 只重跑 Direct 更新文件发布，跳过 tag、nginx 和官网静态页部署。
  STARCAT_RELEASE_SKIP_TAG=1 \
  STARCAT_RELEASE_SKIP_NGINX=1 \
  STARCAT_RELEASE_SKIP_SITE=1 \
  ./scripts/release-direct.sh 1.0.0

默认流程:
  1. 确认当前分支是 main
  2. 确认工作区干净
  3. 同步远端 tags
  4. 确认 tag v<version> 不存在
  5. 创建 annotated tag
  6. 推送 tag 到 origin
  7. 生成 pages/direct/changelog.html
  8. 部署 pages/direct/starcat.ink.conf 并 reload nginx
  9. 部署官网静态页
 10. 调用 scripts/package-direct.sh <version> 打包 Direct DMG 并生成 appcast
 11. 上传 appcast.xml、DMG、SHA256
 12. 校验线上 appcast、DMG、changelog 可访问

环境变量:
  STARCAT_NOTARIZE=1
      透传给 package-direct.sh。正式公开发布建议开启。

  STARCAT_NOTARY_PROFILE=starcat-notary
      透传给 package-direct.sh。推荐使用 notarytool Keychain profile，避免在命令行暴露密码。
      未设置时默认使用本机已保存的 starcat-notary。

  STARCAT_NOTARY_SUBMISSION_ID=<uuid>
      notarization 已提交但 --wait 超时后的断点续跑入口。脚本会复用现有 DMG，
      查询该 submission 状态；Accepted 后自动 staple、生成 appcast 并继续上传。

  STARCAT_DIRECT_SIGN_IDENTITY="Developer ID Application: liwen gong (8WCUMGCWMB)"
      透传给 package-direct.sh。Direct 公开发布用 Developer ID Application 签名身份；
      默认已使用 Starcat 当前 Developer ID 证书，通常无需手动传。

  STARCAT_RELEASE_ALLOW_UNNOTARIZED=1
      允许发布未公证 DMG。仅内部临时验证使用，正式公开发布不要设置。

  STARCAT_RELEASE_HOST=aliyun2
      SSH host，默认 aliyun2，需要在 ~/.ssh/config 中配置。

  STARCAT_RELEASE_SSH_KEY=~/.ssh/server
      发布服务器私钥。设置后会透传给 pages/deploy.sh，并用于本脚本的 ssh / rsync。

  STARCAT_RELEASE_WEB_DIR=/var/www/starcat
      远程网站根目录，默认 /var/www/starcat。

  STARCAT_DOWNLOAD_BASE_URL=https://starcat.ink/downloads/
      appcast 中使用的 DMG 下载前缀。

  STARCAT_RELEASE_BRANCH=main
      允许发布的分支名，默认 main。

  STARCAT_RELEASE_REMOTE=origin
      tag 推送目标 remote，默认 origin。

  STARCAT_RELEASE_SKIP_FETCH=1
      跳过 git fetch --tags。默认会先同步远端 tag，避免本地不知道远端 tag 已存在。

  STARCAT_RELEASE_SKIP_TAG=1
      跳过创建和推送 tag。用于 tag 已存在时重跑发布。

  STARCAT_RELEASE_SKIP_NGINX=1
      跳过 nginx 配置部署。

  STARCAT_RELEASE_SKIP_SITE=1
      跳过官网 changelog 生成和静态页部署。

  STARCAT_RELEASE_SKIP_BRANCH_CHECK=1
      跳过 main 分支检查。仅临时排查使用。

  STARCAT_RELEASE_SKIP_DIRTY_CHECK=1
      跳过工作区干净检查。仅临时排查使用。

  STARCAT_RELEASE_DRY_RUN=1
      演练模式：打印会执行的 git push、rsync、ssh、部署命令；仍会做本地参数和状态检查，
      但不会创建 tag、推送 tag、部署 nginx、部署官网、打包、上传或线上校验。
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  show_help
  exit 0
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  show_help >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是 X.Y.Z，例如 1.0.0；当前: $VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAGES_DIR="${PROJECT_ROOT}/pages/direct"
DOWNLOADS_DIR="${PROJECT_ROOT}/dist/direct/downloads"
DERIVED_DIR="${PROJECT_ROOT}/dist/direct/DerivedData"
APPCAST_INPUT_DIR="${PROJECT_ROOT}/dist/direct/appcast-input"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
APPCAST_PATH="${PAGES_DIR}/appcast.xml"
CURRENT_APPCAST_PATH="${DOWNLOADS_DIR}/appcast-current.xml"
NOTARY_SUBMISSION_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.notary-submission-id"

RELEASE_BRANCH="${STARCAT_RELEASE_BRANCH:-main}"
RELEASE_REMOTE="${STARCAT_RELEASE_REMOTE:-origin}"
RELEASE_HOST="${STARCAT_RELEASE_HOST:-aliyun2}"
RELEASE_SSH_KEY="${STARCAT_RELEASE_SSH_KEY:-${DEPLOY_SSH_KEY:-}}"
REMOTE_WEB_DIR="${STARCAT_RELEASE_WEB_DIR:-/var/www/starcat}"
DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://starcat.ink/downloads/}"
DRY_RUN="${STARCAT_RELEASE_DRY_RUN:-0}"
TAG_NAME="v${VERSION}"
SSH_CMD=(ssh)
RSYNC_SSH="ssh"
if [ -n "$RELEASE_SSH_KEY" ]; then
  SSH_CMD=(ssh -i "$RELEASE_SSH_KEY")
  RSYNC_SSH="ssh -i $RELEASE_SSH_KEY"
  export DEPLOY_SSH_KEY="$RELEASE_SSH_KEY"
fi

log() { printf '[release-direct] %s\n' "$1"; }
fail() { printf '[release-direct] ERROR: %s\n' "$1" >&2; exit 1; }

run_or_print() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[release-direct] DRY RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 不在 PATH"
}

require_clean_worktree() {
  if [ "${STARCAT_RELEASE_SKIP_DIRTY_CHECK:-0}" = "1" ]; then
    log "跳过工作区干净检查"
    return
  fi

  if [ -n "$(git status --porcelain)" ]; then
    git status --short >&2
    fail "工作区不干净；请先提交或暂存无关改动"
  fi
}

require_branch() {
  if [ "${STARCAT_RELEASE_SKIP_BRANCH_CHECK:-0}" = "1" ]; then
    log "跳过分支检查"
    return
  fi

  local current_branch
  current_branch="$(git branch --show-current)"
  [ "$current_branch" = "$RELEASE_BRANCH" ] \
    || fail "当前分支是 ${current_branch}，发布要求在 ${RELEASE_BRANCH}"
}

create_and_push_tag() {
  if [ "${STARCAT_RELEASE_SKIP_TAG:-0}" = "1" ]; then
    log "跳过 tag 创建和推送: ${TAG_NAME}"
    return
  fi

  if [ "${STARCAT_RELEASE_SKIP_FETCH:-0}" != "1" ]; then
    log "同步远端 tags: ${RELEASE_REMOTE}"
    run_or_print git fetch "$RELEASE_REMOTE" --tags
  fi

  if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null; then
    fail "本地 tag 已存在: ${TAG_NAME}。如需重跑发布，请设置 STARCAT_RELEASE_SKIP_TAG=1"
  fi

  log "创建 tag: ${TAG_NAME}"
  run_or_print git tag -a "$TAG_NAME" -m "Starcat ${VERSION}"

  log "推送 tag: ${RELEASE_REMOTE} ${TAG_NAME}"
  run_or_print git push "$RELEASE_REMOTE" "$TAG_NAME"
}

deploy_nginx() {
  if [ "${STARCAT_RELEASE_SKIP_NGINX:-0}" = "1" ]; then
    log "跳过 nginx 配置部署"
    return
  fi

  log "部署 nginx 配置"
  run_or_print "${PAGES_DIR}/deploy.sh" -n
}

require_notarization_policy() {
  if [ "$DRY_RUN" = "1" ]; then
    return
  fi

  if [ "${STARCAT_NOTARIZE:-0}" = "1" ]; then
    return
  fi

  if [ "${STARCAT_RELEASE_ALLOW_UNNOTARIZED:-0}" = "1" ]; then
    log "允许发布未公证 DMG：STARCAT_RELEASE_ALLOW_UNNOTARIZED=1"
    return
  fi

  fail "Direct 正式发布必须设置 STARCAT_NOTARIZE=1；临时内部验证才允许 STARCAT_RELEASE_ALLOW_UNNOTARIZED=1"
}

deploy_site() {
  if [ "${STARCAT_RELEASE_SKIP_SITE:-0}" = "1" ]; then
    log "跳过官网 changelog 生成和静态页部署"
    return
  fi

  log "生成官网 changelog 页面"
  run_or_print python3 "${PAGES_DIR}/generate-changelog.py"

  log "部署官网静态页"
  run_or_print "${PAGES_DIR}/deploy.sh"
}

package_direct() {
  local submission_id
  submission_id="$(existing_notary_submission_id)"
  if [ -n "$submission_id" ]; then
    resume_notarized_package "$submission_id"
    return
  fi

  log "本地打包并生成 Sparkle appcast: ${VERSION}"
  run_or_print env \
    STARCAT_GENERATE_APPCAST=1 \
    STARCAT_DOWNLOAD_BASE_URL="$DOWNLOAD_BASE_URL" \
    "${SCRIPT_DIR}/package-direct.sh" "$VERSION"
}

existing_notary_submission_id() {
  if [ -n "${STARCAT_NOTARY_SUBMISSION_ID:-}" ]; then
    printf '%s\n' "$STARCAT_NOTARY_SUBMISSION_ID"
    return
  fi

  if [ -f "$NOTARY_SUBMISSION_PATH" ]; then
    head -1 "$NOTARY_SUBMISSION_PATH"
  fi
}

notary_auth_args() {
  if [ -n "${STARCAT_NOTARY_PROFILE:-}" ]; then
    printf '%s\n' "--keychain-profile"
    printf '%s\n' "$STARCAT_NOTARY_PROFILE"
    return
  fi

  if [ -n "${APPLE_ID:-}" ] || [ -n "${APPLE_TEAM_ID:-}" ] || [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    [ -n "${APPLE_ID:-}" ] || fail "STARCAT_NOTARY_SUBMISSION_ID 续跑需要 STARCAT_NOTARY_PROFILE 或 APPLE_ID"
    [ -n "${APPLE_TEAM_ID:-}" ] || fail "STARCAT_NOTARY_SUBMISSION_ID 续跑需要 STARCAT_NOTARY_PROFILE 或 APPLE_TEAM_ID"
    [ -n "${APPLE_APP_PASSWORD:-}" ] || fail "STARCAT_NOTARY_SUBMISSION_ID 续跑需要 STARCAT_NOTARY_PROFILE 或 APPLE_APP_PASSWORD"
    printf '%s\n' "--apple-id"
    printf '%s\n' "$APPLE_ID"
    printf '%s\n' "--team-id"
    printf '%s\n' "$APPLE_TEAM_ID"
    printf '%s\n' "--password"
    printf '%s\n' "$APPLE_APP_PASSWORD"
    return
  fi

  printf '%s\n' "--keychain-profile"
  printf '%s\n' "starcat-notary"
}

resume_notarized_package() {
  [ "$DRY_RUN" = "1" ] && return

  local submission_id="$1"
  [ -f "$DMG_PATH" ] || fail "续跑 notarization 需要现有 DMG: $DMG_PATH"
  [ -f "$SHA_PATH" ] || fail "续跑 notarization 需要现有 SHA256: $SHA_PATH"

  log "续跑 notarization: $submission_id"
  local auth_args=()
  while IFS= read -r arg; do
    auth_args+=("$arg")
  done < <(notary_auth_args)

  local info status
  info="$(xcrun notarytool info "$submission_id" "${auth_args[@]}")"
  printf '%s\n' "$info"
  status="$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)"

  case "$status" in
    Accepted)
      log "notarization 已通过，继续 staple 和本地校验"
      ;;
    "In Progress")
      fail "notarization 仍在处理中，请稍后重跑同一条命令"
      ;;
    Invalid)
      fail "notarization 被拒绝，请执行: xcrun notarytool log $submission_id ${auth_args[*]}"
      ;;
    *)
      fail "无法识别 notarization 状态: ${status:-<empty>}"
      ;;
  esac

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --verbose "$DMG_PATH"

  generate_current_appcast_from_existing_dmg
}

generate_current_appcast_from_existing_dmg() {
  local generate_appcast
  generate_appcast="$(find "$DERIVED_DIR" -path '*/Sparkle/bin/generate_appcast' -type f | head -1)"
  [ -n "$generate_appcast" ] || fail "未找到 Sparkle generate_appcast；请重新跑一次完整打包"

  log "基于现有 DMG 生成当前版本 appcast: $CURRENT_APPCAST_PATH"
  rm -rf "$APPCAST_INPUT_DIR"
  mkdir -p "$APPCAST_INPUT_DIR"
  cp "$DMG_PATH" "$APPCAST_INPUT_DIR/"
  "$generate_appcast" --download-url-prefix "$DOWNLOAD_BASE_URL" "$APPCAST_INPUT_DIR"
  cp "$APPCAST_INPUT_DIR/appcast.xml" "$CURRENT_APPCAST_PATH"
  rm -rf "$APPCAST_INPUT_DIR"
  rm -f "$NOTARY_SUBMISSION_PATH"
}

verify_local_artifacts() {
  [ "$DRY_RUN" = "1" ] && return

  [ -f "$DMG_PATH" ] || fail "未找到 DMG: $DMG_PATH"
  [ -f "$SHA_PATH" ] || fail "未找到 SHA256: $SHA_PATH"
  [ -f "$CURRENT_APPCAST_PATH" ] || fail "未找到当前版本 appcast: $CURRENT_APPCAST_PATH"

  if ! grep -q "Starcat-${VERSION}-arm64.dmg" "$CURRENT_APPCAST_PATH"; then
    fail "当前版本 appcast 未指向本次 DMG: Starcat-${VERSION}-arm64.dmg"
  fi

  if ! grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$CURRENT_APPCAST_PATH"; then
    fail "当前版本 appcast 中的 sparkle:shortVersionString 不是 ${VERSION}"
  fi
}

upload_direct_artifacts() {
  log "准备远程目录: ${RELEASE_HOST}:${REMOTE_WEB_DIR}/downloads"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" "mkdir -p '$REMOTE_WEB_DIR/downloads'"

  log "上传 DMG 和 SHA256"
  run_or_print rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$DMG_PATH" \
    "$SHA_PATH" \
    "$RELEASE_HOST:$REMOTE_WEB_DIR/downloads/"
}

merge_appcast() {
  [ "$DRY_RUN" = "1" ] && return

  log "增量合并当前版本 appcast: ${VERSION}"
  python3 "${SCRIPT_DIR}/merge-appcast.py" \
    --base "$APPCAST_PATH" \
    --incoming "$CURRENT_APPCAST_PATH" \
    --output "$APPCAST_PATH"

  if ! grep -q "Starcat-${VERSION}-arm64.dmg" "$APPCAST_PATH"; then
    fail "合并后的 appcast 未指向本次 DMG: Starcat-${VERSION}-arm64.dmg"
  fi

  log "上传 appcast.xml"
  run_or_print rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$APPCAST_PATH" \
    "$RELEASE_HOST:$REMOTE_WEB_DIR/appcast.xml"

  log "设置远程文件权限"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" "chmod 644 '$REMOTE_WEB_DIR/appcast.xml' '$REMOTE_WEB_DIR/downloads/$(basename "$DMG_PATH")' '$REMOTE_WEB_DIR/downloads/$(basename "$SHA_PATH")'"
}

verify_remote_urls() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN 完成，未执行线上校验"
    return
  fi

  local appcast_url="https://starcat.ink/appcast.xml"
  local dmg_url="${DOWNLOAD_BASE_URL%/}/Starcat-${VERSION}-arm64.dmg"
  local changelog_url="https://starcat.ink/changelog.html"

  log "校验线上 appcast: $appcast_url"
  curl -fsSI "$appcast_url" >/dev/null || fail "appcast 线上不可访问: $appcast_url"

  log "校验线上 DMG: $dmg_url"
  curl -fsSI "$dmg_url" >/dev/null || fail "DMG 线上不可访问: $dmg_url"

  if [ "${STARCAT_RELEASE_SKIP_SITE:-0}" != "1" ]; then
    log "校验线上 changelog: $changelog_url"
    curl -fsSI "$changelog_url" >/dev/null || fail "changelog 线上不可访问: $changelog_url"
  fi

  log "完成"
  log "tag: ${TAG_NAME}"
  log "appcast: $appcast_url"
  log "dmg: $dmg_url"
  log "changelog: $changelog_url"
}

main() {
  require_command git
  require_command python3
  require_command rsync
  require_command ssh
  require_command curl

  cd "$PROJECT_ROOT"

  require_branch
  require_clean_worktree
  require_notarization_policy
  create_and_push_tag
  deploy_nginx
  deploy_site
  package_direct
  verify_local_artifacts
  upload_direct_artifacts
  merge_appcast
  verify_remote_urls
}

main
