# AGENTS.md

本文档为跨 Agent 协作提供指导，确保多个 Agent 在本代码库工作时保持一致。

---

## 🧭 主进度索引（每次开工前必读）

**`docs/工程进度/功能实现总览.md`** 是本项目的【活文档主索引】，所有 P0/P1/P2 功能与重构债务都在那里以 checkbox 形式记录。

任意 Agent 在动手实现新功能前必须：

1. **打开该文件检查**：目标功能是否已列入、依赖是否已完成、当前 Week 还剩哪些未做。
2. **完成后立即勾选 + 写实现说明**：
   - 把 `- [ ]` 改 `- [x]`，行末补完成日期 + 关联文件。
   - **必须紧跟一行 `> 实现：...`**，简述：① 关键技术选择（一句话）② 涉及文件清单 ③ 已知约束 / 后续 TODO（有则写）。
   - 顶部「进度仪表盘」数字 + 「变更日志」同步。
3. **新增功能 / 新技术债**：先在对应章节追加条目（功能用 `- [ ]`，技术债取下一个 D-编号），再动手实现。

> ⚠️ **dong4j 在 2026-05-30 明确要求**：仅打勾 `[x]` 是不够的，必须有 `> 实现：...` 行。这是 Starcat 项目的硬性工作流约定，所有 AI 协作者必须遵守。
>
> 不要凭 CLAUDE.md / AGENTS.md 自行推测进度。**`功能实现总览.md` 才是单一信任源**。

---

## 🧪 如何跑单测（必读，2026-05-31 起生效）

**当前最低要求**：跑测前**关闭 Xcode IDE**（Cmd+Q），否则 `xcodebuild test` 与 IDE 抢占同一 `testmanagerd` 实例，可能挂起。

### A. 命令行（CI 友好，推荐 AI Agent 用）

```bash
# 1) 把 xcodegen 生成的 project 同步到最新（每次新增 / 删除 swift 文件后必跑）
xcodegen generate

# 2) 跑全部单测
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test

# 2.1) 只跑某个 Suite（迭代时省时间）
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/TagRepositoryTests test

# 2.2) 同时跑多个 Suite
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/TagRepositoryTests \
  -only-testing:StarcatTests/RepoTagRepositoryTests test
```

预期输出形如：

```
✔ Test "..." passed after 0.003 seconds.
...
✔ Test run with 110 tests in N suites passed after 0.X seconds.
```

### B. Xcode IDE（人工验证用）

在 Xcode 打开 `Starcat.xcodeproj` → Cmd+U 跑全部，或 ⌃⌥⌘U 选择性跑。

### ⚠️ 已知问题 #1：测试 host 启动期弹"Keychain 授权"对话框

**症状**：
- 命令行 `xcodebuild test` 5.5min 后报 `The test runner hung before establishing connection.`
- 屏幕上可能出现 *"Starcat 想要使用你储存在钥匙串的 com.starcat.app 中的机密信息"* 对话框

**根因**：
- ad-hoc 签名下，每次构建后 App 的 code-signature hash 都变，与历史 keychain item ACL 不匹配
- 测试 host App 在启动期任何 `Keychain` 调用都会触发 macOS GUI 授权对话框
- 测试 host 无窗口接收点击 → 主线程死等 → `testmanagerd` 超时

**已加的防护（不要回退）**：
- `Starcat/Shared/Utilities/TestEnvironment.swift`：单一信息源，`TestEnvironment.isRunning == true` 时为测试 host
- `StarcatApp.bootstrap()`：测试期跳过 `KeychainManager.shared.ping()`
- `AuthSession.restoreSessionIfAvailable()`：测试期 no-op

**新增任何 "App 启动期主动调 Keychain / 系统授权" 的代码路径，都必须用 `TestEnvironment.isRunning` 门控。**

### ⚠️ 已知问题 #2：xcodebuild test 与 Xcode IDE 抢 testmanagerd

跑测前请关闭 Xcode IDE，或在 IDE 里直接 Cmd+U。

### ⚠️ 已知问题 #3：新增 Swift 文件后必须 `xcodegen generate`

`Starcat.xcodeproj` 由 xcodegen 从 `project.yml` 自动生成。新增 / 删除 swift 文件后必须先跑 `xcodegen generate`，否则 `xcodebuild` 看不到新文件，会报 `cannot find type ... in scope`。

---

## 项目概述

**Starcat** 是一款面向 Apple 平台的 GitHub Star 管理工具，将扁平的 GitHub 收藏转化为可搜索、AI 驱动的知识库。

- **核心价值**: 整理、理解、找回、评估
- **目标用户**: 独立开发者、技术博主、技术媒体
- **项目状态**: 预开发规划阶段，尚无代码

---

## 文档导航

| 文档 | 用途 |
|------|------|
| **`docs/工程进度/功能实现总览.md`** | **【主进度索引】所有功能 checkbox + 重构债务，开工前必读** |
| `CLAUDE.md` | 单次会话指导，快速了解项目 |
| `docs/概要设计.md` | 技术选型、阶段规划 |
| `docs/功能清单.md` | 功能优先级原表（P0/P1/P2 详细描述） |
| `docs/开发前问题清单.md` | 已解决的问题及解决方案 |
| `docs/详细设计/*.md` | 模块详细设计 |

