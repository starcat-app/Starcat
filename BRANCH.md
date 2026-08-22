# Starcat 分支登记

> 用途：记录仍然存在的 Git 分支为什么创建、当前由哪个 worktree 承载工作，以及下一步应如何处理，避免长期分支被遗忘或误删。
>
> 本文档记录的是分支的产品/开发意图；分支是否真实存在、HEAD 和 worktree 归属仍以 Git 命令输出为准。
>
> 操作规范：[`docs/5-规范/Git-分支与Worktree规范.md`](docs/5-规范/Git-分支与Worktree规范.md)
>
> 最后核对：2026-08-22

## 登记说明

所有分支与 worktree 的创建、切换、同步、合并和删除均遵循上方规范。出现以下情况时，必须在同一任务中同步更新本文档：

1. 创建、切换或恢复长期分支及独立 worktree。
2. 分支用途、开发范围、目标基线或 worktree 位置发生变化。
3. 分支合并、停放、废弃或删除。
4. 审查远端遗留分支并得出保留或删除结论。

短期分支如果能在同一次任务中完成创建、合并和删除，可以不登记；跨会话、跨 worktree 或暂时不能合并的分支必须登记。每次操作仍须以 Git refs、提交关系和 `git worktree list` 核对真实状态，不能只依据本表执行。

状态统一使用：

- `开发中`：仍承载未完成工作，禁止删除。
- `长期保留`：稳定主线或固定集成分支，不进入清理流程。
- `停放`：暂时不开发，但仍有未合并价值。
- `待审查`：用途或语义合并情况尚未确认，禁止直接删除。
- `已合并`：代码已进入目标分支，可以进入删除流程。
- `已废弃`：方案已被替代，经审查后可以删除。

## 当前分支

| 分支 | 位置 | 用途 | 当前状态 | 下一步 |
|---|---|---|---|---|
| `dev` | 本地 + `origin/dev`；当前无独立 worktree | 日常开发与功能集成主线。新功能完成验收后先进入这里，再按发布流程进入 `main`。 | `开发中`；1.4.0 发版准备与 App Store 正式版 Xcode 打包门禁已进入 `main`。 | 后续功能继续在 `dev` 开发；新的发版阻断问题仍回到 `dev` 修复并重新执行门禁。 |
| `main` | 本地 + `origin/main`；仓库根目录 worktree | 远端默认稳定主线和发布基线。 | `长期保留`；2026-08-21 已完成 1.4.0 发布：App Store Connect 构建有效，Direct 完成公证、官网、Sparkle、GitHub Release 和 Homebrew 发布。 | 保持稳定主线；后续功能与发版阻断修复仍先进入 `dev`。 |
| `codex/agent-runtime-trace` | 本地；`../Starcat-agent-runtime-trace` worktree | 基于 `dev@f033e4d9` 把 Codex、DeepSeek Harness 与 Built-in Loop 的真实运行事件持久化为动态 Trace，并重构 Agent Run Surface 时间线。 | `已合并`；2026-08-22 已通过 fast-forward 合入本地 `dev`，专项 worktree 暂留用于对照。 | 由 dong4j 在 `dev` 本地验证；验收完成并授权后再清理专项 worktree 与分支。 |
| `codex/external-agent-runtime-poc` | 本地；`../Starcat-external-agent-runtime-poc` worktree | 基于 `dev@f6d34d1c` 验证可切换 External Agent Runtime 底座，保留 `LoopAgentRuntime`，并接入 Codex App Server 与 DeepSeek Harness adapter。 | `已合并`；2026-08-21 已通过 merge commit 合入本地 `dev`，专项 worktree 暂留用于对照。 | 由 dong4j 在 `dev` 本地验证；验收完成并授权后再清理专项 worktree 与分支。 |

## 近期已清理分支

| 分支 | 处理结论 | 清理依据 |
|---|---|---|
| `codex/curated-publisher` | 已删除 | dong4j 确认已全部合并进 `dev`；`git merge-base --is-ancestor` 成立，独有提交为 0，diff 为空。对应 `../Starcat-curated-publisher` worktree 与本地分支已清理；从未存在远端分支。 |
| `codex/agent-iteration` | 已删除 | dong4j 已确认 Agent 迭代内容合并到 `dev`；对应 `../Starcat-agent-iteration` worktree 与本地分支已清理。 |
| `codex/macos-widget` | 已删除 | 已合并到 `dev`，对应 worktree 已清理。 |
| `codex/my-projects` | 已删除 | 已合并到 `dev`，对应 worktree 已清理。 |
| `feature/rag` | 已删除 | Git 历史未直接合并，但 17 个独有提交的功能已被当前 RAG 实现完整覆盖或升级替代。 |
| `codex/search` | 已删除 | dong4j 已删除远端 `origin/codex/search`；本地无该分支、无 worktree。公开前不再保留这条改写前的旧历史。 |
| `codex/chrome-companion` | 已删除 | 旧提交 `901efc38` 已被项目明确废弃；当前 Companion App 端和独立 Chrome 插件仓库采用重写后的正式方案。 |
