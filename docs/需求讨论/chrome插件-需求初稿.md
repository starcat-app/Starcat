# Starcat Chrome 浏览器插件功能方案

## 1. 核心定位

Starcat Chrome 插件不建议做成一个独立的大产品，而应该作为 Starcat macOS App 的浏览器侧入口。

它的核心定位是：

> Starcat 的浏览器采集入口 + GitHub 增强层 + AI 上下文桥梁。

整体链路：

```text
浏览器页面
  ↓
Chrome Extension 识别 / 提取 / 标注
  ↓
Starcat macOS App
  ↓
本地缓存 / GitHub API / AI 分析 / 收藏 / 项目管理
```

插件主要负责：

- 识别当前页面是不是 GitHub 仓库、Issue、PR、Release、源码文件等。
- 将当前页面、选中文本、代码片段、网页内容发送到 Starcat。
- 在 GitHub 页面中注入 Starcat 操作入口。
- 调起 Starcat App 进行收藏、分析、追踪、对比。

Starcat App 负责：

- GitHub 数据获取。
- 本地缓存。
- AI 分析。
- 项目管理。
- 收藏 / Inbox / Research Session。
- 后续完整展示。

---

## 2. 产品命名建议

可选名称：

- Starcat Companion
- Starcat Browser Helper
- Starcat for GitHub
- Starcat Web Clipper
- Starcat Lens

我个人更推荐：

> Starcat Companion

原因是这个名字能表达它是 Starcat 的配套浏览器插件，而不是一个独立产品。

---

## 3. 核心功能方向

### 3.1 GitHub 仓库一键发送到 Starcat

这是最自然、最适合作为 MVP 的功能。

当用户打开任意 GitHub 仓库页面时，插件可以显示：

```text
Open in Starcat
Analyze with Starcat
Save to Starcat
Track this repo
```

支持页面：

```text
github.com/{owner}/{repo}
github.com/{owner}/{repo}/issues
github.com/{owner}/{repo}/pulls
github.com/{owner}/{repo}/blob/...
github.com/{owner}/{repo}/tree/...
github.com/trending
github.com/topics/xxx
```

用户价值：

- 在浏览器里发现项目后，不需要复制链接。
- 不需要手动打开 Starcat 再搜索。
- 一键进入 Starcat 原生分析流程。
- 让 Starcat 成为 GitHub 项目发现之后的后续处理工具。

---

### 3.2 GitHub 页面增强：Starcat 浮层按钮

插件可以在 GitHub 仓库页面插入一个小面板，例如：

```text
⭐ Starcat
- Open in Starcat
- AI Summary
- Save to Collection
- Track Updates
- Compare with...
```

推荐插入位置：

- README 上方。
- Repo 右侧 About 区域。
- GitHub 页面右下角悬浮按钮。
- Issue / PR 标题区域旁边。

这个功能的关键点是：

> 插件只做入口，重分析交给 Starcat App。

---

### 3.3 网页内容保存为 Starcat Knowledge

用户在浏览器中看到有价值的技术内容时，可以一键保存到 Starcat。

适合保存的内容：

- GitHub repo
- 技术博客
- API 文档
- Issue 讨论
- PR 讨论
- StackOverflow 答案
- Hacker News 讨论
- Reddit 讨论
- Release Notes
- 开源项目官网

保存内容可以包括：

```text
URL
标题
网页正文
选中的文本
页面截图
来源网站
保存时间
标签
关联 GitHub repo
```

Starcat 中可以新增模块：

```text
Knowledge / Clips / Research
```

这个功能会把 Starcat 从 GitHub 客户端扩展为开发者信息工作台。

---

### 3.4 选中文本后发送给 Starcat 分析

用户选中网页上的一段内容，右键菜单出现：

```text
Ask Starcat
Explain with Starcat
Save to Starcat
Create note in Starcat
Find related GitHub repos
```

适合场景：

- 用户选中一段技术概念，让 Starcat 解释。
- 用户选中一段代码，让 Starcat 分析。
- 用户选中一段 Issue 评论，让 Starcat 总结。
- 用户选中一段文档内容，保存为上下文。

这个功能实现成本低，但使用频率可能很高。

---

### 3.5 GitHub Repo AI 速览卡片

