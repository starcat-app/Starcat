---
name: starcat-ui-prototype
description: 为 Starcat 生成 macOS 原型与 UI 设计稿。Starcat 是一款面向重度 GitHub 用户的 Apple 平台 Star 管理与 AI 知识整理工具，采用 macOS 26 Liquid Glass 设计语言。当需要为 Starcat 生成界面原型、UI 设计稿、组件设计或视觉稿时使用此技能。
---

# Starcat UI Prototype Skill

为 Starcat 项目生成 macOS 原型与 UI 设计稿。

## 项目背景

### Starcat 是什么

Starcat 是一款面向重度 GitHub 用户的 Apple 平台 Star 管理与 AI 知识整理工具。

**核心价值**：「整理、理解、找回、评估」
**目标用户**：独立开发者、技术博主、技术媒体
**平台**：macOS（首发）、iOS/iPadOS、watchOS
**设计语言**：macOS 26 Liquid Glass

### 核心功能

1. **GitHub Stars 管理**：OAuth 登录、增量同步、三栏布局
2. **AI 智能整理**：AI 摘要、标签推荐、语义搜索、14 分类体系
3. **发现页**：AI 每日推荐、GitHub Trending、个性化推荐
4. **Release 订阅追踪**：时间线、智能过滤、一键下载
5. **多端同步**：CloudKit 用户数据同步

### 技术栈

- SwiftUI + macOS 26 Liquid Glass
- GRDB.swift (SQLite)
- CloudKit
- Keychain
- 自建 AI 代理（你的云服务器）

---

## 设计方向

### macOS 26 Liquid Glass 设计规范

Liquid Glass 是 macOS 26 引入的设计语言，核心特征：

| 特征 | 实现 |
|------|------|
| 半透明材质 | `.glassEffect()` |
| 动态光影 | 实时折射和反射 |
| 深度层次 | 背景层 → 玻璃层 → 前景控件 |
| 流畅动画 | spring 物理动画、matched transitions |

### 色彩系统

```
主色调：System Blue (#007AFF)
成功色：System Green (#34C759)
警告色：System Orange (#FF9500)
强调色：System Purple (#AF52DE)

暗色模式：
- 背景：#000000 → 渐变透明
- 玻璃层：rgba(255,255,255,0.08)
- 文字 Primary：#FFFFFF
- 文字 Secondary：rgba(255,255,255,0.6)

亮色模式：
- 背景：#F5F5F7
- 玻璃层：rgba(255,255,255,0.72)
- 文字 Primary：#1D1D1F
- 文字 Secondary：rgba(29,29,31,0.6)
```

### 字体系统

```
标题：SF Pro Display，20-28pt，600 weight
正文：SF Pro Text，13-17pt，400 weight
代码：SF Mono，13pt
注释：SF Pro Text，11-12pt，400 weight
```

### 圆角系统

```
小组件：8pt
卡片/按钮：12pt
面板/窗口：16pt
大容器：20pt
```

### 间距系统（8pt Grid）

```
紧凑间距：4pt
标准间距：8pt
宽松间距：16pt
容器间距：24pt
页面边距：32pt
```

---

## 三栏布局设计

### 整体结构

```
┌────────────────────────────────────────────────────────────────────┐
│  Liquid Glass 菜单栏 (macOS 26 透明样式)                            │
├──────────────┬─────────────────────────────────┬───────────────────┤
│              │                                 │                   │
│   Sidebar   │        Repo List               │     Detail       │
│   (220pt)   │        (弹性宽度)             │     (380pt)      │
│              │                                 │                   │
│  ┌────────┐ │  ┌─────────────────────────┐   │  ┌─────────────┐ │
│  │ Avatar │ │  │ 🔍 搜索框 (Glass)    │   │  │ Repo 标题  │ │
│  └────────┘ │  └─────────────────────────┘   │  │             │ │
│              │                                 │  │  Tabs:     │ │
│  All Repos  │  ┌─────────────────────────┐   │  │  README    │ │
│  ★ 1,234   │  │ 🟢 repo-name          │   │  │  Details   │ │
│              │  │    description...       │   │  │  Notes     │ │
│  Untagged   │  │    Python • 12.3k ★   │   │  │            │ │
│  📂 234     │  └─────────────────────────┘   │  └─────────────┘ │
│              │                                 │                   │
│  Tags ────  │  ┌─────────────────────────┐   │                   │
│  ├─ AI      │  │ 🔵 another-repo         │   │                   │
│  ├─ macOS   │  │    ...                  │   │                   │
│  └─ Python  │  └─────────────────────────┘   │                   │
│              │                                 │                   │
│  Languages ─│                                 │                   │
│  ├─ Swift   │         (滚动区域)            │                   │
│  └─ Go      │                                 │                   │
│              │                                 │                   │
└──────────────┴─────────────────────────────────┴───────────────────┘
```

### Sidebar 设计

