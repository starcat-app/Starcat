# AGENTS.md

本文档为跨 Agent 协作提供指导，确保多个 Agent 在本代码库工作时保持一致。

---

## 🚨 硬性铁律（每次写代码前必读，违反即返工）

> ⚠️ **【铁律 #1】本项目已发布正式版，有线上用户与本地数据。**
> ⚠️ **已随正式版发出的数据库 schema：变更必须追加 `registerVN` 迁移，禁止直接改已落地的 `v1-initial`，禁止要求用户删库重建。**
> ⚠️ **未发布功能开发期例外：可直接改该功能建表草稿 SQL + `ensurePrelaunch*` 补齐本机库；收口进正式版时压成单次 `registerVN` 并收口。依赖未建表的中间 migration 必须对「表不存在」no-op。**
> ⚠️ **RAG 已于 2026-07-14 收口为 `v7-knowledge-rag`：禁止再回写 v1 草稿或启动期旁路补 RAG。**
> ⚠️ **应用层仍禁止堆叠无意义的「兼容旧 API / 双写旧字段 / 永久双轨」——废弃路径用迁移删掉或一次性替换，不要长期保留两套接口。**
> ⚠️ **看到代码层旧路径不再需要 → 直接删；已发布库的字段废弃 → 追加迁移处理，不要只改建表语句假装老用户会跟着变。**

> ⚠️ **【铁律 #2】方案讨论 ≠ 动手许可。**
> ⚠️ **dong4j 在反馈方案 / 修正理解 / 给出补充信息时，默认仍在讨论阶段。**
> ⚠️ **必须等 dong4j 明确说「开干 / 改吧 / GO / 动手 / 实施」等字眼，才能开始改代码；只要还在交换意见就只读不写。**

> ⚠️ **【铁律 #3】禁止擅自执行打包 / 发布 / 上传脚本。**
> ⚠️ **除非 dong4j 在当前消息里明确要求执行，否则 Agent 只能修改脚本、写文档、给命令，不能执行 `scripts/package-*`、`scripts/release-*`、`deploy.sh`、notary 上传、App Store 上传、服务器上传等会生成或发布分发产物的命令。**
> ⚠️ **允许执行只读检查命令，例如 `bash -n`、`git diff --check`、`codesign -d`、`PlistBuddy -c Print`、`dwarfdump --uuid`。**

> ⚠️ **【铁律 #4】禁止擅自改写 `docs/功能实现总览.md`。**
> ⚠️ **dong4j 未口头 / 书面明确确认前，禁止对该文件做任何写入**：含勾选 `[x]`、追加 / 改写 `> 实现：`、变更日志、进度仪表盘数字、新增 `- [ ]` / 技术债条目、改状态说明、删改正文、任何措辞润色。
> ⚠️ **改完代码或其它文档 ≠ 可以同步改总览。** 中间迭代、未验收、未确认的改动，一律不准往变更日志里塞条目；禁止连刷返工垃圾日志。
> ⚠️ **允许且鼓励只读打开该文件做开工检查。** 需要登记时：在回复里起草拟写入内容，等 dong4j 明确说「可以写总览 / 同步总览 / 记到总览 / 勾上」等之后再改文件。
> ⚠️ **dong4j 确认后写入时仍须遵守下文勾选与 `> 实现：` 格式**（仅打勾不够）。

> ⚠️ **【铁律 #5】未经 dong4j 明确授权，禁止自行使用 Computer Use（GUI 桌面控制）。（2026-09-13 起生效）**
> ⚠️ **`computer-use` 系列能力（截屏、鼠标键盘、打开 / 操作应用窗口等）默认一律不用；Agent 不得自行判断「需要看界面」就调用。**
> ⚠️ **只读操作同样需要授权：包括获取应用 / 浏览器界面状态、读取辅助功能树（AX tree）、截屏；不得以「没有点击」「仅做验证」为由绕过，也不得换用脚本或其它工具执行等价的 GUI 自动化。**
> ⚠️ **排查 UI / 运行时问题默认只读代码 + Makefile 构建；确需操作屏幕时，先在回复里说明用途与操作范围，等 dong4j 明确说「可以用 computer use / 授权操作屏幕」后再用。**
> ⚠️ **本铁律与铁律 #2 同层：dong4j 描述现象、贴截图 ≠ 授权操作屏幕，截图用文字分析即可。**

---

## 🌿 Git 分支与 Worktree（强制）

所有分支与 worktree 的创建、切换、同步、合并和删除，必须遵循 [`docs/5-规范/Git-分支与Worktree规范.md`](docs/5-规范/Git-分支与Worktree规范.md)。

