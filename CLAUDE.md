# CLAUDE.md

本文档为 Claude Code 在本代码库工作时提供指导。

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

---

## 🧭 主进度索引（每次开工前必读）

**`docs/功能实现总览.md`** 是本项目的【活文档主索引】，所有 P0/P1/P2 功能与重构债务都在那里以 checkbox 形式记录。

每次实现新功能时，必须：

1. **开工前（只读）**：打开该文件检查
   - 目标功能是否在清单里？依赖项是否已勾选？
   - 当前 Week 还有哪些未完成项？是否应该插队？
   - 如发现新功能未列入：在回复里提议拟追加的 `- [ ]` 文案，**等 dong4j 确认后再写入**；未确认不得自行追加。
2. **代码 / 其它文档改完后**：先停手。把拟写入总览的勾选行、`> 实现：`、变更日志草稿贴在回复里，**等 dong4j 审核确认**。
3. **仅在 dong4j 确认「可以写总览」之后**（强制：不仅勾选，还要写实现说明）：
   - 把对应 `- [ ]` 改为 `- [x]`，行末补完成日期 + 关联文件。
   - **必须紧跟一行 `> 实现：...`**，简述：① 关键技术选择（一句话）② 涉及文件清单 ③ 已知约束 / 后续 TODO（有则写）。
   - 同步更新顶部「进度仪表盘」数字 + 「变更日志」追加一行。
4. 如发现新技术债：先在回复里提议 D-编号与条目，**确认后再**追加到第 6 节。

> ⚠️ **dong4j 在 2026-05-30 明确要求**：仅打勾 `[x]` 是不够的，必须有 `> 实现：...` 行。这是 Starcat 项目的硬性工作流约定，所有 AI 协作者必须遵守。
>
> ⚠️ **dong4j 在 2026-07-16 明确要求**：未确认前禁止改 `功能实现总览.md`（含变更日志）；见铁律 #4。
>
> 不要只看本文档（CLAUDE.md）做开发计划。**`功能实现总览.md` 才是单一信任源**。

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
- **项目状态**: 已发布正式版，持续开发与维护中

---

## 文档结构

> 2026-06-28 重整后,docs/ 按「文档生命周期」分目录(版本号只用于里程碑快照)。
> 详细规范见 [`docs/0-总览/文档添加规范.md`](docs/0-总览/文档添加规范.md)。

```
docs/
├── 功能实现总览.md                        # ⭐ 主进度索引(活文档,根级突出)
├── 0-总览/                                # 入口 + 规范
├── 1-立项/                                # 立项期沉淀(永久参考)
├── 2-产品/                                # 需求池 + 里程碑
│   ├── 需求讨论/
│   │   ├── v2-功能规划.md
│   │   ├── 正式方案/                       # 已落地的方案
│   │   ├── _archive/                       # 一次性需求初稿
│   │   ├── agent/
│   │   └── 推荐算法/
│   └── 里程碑/                             # 阶段总结快照
├── 3-设计/                                # 详细技术设计(滚动维护,带版本标签)
│   └── 详细设计/
├── 4-工程进度/                            # 阶段性回顾 + 踩坑 + 重构专项
├── 5-规范/                                # 永久强制规范(UI / i18n / 开源致谢 等)
├── 6-发版与上架/                          # 发版 SOP + 各版本快照
├── 7-工具与脚本/                          # 工具型参考
└── 8-原型设计/
```

> 各目录详细职责见 [`docs/0-总览/README.md`](docs/0-总览/README.md)。

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

> 详细技术选型见 `docs/3-设计/详细设计/04-技术选型.md`

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

> 完整功能清单见 `docs/1-立项/功能清单.md`

---

## 开发规范

- 全新项目，无历史代码需要维护
- 用户面向的内容遵循中文文档风格
- 技术术语保留英文原文，可配中文解释
- 代码必须添加必要注释；**较复杂的代码（actor / Concurrency / WKWebView delegate / URLProtocol / FTS5 / 三阶段 SWR 这类）必须写详细的"为什么 + 关键约束 + 已踩过的坑"级注释**，参考 `Starcat/Features/Home/ReadmeViewModel.swift` / `Starcat/Shared/Components/ReadmeWebView.swift` / `StarcatTests/URLProtocolStub.swift` 三份样板
- **dong4j 是 Swift 初学者**：写新代码或解释已有代码时，遇到关键 Swift / SwiftUI / Concurrency / WebKit / GRDB 概念应主动提示去查 `docs/7-工具与脚本/Swift-学习索引.md` 对应条目
- 所有 Git commit message 必须遵循 [`docs/5-规范/Git-提交规范.md`](docs/5-规范/Git-提交规范.md)，确保提交可以被脚本稳定转换为更新日志
- 详细开发规范见 `docs/` 各文档

