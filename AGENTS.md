# AGENTS.md

本文档为跨 Agent 协作提供指导，确保多个 Agent 在本代码库工作时保持一致。

---

## 🚨 硬性铁律（每次写代码前必读，违反即返工）

> ⚠️ **【铁律 #1】本项目未上线、无线上用户、无线上数据。**
> ⚠️ **禁止写任何"兼容旧字段 / 兼容老版本 / 向后兼容 / 数据迁移 / 保留旧 API"的代码、注释、测试或设计。**
> ⚠️ **看到旧路径不再需要 → 直接删；字段废弃 → 直接改 schema；任何"保留兼容"的提议都是错的，必须当场拒绝。**

> ⚠️ **【铁律 #2】方案讨论 ≠ 动手许可。**
> ⚠️ **dong4j 在反馈方案 / 修正理解 / 给出补充信息时，默认仍在讨论阶段。**
> ⚠️ **必须等 dong4j 明确说「开干 / 改吧 / GO / 动手 / 实施」等字眼，才能开始改代码；只要还在交换意见就只读不写。**

> ⚠️ **【铁律 #3】禁止擅自执行打包 / 发布 / 上传脚本。**
> ⚠️ **除非 dong4j 在当前消息里明确要求执行，否则 Agent 只能修改脚本、写文档、给命令，不能执行 `scripts/package-*`、`scripts/release-*`、`deploy.sh`、notary 上传、App Store 上传、服务器上传等会生成或发布分发产物的命令。**
> ⚠️ **允许执行只读检查命令，例如 `bash -n`、`git diff --check`、`codesign -d`、`PlistBuddy -c Print`、`dwarfdump --uuid`。**

---

## 🧭 主进度索引（每次开工前必读）

**`docs/功能实现总览.md`** 是本项目的【活文档主索引】，所有 P0/P1/P2 功能与重构债务都在那里以 checkbox 形式记录。

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

### 状态符号（与功能实现总览.md 同步）

| 符号 | 含义 |
|------|------|
| `- [x]` | 已完成 |
| `- [ ]` | 待开始 |
| `- [~]` | 部分完成 / 进行中（手写非标准，正文加 ⚠️ 行注释） |
| `✅` | 章节级完成 |
| `⏳` | 章节级计划中 |
| `⚠️` | 有技术债 / 临时方案 |
| `❌` | 已决定不做 |

### 4 条 AI 协作规范（2026-06-28 生效）

1. **勾选完成项时**：
   - checkbox 格式严格：`- [x] **功能名** — 简短描述 — `主要文件路径` — YYYY-MM-DD`
   - 如写 `> 实现:`，必须 ≤ 200 字、一段话，只说「为什么 / 做了什么 / 关键约束」
   - **不写**「涉及 N 文件 / 验证步骤 / 未做清单 / 反思 / dong4j 验收」几大段
2. **新增章节时**：
   - 章节标题**不带**日期、状态符号、周次
   - 章节下**第一行**单独写「状态说明」，例如：`> 状态: 进行中(W6 / 9 项完成)`
   - §0 不再加新子节，新功能条目加到 §3 / §4 / §5 对应章节
3. **变更日志**：
   - 必须在 `功能实现总览.md` §10 顶部加一行：`- YYYY-MM-DD HH:MM: 一句话描述`(≤ 80 字)
   - 不带 emoji / 不带粗体 / 不写「涉及 N 文件 / 验证 / 反思 / 未做」
4. **不要**：
   - 在 `> 实现:` 写「涉及 N 文件 / 验证步骤 / 反思 / 未做」几大段
   - 在章节标题里带 `(W?+)` / `(2026-MM-DD 新增)` / `✅ / ⏳` 状态符号
   - 在 §0.x 写「0.5」「0.7」跳号（按时间倒序加新章节会导致跳号）
   - 把测试详情、commit 详情、讨论沉淀写进 `> 实现:`

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
| **`docs/功能实现总览.md`** | **【主进度索引】所有功能 checkbox + 重构债务，开工前必读** |
| `CLAUDE.md` | 单次会话指导，快速了解项目 |
| `docs/0-总览/README.md` | 文档总入口 / 目录结构 |
| `docs/1-立项/概要设计.md` | 技术选型、阶段规划 |
| `docs/1-立项/功能清单.md` | 功能优先级原表（P0/P1/P2 详细描述） |
| `docs/1-立项/开发前问题清单.md` | 已解决的问题及解决方案 |
| `docs/3-设计/详细设计/*.md` | 模块详细设计 |
| `docs/5-规范/*.md` | UI / i18n / 开源致谢 等强制规范 |
| `docs/6-发版与上架/SOP-发版流程.md` | 发版 SOP（git tag 自动驱动版本号） |

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

## UI 规范（强制）

- **Sheet 关闭**：header 右上角用 `SheetCloseButton`（`xmark.circle.fill` + hierarchical + `.secondary`）
- **刷新 / 同步**：icon-only 触发器用 `SyncIconButton`（`arrow.triangle.2.circlepath`；静止灰、刷新蓝 + 旋转）；Stars 全量同步用 `StarsSyncButton`
- 详见下文「Sheet 关闭图标」「刷新图标」两节

### 设置页按钮右对齐（2026-06-21 起生效）

**所有**设置页内的独立操作按钮必须**右对齐**。

```swift
// ✅ 正确：HStack + Spacer 推到右边
Section {
    HStack {
        Spacer()
        Button("导出 / 重置 / 清除") { ... }
    }
}

// ❌ 错误：按钮左对齐
Section {
    Button("导出 / 重置 / 清除") { ... }
}
```

