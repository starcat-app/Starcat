#!/usr/bin/env bash
#
# release.sh — Starcat 发版总入口
#
# 用途：
#   一行命令完成"打 git tag → 出 DMG → 推 tag 到远端"全流程，本身不重复实现任何
#   构建 / 校验逻辑，只是编排现有脚本（build-dmg.sh）和原生 git / xcodegen。
#
# 用法：
#   ./scripts/release.sh v1.0.0            # 标准发版（happy path，最常用）
#   ./scripts/release.sh 1.0.0             # 等价（v 前缀可省，会自动加上）
#   ./scripts/release.sh v1.0.0 --dry-run  # 演练：只打印要执行的命令，不真做
#   ./scripts/release.sh v1.0.0 --yes      # 跳过二次确认（CI 友好）
#   ./scripts/release.sh v1.0.0 --skip-dmg # 只打 tag + push，不出 DMG
#   ./scripts/release.sh v1.0.0 --skip-push# 只本地 tag + 出 DMG，不推到远端
#   ./scripts/release.sh --help            # 用法
#
# 流程：
#   1. 解析参数 / 归一化版本号（vX.Y.Z 与 X.Y.Z 都接受）
#   2. 前置校验（git 仓库 / working tree 干净 / tag 不冲突 / 工具齐全）
#   3. 二次确认（默认开启，--yes 跳过）
#   4. git tag vX.Y.Z（**本地**）
#   5. scripts/build-dmg.sh X.Y.Z（产物 plist 由 postBuildScripts 自动读 tag 写入）
#   6. git push origin vX.Y.Z
#   7. 打印摘要（DMG 路径 / sha256 / GitHub Release 链接提示）
#
# 顺序为何先本地 tag、build 完才 push：
#   - bump-version.sh 用 `git describe --tags --abbrev=0` 取最近 tag，**本地有 tag 即可**，不必 push
#   - 如果 build 失败，tag 仍只在本地，可以 `git tag -d` 干净撤销
#   - 反过来"先 push 再 build"的话失败要 force-push 删 tag，污染远端 + 影响协作者
#
# 设计取舍：
#   - 不重复实现 build / xcodegen / dmg 打包：那些已在 build-dmg.sh 里做完
#   - 不直接调 bump-version.sh：它是 Xcode build phase，build-dmg.sh 内部 xcodebuild 会自动触发
#   - 不创建 GitHub Release（需要 gh auth + 网络 + Release 文案，不适合一键脚本默默做）
#     → 脚本最后只打印 Release 创建链接，由 dong4j 手动决定是否公开
#
# 已知约束：
#   - 版本号必须严格 X.Y.Z（与 build-dmg.sh 一致），暂不支持 -beta / -rc 后缀
#     如果将来要发 pre-release，先扩 build-dmg.sh 再扩这里
#   - 仅支持 macOS（依赖 git / xcodegen / xcodebuild）
#

set -euo pipefail

# ============================================================================
# 路径与常量
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DMG_SCRIPT="$SCRIPT_DIR/build-dmg.sh"

# ============================================================================
# 日志工具（与 build-dmg.sh 保持一致的视觉风格）
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

