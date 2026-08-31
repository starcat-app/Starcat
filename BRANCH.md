# Starcat 分支登记

> 用途：记录仍然存在的 Git 分支为什么创建、当前由哪个 worktree 承载工作，以及下一步应如何处理，避免长期分支被遗忘或误删。
>
> 本文档记录的是分支的产品/开发意图；分支是否真实存在、HEAD 和 worktree 归属仍以 Git 命令输出为准。
>
> 操作规范：[`docs/5-规范/Git-分支与Worktree规范.md`](docs/5-规范/Git-分支与Worktree规范.md)
>
> 最后核对：2026-08-31

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
| `dev` | 本地 + `origin/dev` | 日常开发与功能集成主线。新功能完成验收后先进入这里，再按发布流程进入 `main`。 | `开发中`；1.5.0 已发布，正式 Changelog 与双渠道打包门禁修正已于 2026-08-31 从 `main` 同步。 | 后续功能继续在 `dev` 开发；下一版本发版问题仍先在 `dev` 修复并重新执行门禁。 |
| `main` | 本地 + `origin/main`；仓库根目录 worktree | 远端默认稳定主线和发布基线。 | `长期保留`；1.5.0 已于 2026-08-31 发布，同日完成正式 Changelog 收口及 App Store / Direct 修正版重打，既有 `v1.5.0` tag 未改写。 | 保持稳定主线；后续正式发布继续从已验收的 `dev` 进入。 |

## 推荐数据链路跨仓分支

2026-08-29 已按 dong4j 授权清理：Starcat `../Starcat-collection-pipeline` worktree 与各仓需求分支均已删除。独立仓库仍各自保留 `dev` / `main`，不由主仓库管理其 Git 历史。

## 近期已清理分支

| 分支 | 处理结论 | 清理依据 |
|---|---|---|
| `codex/collection-pipeline` | 已删除 | 2026-08-29 dong4j 确认删除。已是 local `dev` 的 ancestor，独有提交为 0，diff 为空；`../Starcat-collection-pipeline` worktree 干净后 `git worktree remove`，再 `git branch -d`。从未存在远端分支。配套 `starcat-collection-api` 同名本地分支一并删除。 |
| `codex/awesome-discovery` | 已删除 | 2026-08-29 dong4j 确认删除。Starcat / `starcat-discovery-api` / `starcat-site` 三仓本地分支均已是各自 `dev` 的 ancestor，独有提交为 0，diff 为空；无 worktree。从未存在远端分支。 |
| `codex/collection-api-source` | 已删除 | 2026-08-29 从 `starcat-recsys-trainer` 删除本地分支；已合入该仓 `dev`，从未存在远端分支。 |
| `codex/trained-recommendations` | 已删除 | 2026-08-29 从 `starcat-recommend-api` 删除本地分支；已合入该仓 `dev`，从未存在远端分支。 |
| `feature/export-server-package` | 已删除 | 2026-08-29 从 discovery / recommend / sharing / trending / weekly / wiki 六个 API 删除本地分支，并 `git push origin --delete` 清掉远端同名分支。删除前均为各自 `dev` 的 ancestor，独有提交为 0，diff 为空。 |
| `codex/agent-runtime-trace` | 已删除 | 2026-08-22 已通过 fast-forward 合入本地 `dev`；dong4j 授权清理时 worktree 干净，`git cherry` 为空，分支独有提交为 0，diff 为空。对应 `../Starcat-agent-runtime-trace` worktree 与本地分支已清理；从未存在远端分支。 |
| `codex/external-agent-runtime-poc` | 已删除 | 2026-08-21 已通过 merge commit 合入本地 `dev`；dong4j 授权清理时 worktree 干净，`git cherry` 为空，分支独有提交为 0，diff 为空。对应 `../Starcat-external-agent-runtime-poc` worktree 与本地分支已清理；从未存在远端分支。 |
| `codex/curated-publisher` | 已删除 | dong4j 确认已全部合并进 `dev`；`git merge-base --is-ancestor` 成立，独有提交为 0，diff 为空。对应 `../Starcat-curated-publisher` worktree 与本地分支已清理；从未存在远端分支。 |
| `codex/agent-iteration` | 已删除 | dong4j 已确认 Agent 迭代内容合并到 `dev`；对应 `../Starcat-agent-iteration` worktree 与本地分支已清理。 |
| `codex/macos-widget` | 已删除 | 已合并到 `dev`，对应 worktree 已清理。 |
| `codex/my-projects` | 已删除 | 已合并到 `dev`，对应 worktree 已清理。 |
| `feature/rag` | 已删除 | Git 历史未直接合并，但 17 个独有提交的功能已被当前 RAG 实现完整覆盖或升级替代。 |
| `codex/search` | 已删除 | dong4j 已删除远端 `origin/codex/search`；本地无该分支、无 worktree。公开前不再保留这条改写前的旧历史。 |
| `codex/chrome-companion` | 已删除 | 旧提交 `901efc38` 已被项目明确废弃；当前 Companion App 端和独立 Chrome 插件仓库采用重写后的正式方案。 |