> **阅读顺序建议**：先读 `CLAUDE.md` 了解概览，再根据任务需要查阅对应文档。

---

## 技术栈（保持一致）

| 层级 | 技术 | 说明 |
|------|------|------|
| 客户端 | SwiftUI + macOS 15+ | 最低 macOS 15 Sequoia |
| 状态管理 | @Observable | Swift 5.9+ 可用 |
| 数据库 | GRDB.swift (SQLite) | FTS5 全文搜索 |
| 云同步 | CloudKit | 仅同步用户数据 |
| 安全存储 | Keychain | Token 存储 |
| AI | BYOK / 自建代理 | Pro 订阅解锁 |

---

## 架构决策（关键约束）

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

---

## 已解决的问题

以下问题已在 `docs/开发前问题清单.md` 中确认解决方案，开发时必须遵循：

- ✅ macOS 最低版本：15 Sequoia
- ✅ Swift：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：服务端计算，客户端存缓存
- ✅ Release 订阅通知：使用轮询方案

---

## 跨 Agent 协作规范

### 文档修改

- 修改任何文档前，先检查 `docs/开发前问题清单.md` 确认是否有相关决策
- 跨文档的一致性修改（如技术栈变更），需要同步更新所有相关文档
- 新增设计决策时，在 `开发前问题清单.md` 中记录

### 代码规范

- 代码必须添加必要注释，解释"为什么这样做"
- **较复杂的代码（actor / Concurrency / WKWebView delegate / URLProtocol / FTS5 / 三阶段 SWR 这类）必须写详细的"为什么 + 关键约束 + 已踩过的坑"级注释**。参考样板：`Starcat/Features/Home/ReadmeViewModel.swift` / `Starcat/Shared/Components/ReadmeWebView.swift` / `StarcatTests/URLProtocolStub.swift`
- **dong4j 是 Swift 初学者**：写新代码或解释已有代码时，遇到关键 Swift / SwiftUI / Concurrency / WebKit / GRDB 概念应主动提示去查 `docs/Swift 学习索引.md` 对应条目（仅给关键词 + 项目内代码位置 + 官方搜索词，不展开教学）
- 遵循现有代码风格
- 详细规范见各设计文档

### UI 规范：Focus Ring 蓝框（强制）

**所有**使用 `.buttonStyle(.plain)` 的 Button **必须**添加 `.focusEffectDisabled()`，禁用 macOS 默认的蓝色 focus ring。

> ⚠️ 这是强制规则。任何新建或修改的 Button 若遗漏 `.focusEffectDisabled()`，必须补上。

```swift
// ✅ 正确写法
Button { ... }
    .buttonStyle(.plain)
    .focusEffectDisabled()  // ← 强制，放在 buttonStyle 之后

// ❌ 错误写法：缺少 focusEffectDisabled（会显示蓝框）
Button { ... }
    .buttonStyle(.plain)
```

**适用场景**（包括但不限于）：
- 侧边栏折叠/展开按钮（chevron）
- 登录/注册页面、OAuth 流程所有按钮
- 右上角关闭按钮（xmark.circle.fill）
- 搜索栏展开/收起按钮
- 工具栏图标按钮（sync、filter、sort 等）
- Tags 管理相关按钮（+、编辑、删除）
- 任何自定义图标的装饰性/操作性按钮

**新增 Button 时的检查流程**：
1. 若使用 `.buttonStyle(.plain)` → 必须紧跟 `.focusEffectDisabled()`
2. 提交前用 `grep -n "buttonStyle.plain" --include="*.swift" .` 检查该文件是否遗漏

> 注意：`.buttonStyle(.borderedProminent)` 通常已遮挡 focus ring，但安全起见也建议添加。

### 问题处理

- 发现文档间不一致时，以 `开发前问题清单.md` 中的决策为准
- 新发现的问题先记录到 `开发前问题清单.md`，再实施修改

---

*最后更新：2026-06-01*


<claude-mem-context>
# Memory Context

# claude-mem status

This project has no memory yet. The current session will seed it; subsequent sessions will receive auto-injected context for relevant past work.

Memory injection starts on your second session in a project.

`/learn-codebase` is available if the user wants to front-load the entire repo into memory in a single pass (~5 minutes on a typical repo, optional). Otherwise memory builds passively as work happens.

Live activity: http://localhost:37701
How it works: `/how-it-works`

This message disappears once the first observation lands.
</claude-mem-context>

<!-- BEGIN MULTICA-RUNTIME (auto-managed; do not edit) -->
# Multica Agent Runtime

You are a coding agent in the Multica platform. Use the `multica` CLI to interact with the platform.

## Agent Identity

