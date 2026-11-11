# Starcat 分支登记

> 用途：记录仍然存在的 Git 分支为什么创建、当前由哪个 worktree 承载工作，以及下一步应如何处理，避免长期分支被遗忘或误删。
>
> 本文档记录的是分支的产品/开发意图；分支是否真实存在、HEAD 和 worktree 归属仍以 Git 命令输出为准。
>
> 操作规范：[`docs/5-规范/Git-分支与Worktree规范.md`](docs/5-规范/Git-分支与Worktree规范.md)
>
> 最后核对：2026-11-12

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
| `codex/daily-recommendation-cards` | 本地 worktree：`../Starcat-daily-recommendation-cards`；无远端分支 | 基于 `dev` 实现并继续迭代每日推荐抽卡：透明整窗覆盖、多种子真实推荐、账号历史去重、跨天候选分页与本地反馈。 | `开发中`；2026-11-11 worktree 已按功能提交到 `3a89321c` 并保持干净；该功能不进入 1.9.5 Beta。 | 继续在本 worktree 开发与验收，完成后合回 `dev`；不自动 push 或清理。 |
| `codex/go-security-20261102` | 本地隔离 clone：`task-2/repos/Starcat`；无远端分支 | 从 `main`（`6908f483`）修复 SQLite 备份 helper 的安全构建基线，并统一跨仓 Go 工具链约定。 | `已合并`；2026-11-02 经确认以 fast-forward 合入 `main`（`a787c48`），未发布或操作生产数据。 | 保留本地分支；`dev` 同步与后续发布待单独授权。 |
| `dev` | 本地 + `origin/dev`；仓库根目录 worktree | 日常开发与功能集成主线。新功能完成验收后先进入这里，再按发布流程进入 `main`。 | `开发中`；2026-11-12 已发布 Direct `1.9.5-beta.1`，发布源码为 `1aab33e6`；每日推荐仍在独立分支，未进入本次发布。 | 继续承载后续开发；每次发布后同步主仓库及全部 supports 独立项目的本地与远端 `dev/main`，新增变更不得回写已公开 tag。 |
| `codex/laya-mlx-swift-poc` | 本地；无独立 worktree、无远端分支 | Laya MLX 决策引擎 PoC 的历史分支。 | `已合并`；分支头 `706f6bff` 已是 `dev` 的 ancestor，独有提交为 0。 | 暂时保留本地分支；如需删除，等待 dong4j 单独授权。 |
| `main` | 本地 + `origin/main`；仓库根目录 worktree（发布期间检出） | 远端默认稳定主线和发布基线。 | `长期保留`；2026-11-12 按本次发布收尾要求从 `dev` fast-forward 并推送，本地及远端 `dev/main` 保持一致。 | 保持稳定；发布收尾覆盖全部独立项目，回读远端 refs 确认同步结果，不改写已公开 tag。 |

2026-11-12 发布收尾覆盖主仓库及 supports 下共 31 个独立 Git 仓库。其中 30 个有
`origin`，逐仓核对本地 `dev/main` 与远端同名分支；`supports/ai-file-wall` 无远端，
只核对本地两分支。官网 `dev/main` 同步至发布元数据提交 `4677526f`；
每日推荐独立 worktree 继续保留，不合入本次发布。

## 每周 AI 大事跨仓工作区

主仓分支 `codex/weekly-ai-events-mvp` 原基线 `dev@34b4554c`，正式化期间合入
`dev@8be24cc8`。2026-11-06 dong4j 明确授权合回 `dev`，后续直接在主工作区及
各独立仓的 `dev` 上开发；专项分支和 worktree 保留，不再承载后续开发。
2026-11-09 dong4j 确认功能完成，内容与 API 仓库以 `v1.0.0` 标记发布输入，
`origin/dev` 与 `origin/main` 同步；旧专项分支、远端分支和旧 worktree 删除。
两仓远端默认分支均为 `dev`；内容仓后续 CI 修复单独同步到 `dev/main`，
不改写已推送的 `v1.0.0`。Starcat 主仓已于 2026-11-09 将 `dev` 与 `main` 同步。

| 仓库 | 当前开发目录（主工作区下） | 已整合功能提交 | 当前分支与归宿 |
|---|---|---|---|
| Starcat | `.` | `f5e3895c`，合并前 dev 为 `d166608a` | `dev`；保留已合入的关注图谱等开发 |
| Weekly API | `supports/starcat-weekly-api` | `ed1402cb`，原 dev 为 `622a708` | `dev`；fast-forward，保留原日报 |
| 聚合 API | `supports/starcat-api` | `0c069881`，原 dev 为 `d2fcf37` | `dev`；fast-forward，沿用既有聚合部署 |
| 内容与 Skill | `supports/starcat-ai-events` | `737aff73`，包含业务操作手册 | `dev`；2026-11-09 发布输入固定 `v1.0.0`，不再使用专项分支 |
| AI Events API | `supports/starcat-ai-events-api` | `ddf410b1` | `dev`；2026-11-09 发布输入固定 `v1.0.0`，仍装配进聚合，不建独立 Fly App |

全局 `starcat-weekly-events` Skill 链接改指向主工作区
`supports/starcat-ai-events/skills/starcat-weekly-events`，使用该仓 `dev` 中的版本。
新两仓的本地配置和内容图片缓存一并衔接；不迁移或覆盖后端数据库。

2026-11-09 已清理原专项 worktree 及其支持仓 worktree 登记；主工作区的依赖仓库
保持各自现有分支。内容与 AI Events API 仓库已在主工作区恢复为独立 clone，
Git 元数据不再依赖旧专项目录，本地配置、图片缓存与发布状态保留。
部署固定 SHA 仍见 `supports/starcat-api/dependencies.json`；本次分支收尾不重新部署，
不修改内容与 API 仓库的 Private 状态。