log_step()    { echo -e "\n${BLUE}▶${RESET} ${BOLD}${1}${RESET}"; }
log_ok()      { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_warn()    { echo -e "  ${YELLOW}⚠${RESET} ${1}"; }
log_err()     { echo -e "  ${RED}✗${RESET} ${1}" >&2; }
log_dim()     { echo -e "  ${GRAY}${1}${RESET}"; }
log_info()    { echo -e "  ${CYAN}ℹ${RESET} ${1}"; }
log_section() { echo -e "\n${BOLD}${1}${RESET}"; }

# ============================================================================
# 帮助
# ============================================================================
show_help() {
    cat <<'EOF'
release.sh — Starcat 发版总入口

USAGE
    ./scripts/release.sh <version> [flags]

ARGUMENTS
    <version>       目标版本号，X.Y.Z 或 vX.Y.Z（如 v1.0.0 / 1.2.3）

FLAGS
    --dry-run       演练模式，只打印将要执行的命令，不真做改动
    --yes, -y       跳过二次确认（CI 友好）
    --skip-dmg      不跑 build-dmg.sh，只完成 tag 相关操作
    --skip-push     只在本地打 tag，不推到远端（适合本地试一次发版流程）
    --help, -h      显示本帮助

EXAMPLES
    ./scripts/release.sh v1.0.0                # 标准发版
    ./scripts/release.sh v1.0.0 --dry-run      # 先演练一次看流程
    ./scripts/release.sh 0.1.1 --yes           # 自动化场景跳过确认

详见：docs/发版流程.md
EOF
}

# ============================================================================
# 参数解析
# ============================================================================
VERSION_ARG=""
DRY_RUN=0
SKIP_DMG=0
SKIP_PUSH=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes|-y)
            ASSUME_YES=1
            shift
            ;;
        --skip-dmg)
            SKIP_DMG=1
            shift
            ;;
        --skip-push)
            SKIP_PUSH=1
            shift
            ;;
        -*)
            log_err "未知参数：$1"
            log_dim "→ 使用 --help 查看支持的参数"
            exit 1
            ;;
        *)
            if [[ -n "$VERSION_ARG" ]]; then
                log_err "只接受一个版本号参数，已收到 '$VERSION_ARG'，又收到 '$1'"
                exit 1
            fi
            VERSION_ARG="$1"
            shift
            ;;
    esac
done

if [[ -z "$VERSION_ARG" ]]; then
    log_err "缺少版本号参数"
    show_help
    exit 1
fi

# 归一化：去掉 v / V 前缀，得到 X.Y.Z 形式。后续 git tag 时再补 v 前缀。
PLAIN_VERSION="${VERSION_ARG#v}"
PLAIN_VERSION="${PLAIN_VERSION#V}"
TAG_NAME="v${PLAIN_VERSION}"

