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

## ⚠️ 临时技术债提醒（必读，2026-05-30 起生效）

当前 `KeychainManager.swift` 在 **DEBUG 编译下启用了"Keychain + 沙盒文件双写"绕过方案**，
用于解决 ad-hoc 签名 + App Sandbox 导致 token 跨构建无法持久化的问题。

**发布前必须执行完整切换流程**，详见 `docs/工程进度/2026-05-30-Keychain-临时绕过方案.md`。

切换的触发条件：用户完成 Xcode Apple ID Team 配置 → 重新启用 `keychain-access-groups` entitlement → 删除 `#if DEBUG` 块。

> 当本段提醒还在时，意味着这个技术债没还。任何 release 前的工程审查都必须检查这一项。

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

### 问题处理

- 发现文档间不一致时，以 `开发前问题清单.md` 中的决策为准
- 新发现的问题先记录到 `开发前问题清单.md`，再实施修改

---

*最后更新：2026-05-29*


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