## 推荐数据链路跨仓分支

2026-08-29 已按 dong4j 授权清理：Starcat `../Starcat-collection-pipeline` worktree 与各仓需求分支均已删除。独立仓库仍各自保留 `dev` / `main`，不由主仓库管理其 Git 历史。

## 近期已清理分支

| 分支 | 处理结论 | 清理依据 |
|---|---|---|
| `codex/skills-ui-preview` | 已合并；worktree 已删除，本地分支保留。 | 2026-11-11 dong4j 授权删除 worktree；分支头 `3c32d0c7` 已通过 merge commit `6faa19fa` 合入 `dev`，独有提交为 0，`git cherry` 与内容 diff 为空，worktree 干净。已通过 `git worktree remove` 删除 `../Starcat-skills-ui-preview`，本次未推送。 |
| `codex/diagnostics-overhaul` | 已删除 | 2026-11-10 dong4j 授权合回并删除；`3e69373c` 已以 merge commit `8813bf46` 合入 `dev`，`git cherry` 与内容 diff 为空，worktree 干净，已删除 `../Starcat-diagnostics-overhaul` 与本地分支，解析 Skill 链接改指向主仓。从未存在远端分支。 |
| `codex/background-task-integration` | 已删除 | 2026-11-10 dong4j 授权删除；`c56a9a48` 已合入 `dev`（merge `1ce18786`），`git cherry` 为空、diff 为空，worktree 干净，已删除 `../Starcat-background-task-integration` 与本地分支。从未存在远端分支。 |
| `codex/followers-graph` | 已删除 | 2026-11-09 dong4j 授权清理；`d4ffce59` 已合入 `dev`，worktree 干净，已删除 `../Starcat-followers-graph` 与本地分支。 |
| 主仓 `codex/weekly-ai-events-mvp` | 已删除 | 2026-11-09 dong4j 确认每周 AI 大事完成，授权删除旧 worktree `../Starcat-weekly-ai-events-mvp` 及本地/远端同名分支；功能已合入主仓 `dev`，主仓 `main` 未在本次同步。 |
| 内容 `codex/weekly-ai-events-mvp` | 已删除 | 2026-11-09 dong4j 确认功能完成后授权删除；`737aff73` 已是内容仓库 `dev`（`v1.0.0`）的祖先，旧 `../Starcat-weekly-ai-events-mvp/supports/starcat-ai-events` worktree 干净并已删除。 |
| AI Events API `codex/weekly-ai-events-mvp` | 已删除 | 2026-11-09 dong4j 确认功能完成后授权删除；`ddf410b1` 已是该仓库 `dev`（`v1.0.0`）的祖先，旧 `../Starcat-weekly-ai-events-mvp/supports/starcat-ai-events-api` worktree 干净并已删除。 |
| Weekly API `codex/weekly-ai-events-mvp` | 已删除 | 2026-11-09 清理同一专项遗留；`ed1402cb` 与 `dev` 相同，独有提交为 0，旧 worktree 登记及本地/远端同名分支已删除。 |
| 聚合 API `codex/weekly-ai-events-mvp` | 已删除 | 2026-11-09 清理同一专项遗留；`0c069881` 已是 `dev` 的祖先，独有提交为 0，旧 worktree 登记及本地/远端同名分支已删除。 |
| `codex/follow-graph-mvp` | 已删除 | 2026-11-09 dong4j 授权清理；`e0021690` 已合入 `dev`，worktree 干净，已删除 `../Starcat-follow-graph-mvp` 与本地分支。 |
| `codex/performance-optimization` | 已删除 | 截至 2026-10-11，本地与远端均已不存在该分支，且没有对应 worktree；性能专项改动已在 `dev`。 |
| `feature/anthropic-cc-switch-import` | 已删除 | 2026-09-14 dong4j 确认删除。已以 merge commit（`1341600a`）合入 `dev`，删除前 `merge-base --is-ancestor` 成立、独有提交 0、`git cherry` 为空、diff 为空；`../Starcat-anthropic-cc-switch` worktree 干净后 `git worktree remove`，再 `git branch -d`（HEAD `2ab786f2`）。从未存在远端分支。 |
| `feature/settings-ui-unify` | 已删除 | 2026-09-14 dong4j 确认删除。已以 merge commit（`a7a4c5c7`）合入 `dev`，删除前 `merge-base --is-ancestor` 成立、独有提交 0、`git cherry` 为空、`../Starcat-settings-ui-unify` worktree 干净后 `git worktree remove`，再 `git branch -d`（HEAD `bb013ab1`）。从未存在远端分支。 |
| `feature/local-ai` | 已删除 | 2026-09-13 dong4j 确认删除。2026-09-12 已以 merge commit（`84b7e5c5`）合入 `dev`，删除前 `merge-base --is-ancestor` 成立、独有提交 0、`git cherry` 为空、diff 为空；`../Starcat-local-ai` worktree 干净后 `git worktree remove`，再 `git branch -d`（HEAD `d78b6fcb`）。从未存在远端分支。 |
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

2026-11-06 交付核对：内容 `12bf3159`、独立 API `ddf410b1`、Weekly 迁出 `ed1402cb`、
聚合 `0c069881` 均已推送同名功能分支。聚合 release 39 在现有单 Machine 部署，
八服务健康与业务只读抽样通过；内容及新后端仍为 Private。人工验收与
`AI_EVENTS_READ_TOKEN` 配置尚待完成，验收清单见正式链路设计文档。