- 涉及分支/worktree 操作前，先读取根目录 [`BRANCH.md`](BRANCH.md)，再用 Git 命令核对真实 refs、提交关系和 worktree 归属。
- 创建、切换或恢复长期分支后，必须向 dong4j 说明当前分支、用途、基线、worktree、状态和后续归宿。
- 创建新 worktree 后，必须先从主仓库复制被 Git 忽略的本地配置（至少 `Configs/Secrets.xcconfig`）到相同路径，再构建或测试；不输出、不提交配置内容。SPM 完整锁由受控的 `Configs/SwiftPackages.resolved` 提供，生成工程时恢复，不再从其他工作区复制生成的 `Package.resolved` 作为版本来源，详见 [Git-分支与Worktree规范](docs/5-规范/Git-分支与Worktree规范.md)。
- 创建、合并、停放、废弃或删除长期分支/worktree 时，必须在同一任务中同步更新 `BRANCH.md`。
- 删除前必须检查独有提交、Git 合并关系、语义覆盖和 worktree 脏状态；未审查分支禁止直接删除。
- 未经 dong4j 明确授权，不得 push、删除远端分支、强制删除 worktree 或改写共享历史。

`BRANCH.md` 记录分支意图；Git refs 与 `git worktree list` 是实际状态的事实来源。

---

## 🧭 主进度索引（每次开工前必读）

**`docs/功能实现总览.md`** 是本项目的【活文档主索引】，所有 P0/P1/P2 功能与重构债务都在那里以 checkbox 形式记录。

任意 Agent 在动手实现新功能前必须：

1. **打开该文件检查（只读）**：目标功能是否已列入、依赖是否已完成、当前 Week 还剩哪些未做。如需新增 `- [ ]`：先在回复里提议文案，**确认后再写入**。
2. **代码 / 其它文档改完后**：先停手。把拟写入总览的勾选行、`> 实现：`、变更日志草稿贴在回复里，**等 dong4j 审核确认**。**禁止**完成后立刻改写总览。
3. **仅在 dong4j 确认「可以写总览」之后**才允许改写总览：
   - 把 `- [ ]` 改 `- [x]`，行末补完成日期 + 关联文件。
   - **必须紧跟一行 `> 实现：...`**，简述：① 关键技术选择（一句话）② 涉及文件清单 ③ 已知约束 / 后续 TODO（有则写）。
   - 顶部「进度仪表盘」数字 + 「变更日志」同步。
4. **新技术债**：先在回复里提议 D-编号与条目，**确认后再**追加到第 6 节。
5. **专项收尾门禁（2026-09-16 起）**：`docs/4-工程进度/` 专项关闭（结果报告落档）时，必须同批把对应功能回写总览 checkbox（`- [x]` + `> 实现：`，写入前仍需 dong4j 确认）；**禁止只留专项文档与 changelog、不回写总览**。

> ⚠️ **dong4j 在 2026-05-30 明确要求**：仅打勾 `[x]` 是不够的，必须有 `> 实现：...` 行。这是 Starcat 项目的硬性工作流约定，所有 AI 协作者必须遵守。
>
> ⚠️ **dong4j 在 2026-07-16 明确要求**：未确认前禁止改 `功能实现总览.md`（含变更日志）；见铁律 #4。
>
> 不要凭 `AGENTS.md` 自行推测进度。**`功能实现总览.md` 才是单一信任源**。

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
3. **变更日志**（仅 dong4j 确认记总览之后）：
   - 在 `功能实现总览.md` §10 顶部加一行：`- YYYY-MM-DD HH:MM: 一句话描述`(≤ 80 字)
   - 不带 emoji / 不带粗体 / 不写「涉及 N 文件 / 验证 / 反思 / 未做」
   - **禁止**在未确认时抢先追加；**禁止**为同一未验收问题连刷多条中间态日志
4. **不要**：
   - 在 `> 实现:` 写「涉及 N 文件 / 验证步骤 / 反思 / 未做」几大段
   - 在章节标题里带 `(W?+)` / `(2026-MM-DD 新增)` / `✅ / ⏳` 状态符号
   - 在 §0.x 写「0.5」「0.7」跳号（按时间倒序加新章节会导致跳号）
   - 把测试详情、commit 详情、讨论沉淀写进 `> 实现:`
   - **在 dong4j 确认前改写 `功能实现总览.md` 的任何内容**（见铁律 #4）

---

## 🛠️ 本地构建与启动（强制）

本项目同时维护 App Store / Direct 两套 scheme，并允许本机安装多个 Xcode。Agent 不得根据全局 `xcode-select` 临时拼接构建命令，统一使用 Makefile：

```bash
# 只构建并校验产物，不停止或启动 App
make build-appstore
make build-direct

# 构建、校验并启动对应渠道
make run-appstore
make run-direct
```

- 上述入口固定使用 `/Applications/Xcode.app`；如稳定版 Xcode 安装在其他位置，显式设置 `STARCAT_STABLE_XCODE_DEVELOPER_DIR`。
- `build/DerivedData-Sandbox` 只属于 App Store Debug，`build/DerivedData-NoSandbox` 只属于 Direct Debug，`build/DerivedData-Tests` 只属于命令行单测。脚本会记录 Xcode / SDK / scheme 所有权指纹，环境变化时仅重建对应的可再生缓存。
- **禁止**裸 `xcodebuild build` 写入这三个固定目录，也禁止把其他 scheme、Xcode Beta 或一次性诊断构建指向它们。
- 需要新增构建场景时，先补 Makefile / 脚本标准入口；一次性裸 `xcodebuild` 必须使用独立的 `/tmp` DerivedData，不能借用项目固定缓存。