**适用**：重置、清除、导出等一次性操作按钮。**不适用**：Toggle、Picker 等表单控件。

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

以下问题已在 `docs/1-立项/开发前问题清单.md` 中确认解决方案，开发时必须遵循：

- ✅ macOS 最低版本：15 Sequoia
- ✅ Swift：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：服务端计算，客户端存缓存
- ✅ Release 订阅通知：使用轮询方案

---

## 跨 Agent 协作规范

### Skill 编写语言规范

本项目内新增或维护的所有 skill 必须使用中文编写，包括 `SKILL.md`、`references/` 下的说明文档、示例、触发说明和操作步骤。代码、命令、文件路径、环境变量、脚本名、错误日志、YAML key 等技术字面量保持原文，不强行翻译。

### 文档修改

- 修改任何文档前，先检查 `docs/1-立项/开发前问题清单.md` 确认是否有相关决策
- 跨文档的一致性修改（如技术栈变更），需要同步更新所有相关文档
- 新增设计决策时，在 `docs/1-立项/开发前问题清单.md` 中记录

### 代码规范

- 代码必须添加必要注释，解释"为什么这样做"
- **较复杂的代码（actor / Concurrency / WKWebView delegate / URLProtocol / FTS5 / 三阶段 SWR 这类）必须写详细的"为什么 + 关键约束 + 已踩过的坑"级注释**。参考样板：`Starcat/Features/Home/ReadmeViewModel.swift` / `Starcat/Shared/Components/ReadmeWebView.swift` / `StarcatTests/URLProtocolStub.swift`
- **dong4j 是 Swift 初学者**：写新代码或解释已有代码时，遇到关键 Swift / SwiftUI / Concurrency / WebKit / GRDB 概念应主动提示去查 `docs/7-工具与脚本/Swift-学习索引.md` 对应条目（仅给关键词 + 项目内代码位置 + 官方搜索词，不展开教学）
- 遵循现有代码风格
- 详细规范见各设计文档

### UI 设计契约：DESIGN.md（强制，2026-07-04 起生效）

> 单一入口：根目录 [`DESIGN.md`](DESIGN.md)
> 任何新增或修改 UI 的任务，必须先读 `DESIGN.md`，再读相关 Swift 代码和 `docs/5-规范/*.md`。`DESIGN.md` 负责约束 Starcat 的整体视觉语言（主窗口三栏 / Agent 工作台 / 知识库 RAG 工作台），`docs/5-规范/*.md` 仍是具体强制规则来源。

### UI 颜色规范：适配明暗主题（强制，2026-06-14 起生效）

> 单一信任源：[`docs/5-规范/UI-颜色规范.md`](docs/5-规范/UI-颜色规范.md)
> 文字 / 图标 `foregroundStyle` **只用 `.primary` 或 `.secondary`，禁止 `.tertiary`**。唯一例外需在代码注释里写明"故意弱化 + 产品意图"。

### UI 规范：Focus Ring 蓝框（强制）

> 单一信任源：[`docs/5-规范/UI-Focus-Ring-规范.md`](docs/5-规范/UI-Focus-Ring-规范.md)
> 使用 `.buttonStyle(.plain)` 的 Button **必须**添加 `.focusEffectDisabled()`。

### UI 规范：Sheet 关闭图标（强制，2026-06-26 起生效）

> 单一信任源：[`docs/5-规范/UI-Sheet-关闭图标-规范.md`](docs/5-规范/UI-Sheet-关闭图标-规范.md)
> 所有 sheet header 右上角「关闭」走 `SheetCloseButton`,`xmark.circle.fill` + `.secondary`。

### UI 规范：刷新图标（强制，2026-06-26 起生效）

> 单一信任源：[`docs/5-规范/UI-刷新图标-规范.md`](docs/5-规范/UI-刷新图标-规范.md)
> 所有 icon-only 刷新触发器走 `SyncIconButton`,`arrow.triangle.2.circlepath`,静止 `.secondary` / 刷新中 `.accentColor` + 旋转。

### UI 规范：禁止 Stepper（强制，2026-06-20 起生效）

> 单一信任源：[`docs/5-规范/UI-禁止Stepper-规范.md`](docs/5-规范/UI-禁止Stepper-规范.md)
> 数值输入一律 `TextField` + 数字过滤 + 范围钳制。**禁止** `Stepper`。

### 开源致谢同步规则（强制，2026-06-07 起生效）

> 单一信任源：[`docs/5-规范/开源致谢同步-规范.md`](docs/5-规范/开源致谢同步-规范.md)
> 任何 SPM 依赖 / 嵌入式资源 / 生成代码 / vendored 源码都必须登记到 `Starcat/Features/About/AboutView.swift` 的 `AboutDependency.all`。
> 登记字段：`name` / `license` / `copyright` / `url`（copyright 必须取自上游 `LICENSE`）。

### 国际化规范（i18n，强制）

> 单一信任源：[`docs/5-规范/国际化-规范.md`](docs/5-规范/国际化-规范.md) + [`docs/5-规范/i18n-军规.md`](docs/5-规范/i18n-军规.md)
> 关键 5 条：`String.l10n` / `Text("key")` / `.appLocaleEnvironment()` / locale 注入 / `Localizable.xcstrings` 命名 `{section}.{subsection}.{component}`。
> 自检：提交前 `rg "String\(localized:"` 与 `rg "NSLocalizedString"` 应只命中注释。

### 问题处理

- 发现文档间不一致时，以 `docs/1-立项/开发前问题清单.md` 中的决策为准
- 新发现的问题先记录到 `docs/1-立项/开发前问题清单.md`，再实施修改

---

*最后更新：2026-06-26*


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
