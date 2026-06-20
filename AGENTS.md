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

### UI 颜色规范：适配明暗主题（强制，2026-06-14 起生效）

文字 / 图标 `foregroundStyle` **只用 `.primary` 或 `.secondary`，禁止 `.tertiary`**。

`.tertiary` 在浅色主题下对比度仅约 1.5:1（远低于 WCAG AA 4.5:1），文字图标在白底上几乎"灰糊"不可读。

**唯一例外**：刻意弱化的装饰性图标占位（如队列未开始态 `Image("circle")`、未选中态视觉降级等），可以保留 `.tertiary`，但**必须**在代码注释里写明"故意弱化 + 产品意图"。

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

### 开源致谢同步规则（强制，2026-06-07 起生效）

**任何**集成进 Starcat 的外部开源项目，**必须**在「关于页 → 开源致谢（Credits）」列表中追加一条对应的引用。

> ⚠️ 这是强制规则。少加 / 漏加都视为不合规，提交前必须补齐。

**适用范围**（只要满足任一条就算「集成」，必须登记）：
1. **SPM 依赖**：在 `project.yml` 的 `packages:` 里新增的任何 package。
2. **嵌入式资源**：把第三方仓库里的 SVG / 图标 / 图片 / 字体等素材复制进 `Starcat/Resources/Assets.xcassets/` 或其它资源目录。
3. **生成代码**：用脚本（如 `scripts/generate_*.py`）从第三方数据源生成的 Swift 文件（典型例子：`LinguistLanguages.generated.swift` 来源 GitHub Linguist）。
4. **Vendored 源码**：把第三方源码片段直接拷贝进 `Starcat/Shared/` 等目录使用（即便只用了一两个文件）。

**登记位置**：`Starcat/Features/About/AboutView.swift` → `private struct AboutDependency` → `static let all`

**单条记录必填字段**：
- `name`：项目名（与官方仓库一致，如 `swift-markdown-ui`）
- `license`：许可证名（`MIT` / `Apache 2.0` / `BSD-3-Clause` 等）
- `copyright`：版权声明文本（保留官方 `LICENSE` 文件里的原文版权行）
- `url`：项目源仓库地址（GitHub / GitLab 等）

**新增第三方依赖时的检查流程**：
1. 修改 `project.yml` 或新增嵌入资源 / 生成脚本之后，**立即**打开 `AboutView.swift` 追加 `AboutDependency` 条目。
2. 验证许可证：从依赖仓库的 `LICENSE` 文件复制 `Copyright (c) ...` 那一行到 `copyright` 字段。
3. 如果该依赖不允许商用 / 闭源分发（GPL / AGPL / SSPL 等 copyleft），先评估再集成，必要时记录到 `docs/开发前问题清单.md`。
4. 跑一次 Starcat → About → 致谢页，肉眼确认列表里能看到、能点开源链接。

**反例（必须避免）**：
- ❌ 在 `project.yml` 加了新 SPM package，但忘了同步 `AboutDependency.all`
- ❌ 把 Devicon / Linguist 这种「资源型开源项目」拷贝进 Assets，却不登记，因为它不在 SPM 里
- ❌ 写了一份 `Foo.generated.swift` 数据来自第三方仓库，却不登记数据源
- ❌ `copyright` 字段编造或留空 —— 必须取自上游 `LICENSE`

> 与之配套的常驻提醒已在 `AboutView.swift` 顶部 `AboutDependency` 注释中复述，避免后续协作者只看代码不看文档时漏登记。

### 国际化规范（i18n，强制）

> ⚠️ **新增 / 修改任何国际化代码前，必读** [`docs/i18n军规.md`](docs/i18n军规.md)（单一信任源，含决策矩阵 / 5 大 root cause / 反例对照 / 实战参考文件）。

**最小必知（违反任一项即不合规）**：

1. **新代码禁止** `String(localized:)` 与 `NSLocalizedString`。返回 `String` 的本地化场景一律走 `String.l10n("key")`。
2. SwiftUI `Text` / `Label` / `Button` 等接 `LocalizedStringKey` 的 view **直接写** `Text("key")`，不要套 `String.l10n`。
3. **每个** `.sheet { }` / `.popover { }` 闭包内根视图、**每个**自建 `NSWindow` / `NSPanel` 的 hostingView 根，**必须**挂 `.appLocaleEnvironment()`。
4. 任何 Foundation formatter（`RelativeDateTimeFormatter` / `Date.RelativeFormatStyle` / `DateFormatter` / `NumberFormatter`）默认走系统 locale，**必须**视图内 `@Environment(\.locale)` + `formatter.locale = locale`（或链式 `.locale(locale)`）显式注入。
5. 字符串目录：`Starcat/Resources/Localizable.xcstrings`，新增 key **必须**同时填 en + zh-Hans 双语，命名 `{section}.{subsection}.{component}`，禁用 `_`。

提交前自检：

```bash
rg "String\(localized:" --type swift Starcat/   # 必须只出现在注释里
rg "NSLocalizedString"  --type swift Starcat/   # 必须只出现在注释里
```

### 问题处理

- 发现文档间不一致时，以 `开发前问题清单.md` 中的决策为准
- 新发现的问题先记录到 `开发前问题清单.md`，再实施修改

---

*最后更新：2026-06-16*

---

## Cursor Cloud specific instructions

> 本节面向后续 Cloud Agent。环境为 **Linux x86_64**，与本项目主产品的目标平台（Apple）不一致，存在硬性平台限制，先读完再动手。

### ⚠️ 主产品（Starcat macOS App）无法在本 Cloud 环境构建 / 运行 / 测试

- Starcat 是 **macOS 15+ 原生 App**（SwiftUI + AppKit + WebKit + CloudKit + Keychain，遍布 100+ 个 `.swift` 文件），构建链是 `xcodegen` + `xcodebuild`。
- Cloud Agent VM 是 **Linux**，没有 Swift / Xcode / xcodegen，且这些 Apple 框架与 `xcodebuild`/`xcodegen` 在 Linux 上根本不存在。**即使安装 Linux 版 Swift 也无法编译**（SwiftUI/AppKit 等是 Apple-only）。
- 因此 AGENTS.md「如何跑单测」一节里的 `xcodegen generate` / `xcodebuild ... test`、`make run` / `make test`、`scripts/run-debug.sh` 等命令在本环境 **全部不可用**，需在 macOS + Xcode 上执行。改动 Swift 代码后，**lint/build/test 必须由人在 macOS 上验证**。

### 本环境实际可运行的部分

1. **落地页（`pages/`）** —— 纯静态 HTML（`index.html` 英文 / `index-zh.html` 中文 + `privacy*.html` / `eula*.html`），无构建步骤。本地预览：
   ```bash
   cd pages && python3 -m http.server 8080   # 然后浏览器开 http://localhost:8080/index.html
   ```
   `pages/deploy.sh` 仅用 rsync 把静态文件推到远端服务器，本环境无需执行。
2. **Python 开发脚本（`scripts/`）** —— `xcstrings_patch.py`（仅标准库）、`generate_linguist_metadata.py`（依赖 `pyyaml`，需联网拉数据）。`python3` 与 `pyyaml` 在基础镜像中已就绪，**无需额外安装**。

### 依赖刷新说明

- Linux 可运行部分（静态页 + Python 脚本）**没有需要安装的第三方依赖**（无 `requirements.txt` / `package.json`；`pyyaml` 系统自带）。启动脚本因此保持空操作即可，不要往里塞 macOS 构建命令。

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