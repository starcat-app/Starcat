#!/usr/bin/env bash
# =============================================================================
# scripts/pr-helper.sh — Starcat 项目 dev → main PR 自动化脚本
# =============================================================================
#
# 用法:
#   ./scripts/pr-helper.sh
#
# 前置依赖:
#   - git (>= 2.x)
#   - gh (GitHub CLI, 已认证: `gh auth status`)
#   - 当前所在分支必须是 dev
#
# 完整流程 (按顺序):
#   1. 校验: 在 git 仓库
#   2. 校验: 当前分支是 dev
#   3. 校验: 工作区干净 (无 uncommitted / untracked)
#   4. 校验: 当前分支没有未推送的 commit
#   5. 校验: gh CLI 已认证
#   6. 推送 dev 到 origin
#   7. 创建 PR (dev → main)
#   8. 自动合并 PR
#   9. 切回 dev (终态明确)
#
# 关键约束 (踩过的坑):
#   - 必须从 dev 分支运行, 不支持 feature 分支
#   - main / master 上禁止运行 (会 PR 自己到自己, 无意义)
#   - 合并策略: --merge (保留 dev 历史, 不 squash)
#   - 不删 dev 分支: Starcat 简化流程, dev 是常驻集成分支
#   - 不打 tag: Starcat 暂不维护语义化版本
#
# 失败处理: set -e + 任意一步 exit 1 都会停止
# (已创建的 PR 不会自动关, 需要手动去 GitHub 处理)
# =============================================================================

set -euo pipefail

# =============================================================================
# 颜色 (只在 TTY 输出, pipe 时关掉避免污染日志)
# =============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# 错误退出: 红字 + exit 1
die() {
    echo -e "${RED}✗ Error:${NC} $*" >&2
    exit 1
}

# 成功步骤: 绿勾
ok() {
    echo -e "${GREEN}✓${NC} $*"
}

# 提示信息: 蓝色
info() {
    echo -e "${BLUE}▶${NC} $*"
}

# 警告: 黄色 (不退出)
warn() {
    echo -e "${YELLOW}!${NC} $*" >&2
}

# =============================================================================
# 1. 在 git 仓库
# =============================================================================
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not in a git repository"

# =============================================================================
# 2. 当前分支是 dev
# =============================================================================
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null \
    || git rev-parse --short HEAD)

# 硬拦: 必须在 dev 上跑 (此脚本 PR head 固定是 dev)
if [[ "$CURRENT_BRANCH" != "dev" ]]; then
    die "must run on 'dev' branch, current: '$CURRENT_BRANCH' — run: git checkout dev"
fi
ok "branch: dev"

# =============================================================================
# 3. 工作区干净
# =============================================================================
if ! git diff --quiet HEAD 2>/dev/null; then
    die "working tree has unstaged/staged changes, commit or stash first:
$(git status --short)"
fi

if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    die "working tree has untracked files, commit or remove first:
$(git ls-files --others --exclude-standard)"
fi
ok "working tree clean"

# =============================================================================
# 4. 当前分支没有未推送的 commit
# =============================================================================
# 防止本地有 commit 没推, PR 创建后 origin 还少这些 commit
if git rev-parse --abbrev-ref "@{u}" >/dev/null 2>&1; then
    UNPUSHED=$(git log --oneline "@{u}..HEAD" 2>/dev/null || true)
    if [[ -n "$UNPUSHED" ]]; then
        die "current branch has unpushed commits, push first:
$UNPUSHED"
    fi
    ok "no unpushed commits on dev"
else
    warn "dev has no upstream tracking — assuming local is the source of truth"
fi

# =============================================================================
# 5. gh CLI 已认证
# =============================================================================
if ! gh auth status >/dev/null 2>&1; then
    die "gh CLI not authenticated, run: gh auth login"
fi
ok "gh CLI authenticated"

# =============================================================================
# 6. 推送 dev 到 origin
# =============================================================================
info "pushing dev to origin..."
git push origin dev
ok "pushed dev"

# =============================================================================
# 7. 创建 PR (dev → main)
# =============================================================================
info "creating PR dev → main..."

# PR body 按 .github/PULL_REQUEST_TEMPLATE.md 规范填
# Starcat 是 SwiftUI 项目, 去掉 Go 相关 checklist, 改用 Xcode/build 维度
PR_BODY=$(cat <<'EOF'
## 变更说明

将 `dev` 合并到 `main`。

## 关联 Issue

<!-- 如有关联 Issue, 请使用 `Closes #123` 或 `Fixes #123` -->

- Fixes #

## 变更类型

请勾选适用的选项:

- [ ] 新功能 (非破坏性,新增功能)
- [ ] Bug 修复
- [ ] 文档更新
- [ ] 重构 / 性能优化
- [ ] 测试相关

## 测试

- [x] `xcodebuild -scheme Starcat build` 通过
- [x] 单元测试已通过 (`xcodebuild test`)
EOF
)

# gh pr create 失败会触发 set -e 退出
PR_URL=$(gh pr create \
    --base main \
    --head dev \
    --title "chore: merge dev into main" \
    --body "$PR_BODY")

PR_NUM=$(echo "$PR_URL" | grep -oE '/pull/[0-9]+$' | grep -oE '[0-9]+')
ok "PR created: $PR_URL (PR #$PR_NUM)"

# =============================================================================
# 8. 合并 PR
# =============================================================================
info "merging PR #$PR_NUM..."
gh pr merge "$PR_NUM" --merge
ok "PR #$PR_NUM merged"

# =============================================================================
# 9. 切回 dev (终态明确)
# =============================================================================
info "switching back to dev..."
git checkout dev
ok "switched to dev, done ✓"
