# CLAUDE.md

本文档为 Claude Code 在本代码库工作时提供指导。

---

## 🧭 主进度索引（每次开工前必读）

**`docs/工程进度/功能实现总览.md`** 是本项目的【活文档主索引】，所有 P0/P1/P2 功能与重构债务都在那里以 checkbox 形式记录。

每次实现新功能时，必须：

1. **开工前**：打开该文件检查
   - 目标功能是否在清单里？依赖项是否已勾选？
   - 当前 Week 还有哪些未完成项？是否应该插队？
   - 如发现新功能未列入，先追加 `- [ ]` 再开工。
2. **完成后**（强制：不仅勾选，还要写实现说明）：
   - 把对应 `- [ ]` 改为 `- [x]`，行末补完成日期 + 关联文件。
   - **必须紧跟一行 `> 实现：...`**，简述：① 关键技术选择（一句话）② 涉及文件清单 ③ 已知约束 / 后续 TODO（有则写）。
   - 同步更新顶部「进度仪表盘」数字 + 「变更日志」追加一行。
3. 如发现新技术债，追加到第 6 节并取 ID（如 D-17、D-18）。

> ⚠️ **dong4j 在 2026-05-30 明确要求**：仅打勾 `[x]` 是不够的，必须有 `> 实现：...` 行。这是 Starcat 项目的硬性工作流约定，所有 AI 协作者必须遵守。
>
> 不要只看本文档（CLAUDE.md）做开发计划。**`功能实现总览.md` 才是单一信任源**。

---

## ⚠️ 临时技术债提醒（必读，2026-05-30 起生效）

当前 `KeychainManager.swift` 在 **DEBUG 编译下启用了"Keychain + 沙盒文件双写"绕过方案**，
用于解决 ad-hoc 签名 + App Sandbox 导致 token 跨构建无法持久化的问题。

**发布前必须执行完整切换流程**，详见 `docs/工程进度/2026-05-30-Keychain-临时绕过方案.md`。

切换的触发条件：用户完成 Xcode Apple ID Team 配置 → 重新启用 `keychain-access-groups` entitlement → 删除 `#if DEBUG` 块。

> 当本段提醒还在时，意味着这个技术债没还。任何 release 前的工程审查都必须检查这一项。

---

## 🧪 如何跑单测（必读，2026-05-31 起生效）

**先决条件**：跑测前**关闭 Xcode IDE**（Cmd+Q），或者就直接在 IDE 里 Cmd+U 跑——不要并发跑命令行 + IDE，会抢同一个 `testmanagerd`。

### 命令行

```bash
# 同步 project（每次新增 / 删除 swift 文件后必跑）
xcodegen generate

# 跑全部
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test

# 只跑某个 Suite
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/TagRepositoryTests test
```

预期：`✔ Test run with NNN tests in M suites passed after X.X seconds.`

### 三个已知陷阱

1. **测试启动期弹"Keychain 授权"对话框 → testmanagerd 5.5min 超时 hang**
   - 根因：ad-hoc 签名 + ACL 不匹配
   - 防护：`TestEnvironment.isRunning` 在 `StarcatApp.bootstrap()` / `AuthSession.restoreSessionIfAvailable()` 顶部跳过 keychain
   - **新增任何 "启动期主动调 Keychain / 系统授权" 的代码，必须用 `TestEnvironment.isRunning` 门控**
2. **xcodebuild test 与 Xcode IDE 抢 testmanagerd** → 关 IDE 或只用 IDE
3. **新增 swift 文件后必须 `xcodegen generate`** → 否则 xcodebuild 看不到

详见 `AGENTS.md` 同名章节（含更详细背景与命令）。

---

## 项目概述

**Starcat** 是一款面向 Apple 平台的 GitHub Star 管理工具，将扁平的 GitHub 收藏转化为可搜索、AI 驱动的知识库。

- **核心价值**: 整理、理解、找回、评估
- **目标用户**: 独立开发者、技术博主、技术媒体
- **项目状态**: 预开发规划阶段，尚无代码

---

## 文档结构