当用户打开一个 GitHub repo，插件可以展示轻量信息卡片：

```text
Starcat Summary

Language: Swift
Stars: 12.4k
Last update: 2 days ago
Activity: High
License: MIT
AI Score: 8.6 / 10

Summary:
A SwiftUI-based markdown editor...
```

需要注意：

- 插件里不要做重分析。
- 可以展示 Starcat 已缓存的分析结果。
- 如果 Starcat 没有分析过，则显示 Analyze with Starcat。

推荐逻辑：

```text
如果 Starcat 已分析过当前 repo：
  展示摘要 / 状态 / 标签 / 是否已收藏

如果 Starcat 没分析过当前 repo：
  展示 Analyze with Starcat 按钮
```

---

### 3.6 GitHub Trending 增强

Starcat 已经规划 GitHub Trending 能力，Chrome 插件可以增强 GitHub Web 的 Trending 页面。

当用户访问：

```text
https://github.com/trending
```

插件可以提供：

```text
Open today's trending in Starcat
Import all visible repos
Compare with yesterday
Filter by Starcat collections
Hide already saved repos
```

还可以在每个 repo 条目上展示状态：

```text
Saved
Analyzed
Tracked
Ignored
```

这样浏览器和 Starcat 的状态可以同步。

---

### 3.7 Repository 追踪提醒

用户在 GitHub 页面点击：

```text
Track this repo
```

Starcat 后台可以追踪：

- stars 变化
- release 更新
- issue 数变化
- PR 活跃度
- commit 频率
- license 变化
- README 变化
- 依赖变化
- 安全公告

Chrome 插件可以辅助显示：

```text
This repo has a new release.
Open in Starcat?
```

不过通知能力不一定要放在插件里，Starcat macOS App 也可以直接通过系统通知完成。

---

### 3.8 GitHub Issue / PR 总结

当用户打开一个很长的 Issue 或 PR 页面时，插件显示：

```text
Summarize with Starcat
```

Starcat 可以提取：

- 问题背景
- 核心争议
- 当前状态
- 关键评论
- 维护者态度
- 是否已解决
- 相关提交
- 后续处理建议

适合场景：

- 评估一个开源项目是否维护活跃。
- 判断某个 bug 是否严重。
- 判断某个 PR 是否会影响使用。
- 快速理解长讨论。
- 分析维护者对问题的态度。

这个功能非常适合 AI，也是插件很有价值的差异化入口。

---

### 3.9 Release Notes / Changelog 解释器

很多开源项目的 Release Notes 很长，用户真正关心的是：

```text
我需要升级吗？
有没有 breaking changes？
和我当前版本相关吗？
升级风险是什么？
```

插件可以在 GitHub Releases 页面增加：

```text
Explain this release
Check upgrade risk
Compare releases
```

Starcat 输出：

- 升级收益
- 潜在风险
- Breaking Changes
- Migration Steps
- 建议是否升级
- 适合哪些用户升级
- 不建议哪些用户升级

这个功能和 Starcat 的开发者工具定位非常契合。

---

### 3.10 GitHub 文件 / 代码片段发送给 Starcat

用户打开 GitHub 的某个源码文件时，插件可以支持：

```text
Explain this file
Explain selected code
Find related files
Save as context
Ask about this implementation
```

需要注意：

- 浏览器页面中的源码只是局部上下文。
- 完整分析仍然应该由 Starcat 通过 GitHub API 获取仓库结构和文件内容。
- 插件的职责是告诉 Starcat：用户当前对这个文件或这段代码感兴趣。

---

## 4. 更有产品感的功能

### 4.1 Open in Starcat 深度链接

Starcat 应该优先设计一套 URL Scheme。

示例：

```text
starcat://repo?url=https://github.com/owner/repo
starcat://analyze?url=https://github.com/owner/repo
starcat://clip?url=https://example.com/article
starcat://issue?url=https://github.com/owner/repo/issues/123
starcat://release?url=https://github.com/owner/repo/releases/tag/v1.2.0
```

这样架构会非常清晰：

```text
Chrome Extension
  只做识别、提取、唤起

Starcat App
  做数据获取、缓存、AI 分析、展示
```

推荐优先使用 URL Scheme，而不是一开始就做复杂的 Native Messaging。

原因：