### 简单 UI 改动免构建（2026-11-14 起生效）

单个任务如果**只**改 UI 组件（间距、颜色、字号、图标、文案、对齐、局部布局等纯展示层调整），验证口径为：

- **有对应单测就跑**：`make test TEST_ARGS="-only-testing:StarcatTests/XXX"`；确认没有相关测试则跳过测试，直接说明「无相关测试」。
- **不要额外编译**：不跑 `make build-appstore` / `make build-direct` / `make run-*`，也不裸跑 `xcodebuild build`。
- `make test` 自身会编译测试目标，属于允许范围；本条约束的是额外的产物构建。

以下情况**不适用**本豁免，仍需按上文完整构建：改动涉及非 UI 逻辑（数据层、网络、并发、状态管理）、新增或删除 Swift 文件（需 `xcodegen generate`）、修改 `project.yml` / 构建配置 / 签名，或改动同时跨越 UI 与业务边界。

---

## 🧪 如何跑单测（必读，2026-05-31 起生效）

**当前最低要求**：跑测前**关闭 Xcode IDE**（Cmd+Q），否则 `xcodebuild test` 与 IDE 抢占同一 `testmanagerd` 实例，可能挂起。

### A. 命令行（CI 友好，推荐 AI Agent 用）

```bash
# 跑全部单测；入口会执行 xcodegen、固定稳定版 Xcode，并复用 build/DerivedData-Tests
make test

# 只跑某个 Suite（迭代时省时间；同样走测试专用缓存，禁止 mktemp）
make test TEST_ARGS="-only-testing:StarcatTests/TagRepositoryTests"

# 同时跑多个 Suite
make test TEST_ARGS="-only-testing:StarcatTests/TagRepositoryTests -only-testing:StarcatTests/RepoTagRepositoryTests"
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
- **项目状态**: 已发布正式版，持续开发与维护中

---

## 仓库目录结构

```text
Starcat/
├── Starcat/                         # macOS App 源码
│   ├── App/                         # App 入口与生命周期
│   ├── Core/                        # 数据库、网络、同步、AI 等核心能力
│   ├── Features/                    # 按产品功能划分的 SwiftUI 模块
│   ├── Shared/                      # 共享组件、工具与扩展
│   ├── Resources/                   # 本地化、Assets、entitlements 等资源
│   └── Generated/                   # xcodegen 等流程生成的文件
├── StarcatTests/                    # 单元测试与集成测试
├── Configs/                         # 构建配置；真实 secrets 不进 Git
├── docs/                            # 产品、设计、规范、进度与发版文档
├── scripts/                         # 构建、打包、发布与本地工具脚本
├── resources/                       # 仓库级素材与辅助资源
├── screenshots/                     # 商店、文档与验收截图
├── supports/                        # 配套项目工作区
│   ├── .github/                     # starcat-app 组织主页与共享社区文件（独立仓库）
│   ├── starcat-docs/                # 官方用户文档（独立仓库）
│   ├── starcat-site/                # 官网源码单一来源（独立仓库）
│   │   ├── direct/                  # starcat.ink Direct 正式站
│   │   ├── direct-test/             # Direct 测试站
│   │   ├── appstore/                # Mac App Store 官网
│   │   └── _local-admin/            # 本地运营控制台
│   ├── starcat-*-api/               # 各后端 API 独立仓库
│   ├── starcat-pro/                 # 已归档：changelog 迁至 starcat-site，支持入口迁至主仓库 issues
│   ├── starcat-cli/                 # CLI / MCP 独立仓库
│   ├── starcat-skill/               # AI Agent Skill 独立仓库
│   ├── starcat-localization/        # 本地化资源独立仓库
│   ├── homebrew-starcat*/           # App / CLI Homebrew taps
│   ├── extensions/                  # Chrome / Safari 插件独立仓库
│   └── scripts/                     # 跨 supports 项目运维脚本
├── project.yml                      # xcodegen 单一配置源
└── Makefile                         # 常用开发与运维命令入口
```

`supports/` 下的产品配套目录多数是独立 Git 仓库，不能按主仓库文件处理。首次拉取或补齐这些仓库使用 `supports/clone-all.sh`；官网修改、Changelog 生成和部署统一在 `supports/starcat-site/` 完成。

---

## 文档导航

| 文档 | 用途 |
|------|------|
| **`AGENTS.md`** | **跨 Agent 协作唯一维护源（本文档）** |
| **`docs/功能实现总览.md`** | **【主进度索引】所有功能 checkbox + 重构债务，开工前必读** |
| [`LESSONS.md`](LESSONS.md) | 高置信经验规则索引；开工前按任务域核对，新增教训先登记 Rule / Reason / Evidence |
| `docs/0-总览/README.md` | 文档总入口 / 目录结构 |
| `docs/1-立项/概要设计.md` | 技术选型、阶段规划 |
| `docs/1-立项/功能清单.md` | 功能优先级原表（P0/P1/P2 详细描述） |
| `docs/1-立项/开发前问题清单.md` | 已解决的问题及解决方案 |
| `docs/3-设计/详细设计/*.md` | 模块详细设计 |
| `docs/5-规范/*.md` | UI / i18n / 开源致谢 等强制规范 |
| `docs/5-规范/Git-提交规范.md` | Git commit message 格式与更新日志分类规则 |
| `docs/5-规范/Git-分支与Worktree规范.md` | 分支、worktree、`BRANCH.md` 登记、合并与清理规则 |
| `docs/5-规范/Changelog-更新规范.md` | Changelog 询问时机、授权边界、日常文件范围与发版生成规则 |
| `docs/6-发版与上架/SOP-双渠道签名与发布.md` | 当前 App Store / Direct 正式发布 SOP；`SOP-发版流程.md` 仅保留旧版流程与版本号机制 |

> **阅读顺序建议**：先读 `AGENTS.md` 了解概览，再根据任务需要查阅对应文档。

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

新增或修改业务功能时，AI 必须主动读取并执行 [`docs/5-规范/CLI与MCP能力暴露规范.md`](docs/5-规范/CLI与MCP能力暴露规范.md)：逐动作评估 CLI / MCP 暴露、登记公共目录和验证；暂缓写具体原因，纯 UI 写不适用结论，无需 dong4j 再次提醒。

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
- ✅ Swift：Swift 6 语言模式 + 严格并发检查 + @Observable；编译器由标准构建入口选择的稳定版 Xcode 提供
- ✅ README 渲染：WKWebView；具体 GFM、资源加载与降级边界以渲染实现和相关设计为准
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：Embedding Provider 生成向量，客户端保存索引并计算相似度；不依赖固定的服务端语义排序接口
- ✅ Release 订阅通知：使用轮询方案

---

## 跨 Agent 协作规范

### Multica 与 GitHub Issue 同步

- Starcat 主仓库及配套仓库以 Multica 为日常执行入口；每个在办任务必须有唯一的 GitHub 主关联，GitHub 正文同时记录对应 HOM 编号。
- 验收通过后，在关联 GitHub Issue 记录英文交付证据、按 `completed` 关闭并同步 Project，再把 Multica 设为 `done`；必须回读双方状态。取消对应 `cancelled` / `not planned`，子任务完成不得直接关闭父任务。
- 任一端更新失败，明确记录“同步待补”，不得宣称双端完成。仅在 Multica 手动切换状态不会自动同步 GitHub；执行者必须完成收尾步骤。
- 创建、拆分、变更范围及收尾按 [`docs/4-工程进度/任务录入规范.md`](docs/4-工程进度/任务录入规范.md)；当前对应关系见 [`2026-10-07-GitHub与Multica任务对齐.md`](docs/4-工程进度/2026-10-07-GitHub与Multica任务对齐.md)。

### AI File Wall 协作登记

本仓库启动 `supports/ai-file-wall` 后，Cursor Agent 在首次编辑目标文件前必须调用 MCP 工具 `ai-file-wall.claim_files`，任务结束后调用 `ai-file-wall.release_files`；长任务在 3 分钟内续期一次。Codex 与 Claude Code 由项目 hook 自动登记和释放。该规则只用于显示协作冲突预警，不阻断文件写入。

### Skill 编写语言规范

本项目内新增或维护的所有 skill 必须使用中文编写，包括 `SKILL.md`、`references/` 下的说明文档、示例、触发说明和操作步骤。代码、命令、文件路径、环境变量、脚本名、错误日志、YAML key 等技术字面量保持原文，不强行翻译。

### 版本迭代与日常 Checklist

- 用户提出“开始进行 X.Y.Z 的版本迭代”、增补版本范围或维护清单时，先读取项目 Skill [`skills/starcat-version-iteration/SKILL.md`](skills/starcat-version-iteration/SKILL.md) 与[版本迭代规范](docs/5-规范/版本迭代规范.md)，即使工具未自动加载 Skill 也执行此入口；分支、计划路径、每轮依赖检查及授权边界以该规范为准。
- 日常开发交付先按该规范定位当前版本计划，获授权的本版任务同批维护 Checklist；Changelog 的逐任务询问豁免、收口整理及独立写入授权以 [Changelog 更新规范](docs/5-规范/Changelog-更新规范.md)为准。

### 文档修改

- 修改任何文档前，先检查 `docs/1-立项/开发前问题清单.md` 确认是否有相关决策
- 跨文档的一致性修改（如技术栈变更），需要同步更新所有相关文档
- 新增设计决策时，在 `docs/1-立项/开发前问题清单.md` 中记录
- 所有 Changelog 询问时机、授权边界、日常文件范围与发版生成规则，必须遵循 [`docs/5-规范/Changelog-更新规范.md`](docs/5-规范/Changelog-更新规范.md)

### 代码规范

- 所有 Git commit message 必须遵循 [`docs/5-规范/Git-提交规范.md`](docs/5-规范/Git-提交规范.md)，确保提交可以被脚本稳定转换为更新日志
- 所有 Git 分支与 worktree 操作必须遵循 [`docs/5-规范/Git-分支与Worktree规范.md`](docs/5-规范/Git-分支与Worktree规范.md)，并同步维护根目录 [`BRANCH.md`](BRANCH.md)
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

### UI 规范：Markdown 字号与渲染器（强制，2026-11-19 起生效）

> 单一信任源：[`docs/5-规范/UI-Markdown字号与渲染规范.md`](docs/5-规范/UI-Markdown字号与渲染规范.md)
> Markdown 阅读、预览及内容输入（含占位提示）默认采用共享 16 号正文基准，仓库笔记采用共享 14 号基准。统一接入界面字号档位与现有阅读微调，禁止业务视图散写字号。单篇独立文档复用 WebView，原生会话、编辑预览及流式正文按规范保留 MarkdownUI；切换渲染器须明确授权与来源资源边界。新增或修改 Markdown 入口前必须读取该规范。

### UI 规范：Focus Ring 蓝框（强制）

> 单一信任源：[`docs/5-规范/UI-Focus-Ring-规范.md`](docs/5-规范/UI-Focus-Ring-规范.md)
> 使用 `.buttonStyle(.plain)` 的 Button **必须**添加 `.focusEffectDisabled()`。

### UI 规范：动效（强制，2026-11-15 起生效）

> 单一信任源：[`docs/5-规范/UI-动效规范.md`](docs/5-规范/UI-动效规范.md)
> 凡新增或修改用户可见 UI，AI 必须主动读取并落实适用的反馈、切换与加载动效，无需 dong4j 再单独提醒；列表、详情及骨架加载继续执行下述专项规范。

### UI 规范：折叠/展开整行点击（强制，2026-07-13 起生效）

> 单一信任源：[`docs/5-规范/UI-折叠展开-规范.md`](docs/5-规范/UI-折叠展开-规范.md)
> 所有折叠/展开标题行必须整行可点击；chevron 只表达状态，不能是唯一触发区。

### UI 规范：Sheet 关闭图标（强制，2026-06-26 起生效）

> 单一信任源：[`docs/5-规范/UI-Sheet-关闭图标-规范.md`](docs/5-规范/UI-Sheet-关闭图标-规范.md)
> 所有 sheet header 右上角「关闭」走 `SheetCloseButton`,`xmark.circle.fill` + `.secondary`。

### UI 规范：刷新图标（强制，2026-06-26 起生效）

> 单一信任源：[`docs/5-规范/UI-刷新图标-规范.md`](docs/5-规范/UI-刷新图标-规范.md)
> 所有 icon-only 刷新触发器走 `SyncIconButton`,`arrow.triangle.2.circlepath`,静止 `.secondary` / 刷新中 `.accentColor` + 旋转。

### UI 规范：列表分页加载（强制，2026-08-28 起生效）

> 单一信任源：[`docs/5-规范/UI-列表分页加载规范.md`](docs/5-规范/UI-列表分页加载规范.md)
> 所有滚动驱动的增量列表统一使用 `ListPaginationPolicy` 与 `automaticListPagination`；剩余 10 个可见项时预取，快速滚动期间不得丢失加载需求，筛选、排序或来源变化时必须重置分页身份。

### UI 规范：列表交互、详情切换与骨架加载（强制，2026-11-15 起生效）

> 单一信任源：[`docs/5-规范/UI-列表与详情切换动效规范.md`](docs/5-规范/UI-列表与详情切换动效规范.md)
> 凡新增或修改列表、导航菜单、详情页及其加载状态，AI 必须主动读取并执行该规范，无需 dong4j 再说“参考 Codenotch”。
> 常规行列表默认具备斑马纹与整行悬停高亮；单选导航采用选中背景跨行弹簧动效；详情有完整出入场；内容区域异步加载采用骨架屏 + 轻量动画 + 就绪后过渡。只落实当前任务涉及的页面。

### UI 规范：复制按钮反馈（强制，2026-07-12 起生效）

> 单一信任源：[`docs/5-规范/UI-复制按钮-规范.md`](docs/5-规范/UI-复制按钮-规范.md)
> 新增或调整的复制入口走 `CopyFeedbackButton`；成功后显示绿色 `checkmark.circle.fill`，并在 1.5 秒后恢复。

### UI 规范：禁止 Stepper（强制，2026-06-20 起生效）

> 单一信任源：[`docs/5-规范/UI-禁止Stepper-规范.md`](docs/5-规范/UI-禁止Stepper-规范.md)
> 数值输入一律 `TextField` + 数字过滤 + 范围钳制。**禁止** `Stepper`。

### 开源致谢同步规则（强制，2026-06-07 起生效）

> 单一信任源：[`docs/5-规范/开源致谢同步-规范.md`](docs/5-规范/开源致谢同步-规范.md)
> 任何 SPM 依赖 / 嵌入式资源 / 生成代码 / vendored 源码都必须登记到 `Starcat/Features/About/AboutView.swift` 的 `AboutDependency.all`。
> 登记字段：`name` / `license` / `copyright` / `url`（copyright 必须取自上游 `LICENSE`）。

### 国际化规范（i18n，强制）

> 单一信任源：[`docs/5-规范/国际化-规范.md`](docs/5-规范/国际化-规范.md) + [`docs/5-规范/i18n-军规.md`](docs/5-规范/i18n-军规.md)
> 关键 7 条：`String.l10n` / `Text("key")` / `.appLocaleEnvironment()` / locale 注入 / `Localizable.xcstrings` 命名 `{section}.{subsection}.{component}` / 目录编辑必须保持 `"key" : value` 并禁止整文件格式化 / **Catalog 禁止 StrReplace/ApplyPatch 与 JSON 重排写回；只允许 Xcode 或经验证的按行插入（diff 只能新增）**。
> **全语言交付（2026-10-21 起强制）**：新增或修改国际化文案后，必须同步完成当前全部支持语言（现为 17 种）的配置与校验；禁止只补中英文、复制英语冒充翻译，或把英语兜底当成国际化完成。语言集合以 `AppLocale`（排除 `system`）与 `supports/starcat-localization/locales.json` 为准；提交前核对本次全部 key 的语言覆盖、占位符、编译资源和长文案布局。AI 初稿与人工审核状态必须如实保留，未验收部分明确报告。
> 自检：提交前 `rg "String\(localized:"` 与 `rg "NSLocalizedString"` 应只命中注释。

### 问题处理

- 发现文档间不一致时，以 `docs/1-立项/开发前问题清单.md` 中的决策为准
- 新发现的问题先记录到 `docs/1-立项/开发前问题清单.md`，再实施修改

---

*最后更新：2026-11-15*

<!-- aoci:begin -->
## AOCI 仓库认知

AOCI 为本仓库维护一个稳定、可版本化、可增量更新的仓库级认知层，供模型跨任务复用对系统的理解。

`aoci.txt` 是面向模型的结构化认知索引。它以每个受管理文件、数据库表或其他受管理对象一条独立 Entry 的方式，用符号标签与 F/R/A/S 语义表达对象的核心职责、重要关系、对外契约，以及理解或修改系统时必须知道的非显然约束和设计决策。

Header、目录段和全部 Entry 共同组成完整仓库索引，可以覆盖前端、后端、配置、数据库结构及其他受管理内容。受管理内容发生变化时，通常只需维护受影响的认知条目，不需要重新生成整个索引。

AOCI 提供系统架构、对象职责、重要关系、对外契约和关键约束的高密度视图。

### 工作原理

AOCI 采用“模型生成、模型读取”的认知闭环。

Header、Entry 和 Curation 语义的创作只按当前机器签发的 Plan 与实时 Guide 执行；由 Host 模型基于当前绑定证据独立完成。

Entry 的语义必须来自模型对真实证据的理解。不得仅依据路径、文件名、扩展名、AST、符号列表、依赖扫描、正则、固定模板或规则引擎推导、预填、拼接或改写索引语义。

对 Fresh Bootstrap，只按当前机器签发的 Plan 和实时 Guide 执行。当它们要求创作时，Host 模型创作 Root、Meta、Tag 和 F/R/A/S，提供 authoring-run 声明，并把它绑定到 Plan、Evidence 与完整 Candidate。不得要求 AOCI 填写 `origin=host_model`、制造 Receipt 或把程序生成的 Framework 当作语义。本文件不自行重建 Onboarding 流程。内部批次不是用户决策；只有遇到既有批准边界或真实的安全、漂移、CAS、Recovery 条件才停止。

### 最小使用入口

- `aoci_rules`：取得当前AOCI版本的会话运行合同。
- `aoci_overview`：建立或恢复本仓库的完整认知。
- `aoci_maintain`：受管理对象达到最终稳定状态后检查认知是否需要维护。
- `aoci_update_entry`：提交与当前证据和源码摘要绑定的完整语义更新批次。
- `aoci_report`：仅当当前布局和工具状态支持时，在证据不足、无法可靠生成语义时登记待办，不猜写。

其他MCP工具、CLI命令、参数和专项流程，以当前工具说明、Guide和 `--help` 返回内容为准，不在本文件中重复完整手册。

本区块只规定仓库接入、认知使用和收尾原则。`aoci_rules` 承载当前会话合同，Guide实时输出承载当前Plan的执行顺序与停点，工具Schema、Spec和Validator承载机器结构与判据；Prompt、Description、README和静态文档不能覆盖这些机器事实。

### 建立、生成和恢复认知

1. 每个新的 Agent Run 开始时，应先判断：

   - 本仓库是否已经存在可用的完整AOCI索引；
   - 当前上下文中是否已有与本仓库根、当前索引版本和当前AOCI服务相匹配，并且模型仍可可靠使用的完整仓库认知。

2. 仓库已经存在可用的完整索引，但当前Run没有可靠完整认知时，先调用 `aoci_rules`，再调用 `aoci_overview`。

   完整认知仍可靠时直接复用。局部不确定本身不要求机械重读系统全貌。可靠认知建立后，默认以它作为仓库级系统上下文，只读取当前任务直接需要的源码、测试、配置与契约，只有某个缺失的具体事实可能改变回答或验证结论时才扩大证据范围；AOCI不能替代修改对象与验证行为所需的直接源码证据。

   本Run从已知Host上下文压缩恢复时（包括宿主注入的压缩摘要），必须把此前模型认知视为不可靠。压缩handoff不得保留或摘要正式Whole-Index，也不得保留或摘要任何Overview Header、Entry、Chunk、Challenge或Attestation正文；只能保留安全续接所需的receipt身份、未完成write或Recovery状态，以及立即重载指令。复制进handoff的Whole-Index语义或receipt不能证明恢复后模型的当前认知可靠。若当前上下文已无法可靠保留运行合同，先调用 `aoci_rules`。继续业务任务前，使用 `refresh_reasons=["context_compaction"]` 和新的 `refresh_event_id` 调用普通完整Whole-Index `aoci_overview`（不设置 `check_only` 或设为false）；不得使用 `check_only` 或认知probe。原样跟随每个 `next_cursor` 直到 `completed=true`，确认交付，并且只基于新交付正文提交一次Attestation。完成这次新的完整传输后，即使Attestation为partial或fail也消费该generation，并按既有合同继续source-bound任务，不再自动调用第二次Overview。若该请求返回 `delivery_mode=capacity_stop`，说明Whole-Index装不进本Host的上下文：不得重试或调小 `chunk_tokens`；该停止消费本generation，任务按source-bound继续，且不作无保留的完整系统认知声明。

   AOCI可以针对 `context_compaction`、项目 `cognition_refresh_threshold` 下的机器 `semantic_threshold` 或主要 `phase_transition` 提供checkpoint与认知状态事实。只需要这些紧凑事实时使用 `check_only=true`；这些事实只向Agent提供建议，不替模型决定是否需要系统全貌。

   Agent显式调用普通 `aoci_overview`（未设置 `check_only` 或为false）时，只要能形成一致的CognitionSet，AOCI必须完整交付请求scope。不得因为已有receipt、阈值未达到或没有待处理刷新原因而抑制正文；唯一例外是待处理压缩刷新的上述容量停止。正式认知Dirty或Stale时仍交付正文，但必须标记不可靠。存在未决恢复或无法形成一致snapshot时失败关闭，不返回混合正文。

   普通Overview返回 `continuation_required=true` 时，必须原样提交 `next_cursor` 并自动继续到 `completed=true`。不得询问用户、开始业务任务或给出阶段性系统结论。每块单独一次工具调用；不得在一个脚本里连取多块或合并其输出。缺块、重复、乱序、cursor失败、Index变化或`chunk_tokens`变化时停止本次认知链。Attestation完成前不得用Memory、源码、Spec、`aoci.txt`、历史会话、scope、search或Entry读取修补或补充Whole-Index认知。Challenge ordinal是正式Entry序列中的1-based位置；Header内容、注释、空行、Section/Overview/Chunk Marker、Receipt与Metadata均不计数，Chunk Receipt ordinal使用同一序列。Attestation必须原样回绑本次Challenge发布的当前`index_sha256`、`entry_sequence_sha256`与`entry_count`；旧Index、旧Entry序列、旧数量或旧Attestation均无效。完整链结束后只正式提交一次既有模型认知Attestation；同一响应只允许一次不改变语义答案的JSON Schema或字段格式修正。对象、Tag或F不匹配即失败且认知吸收不确定，不得语义重试或旁路补答。首次认知失败时还不得执行Root/Meta、Migration、全局布局或其他未重新绑定的系统级决策。上下文压缩刷新若传输完整、认知身份不变、治理对齐且没有Recovery或第三方冲突，即使Attestation为partial或fail也消耗该refresh generation，并继续原任务，不再自动重读Overview。`system_mastery_percent`只自评系统框架——架构、职责、强关系、稳定外部契约以及高熵安全和维护约束——不表示完整实现或运行实况知识；机器索引覆盖率必须分开。默认只向用户输出由本次真实覆盖率、Challenge、块数、Token和掌握度生成的规定成功或失败一句话。Host截断某一块时，用同一cursor重取一次并核对 `chunk_sha256`，服务端返回完全相同的字节。仍被截断才停止，提示用户把 `overview_delivery.chunk_tokens` 设置为更小的合法值后重新开始，不得自动修改。

   加法认知等级必须与严格证明字段分开解释。`delivery_verified`表示已加载Index且Host交付已确认，但完整认知验证仍未完成；应表达为“已加载且交付已验证”，不得描述为“没有认知”或“没有理解系统”。`cognition_verified`要求Attestation通过（Challenge至少80%的ordinal完全正确且对象身份至多失手一处），`cognition_governed`还要求治理对齐。通用完整读取失败句只用于真实交付故障。

   当Overview响应包含可选`cognition-state/v2`投影时，必须分别解释各维度。其Level止于`model_cognition_usable`；`strict_attestation_verified`、`governance_aligned`与`current_system_cognition_reliable`都是独立状态，绝不参与该Level。ordinal、对象身份、Tag或核心F不匹配可以导致严格Attestation失败，而模型认知仍然可用；不得仅凭这种不匹配就宣称模型没有理解系统。只有`current_system_cognition_reliable=true`允许无保留地声称当前完整系统认知可靠。投影缺失时继续使用上述Legacy解释。

   普通的只读审计、分析、检查、不修改代码或不提交、不push，不自动等于严格零写入，也不改变上述认知有效性判断。Codex Memory和历史Skill只能辅助恢复经验、用户偏好与调查方向，不能替代与当前仓库根、索引摘要、AOCI服务身份和认知范围匹配的当前认知收据；项目AGENTS和当前AOCI身份在AOCI状态上优先于历史Memory。

   只有用户明确禁止Ledger、元数据、`.aoci`运行资产及任何文件写入时，才按严格零写入处理。若必要的认知建立与该边界冲突，必须报告冲突并请求用户裁决或建议使用隔离副本，不得静默以Memory替代当前仓库认知。

3. 仓库没有可用的完整索引，或当前只有最小骨架、Header不完整、Entries未完成、必要Curation尚未裁决时，如果需要建立正式完整AOCI索引，先取得 `aoci_rules`，然后进入当前AOCI Guide。由Guide依据仓库真实状态决定下一阶段并完成必要安全步骤。

   `aoci_maintain` 不替代索引建立流程。

   不在本文件中自行重建或硬编码完整索引生成状态机。

4. 在长程任务中，模型负责保留当前认知收据并正确使用刷新门禁：

   - Host报告上下文压缩或模型已知系统全貌丢失时，执行上述强制 `context_compaction` 重载规则；AOCI不能自行推断Host事件；
   - 进入真正的主要阶段时声明 `phase_transition`，不得把函数、测试运行或小步骤当作阶段；
   - 在有用的稳定检查点通过 `check_only=true` 取得机器语义计数；
   - 除已知压缩的强制重载外，由Agent判断当前任务是否需要再次显式获取指定scope或完整Overview；
   - 在维护和对齐完成前，保留AOCI报告的Dirty或Stale可靠性状态。

### 任务收尾与认知维护

5. 纯只读问答、分析、版本核验，或没有产生受AOCI管理对象变化的任务，不需要调用维护工具。当前AOCI版本是任意`aoci_overview` check_only或`aoci_maintain`响应里的`cognition_receipt.mcp_service_version`；二进制路径是项目`.mcp.json`里的`command`，CLI不必在PATH上。

6. 发生受AOCI管理对象变化时，待其达到本次任务的最终稳定状态后，只调用一次 `aoci_maintain`。不要在每次中间修改后逐文件维护。

7. 若维护结果返回真实语义候选，Host 模型必须基于每个候选绑定的对象和必要证据，独立创作完整标签与F/R/A/S更新。通过 `aoci_update_entry` 一次提交当前机器签发批次的完整候选集合，同时原样保留每项 `source_sha256`、`candidate_id` 与对应domain批次身份。`max_entries`只限制单次请求和原子事务，不限制logical plan、Whole-Index或Managed Scope。`remaining`非零时，在当前批次成功Apply后重新调用Maintain并从新preimage继续；绝不能为满足transport上限缩减Index覆盖或自行截取返回批次。

   没有足够证据且当前布局支持 `aoci_report` 时，使用它而不猜测、套用模板或为消除待办而生成缺乏证据的认知。

8. 必须遵守工具返回的结构化状态和安全边界：

   - `repair_required`：只修复明确命中的候选，再重新提交当前机器签发的完整批次；
   - `stopped`：结束当前写入尝试并检查 `failed_step`、错误、正式写入证据与Recovery。auto模式下，已证明零写入则记录closure并重新Plan；完整Intent和可证明postimage则Resume；策略要求Rollback且preimage可证明则精确恢复后重新Plan。只有证据不足、第三方正式字节冲突、需要审批或外部动作，或命中其他真实安全边界时，才停止整个用户任务；
   - 冲突、审批、人工裁决、权限和安全信号不得忽略；
   - 已经对齐后不得重复维护或重复写入；`refresh_ready_for_overview` 是checkpoint事实，由Agent决定是否为下一阶段请求普通完整Overview。

   维护完成后如果又修改了任何受管理对象，之前的维护结果失效，应在新的最终稳定状态重新完成收尾。

9. 用户只限制业务文件范围，但没有明确禁止仓库托管资产时，AOCI托管资产可以在收尾阶段为保持认知一致而更新，并应在审计和提交中与业务文件区分。

   用户明确禁止修改 `aoci.txt`、`.aoci`、元数据或任何额外文件时，以用户限制为准，不得写入，并如实报告剩余不一致。

### 专项流程

初始化、完整索引生成、Header生成、Entries生成、数据库结构索引、Curation、人工评审和故障恢复，只按当前AOCI Guide或工具在对应阶段返回的指令、命令和安全停点执行。

不预加载、不猜测，也不自行重建这些专项流程。平台调用方式、请求格式、批次上限、审批规则、索引格式细节和恢复步骤由对应Guide、工具说明、模型Prompt和CLI帮助按需提供。
<!-- aoci:end -->