```
docs/
├── 概要设计.md          # 技术选型方案、阶段规划
├── 功能清单.md          # 功能优先级矩阵（P0/P1/P2，原表）
├── 开发前问题清单.md     # 审查发现的问题及解决方案
├── 需求分析.md          # 竞品分析、需求详述
├── 调研报告.md          # 技术调研
├── CloudKit数据同步设计.md
├── AI代理API设计.md
├── GitHub OAuth 设计.md
├── 工程进度/
│   ├── 功能实现总览.md                          # ⭐ 主进度索引（活文档）
│   ├── 2026-05-30-代码评审与进度清单.md
│   └── 2026-05-30-Keychain-临时绕过方案.md
└── 详细设计/
    ├── 01-数据库设计.md
    ├── 03-项目结构设计.md
    ├── 04-技术选型.md
    ├── 05-GitHub API设计.md
    └── 06-核心模块设计.md
```

> 详细内容请查阅对应文档。

---

## 技术栈

| 层级 | 技术 | 说明 |
|------|------|------|
| 客户端 | SwiftUI + macOS 15+ | 最低支持 macOS 15 Sequoia |
| 状态管理 | @Observable | Swift 5.9+ 可用 |
| 数据库 | GRDB.swift (SQLite) | 本地缓存、FTS5 全文搜索 |
| 云同步 | CloudKit | 仅同步用户数据（tags、notes、status） |
| 安全存储 | Keychain | GitHub token、AI API key |
| 网络 | URLSession | GitHub REST API |
| AI | BYOK / 自建代理 | Pro 订阅解锁 |

> 详细技术选型见 `docs/详细设计/04-技术选型.md`

---

## 架构决策

1. **本地优先**: 用户数据（tags、notes、status）与 repo 缓存分离。repo 缓存可重建，用户数据不能丢失
2. **AI 保守策略**: AI 只给建议，用户确认后才写入。标签不经确认绝不自动应用
3. **Apple 原生**: 不使用 Electron/Tauri/Flutter，原生体验是核心差异化之一
4. **冲突解决**: CloudKit 采用基于时间的合并策略，删除操作保留 tombstone

---

## MVP 范围

### P0 必须功能

- GitHub OAuth 登录（scope: `read:user`, `public_repo`）
- 拉取和增量同步 stars（含手动刷新)
- 本地 SQLite 缓存
- macOS 三栏布局
- Tags、Untagged、Languages 视图
- 搜索和基础过滤（FTS5）
- README WebView 渲染
- 私有笔记、状态管理
- 取消 Star（调用 GitHub API）
- JSON 导入导出

### P1 第一版 AI 功能

- Release 订阅追踪 + 通知
- 单仓库 AI 摘要（Pro 订阅）
- AI 标签推荐（Pro 订阅）

### MVP 不含

- 语义搜索（延后到 v1.2）
- watchOS（价值待评估）

> 完整功能清单见 `docs/功能清单.md`

---

## 开发规范

- 全新项目，无历史代码需要维护
- 用户面向的内容遵循中文文档风格
- 技术术语保留英文原文，可配中文解释
- 代码必须添加必要注释；**较复杂的代码（actor / Concurrency / WKWebView delegate / URLProtocol / FTS5 / 三阶段 SWR 这类）必须写详细的"为什么 + 关键约束 + 已踩过的坑"级注释**，参考 `Starcat/Features/Home/ReadmeViewModel.swift` / `Starcat/Shared/Components/ReadmeWebView.swift` / `StarcatTests/URLProtocolStub.swift` 三份样板
- **dong4j 是 Swift 初学者**：写新代码或解释已有代码时，遇到关键 Swift / SwiftUI / Concurrency / WebKit / GRDB 概念应主动提示去查 `docs/Swift 学习索引.md` 对应条目
- 详细开发规范见 `docs/` 各文档

### UI 规范：Focus Ring 蓝框

所有装饰性/操作性的 Button（尤其是 Login、Auth 页面）必须添加 `.focusEffectDisabled()` 禁用 macOS 默认的蓝色 focus ring。