### UI 设计契约：DESIGN.md（强制，2026-07-04 起生效）

> 单一入口：根目录 [`DESIGN.md`](DESIGN.md)
> 任何新增或修改 UI 的任务，必须先读 `DESIGN.md`，再读相关 Swift 代码和 `docs/5-规范/*.md`。`DESIGN.md` 负责约束 Starcat 的整体视觉语言（主窗口三栏 / Agent 工作台 / 知识库 RAG 工作台），`docs/5-规范/*.md` 仍是具体强制规则来源。

### UI 颜色规范：适配明暗主题（强制，2026-06-14 起生效）

> 单一信任源：[`docs/5-规范/UI-颜色规范.md`](docs/5-规范/UI-颜色规范.md)
> 文字 / 图标 `foregroundStyle` **只用 `.primary` 或 `.secondary`，禁止 `.tertiary`**。
> `.tertiary` 在浅色主题下对比度仅约 1.5:1（远低于 WCAG AA 4.5:1）。
> 唯一例外:刻意弱化的装饰性图标占位,可在代码注释里写明"故意弱化 + 产品意图"后保留。

### UI 规范：Focus Ring 蓝框（强制）

> 单一信任源：[`docs/5-规范/UI-Focus-Ring-规范.md`](docs/5-规范/UI-Focus-Ring-规范.md)
> **所有**使用 `.buttonStyle(.plain)` 的 Button **必须**添加 `.focusEffectDisabled()`,禁用 macOS 默认的蓝色 focus ring。

> ⚠️ 这是强制规则。任何新建或修改的 Button若遗漏 `.focusEffectDisabled()`,必须补上。

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

### UI 规范：Sheet 关闭图标（强制，2026-06-26 起生效）

> 单一信任源：[`docs/5-规范/UI-Sheet-关闭图标-规范.md`](docs/5-规范/UI-Sheet-关闭图标-规范.md)
> 所有 sheet / 浮层 / 面板的右上角关闭按钮必须走 `SheetCloseButton` 共享组件,SF Symbol `xmark.circle.fill` + `.symbolRenderingMode(.hierarchical)` + `.secondary`。

### UI 规范：刷新图标（强制，2026-06-26 起生效）

> 单一信任源：[`docs/5-规范/UI-刷新图标-规范.md`](docs/5-规范/UI-刷新图标-规范.md)
> 所有 icon-only 刷新触发器必须走 `SyncIconButton`,SF Symbol `arrow.triangle.2.circlepath`,静止 `.secondary` / 刷新中 `.accentColor` + 旋转。
> **禁止** `arrow.clockwise` / `ProgressView` / `.symbolEffect(.rotate, value:)`。

### UI 规范：禁止 Stepper（强制，2026-06-20 起生效）

> 单一信任源：[`docs/5-规范/UI-禁止Stepper-规范.md`](docs/5-规范/UI-禁止Stepper-规范.md)
> 数值输入一律 `TextField` + 数字过滤 + 范围钳制;范围大时用 `Slider`。**禁止** `Stepper`。

### UI 规范：设置页按钮右对齐（强制，2026-06-21 起生效）

> 单一信任源：[`docs/5-规范/UI-设置页按钮对齐-规范.md`](docs/5-规范/UI-设置页按钮对齐-规范.md)
> 所有设置页内的独立操作按钮(重置/清除/导出/一次性动作)必须右对齐。

### 开源致谢同步规则（强制，2026-06-07 起生效）

> 单一信任源：[`docs/5-规范/开源致谢同步-规范.md`](docs/5-规范/开源致谢同步-规范.md)
> 任何 SPM 依赖 / 嵌入式资源 / 生成代码 / vendored 源码都必须登记到 `Starcat/Features/About/AboutView.swift` 的 `AboutDependency.all`。
> 登记字段:`name` / `license` / `copyright` / `url`(copyright 必须取自上游 `LICENSE`)。

### 国际化规范（i18n，强制）

> 单一信任源：[`docs/5-规范/国际化-规范.md`](docs/5-规范/国际化-规范.md) + [`docs/5-规范/i18n-军规.md`](docs/5-规范/i18n-军规.md)
> 关键 5 条:`String.l10n` / `Text("key")` / `.appLocaleEnvironment()` / locale 注入 / `Localizable.xcstrings` 命名 `{section}.{subsection}.{component}`。
> 自检:提交前 `rg "String\(localized:"` 与 `rg "NSLocalizedString"` 应只命中注释。

---

## 已解决的问题

以下问题已在 `docs/1-立项/开发前问题清单.md` 中确认解决方案：

- ✅ macOS 最低版本：15 Sequoia（兼容 Liquid Glass API）
- ✅ Swift 版本：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：BYOK Provider 生成 embedding，本地 SQLite 缓存并由 Swift 计算 cosine

---

*最后更新：2026-06-26*