**You are: Cursor** (ID: `41979695-2658-4251-9d8d-4c81e730f5cc`)

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
- `multica issue comment add <issue-id> [--content "..." | --content-stdin | --content-file <path>] [--parent <comment-id>] [--attachment <path>]` — Post a comment. For agent-authored bodies, do NOT inline `--content` — the shell can rewrite backticks, `$()`, quotes, or newlines before the CLI sees them; use the platform-correct non-inline mode shown in ## Comment Formatting below. Run `multica issue comment add --help` for details.
- `multica issue metadata list <issue-id> [--output json]` — List every metadata key pinned to an issue. Empty `{}` is normal.
- `multica issue metadata set <issue-id> --key <k> --value <v> [--type string|number|bool]` — Pin (or overwrite) a single metadata key. The CLI auto-infers JSON primitives, so URLs and plain text are stored as strings — pass `--type number` or `--type bool` only when the semantic type matters.
- `multica issue metadata delete <issue-id> --key <k>` — Remove a metadata key.

### Squad maintenance
- `multica squad member set-role <squad-id> --member-id <id> --member-type <agent|member> --role <role> [--output json]` — Change a squad member role in place; use this instead of remove+add when only the role changes.

## Comment Formatting

For issue comments, always use `--content-stdin` with a HEREDOC, even for short single-line replies — use a quoted delimiter (`<<'COMMENT'`) so the shell does not expand backticks, `$()`, or `$VAR` inside the body. `--content-file <path>` works too. Never use inline `--content` for agent-authored comments: unescaped backticks, `$()`, `$VAR`, or quotes in the body are rewritten by the shell before the CLI receives them. Keep the same `--parent` value from the trigger comment when replying. Do not compress a multi-paragraph answer into one line and do not rely on `\n` escapes.

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

**This task was triggered by a NEW comment.** Your primary job is to respond to THIS specific comment, even if you have handled similar requests before in this session.

1. Run `multica issue get 26313430-0c9b-46fe-8d79-b332f385eb83 --output json` to understand the issue context
2. Run `multica issue metadata list 26313430-0c9b-46fe-8d79-b332f385eb83 --output json` to see what prior agents pinned — best-effort, empty `{}` and CLI failures are normal. See the `## Issue Metadata` section above for what to look for.
3. You're resuming the prior session, and the triggering comment is already included above. No other new comments on this issue since your last run. Use the triggering comment ID / thread anchor: `6ede3090-9397-4f5f-be76-456a4a97e858`. If your reply depends on thread context, do not rely only on resumed session memory — first pull the triggering conversation with: `multica issue comment list 26313430-0c9b-46fe-8d79-b332f385eb83 --thread 6ede3090-9397-4f5f-be76-456a4a97e858 --tail 30 --output json`.

4. Find the triggering comment (ID: `6ede3090-9397-4f5f-be76-456a4a97e858`) and understand what is being asked — do NOT confuse it with previous comments
5. **Decide whether a reply is warranted.** If you produced actual work this turn (investigated, fixed, answered a real question), post the result via step 7 — that is a normal reply, not a noise comment. If the triggering comment was a pure acknowledgment / thanks / sign-off from another agent AND you produced no work this turn, do NOT post a reply — and do NOT post a comment saying 'No reply needed' or similar. Simply exit with no output. Silence is a valid and preferred way to end agent-to-agent conversations.
6. If a reply IS warranted: do any requested work first, then **decide whether to include any `@mention` link.** The default is NO mention. Only mention when you are escalating to a human owner who is not yet involved, delegating a concrete new sub-task to another agent for the first time, or the user explicitly asked you to loop someone in. Never @mention the agent you are replying to as a thank-you or sign-off.
7. **If you reply, post it as a comment — this step is mandatory when you reply.** Text in your terminal or run logs is NOT delivered to the user. If you decide to reply, post it as a comment — always use the trigger comment ID below, do NOT reuse --parent values from previous turns in this session.

Always use `--content-stdin` with a HEREDOC for agent-authored issue comments, even when the reply is a single line. Do NOT use inline `--content`; the shell rewrites unescaped backticks, `$()`, `$VAR`, or quotes in the body before the CLI receives them, and it is easy to lose formatting or compress a structured reply into one line.

Use this form, preserving the same issue ID and --parent value:

    cat <<'COMMENT' | multica issue comment add 26313430-0c9b-46fe-8d79-b332f385eb83 --parent 6ede3090-9397-4f5f-be76-456a4a97e858 --content-stdin
    First paragraph.

    Second paragraph.
    COMMENT

Do NOT write literal `\n` escapes to simulate line breaks; the HEREDOC preserves real newlines.
8. Before exiting: only if this run produced a fact that clears the high bar (important AND likely to be re-read by future runs on this same issue, e.g. a new PR URL or deploy URL), or you noticed a metadata key from entry that is now stale, pin or clear it via `multica issue metadata set`/`delete`. Most runs write nothing here — that is the expected outcome, not a gap. When in doubt, do not write. See the `## Issue Metadata` section above for the full bar.
9. Do NOT change the issue status unless the comment explicitly asks for it

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