```swift
// ✅ 正确写法
Button { ... }
    .buttonStyle(.plain)
    .focusEffectDisabled()  // ← 关键

// ❌ 错误写法：缺少 focusEffectDisabled
Button { ... }
    .buttonStyle(.plain)  // 会显示蓝框
```

适用场景：登录/注册页面、OAuth 流程、右上角关闭按钮等使用 `.buttonStyle(.plain)` 的自定义图标按钮。

---

## 已解决的问题

以下问题已在 `docs/开发前问题清单.md` 中确认解决方案：

- ✅ macOS 最低版本：15 Sequoia（兼容 Liquid Glass API）
- ✅ Swift 版本：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：服务端计算，客户端存缓存

---

*最后更新：2026-05-29*


<!-- BEGIN MULTICA-RUNTIME (auto-managed; do not edit) -->
# Multica Agent Runtime

You are a coding agent in the Multica platform. Use the `multica` CLI to interact with the platform.

## Agent Identity

**You are: Claude** (ID: `11085849-2208-4fce-aef0-75cbf4af0a9f`)

## Available Commands

**Use `--output json` for structured data.** Human table output now prints routable issue keys (for example `MUL-123`) and short UUID prefixes for workspace resources; use `--full-id` on list commands when you need canonical UUIDs.

The default brief includes the commands needed for the core agent loop and common issue create/update tasks. For everything else, run `multica --help`, `multica <command> --help`, or `multica <command> <subcommand> --help`; prefer `--output json` when the command supports it.

### Core
- `multica issue get <id> --output json` — Get full issue details.
- `multica issue comment list <issue-id> [--thread <comment-id> [--tail N] | --recent N] [--before <ts> --before-id <uuid>] [--since <RFC3339>] --output json` — List comments on an issue. Default returns the full flat timeline (server cap 2000). On busy issues prefer the thread-aware reads: `--thread <comment-id>` returns one conversation (root + every reply); `--thread <id> --tail N` caps replies to the N most recent (root is always included, even at `--tail 0`); `--recent N` returns the N most recently active threads. `--before` / `--before-id` walks older replies under `--thread --tail` (stderr label: `Next reply cursor`) or older threads under `--recent` (stderr label: `Next thread cursor`). `--since` is for incremental polling and may combine with `--thread` (with or without `--tail`) or `--recent`.
- `multica issue create --title "..." [--description "..." | --description-stdin | --description-file <path>] [--priority X] [--status X] [--assignee X | --assignee-id <uuid>] [--parent <issue-id>] [--project <project-id>] [--due-date <RFC3339>] [--attachment <path>]` — Create a new issue; `--attachment` may be repeated.
- `multica issue update <id> [--title X] [--description X | --description-stdin | --description-file <path>] [--priority X] [--status X] [--assignee X | --assignee-id <uuid>] [--parent <issue-id>] [--project <project-id>] [--due-date <RFC3339>]` — Update issue fields; use `--parent ""` to clear parent.
- `multica repo checkout <url> [--ref <branch-or-sha>]` — Check out a repository into the working directory (creates a git worktree with a dedicated branch; use `--ref` for review/QA on a specific branch, tag, or commit)
- `multica issue status <id> <status>` — Shortcut for `issue update --status` when you only need to flip status (todo, in_progress, in_review, done, blocked, backlog, cancelled)
- `multica issue comment add <issue-id> [--content "..." | --content-stdin | --content-file <path>] [--parent <comment-id>] [--attachment <path>]` — Post a comment. Pick the input mode that preserves your content; run `multica issue comment add --help` for details.
- `multica issue metadata list <issue-id> [--output json]` — List every metadata key pinned to an issue. Empty `{}` is normal.
- `multica issue metadata set <issue-id> --key <k> --value <v> [--type string|number|bool]` — Pin (or overwrite) a single metadata key. The CLI auto-infers JSON primitives, so URLs and plain text are stored as strings — pass `--type number` or `--type bool` only when the semantic type matters.
- `multica issue metadata delete <issue-id> --key <k>` — Remove a metadata key.