# 严格 X.Y.Z 校验（与 build-dmg.sh 一致，避免后续才发现版本号不合法）。
if ! [[ "$PLAIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_err "版本号格式错误：'$VERSION_ARG'"
    log_dim "→ 必须是 X.Y.Z 三段纯数字（如 v1.0.0 / 1.2.3）"
    log_dim "→ 暂不支持 -beta / -rc 等 SemVer 预发布后缀，受限于 build-dmg.sh"
    log_dim "→ v 前缀可省可加（v1.0.0 与 1.0.0 等价）"
    exit 1
fi

# ============================================================================
# 命令执行包装：DRY_RUN 模式只打印不执行
# ============================================================================
run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "  ${GRAY}[dry-run]${RESET} $*"
        return 0
    fi
    "$@"
}

# ============================================================================
# 工具与环境前置检查
# ============================================================================
log_step "前置检查"

cd "$PROJECT_ROOT"

# 1) git 仓库
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_err "当前目录不是 git 仓库：$PROJECT_ROOT"
    exit 1
fi
log_ok "git 仓库：$PROJECT_ROOT"

# 2) git 必备工具
command -v git >/dev/null 2>&1 || { log_err "git 未安装"; exit 1; }

# 3) build-dmg.sh 存在且可执行（除非 --skip-dmg）
if [[ $SKIP_DMG -eq 0 ]]; then
    if [[ ! -x "$BUILD_DMG_SCRIPT" ]]; then
        log_err "build-dmg.sh 不存在或不可执行：$BUILD_DMG_SCRIPT"
        log_dim "→ chmod +x $BUILD_DMG_SCRIPT"
        exit 1
    fi
    log_ok "build-dmg.sh 可用"
fi

# 4) working tree 干净 —— 发版必须从干净状态开始，否则 hash 反映不出实际 build 的代码
if [[ -n "$(git status --porcelain)" ]]; then
    log_err "git working tree 有未提交改动"
    log_dim "→ 先 git commit / git stash 处理干净再发版"
    log_dim "→ 当前改动："
    git status --short | sed 's/^/      /'
    exit 1
fi
log_ok "working tree 干净"

# 5) 当前分支信息（仅展示，不强制限制为 main —— 让用户自己负责）
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CURRENT_COMMIT="$(git rev-parse --short=7 HEAD)"
COMMIT_COUNT="$(git rev-list --count HEAD)"
log_ok "当前分支：${CURRENT_BRANCH} @ ${CURRENT_COMMIT}（commit #${COMMIT_COUNT}）"

# 6) tag 在本地不存在
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
    log_err "tag '$TAG_NAME' 已存在于本地"
    log_dim "→ 想重发请先 git tag -d $TAG_NAME"
    log_dim "→ 想撤销远端 tag 需 git push origin :refs/tags/$TAG_NAME（影响协作者，慎用）"
    exit 1
fi
log_ok "tag '$TAG_NAME' 在本地未占用"

# 7) tag 在远端不存在（fetch 一下再查，避免本地缓存陈旧）
if [[ $SKIP_PUSH -eq 0 ]]; then
    if git remote get-url origin >/dev/null 2>&1; then
        # ls-remote 比 fetch --tags 轻量，不污染本地 refs
        REMOTE_TAG_REF="$(git ls-remote --tags origin "refs/tags/$TAG_NAME" 2>/dev/null || true)"
        if [[ -n "$REMOTE_TAG_REF" ]]; then
            log_err "tag '$TAG_NAME' 已存在于远端 origin"
            log_dim "→ 远端 ref：$REMOTE_TAG_REF"
            log_dim "→ 想重发需先 git push origin :refs/tags/$TAG_NAME（影响协作者）"
            exit 1
        fi
        log_ok "tag '$TAG_NAME' 在远端未占用"
    else
        log_warn "未配置 origin 远端，将自动改为 --skip-push"
        SKIP_PUSH=1
    fi
fi

# 8) 上一个 tag（若有）展示给用户做对比
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
    LAST_TAG_COMMIT_COUNT="$(git rev-list --count "${LAST_TAG}..HEAD" 2>/dev/null || echo "?")"
    log_ok "上一个 tag：${LAST_TAG}（距 HEAD 还有 ${LAST_TAG_COMMIT_COUNT} 个新 commit）"
else
    log_ok "上一个 tag：（无，这是首次发版）"
fi

# ============================================================================
# 摘要 + 二次确认
# ============================================================================
log_section "发版摘要"
echo "  目标 tag         : ${BOLD}${TAG_NAME}${RESET}"
echo "  Marketing 版本   : ${PLAIN_VERSION}"
echo "  Build 号 (auto)  : ${COMMIT_COUNT}.${CURRENT_COMMIT}（由 bump-version.sh 写入 plist）"
echo "  当前 commit      : ${CURRENT_COMMIT} on ${CURRENT_BRANCH}"
echo "  出 DMG           : $([[ $SKIP_DMG -eq 1 ]] && echo '否（--skip-dmg）' || echo '是 → scripts/build-dmg.sh')"
echo "  推送 tag         : $([[ $SKIP_PUSH -eq 1 ]] && echo '否（--skip-push 或无 origin）' || echo '是 → git push origin')"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  执行模式         : ${YELLOW}DRY-RUN（只打印不执行）${RESET}"
fi

if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
    echo
    read -r -p "确认开始发版？[y/N] " confirm
    case "$confirm" in
        y|Y|yes|YES)
            ;;
        *)
            log_warn "用户取消"
            exit 130
            ;;
    esac
fi

# ============================================================================
# Phase 1: 本地打 tag
# ============================================================================
log_step "Phase 1/3 本地打 tag"

TAG_MESSAGE="Release ${TAG_NAME}"
run_cmd git tag -a "$TAG_NAME" -m "$TAG_MESSAGE"
log_ok "已创建本地 tag：$TAG_NAME"

