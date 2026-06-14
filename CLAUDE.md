# CLAUDE.md

本文档为 Claude Code 在本代码库工作时提供指导。

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
├── 发版流程.md          # ⭐ 发版 SOP（git tag 自动驱动版本号）
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

### UI 颜色规范：适配明暗主题（强制，2026-06-14 起生效）

文字 / 图标 `foregroundStyle` **只用 `.primary` 或 `.secondary`，禁止 `.tertiary`**。

`.tertiary` 在浅色主题下对比度仅约 1.5:1（远低于 WCAG AA 4.5:1），文字图标在白底上几乎"灰糊"不可读。

**唯一例外**：刻意弱化的装饰性图标占位（如队列未开始态 `Image("circle")`、未选中态视觉降级等），可以保留 `.tertiary`，但**必须**在代码注释里写明"故意弱化 + 产品意图"。

### UI 规范：Focus Ring 蓝框（强制）

**所有**使用 `.buttonStyle(.plain)` 的 Button **必须**添加 `.focusEffectDisabled()`，禁用 macOS 默认的蓝色 focus ring。

> ⚠️ 这是强制规则。任何新建或修改的 Button若遗漏 `.focusEffectDisabled()`，必须补上。

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

### 国际化规范（i18n）

**所有用户可见文本必须使用 String Catalog 本地化键**，禁止硬编码。

#### 键命名规范
格式：`{section}.{subsection}.{component}`，使用 `.` 分隔，禁止使用 `_`。

#### 代码规范
```swift
// ✅ 正确：SwiftUI 自动解析字符串字面量
Text("settings.general.title")
Label("sidebar.allRepos", systemImage: "star.fill")

// ✅ 正确：带参数的本地化字符串
Text("batch.selectedCount", args: ["count": viewModel.multiSelectedRepoIDs.count])

// ❌ 错误：硬编码
Text("设置")
Text("已选 \(count) 个")
```

#### 枚举 displayName 规范
枚举的本地化显示名应使用 `displayNameKey` 属性返回 String Catalog 键名：
```swift
enum RepoListDensity: String, CaseIterable, Identifiable {
    case compact
    case card

    var displayNameKey: String {
        switch self {
        case .compact: return "settings.listDensity.compact"
        case .card:    return "settings.listDensity.card"
        }
    }
}
```

#### 资源文件
- 字符串目录：`Starcat/Resources/Localizable.xcstrings`
- 新增字符串时需同时添加 en 和 zh-Hans 翻译
- SF Symbols 无需本地化（系统已处理）

#### 多语言预览
使用 `.environment(\.locale, _)` 在 #Preview 中预览不同语言：
```swift
#Preview("English") {
    SettingsView()
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("简体中文") {
    SettingsView()
        .environment(\.locale, Locale(identifier: "zh-Hans"))
}
```

---

## 已解决的问题

以下问题已在 `docs/开发前问题清单.md` 中确认解决方案：

- ✅ macOS 最低版本：15 Sequoia（兼容 Liquid Glass API）
- ✅ Swift 版本：编译器 6.0 + 语言模式 5 + @Observable
- ✅ README 渲染：WebView（100% GFM 兼容）
- ✅ OAuth scope：`["read:user", "public_repo"]`
- ✅ 后台任务：macOS 用 NSBackgroundActivityScheduler
- ✅ 语义搜索：BYOK Provider 生成 embedding，本地 SQLite 缓存并由 Swift 计算 cosine

---

*最后更新：2026-06-14*