- 实现简单。
- 跨浏览器迁移更容易。
- 对 macOS App 友好。
- 插件权限更少。
- MVP 更容易落地。

---

### 4.2 Starcat Inbox

插件保存的内容可以先进入 Starcat 的 Inbox。

Inbox 支持的内容类型：

```text
GitHub repo
Blog article
Issue discussion
PR discussion
Release note
Code snippet
API document
Hacker News discussion
StackOverflow answer
```

用户之后在 Starcat 中统一处理：

```text
收藏
归档
打标签
AI 分析
关联项目
加入阅读列表
加入研究主题
```

这个功能会明显提升 Starcat 的长期使用价值。

---

### 4.3 Research Session

这是非常有差异化的功能。

用户在浏览器中研究一个技术问题，例如：

```text
SwiftUI markdown renderer
```

插件可以记录这次研究过程：

- 访问过哪些 GitHub 仓库
- 看过哪些文章
- 保存了哪些片段
- 对比了哪些项目
- 最终选择了哪个方案
- 为什么放弃了其他方案

Starcat 中可以形成一个研究会话：

```text
Research: SwiftUI Markdown Renderer

Sources:
- github.com/gonzalezreal/swift-markdown-ui
- github.com/markiv/SwiftUI-Shimmer
- Apple Markdown docs
- StackOverflow discussion

AI Summary:
...

Decision:
...
```

这不是简单收藏网页，而是帮助用户沉淀一次技术调研过程。

---

### 4.4 GitHub Repo 对比入口

用户浏览一个 repo 时，可以点击：

```text
Compare in Starcat
```

然后选择另一个已保存 repo。

Starcat 可以对比：

- Star 数趋势
- 维护活跃度
- License
- 语言和技术栈
- 最近 Release
- Issue 响应情况
- PR 合并情况
- 代码规模
- README 质量
- AI 总结
- 适合场景

典型对比场景：

```text
Alamofire vs Moya
Kingfisher vs Nuke
SwiftUI Markdown UI vs MarkdownUI
React Query vs SWR
Vite vs Rspack
```

这个功能适合做技术选型助手。

---

## 5. 插件产品形态设计

### 5.1 Toolbar Popup

点击浏览器右上角 Starcat 图标后展示当前页面信息。

如果当前是 GitHub Repo 页面：

```text
Current Page

GitHub Repo detected:
dong4j/starcat

[Open in Starcat]
[Analyze]
[Save to Inbox]
[Track Repo]
```

如果当前是普通网页：

```text
Current Page

Web Page detected:
Article / Docs / Blog

[Save to Starcat]
[Summarize]
[Ask Starcat]
```

---

### 5.2 Context Menu

右键菜单建议提供：

```text
Ask Starcat
Save selection to Starcat
Explain selected code
Find related repos
Save page to Starcat Inbox
```

适用对象：

- 当前页面
- 选中文本
- 图片
- 链接
- GitHub repo 链接
- GitHub issue 链接
- GitHub release 链接

---

### 5.3 GitHub Content Script

在 GitHub 页面中注入按钮。

仓库页：

```text
Starcat
Open
Analyze
Save
Track
Compare
```

Issue / PR 页：

```text
Summarize with Starcat
Save discussion
Extract decisions
```

Release 页：

```text
Explain release
Check upgrade risk
Compare versions
```

源码页：

```text
Explain file
Explain selected code
Save as context
```

---

## 6. 功能优先级建议

### 6.1 MVP 版本

第一版建议只做最核心的闭环。

| 功能 | 价值 | 实现难度 | 是否建议 MVP |
|---|---:|---:|---:|
| GitHub repo 页面识别 | 高 | 低 | 是 |
| Open in Starcat | 高 | 低 | 是 |
| Analyze with Starcat | 高 | 中 | 是 |
| Save to Starcat Inbox | 高 | 中 | 是 |
| 右键选中文本发送到 Starcat | 中 | 低 | 是 |
| GitHub 页面插入 Starcat 按钮 | 高 | 中 | 是 |
| Issue / PR 总结 | 高 | 中高 | 否 |
| Release Notes 分析 | 高 | 中高 | 否 |
| Research Session | 高 | 高 | 否 |
| Repo 对比 | 高 | 高 | 否 |

MVP 的核心体验：