```
┌─────────────────────────┐
│  ┌─────┐               │
│  │Avatar│  Username   │  ← 用户信息区
│  └─────┘  ★ 1,234    │
├─────────────────────────┤
│ ▶ All Repos      1,234 │  ← 主导航
│   Untagged         234 │
├─────────────────────────┤
│ ▼ Tags              ▼  │  ← 可折叠
│   ├─ AI             42 │
│   ├─ macOS          28 │
│   ├─ Python         56 │
│   └─ ...            ... │
├─────────────────────────┤
│ ▼ Languages        ▼  │  ← 可折叠
│   ├─ Swift          89 │
│   ├─ Python         56 │
│   └─ Go             34 │
├─────────────────────────┤
│ 🔔 Releases           │  ← 新功能入口
│ 📊 Trending           │  ← 新功能入口
└─────────────────────────┘
```

**动画规范**：
- 展开/折叠：`.easeOut(duration: 0.2)`
- Hover 高亮：scale 1.02 + 背景透明度变化
- 选中态：左边框 3pt System Blue + 背景高亮

### Repo List 设计

```
┌───────────────────────────────────────────────┐
│ 🔍 搜索 GitHub Stars...           ⌘K        │
├───────────────────────────────────────────────┤
│ 排序: 最近更新 ▼  │  密度: ▦▦           │  │
├───────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────┐ │
│ │ 🟢 repo-name                    ★ 12.3k │ │
│ │ A short description of the repository   │ │  ← 选中态：高亮背景
│ │ Python • Updated 2h ago                │ │
│ │ [AI] [macOS] [Swift]                   │ │  ← 标签 Pills
│ └─────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────┐ │
│ │ 🔵 another-repo                  ★ 8.1k │ │
│ │ Another description here...              │ │
│ │ TypeScript • Updated 5h ago             │ │
│ └─────────────────────────────────────────┘ │
│                   ...                       │
└───────────────────────────────────────────────┘
```

**列表项交互**：
- 点击：scale 0.98 → 1.0 spring 动画
- 选中：背景渐变 + 边框高亮
- 右键：玻璃弹出菜单

### Detail 面板设计

```
┌───────────────────────────────────────────────┐
│  repo-name                           ⋯      │  ← 操作菜单
├───────────────────────────────────────────────┤
│ ★ 12.3k  │  🍴 1.2k  │  👁 234  │  🌍 MIT│  ← 统计
├───────────────────────────────────────────────┤
│ [README] [Details] [Notes] [AI]             │  ← Tab 切换
├───────────────────────────────────────────────┤
│                                               │
│  # Project Name                              │
│  A detailed description...                    │
│                                               │
│  ## Installation                             │
│  ```bash                                    │
│  npm install project-name                     │
│  ```                                        │
│                                               │
│  ## Features                                │
│  - Feature 1                                │
│  - Feature 2                                │
│                                               │
└───────────────────────────────────────────────┘
```

**Tab 动画**：`.matchedTransitionSource` 实现 hero 动画

---

## AI 功能 UI

### AI 摘要面板

```
┌───────────────────────────────────────────────┐
│ 🤖 AI 摘要                           [重新生成] │
├───────────────────────────────────────────────┤
│                                               │
│ 📝 一句话描述                                │
│ 「让开发者高效管理 GitHub Stars 的工具」        │
│                                               │
│ 📖 中文摘要                                  │
│ Starcat 是一款面向重度 GitHub 用户的...        │
│                                               │
│ 🏷️ 推荐标签                                 │
│ [AI] [macOS] [Swift] [DevTools]            │  ← 可点击取消
│                                               │
│ 📦 支持平台                                  │
│ macOS • iOS • Linux                         │
│                                               │
│ ⚠️ 注意事项                                  │
│ 需要 GitHub OAuth 授权                       │
│                                               │
│         [采纳全部]  [选择采纳]               │
└───────────────────────────────────────────────┘
```

### 语义搜索 UI

```
┌───────────────────────────────────────────────┐
│ 🔍 找适合做生产环境 API 的 Python 框架...   │
├───────────────────────────────────────────────┤
│                                               │
│ 💡 搜索建议：                                │
│ • 包含「Python」「API」「生产环境」          │
│ • 按最近更新时间排序                          │
│                                               │
├───────────────────────────────────────────────┤
│                                               │
│ 🎯 搜索结果 (3 个匹配)                       │
│                                               │
│ ┌─────────────────────────────────────────┐ │
│ │ 1. FastAPI                      ★ 78k  │ │
│ │    匹配原因：README 提到「production」    │ │
│ │    现代 Python Web 框架...               │ │
│ └─────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────┐ │
│ │ 2. Django                       ★ 78k  │ │
│ │    匹配原因：Python 全栈框架             │ │
│ │    ...                                  │ │
│ └─────────────────────────────────────────┘ │
│                                               │
└───────────────────────────────────────────────┘
```

---

## 发现页 / Trending

