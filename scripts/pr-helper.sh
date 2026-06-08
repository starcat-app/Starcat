#!/usr/bin/env bash
# =============================================================================
# scripts/pr-helper.sh — Starcat 项目 PR 自动化脚本
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
#   4. 校验: gh CLI 已认证
#   5. 推送 dev 到 origin (远端无 dev 自动创建, -u 设 upstream)
#   6. 创建 PR (dev → main)
#   7. 自动合并 PR (失败 = 冲突 / 分支保护, 退出并提示)
#   8. 删除远端 dev
#   9. 从 origin/main 拉取最新, 重置本地 dev 到 origin/main
#      (新一轮开发周期开始)
#
# 工作流模型:
#   - 本地 dev 是常驻开发分支, 用户一直在 dev 上 commit
#   - 每轮开发 = [dev 开发 → 跑脚本 PR+合并 → 删远端 dev → 本地 dev 重置为 origin/main]
#   - 远端 dev 仅作为 PR head 临时存在, PR 合并后删除
#
# 关键约束 (踩过的坑):
#   - 必须从 dev 分支运行, 不支持其他分支
#   - 合并策略: --merge (保留 dev 历史, 不 squash)
#   - 合并失败 (exit code != 0) = 冲突 / 分支保护 / CI 未通过, 脚本立即退出
#   - 步骤 8 / 9 顺序不能颠倒: 必须先删远端 dev 再重置本地,
#     否则远端残留 dev ref 会让协作者/CI 误以为 dev 还在用
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
# 4. gh CLI 已认证
# =============================================================================
if ! gh auth status >/dev/null 2>&1; then
    die "gh CLI not authenticated, run: gh auth login"
fi
ok "gh CLI authenticated"

# =============================================================================
# 5. 推送 dev 到 origin (远端无 dev 自动创建)
# =============================================================================
# git push -u 处理两种情况:
#   - 远端无 dev: 自动创建并设 upstream
#   - 远端有 dev: 仅推送 (本地需是 fast-forward, 否则失败 → 提示用户先 pull --rebase)
info "pushing dev to origin..."
git push -u origin dev
ok "pushed dev"

# =============================================================================
# 6. 创建 PR (dev → main)
# =============================================================================
info "creating PR dev → main..."

# PR body 按 .github/PULL_REQUEST_TEMPLATE.md 规范填
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
# 7. 自动合并 PR
# =============================================================================
# gh pr merge 失败场景 (exit code != 0):
#   - PR 标记为 "无法自动合并" (merge 冲突)
#   - main 分支保护规则要求 review / CI 通过
#   - 远端权限不足
# 失败时脚本立即退出, 提示用户去 GitHub 手动处理
info "merging PR #$PR_NUM..."

if ! gh pr merge "$PR_NUM" --merge; then
    die "PR #$PR_NUM cannot be auto-merged (likely merge conflict or branch protection).
Resolve manually:
  1. Go to $PR_URL
  2. Resolve the conflict (rebase dev on main / merge main into dev / edit on GitHub)
  3. After manual merge, run cleanup manually:
     git push origin --delete dev
     git fetch origin main
     git checkout -B dev origin/main"
fi
ok "PR #$PR_NUM merged"

# =============================================================================
# 8. 删除远端 dev
# =============================================================================
# 远端 dev 使命完成, 下轮开发从 origin/main 重建本地 dev
# 容错: GitHub PR 合并时可能自动删 head 分支 (有多种触发路径):
#   - 仓库 Settings → General → "Automatically delete head branches" 勾选
#   - 用户点过 PR 页面 "Delete branch" 按钮
#   - GitHub 异步删除存在 race condition, ls-remote 紧跟查可能还看得到 dev
#   - 设置仓库自动删除 PR 分支: gh repo edit dong4j/Starcat --delete-branch-on-merge
# 采用"先试再容错"模式: 直接 push --delete, 失败就 warn 但不退出
# (失败原因主要是 dev 已不存在, 本地 ref 不感知, 后续 step 9 会重置本地 dev)
info "deleting remote dev..."
if git push origin --delete dev 2>/dev/null; then
    ok "remote dev deleted"
else
    warn "remote dev may already be deleted (skipped, likely auto-deleted by GitHub on PR merge)"
fi

# =============================================================================
# 9. 重置本地 dev 到 origin/main (新一轮开发开始)
# =============================================================================
# 关键约束: 步骤 8 / 9 顺序不能颠倒
# (若先重置本地, 远端残留 dev ref 会让协作者 / CI 误以为 dev 还在用)
# 用 -B 强制重置 (不依赖当前分支, 语义明确)
# 不打 tag, fetch 不加 --tags
info "resetting local dev to origin/main..."
git fetch origin main
git checkout -B dev origin/main
ok "local dev reset to origin/main ✓"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  本轮开发完成, 下一轮就绪 ✓${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "  - PR:     $PR_URL"
echo "  - Actions: https://github.com/dong4j/Starcat/actions"
echo ""
echo "  下一步: 在 dev 上开始下一轮开发"