```text
我在浏览器里看到一个项目
点击 Starcat 按钮
Starcat 自动打开并分析这个项目
```

---

### 6.2 第二阶段

第二阶段可以做：

| 功能 | 说明 |
|---|---|
| Issue / PR 总结 | 对长讨论非常有用 |
| Release Notes 分析 | 判断是否值得升级 |
| Trending 页面增强 | 和 Starcat Trending 功能联动 |
| Research Session 雏形 | 做开发者研究流 |
| Save Web Article | 让 Starcat 变成开发者知识库 |

---

### 6.3 第三阶段

第三阶段可以做更高级的功能：

| 功能 | 说明 |
|---|---|
| Repo 健康评分 | 综合维护活跃度、issue、release、stars |
| 技术选型助手 | 对比多个 repo |
| 浏览历史智能归类 | 自动识别研究主题 |
| 自动关联当前项目依赖 | 判断浏览的 repo 是否已被本地项目使用 |
| 安全风险提醒 | 依赖安全、归档仓库、维护停止等 |

---

## 7. 我最推荐优先做的 5 个功能

### 7.1 Open / Analyze GitHub Repo in Starcat

这是插件存在的最强理由。

```text
浏览器发现项目 → 一键进入 Starcat 分析
```

---

### 7.2 Starcat Inbox

把浏览器看到的技术资源统一保存进 Starcat。

支持内容：

```text
repo / issue / blog / docs / release notes / code snippet
```

这个会明显增强 Starcat 的长期使用价值。

---

### 7.3 Issue / PR AI Summary

GitHub 上最耗时间的不是看 README，而是读 Issue 和 PR 讨论。

AI 非常适合做这件事。

---

### 7.4 Release Upgrade Risk Analysis

这个功能对开发者很实用。

核心问题：

```text
这个版本要不要升？
有什么 breaking changes？
升级风险是什么？
```

---

### 7.5 Research Session

这是最有差异化的功能。

```text
调研主题
浏览来源
候选项目
AI 总结
最终结论
```

它能让 Starcat 从项目浏览工具升级为开发者研究工具。

---

## 8. 技术实现建议

### 8.1 Chrome 插件侧模块

插件主要由以下模块组成：

```text
manifest.json
background service worker
content script
popup UI
context menu
chrome.storage
custom URL scheme 调起 Starcat
```

推荐先采用 Manifest V3。

核心能力：

- 读取当前 tab URL。
- 判断页面类型。
- 注入 GitHub 页面按钮。
- 添加右键菜单。
- 通过 URL Scheme 调起 Starcat。
- 可选：保存插件侧临时状态。

---

### 8.2 Starcat macOS 侧能力

Starcat 需要支持：

```text
URL Scheme 路由
Repo URL 解析
Inbox 数据表
AI 分析任务入口
页面来源记录
Web Clip 基础模型
```

建议设计几种 Deep Link Action：

```swift
enum StarcatDeepLinkAction {
    case openRepo(url: URL)
    case analyzeRepo(url: URL)
    case savePage(url: URL, title: String?)
    case saveSelection(text: String, sourceURL: URL?)
    case summarizeIssue(url: URL)
    case summarizeRelease(url: URL)
}
```

---

### 8.3 Deep Link 设计

建议 URL Scheme：

```text
starcat://repo?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo
starcat://analyze?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo
starcat://clip?url=https%3A%2F%2Fexample.com%2Farticle&title=xxx
starcat://selection?text=xxx&url=https%3A%2F%2Fexample.com
starcat://issue?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%2Fissues%2F123
starcat://release?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%2Freleases%2Ftag%2Fv1.2.0
```

插件只需要执行：

```javascript
chrome.tabs.create({
  url: `starcat://analyze?url=${encodeURIComponent(currentUrl)}`
});
```

---

### 8.4 数据模型建议

#### InboxItem

```swift
struct InboxItem {
    let id: UUID
    let type: InboxItemType
    let title: String
    let url: String
    let source: String
    let selectedText: String?
    let htmlSnapshot: String?
    let markdownContent: String?
    let relatedRepoFullName: String?
    let tags: [String]
    let createdAt: Date
    let updatedAt: Date
}
```

#### InboxItemType

```swift
enum InboxItemType {
    case githubRepo
    case githubIssue
    case githubPullRequest
    case githubRelease
    case githubFile
    case article
    case documentation
    case codeSnippet
    case discussion
    case unknown
}
```

#### RepoTracking

```swift
struct RepoTracking {
    let repoFullName: String
    let enabled: Bool
    let trackStars: Bool
    let trackReleases: Bool
    let trackIssues: Bool
    let trackPullRequests: Bool
    let trackReadme: Bool
    let trackSecurityAdvisories: Bool
    let createdAt: Date
    let updatedAt: Date
}
```

---

## 9. MVP 详细方案

### 9.1 MVP 目标

```text
Starcat Chrome Extension v0.1