# 失败回滚 trap：从这一刻起到流程结束前，任何异常退出都提示"是否删除刚打的本地 tag"
ROLLBACK_DONE=0
on_failure() {
    local exit_code=$?
    if [[ $ROLLBACK_DONE -eq 1 || $DRY_RUN -eq 1 ]]; then
        return
    fi
    if [[ $exit_code -ne 0 ]]; then
        echo
        log_err "发版流程异常退出（exit=$exit_code）"
        log_warn "本地 tag '$TAG_NAME' 仍存在，根据失败阶段你可能需要：" >&2
        echo "    - build 失败  → 删 tag：${BOLD}git tag -d $TAG_NAME${RESET}" >&2
        echo "    - push 失败   → 网络问题，可手动 git push origin $TAG_NAME 重试" >&2
        echo "    - 不确定      → 先保留 tag，定位问题后再决定" >&2
    fi
}
trap on_failure EXIT

# ============================================================================
# Phase 2: build DMG（可跳过）
# ============================================================================
if [[ $SKIP_DMG -eq 0 ]]; then
    log_step "Phase 2/3 构建 DMG"
    log_dim "→ 调用 scripts/build-dmg.sh ${PLAIN_VERSION}"
    log_dim "→ 该脚本内部跑 xcodegen + xcodebuild，触发 postBuildScripts 中的 bump-version.sh"
    log_dim "→ bump-version.sh 会读到刚打的本地 tag '$TAG_NAME'，写 plist 三字段："
    log_dim "    CFBundleShortVersionString = ${PLAIN_VERSION}"
    log_dim "    CFBundleVersion            = ${COMMIT_COUNT}"
    log_dim "    GitCommitHash              = ${CURRENT_COMMIT}"
    echo

    run_cmd "$BUILD_DMG_SCRIPT" "$PLAIN_VERSION"

    log_ok "DMG 构建完成"
else
    log_step "Phase 2/3 构建 DMG"
    log_warn "已跳过（--skip-dmg）"
fi

# ============================================================================
# Phase 3: push tag（可跳过）
# ============================================================================
if [[ $SKIP_PUSH -eq 0 ]]; then
    log_step "Phase 3/3 推送 tag 到远端"
    run_cmd git push origin "$TAG_NAME"
    log_ok "已推送到 origin：$TAG_NAME"
else
    log_step "Phase 3/3 推送 tag 到远端"
    log_warn "已跳过（--skip-push）"
fi

# 走到这里说明所有阶段都成功了，关掉回滚提示
ROLLBACK_DONE=1
trap - EXIT

# ============================================================================
# 最终摘要
# ============================================================================
log_section "✅ 发版完成"
echo "  Tag                       : ${TAG_NAME}"
echo "  Marketing version         : ${PLAIN_VERSION}"
echo "  Source commit             : ${CURRENT_COMMIT} on ${CURRENT_BRANCH}"
echo "  Build (commit count)      : ${COMMIT_COUNT}"

if [[ $SKIP_DMG -eq 0 && $DRY_RUN -eq 0 ]]; then
    DMG_PATH="$PROJECT_ROOT/build/dmg/Starcat-${PLAIN_VERSION}-arm64.dmg"
    SHA_PATH="${DMG_PATH}.sha256"
    INSTALL_MD="$PROJECT_ROOT/build/dmg/INSTALL-${PLAIN_VERSION}.md"
    if [[ -f "$DMG_PATH" ]]; then
        DMG_SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
        echo "  DMG                       : $DMG_PATH ($DMG_SIZE)"
    fi
    [[ -f "$SHA_PATH" ]]    && echo "  SHA-256                   : $SHA_PATH"
    [[ -f "$INSTALL_MD" ]]  && echo "  Install README            : $INSTALL_MD"
fi

# 提示 GitHub Release（仅打印链接，不自动创建）
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -n "$ORIGIN_URL" && $SKIP_PUSH -eq 0 && $DRY_RUN -eq 0 ]]; then
    # 把 git@github.com:user/repo.git / https://github.com/user/repo.git 都转成 https://github.com/user/repo
    REPO_PATH="$(echo "$ORIGIN_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
    if [[ -n "$REPO_PATH" ]]; then
        echo
        log_info "下一步（可选）：在 GitHub 创建 Release"
        echo "    https://github.com/${REPO_PATH}/releases/new?tag=${TAG_NAME}"
    fi
fi

echo