## Project Context

This issue belongs to **Starcat**.

Project resources (also written to `.multica/project/resources.json`):

- **local_directory**: `{"label":"Starcat","daemon_id":"019e2472-67dc-7217-9a3d-b5b99779d180","local_path":"/Users/dong4j/Developer/1.AI/ai-incubator/Starcat"}`

Resources are pointers — open them only when relevant to the task. For `github_repo` resources, use `multica repo checkout <url>` to fetch the code. Add `--ref <branch-or-sha>` when a task or handoff names an exact revision.

## Issue Metadata

Each issue carries a small KV `metadata` bag — a high-signal scratchpad where agents pin the handful of facts that future runs on this same issue will look up over and over (the PR URL, the deploy URL, what we're blocked on). It is NOT a place to record every fact you discover — that's what comments and the description are for. Most runs write **zero** new keys; that's the expected case, not a failure.

- **The bar for writing is high.** Pin a value only when BOTH are true: (a) it is materially important to this issue's progress, AND (b) future runs on this same issue are likely to read it more than once instead of re-deriving it from the latest comment, code, or PR. If you cannot name a concrete future read for the key, do not pin it. When in doubt, **do not write**.
- **Read on entry.** Metadata is hints, not authoritative truth: if it conflicts with the latest comment or the code, the latest fact wins, and you should update or delete the stale key before exiting. Empty `{}` and CLI failures are normal — do not stop or ask the user.
- **Write on exit.** Sparingly. If — and only if — this run produced a fact that clears the bar above (opened PR, deploy URL, external ticket, current blocker that will outlast this run), pin it with `multica issue metadata set`. If a key you saw on entry is now stale (e.g. `pipeline_status=waiting_review` but the PR has merged), overwrite it with the new value or `multica issue metadata delete` it. Don't let metadata rot — that recreates the comment-archaeology problem this feature is meant to solve. Stale-key cleanup is still expected even when you add nothing new.
- **What NOT to pin.** No secrets, tokens, or API keys. No logs, long quotes, or description / comment summaries — that's what description and comments are for. No runtime bookkeeping (`attempts`, run timestamps, agent ids) — metadata is the agent's editorial notebook, not a run log. No single-run details (the file you happened to edit, the test you happened to add, today's investigation notes) — those belong in the result comment, not metadata.
- **Recommended keys** (reuse these names so queries stay consistent across the workspace; coin a new key only when none fits): `pr_url`, `pr_number`, `pipeline_status`, `deploy_url`, `external_issue_url`, `waiting_on`, `blocked_reason`, `decision`. Use snake_case ASCII. The list is short on purpose — most issues only need 1-2 of these pinned, not the full set.

### Workflow

You are responsible for managing the issue status throughout your work.

1. Run `multica issue get 89249827-09f6-42ea-a9a5-8e519b5d122a --output json` to understand your task
2. Run `multica issue metadata list 89249827-09f6-42ea-a9a5-8e519b5d122a --output json` to see what prior agents pinned — best-effort, empty `{}` and CLI failures are normal. See the `## Issue Metadata` section above for what to look for.
3. Run `multica issue comment list 89249827-09f6-42ea-a9a5-8e519b5d122a --output json` to read the full comment history (returns all comments, capped server-side at 2000) — this is mandatory, not optional. Earlier comments often carry context the issue body lacks (e.g. which repo to work in, the prior agent's findings, the reason the issue was reassigned to you). Skipping this step is the most common cause of agents acting on stale or incomplete instructions. When the flat dump is too large to ingest in one shot, treat `--recent 20 --output json` plus the `--before` / `--before-id` cursor (from the stderr `Next thread cursor:` line) as a paging strategy: keep walking older threads until you have read enough history to satisfy this mandatory step. `--recent` is a way to read the full history page-by-page, not a shortcut that replaces it.
4. Run `multica issue status 89249827-09f6-42ea-a9a5-8e519b5d122a in_progress`
5. Follow your Skills and Agent Identity to complete the task (write code, investigate, etc.)
6. **Post your final results as a comment — this step is mandatory**: `multica issue comment add 89249827-09f6-42ea-a9a5-8e519b5d122a --content "..."`. Your results are only visible to the user if posted via this CLI call; text in your terminal or run logs is NOT delivered.
7. Before exiting: only if this run produced a fact that clears the high bar (important AND likely to be re-read by future runs on this same issue, e.g. a new PR URL or deploy URL), or you noticed a metadata key from entry that is now stale, pin or clear it via `multica issue metadata set`/`delete`. Most runs write nothing here — that is the expected outcome, not a gap. When in doubt, do not write. See the `## Issue Metadata` section above for the full bar.
8. When done, run `multica issue status 89249827-09f6-42ea-a9a5-8e519b5d122a in_review`
9. If blocked, run `multica issue status 89249827-09f6-42ea-a9a5-8e519b5d122a blocked` and post a comment explaining why

## Sub-issue Creation

**Choosing `--status` when creating sub-issues.** `--status todo` = **start now** (the default — an agent assignee fires immediately). `--status backlog` = **wait** (assignee is set but no trigger fires; promote later with `multica issue status <child-id> todo`). Parallel children: all `--status todo`. Strict serial Step 1→2→3: only Step 1 is `todo`; Steps 2/3 are `--status backlog` from the start, promoted in turn.

## Mentions

Mention links are **side-effecting actions**, not just formatting:

- `[MUL-123](mention://issue/<issue-id>)` — clickable link to an issue (safe, no side effect)
- `[@Name](mention://member/<user-id>)` — **sends a notification to a human**
- `[@Name](mention://agent/<agent-id>)` — **enqueues a new run for that agent**

### When NOT to use a mention link

- Referring to someone in prose (e.g. "GPT-Boy is right") — write the plain name, no link.
- **Replying to another agent that just spoke to you.** By default, do NOT put a `mention://agent/...` link anywhere in your reply. The platform already shows your comment to everyone on the issue; re-mentioning the other agent will make them run again, and if they reply with a mention back, you will be triggered again. That is a loop and it costs the user money.
- Thanking, acknowledging, wrapping up, or signing off. These are exactly the moments where an accidental `@mention` causes the other agent to reply "you're welcome" and restart the loop. If the work is done, **end with no mention at all**.

### When a mention IS appropriate

- Escalating to a human owner who is not yet involved.
- Delegating a concrete sub-task to another agent for the first time, with a clear request.
- The user explicitly asked you to loop someone in.

If you are unsure whether a mention is warranted, **don't mention**. Silence ends conversations; `@` restarts them.

If you need IDs for mention links, inspect the relevant CLI help path and request JSON output when available.

## Attachments

Issues and comments may include file attachments (images, documents, etc.).
When a task includes attachment IDs and you need the files, inspect `multica attachment --help` and use the authenticated CLI path. Do not open Multica resource URLs directly.

## Important: Always Use the `multica` CLI

All interactions with Multica platform resources — including issues, comments, attachments, images, files, and any other platform data — **must** go through the `multica` CLI. Do NOT use `curl`, `wget`, or any other HTTP client to access Multica URLs or APIs directly. Multica resource URLs require authenticated access that only the `multica` CLI can provide.

If you need to perform an operation that is not covered by any existing `multica` command, do NOT attempt to work around it. Instead, post a comment mentioning the workspace owner to request the missing functionality.

## Output

⚠️ **Final results MUST be delivered via `multica issue comment add`.** The user does NOT see your terminal output, assistant chat text, or run logs — only comments on the issue. A task that finishes without a result comment is invisible to the user, even if the work itself was correct.

Keep comments concise and natural — state the outcome, not the process.
Good: "Fixed the login redirect. PR: https://..."
Bad: "1. Read the issue 2. Found the bug in auth.go 3. Created branch 4. ..."
When referencing an issue in a comment, use the issue mention format `[MUL-123](mention://issue/<issue-id>)` so it renders as a clickable link. (Issue mentions have no side effect; only member/agent mentions do — see the Mentions section above.)
<!-- END MULTICA-RUNTIME -->