目标：
让用户在浏览器中发现 GitHub 仓库后，可以一键发送到 Starcat 进行收藏、分析和追踪。
```

---

### 9.2 MVP 功能列表

```text
1. 识别 GitHub repo 页面
2. Popup 展示当前 repo 信息
3. 支持 Open in Starcat
4. 支持 Analyze with Starcat
5. 支持 Save to Starcat Inbox
6. 支持右键保存选中文本
7. 支持 GitHub 页面注入 Starcat 按钮
```

---

### 9.3 MVP 插件界面

#### GitHub Repo 页面

```text
Starcat Companion

Detected GitHub Repo:
owner/repo

[Open in Starcat]
[Analyze with Starcat]
[Save to Inbox]
[Track Repo]
```

#### 普通网页

```text
Starcat Companion

Current Page:
Article / Docs / Blog

[Save to Starcat]
[Ask Starcat]
```

#### 选中文本右键菜单

```text
Starcat
- Ask Starcat
- Save Selection to Starcat
- Explain Selected Code
```

---

### 9.4 MVP Starcat App 配合改造

Starcat App 需要新增：

```text
1. 注册 starcat:// URL Scheme
2. 支持解析 deep link
3. 新增 Inbox 表
4. 新增 Repo Import / Analyze 入口
5. 新增 Web Clip 基础模型
6. 支持从外部链接打开 repo 详情页
7. 支持从外部链接触发 AI 分析任务
```

---

## 10. 不建议第一版做的功能

第一版不建议做这些：

| 功能 | 原因 |
|---|---|
| 完整网页正文抽取 | 解析复杂，站点差异大 |
| 浏览历史自动分析 | 权限敏感，容易让用户反感 |
| Native Messaging | 实现成本高，MVP 阶段没必要 |
| 插件内 AI 对话 | 会分散 Starcat App 的核心价值 |
| 插件内完整项目分析 | 插件环境不适合做重任务 |
| 自动注入大量 GitHub UI | 容易和 GitHub 页面结构变化耦合 |

---

## 11. 产品边界建议

插件的边界应该是：

```text
浏览器负责发现
Starcat 负责理解
```

不要把插件做成一个完整的 AI 助手，也不要让插件承担完整分析逻辑。

推荐职责划分：

| 模块 | 职责 |
|---|---|
| Chrome 插件 | 识别页面、提取 URL、提取选中文本、注入按钮、调起 Starcat |
| Starcat App | 数据获取、AI 分析、本地缓存、项目管理、Inbox、追踪、对比 |
| 后端服务 | GitHub API 聚合、Trending、Show HN 抓取、AI 分类、远程同步 |

---

## 12. 最终推荐方案

我建议 Starcat Chrome 插件第一版定位为：

> Starcat Companion：浏览器里的 GitHub 项目发现与采集入口。

第一版只聚焦一个核心闭环：

```text
在浏览器里发现 GitHub 项目
  ↓
点击 Starcat 按钮
  ↓
打开 Starcat
  ↓
收藏 / 分析 / 追踪
```

第一版功能：

```text
1. Open in Starcat
2. Analyze with Starcat
3. Save to Starcat Inbox
4. Track Repo
5. 右键选中文本 Ask / Save
6. GitHub 页面注入 Starcat 按钮
```

后续逐步扩展：

```text
Issue / PR 总结
Release 升级风险分析
GitHub Trending 增强
Research Session
Repo 对比
开发者知识库
```

最终用户心智应该是：

> 看到有价值的开发资源 → 丢进 Starcat → Starcat 帮我分析、整理、追踪、对比。

这个方向最适合 Starcat 当前的产品定位，也最容易形成差异化。
