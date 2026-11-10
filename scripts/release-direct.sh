#!/usr/bin/env bash
#
# release-direct.sh — Starcat Direct 渠道一键发布脚本。
#
# 用途：
#   从 git tag 到 Direct 打包、GitHub Release、官网 appcast 上传和线上校验，
#   串联一次 Direct 渠道发布所需的人工步骤。
#
# 设计约束：
#   - 构建逻辑仍由 package-direct.sh 负责，本脚本只做发布编排。
#   - 默认走完整发布流程；重跑某一段时用 STARCAT_RELEASE_SKIP_* 显式跳过。
#   - 新构建要求 main 分支和干净工作区；--resume 只校验并上传原 tag 的最终产物。
#   - appcast 使用增量合并，历史版本以 supports/starcat-site/direct/appcast.xml 为准，不依赖本地保留旧 DMG。
#   - appcast item 会注入 CHANGELOG 衍生的 Sparkle 更新说明（description CDATA）。
#

set -euo pipefail

show_help() {
  cat <<'EOF'
Starcat Direct 一键发布脚本

用法:
  ./scripts/release-direct.sh <version> [--resume]
  ./scripts/release-direct.sh --help

示例:
  # 完整发布 1.0.0：检查 main/干净工作区，创建并推送 v1.0.0 tag，
  # 打包 Direct DMG，生成 appcast，发布 GitHub 附件后更新官网和 appcast。
  STARCAT_NOTARIZE=1 ./scripts/release-direct.sh 1.0.0

  # 演练完整流程，不创建 tag、不推送、不上传、不部署、不做线上校验。
  STARCAT_RELEASE_DRY_RUN=1 ./scripts/release-direct.sh 1.0.0

  # 已有最终产物：只恢复 GitHub 与更新源，保留当前源码工作区。
  ./scripts/release-direct.sh 1.0.0 --resume

  # tag 已经存在且已推送，但尚需打包/续跑公证；已有最终产物应使用 --resume。
  STARCAT_NOTARIZE=1 STARCAT_RELEASE_SKIP_TAG=1 ./scripts/release-direct.sh 1.0.0

默认流程:
  1. 确认当前分支是 main
  2. 确认工作区干净
  3. 同步远端 tags
  4. 确认 tag v<version> 不存在
  5. 创建 annotated tag
  6. 推送 tag 到 origin
  7. 调用 package-direct.sh 打包、公证并生成当前版本 appcast
  8. 校验本地产物，合并本地 appcast 历史版本
  9. 上传 GitHub Release 草稿附件，下载校验 SHA256 后公开 Release
 10. 生成并部署官网 changelog / 静态页 / nginx
 11. 确认 GitHub 下载可用后，只向官网上传 appcast.xml
 12. 校验线上 appcast、GitHub DMG、changelog 可访问

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
      允许发布未公证 DMG，并忽略环境变量或本地文件中的旧 Submission ID。
      仅内部临时验证使用，正式公开发布不要设置。

  STARCAT_RELEASE_HOST=aliyun2
      SSH host，默认 aliyun2，需要在 ~/.ssh/config 中配置。

  STARCAT_RELEASE_SSH_KEY=~/.ssh/server
      发布服务器私钥。设置后会透传给 starcat-site/direct/deploy.sh，并用于本脚本的 ssh / rsync。

  STARCAT_RELEASE_WEB_DIR=/var/www/starcat
      远程网站根目录，默认 /var/www/starcat。

  STARCAT_SITE_ROOT=/path/to/starcat-site
      独立官网仓库路径，默认使用主仓库下的 supports/starcat-site。

  STARCAT_DOWNLOAD_BASE_URL=https://github.com/starcat-app/Starcat/releases/download/v<version>/
      appcast 中使用的 DMG 下载前缀，默认随当前版本生成。
      本脚本通过本机 gh 发布 starcat-app/Starcat 的同版本 DMG/SHA256。

  STARCAT_RELEASE_REUSE_ARTIFACTS=1
      等同 --resume：校验原 tag/最终产物后只恢复 GitHub 和 appcast。
      不检查当前分支或源码脏状态，不打 tag、不打包、不部署官网静态页。

  STARCAT_RELEASE_BRANCH=main
      允许发布的分支名，默认 main。

  STARCAT_RELEASE_REMOTE=origin
      tag 推送目标 remote，默认 origin。

  STARCAT_RELEASE_SKIP_FETCH=1
      跳过 git fetch --tags。默认会先同步远端 tag，避免本地不知道远端 tag 已存在。

  STARCAT_RELEASE_SKIP_TAG=1
      跳过创建和推送 tag，仍会进入打包/公证。已有最终产物请使用 --resume。

  STARCAT_RELEASE_SKIP_NGINX=1
      兼容旧变量；由于 starcat-site/direct/deploy.sh 已合并 nginx 与静态资源部署，
      设置后会跳过整个官网部署。

  STARCAT_RELEASE_SKIP_SITE=1
      跳过官网 changelog 生成、nginx 和静态页部署。

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
if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--resume" ]; }; then
  echo "未知参数；仅支持在版本号后添加 --resume" >&2
  exit 1
fi
if [ "${2:-}" = "--resume" ]; then
  export STARCAT_RELEASE_REUSE_ARTIFACTS=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# 官网已拆为独立仓库；保留环境变量覆盖，便于维护者把 starcat-site 放在其他位置。
STARCAT_SITE_ROOT="${STARCAT_SITE_ROOT:-${PROJECT_ROOT}/supports/starcat-site}"
PAGES_DIR="${STARCAT_SITE_ROOT}/direct"
DOWNLOADS_DIR="${PROJECT_ROOT}/dist/direct/downloads"
DERIVED_DIR="${PROJECT_ROOT}/dist/direct/DerivedData"
APPCAST_INPUT_DIR="${PROJECT_ROOT}/dist/direct/appcast-input"
DMG_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
APPCAST_PATH="${PAGES_DIR}/appcast.xml"
DEVELOPMENT_APPCAST_PATH="${PAGES_DIR}/appcast-development.xml"
CURRENT_APPCAST_PATH="${DOWNLOADS_DIR}/appcast-current.xml"
NOTARY_SUBMISSION_PATH="${DOWNLOADS_DIR}/Starcat-${VERSION}-arm64.notary-submission-id"

RELEASE_BRANCH="${STARCAT_RELEASE_BRANCH:-main}"
RELEASE_REMOTE="${STARCAT_RELEASE_REMOTE:-origin}"
RELEASE_HOST="${STARCAT_RELEASE_HOST:-aliyun2}"
RELEASE_SSH_KEY="${STARCAT_RELEASE_SSH_KEY:-${DEPLOY_SSH_KEY:-}}"
REMOTE_WEB_DIR="${STARCAT_RELEASE_WEB_DIR:-/var/www/starcat}"
# 官网与 Sparkle 均读取 appcast；按当前版本固定 Release tag，避免下次发版切回旧下载源。
DOWNLOAD_BASE_URL="${STARCAT_DOWNLOAD_BASE_URL:-https://github.com/starcat-app/Starcat/releases/download/v${VERSION}/}"
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
    fail "本地 tag 已存在: ${TAG_NAME}。最终产物已就绪请使用 --resume；尚需打包/公证才设置 STARCAT_RELEASE_SKIP_TAG=1"
  fi

  log "创建 tag: ${TAG_NAME}"
  run_or_print git tag -a "$TAG_NAME" -m "Starcat ${VERSION}"

  log "推送 tag: ${RELEASE_REMOTE} ${TAG_NAME}"
  run_or_print git push "$RELEASE_REMOTE" "$TAG_NAME"
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
  if [ "${STARCAT_RELEASE_SKIP_NGINX:-0}" = "1" ]; then
    log "跳过官网部署：deploy.sh 已合并 nginx + 静态资源，STARCAT_RELEASE_SKIP_NGINX=1 时不单独部署静态页"
    return
  fi
  if [ "${STARCAT_RELEASE_SKIP_SITE:-0}" = "1" ]; then
    log "跳过官网 changelog 生成、nginx 和静态页部署"
    return
  fi

  log "生成官网 changelog 页面"
  run_or_print python3 "${PAGES_DIR}/generate-changelog.py"

  log "部署官网 nginx 配置和静态页"
  run_or_print "${PAGES_DIR}/deploy.sh"
}