```
┌───────────────────────────────────────────────┐
│ 🔥 今日精选  │  📈 上升最快  │  ✨ 新晋  │  🎯 为你推荐│
├───────────────────────────────────────────────┤
│                                               │
│ ┌─────────────────────────────────────────┐ │
│ │ 🟢 awesome-llm                ★ 45.2k  │ │
│ │ 排序原因：24h 内 +2.3k stars           │ │
│ │ 📈 7日增长：+15.2k                     │ │
│ │ [AI] [Python] [LLM]                     │ │
│ │                             [★ 收藏]     │ │
│ └─────────────────────────────────────────┘ │
│                                               │
│ ┌─────────────────────────────────────────┐ │
│ │ 🔵 another-repo                 ★ 23k   │ │
│ │ ...                                    │ │
│ └─────────────────────────────────────────┘ │
│                                               │
└───────────────────────────────────────────────┘
```

---

## Release 订阅追踪

```
┌───────────────────────────────────────────────┐
│ 🔔 Releases                    [订阅管理] [全部已读]│
├───────────────────────────────────────────────┤
│ 过滤: [全部] [macOS] [iOS] [CLI]  │  搜索... │
├───────────────────────────────────────────────┤
│                                               │
│ today                                        │
│ ┌─────────────────────────────────────────┐ │
│ │ 🔵 FastAPI                       v0.115.0│ │
│ │ 2 hours ago                             │ │
│ │ dmg • zip • source code                 │ │
│ │                    [📋 复制] [⬇️ 下载]   │ │
│ └─────────────────────────────────────────┘ │
│                                               │
│ yesterday                                    │
│ ┌─────────────────────────────────────────┐ │
│ │ 🟢 React                        v19.0.0  │ │
│ │ 1 day ago                               │ │
│ │ dmg • zip • deb                         │ │
│ └─────────────────────────────────────────┘ │
│                                               │
└───────────────────────────────────────────────┘
```

---

## 组件规范

### 玻璃容器（Glass Card）

```swift
// SwiftUI 实现
struct GlassCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

**样式**：
- 圆角：12pt
- 背景：Liquid Glass 材质
- 内边距：16pt
- 间距：与相邻元素 8pt

### 玻璃按钮

```swift
// 标准按钮
Button("Label") { }
    .buttonStyle(.glass)

// 突出按钮
.buttonStyle(.glassProminent)
```

**样式**：
- 圆角：8pt
- 内边距：水平 16pt，垂直 8pt
- Hover：scale 1.02 + 透明度变化
- 动画：`.easeOut(duration: 0.15)`

### 标签 Pill

```
┌──────────┐ ┌─────────┐ ┌────────────┐
│ [AI] ×   │ │ [macOS] │ │ [+ 添加标签] │
└──────────┘ └─────────┘ └────────────┘
```

**样式**：
- 圆角：6pt（药丸形状）
- 内边距：4pt 水平，2pt 垂直
- 可删除态：显示 × 按钮
- 可添加态：虚线边框

### 输入框

```swift
// 玻璃输入框
TextField("搜索...", text: $query)
    .textFieldStyle(.glass)
```

---

## 动画规范

### 页面切换

```swift
// Hero 动画（macOS 26）
NavigationLink(value: repo) {
    RepoRow(repo: repo)
}
.matchedTransitionSource(id: repo.id, in: namespace)

// Tab 切换
TabView(selection: $selectedTab) {
    // ...
}
.animation(.easeOut(duration: 0.25), value: selectedTab)
```

### 列表动画

```swift
// Scroll 动画
ScrollView {
    LazyVStack {
        ForEach(repos) { repo in
            RepoRow(repo: repo)
                .scrollTargetLayout()
        }
    }
}
.animation(.interpolatingSpring(duration: 0.4, bounce: 0.2), value: selectedRepo)
```

### Hover 动画

```swift
// 推荐使用 easeOut
Button { } label: { Text("Label") }
    .buttonStyle(.easeOut(duration: 0.15))
```

### 展开/折叠

```swift
// 玻璃变形动画
.glassEffectID(repo.id, in: namespace)
    .animation(.easeOut(duration: 0.2), value: isExpanded)
```

---

## 输出要求

### 原型输出

当调用此技能时，请输出：

1. **线框图**：展示布局结构
2. **高保真设计稿**：展示视觉效果
3. **组件规格**：尺寸、颜色、字体等
4. **交互说明**：动画、状态、过渡
5. **SwiftUI 代码片段**：关键组件实现

### 格式要求

- 输出格式：Markdown + 代码块
- 包含可视化布局图（ASCII 或 Mermaid）
- 提供可运行的 SwiftUI 代码示例
- 说明设计决策和理由

### 示例调用

```
使用此技能生成 Starcat 三栏主界面的高保真原型，
包含 Liquid Glass 效果的侧边栏、仓库列表和详情面板。
```

---

## 参考资源

- [macOS 26 HIG](https://developer.apple.com/design/human-interface-guidelines/)
- [Liquid Glass SwiftUI](https://swiftcrafted.dev/article/mastering-liquid-glass-swiftui-complete-guide-ios-26-design-language)
- [Apple Design Resources](https://developer.apple.com/design/resources/)