package_direct() {
  if [ "${STARCAT_RELEASE_REUSE_ARTIFACTS:-0}" = "1" ]; then
    log "复用最终分发产物；上传重试期间不得重新签名或 staple 改变 DMG"
    if [ "${STARCAT_NOTARIZE:-0}" = "1" ]; then
      run_or_print xcrun stapler validate "$DMG_PATH"
      run_or_print spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
    fi
    return
  fi

  if [ "${STARCAT_NOTARIZE:-0}" = "1" ]; then
    local submission_id
    submission_id="$(existing_notary_submission_id)"
    if [ -n "$submission_id" ]; then
      resume_notarized_package "$submission_id"
      return
    fi
  elif [ "${STARCAT_RELEASE_ALLOW_UNNOTARIZED:-0}" = "1" ]; then
    # 临时未公证模式必须忽略残留 ID，否则旧任务会抢先进入续跑分支，
    # 导致 Apple 已清理的 Submission 阻断后续打包和上传流程。
    log "未公证模式：忽略已有 notarization Submission ID"
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
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

  # 断点续跑会在这里首次写入公证票据；重新计算 SHA，避免上传 staple 前的旧摘要。
  local sha256
  sha256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  printf '%s  %s\n' "$sha256" "$(basename "$DMG_PATH")" > "$SHA_PATH"

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
  # 与 package-direct.sh 一致：补上 CHANGELOG 衍生的更新说明，避免断点续跑路径漏注。
  log "注入 Sparkle 更新说明: ${VERSION}"
  python3 "${SCRIPT_DIR}/inject-appcast-release-notes.py" \
    --appcast "$CURRENT_APPCAST_PATH" \
    --version "$VERSION"
  rm -f "$NOTARY_SUBMISSION_PATH"
}

verify_local_artifacts() {
  [ "$DRY_RUN" = "1" ] && return

  [ -f "$DMG_PATH" ] || fail "未找到 DMG: $DMG_PATH"
  [ -f "$SHA_PATH" ] || fail "未找到 SHA256: $SHA_PATH"
  [ -f "$CURRENT_APPCAST_PATH" ] || fail "未找到当前版本 appcast: $CURRENT_APPCAST_PATH"

  # 复用产物也必须匹配本次下载源和最终 DMG，防止旧清单被带入新的 GitHub 发布。
  python3 - "$CURRENT_APPCAST_PATH" "$VERSION" "$DOWNLOAD_BASE_URL" "$DMG_PATH" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path, version, base_url, dmg = sys.argv[1:]
items = ET.parse(path).findall("./channel/item")
if len(items) != 1:
    raise SystemExit("当前版本 appcast 必须恰好包含一个 item")
enclosure = items[0].find("enclosure")
expected_url = f"{base_url.rstrip('/')}/Starcat-{version}-arm64.dmg"
if enclosure is None or enclosure.get("url") != expected_url:
    raise SystemExit("当前版本 appcast 下载地址与本次发布不一致")
if enclosure.get("length") != str(Path(dmg).stat().st_size):
    raise SystemExit("当前版本 appcast 大小与最终 DMG 不一致")
PY

  if ! grep -q "Starcat-${VERSION}-arm64.dmg" "$CURRENT_APPCAST_PATH"; then
    fail "当前版本 appcast 未指向本次 DMG: Starcat-${VERSION}-arm64.dmg"
  fi

  if ! grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$CURRENT_APPCAST_PATH"; then
    fail "当前版本 appcast 中的 sparkle:shortVersionString 不是 ${VERSION}"
  fi

  # inject-appcast-release-notes.py 会为更新说明写入 xml:lang；门禁应验证
  # description + CDATA 的结构，不能把合法的 XML 属性误判为缺少说明。
  if ! grep -Eq '<description[^>]*><!\[CDATA\[' "$CURRENT_APPCAST_PATH"; then
    fail "当前版本 appcast 缺少 Sparkle 更新说明（description CDATA）"
  fi
}

publish_github_release() {
  log "上传并核验 GitHub Release 的 DMG/SHA256"
  run_or_print python3 "${SCRIPT_DIR}/publish-direct-github-release.py" \
    --version "$VERSION" \
    --dmg "$DMG_PATH" \
    --sha256 "$SHA_PATH" \
    --changelog "${PROJECT_ROOT}/supports/starcat-site/direct/CHANGELOG.md"
}

merge_appcast() {
  [ "$DRY_RUN" = "1" ] && return

  # 本地清单先生成；此时 GitHub 附件尚可不存在，不在这里执行远端校验或上传。
  log "增量合并当前版本 appcast: ${VERSION}"
  python3 "${SCRIPT_DIR}/merge-appcast.py" \
    --base "$APPCAST_PATH" \
    --incoming "$CURRENT_APPCAST_PATH" \
    --output "$APPCAST_PATH"

  # Beta 版用户也必须接收后续正式版。正式 item 会按营销版本替换同版本的
  # Beta item，但正式 appcast 永远不会反向合入 Beta 版条目。
  log "同步正式版本到 Beta 版 appcast: ${VERSION}"
  python3 "${SCRIPT_DIR}/merge-appcast.py" \
    --base "$DEVELOPMENT_APPCAST_PATH" \
    --incoming "$CURRENT_APPCAST_PATH" \
    --output "$DEVELOPMENT_APPCAST_PATH"

  # 合并后再按 CHANGELOG 全量回填，历史版本说明与当前版本保持一致来源。
  log "回填 appcast 更新说明"
  python3 "${SCRIPT_DIR}/inject-appcast-release-notes.py" \
    --appcast "$APPCAST_PATH"
  python3 "${SCRIPT_DIR}/inject-appcast-release-notes.py" \
    --appcast "$DEVELOPMENT_APPCAST_PATH"

  if ! grep -q "Starcat-${VERSION}-arm64.dmg" "$APPCAST_PATH"; then
    fail "合并后的 appcast 未指向本次 DMG: Starcat-${VERSION}-arm64.dmg"
  fi

  if ! grep -Eq '<description[^>]*><!\[CDATA\[' "$APPCAST_PATH"; then
    fail "合并后的 appcast 缺少 Sparkle 更新说明（description CDATA）"
  fi
}

publish_appcast() {
  # Release 附件已经校验并公开，再让官网和旧客户端看到新版本。
  verify_public_url "DMG（发布 appcast 前检查）" "${DOWNLOAD_BASE_URL%/}/Starcat-${VERSION}-arm64.dmg"
  log "上传 appcast.xml"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" "mkdir -p '$REMOTE_WEB_DIR'"
  run_or_print rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$APPCAST_PATH" \
    "$RELEASE_HOST:$REMOTE_WEB_DIR/appcast.xml"
  run_or_print rsync -avz --progress \
    -e "$RSYNC_SSH" \
    "$DEVELOPMENT_APPCAST_PATH" \
    "$RELEASE_HOST:$REMOTE_WEB_DIR/appcast-development.xml"

  log "设置远程文件权限"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" "chmod 644 '$REMOTE_WEB_DIR/appcast.xml'"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" "chmod 644 '$REMOTE_WEB_DIR/appcast-development.xml'"
}

verify_remote_urls() {
  local appcast_url="https://starcat.ink/appcast.xml"
  local development_appcast_url="https://starcat.ink/appcast-development.xml"
  local dmg_url="${DOWNLOAD_BASE_URL%/}/Starcat-${VERSION}-arm64.dmg"
  local changelog_url="https://starcat.ink/changelog.html"

  verify_public_url "appcast" "$appcast_url"
  verify_public_url "development appcast" "$development_appcast_url"
  verify_public_url "DMG" "$dmg_url"

  if [ "${STARCAT_RELEASE_SKIP_SITE:-0}" != "1" ]; then
    verify_public_url "changelog" "$changelog_url"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN 完成，未执行线上校验"
    return
  fi

  log "完成"
  log "tag: ${TAG_NAME}"
  log "appcast: $appcast_url"
  log "dmg: $dmg_url"
  log "changelog: $changelog_url"
}

verify_public_url() {
  local label="$1"
  local url="$2"
  local remote_command

  # 从本机验证实际下载链路；本机代理异常时才改从服务器复核。
  # 两个出口都有限超时，不能因服务器访问 GitHub 的 504 一直卡住已完成的上传。
  log "本机校验线上 ${label}: $url"
  if run_or_print curl -fsSLI --connect-timeout 15 --max-time 45 \
    --retry 2 --retry-max-time 90 "$url" >/dev/null; then
    return
  fi
  printf -v remote_command \
    'curl -fsSLI --connect-timeout 15 --max-time 45 --retry 2 --retry-max-time 90 %q >/dev/null' \
    "$url"

  log "从发布服务器校验线上 ${label}: $url"
  run_or_print "${SSH_CMD[@]}" "$RELEASE_HOST" "$remote_command" \
    || fail "${label} 线上不可访问: $url"
}

main() {
  require_command git
  require_command gh
  require_command python3
  require_command rsync
  require_command ssh
  require_command curl

  cd "$PROJECT_ROOT"

  [ -d "$STARCAT_SITE_ROOT/.git" ] \
    || fail "未找到独立官网仓库: ${STARCAT_SITE_ROOT}；请先运行 supports/clone-all.sh"
  if [ "${STARCAT_RELEASE_REUSE_ARTIFACTS:-0}" = "1" ]; then
    # 产物恢复只校验已推送 tag 与已公证 DMG，不发布当前工作区的官网源码。
    run_or_print python3 "$SCRIPT_DIR/verify-direct-release-artifacts.py" \
      --version "$VERSION" --dmg "$DMG_PATH" --sha256 "$SHA_PATH" \
      --appcast "$CURRENT_APPCAST_PATH" --remote "$RELEASE_REMOTE"
    export STARCAT_RELEASE_SKIP_SITE=1
    export STARCAT_RELEASE_SKIP_NGINX=1
    log "恢复已有产物，仅续传 GitHub 与更新源"
  else
    [ -f "$PAGES_DIR/deploy.sh" ] \
      || fail "未找到 Direct 官网部署脚本: ${PAGES_DIR}/deploy.sh"
    require_branch
    require_clean_worktree
    require_notarization_policy
  fi
  run_or_print gh auth status
  if [ "${STARCAT_RELEASE_REUSE_ARTIFACTS:-0}" != "1" ]; then
    create_and_push_tag
    package_direct
  fi
  verify_local_artifacts
  merge_appcast
  publish_github_release
  deploy_site
  publish_appcast
  verify_remote_urls
}

main
