# Starcat GitHub Search 集成设计方案

## 1. 设计目标

在 Starcat 现有三栏架构中无缝集成 GitHub 全站仓库搜索，复用现有 Repo 卡片、详情页基础设施，分 MVP 和 AI 增强两个阶段落地。

---

## 2. 现有架构分析（与 Search 集成相关的部分）

### 2.1 导航体系

```
页面模式
├── Manage    → SidebarItem (.allStars / .untagged / .language / .tag)
├── Trending  → TrendingView + TrendingViewModel
├── Activity  → ActivityView + ActivityViewModel
└── [Toolbar] → GitHub 全站搜索（临时覆盖中间栏，不占 Sidebar 位置）
```

Search 不进入 Sidebar，而是通过 toolbar 搜索框随时激活。

### 2.2 数据展示链路

```
中间栏列表                       右侧详情
┌─────────────────┐           ┌─────────────────┐
│ UnifiedRepoRow   │ ─click→  │ RepoDetailView   │
│ (RepoCardViewData)│          │   ├─ manage:     │
│                  │          │   │  RepoDetailScaffold
│                  │          │   │  + ManageDetailContent
│                  │          │   ├─ trending:    │
│                  │          │   │  TrendingScaffoldShell
│                  │          │   └─ empty        │
└─────────────────┘           └─────────────────┘
```

`RepoCardViewData` 是卡片视图的统一数据模型，与来源无关（本地 DB / Trending API / Activity API 均可适配）。

### 2.3 Trending 模式（Search 的主要参考对象）

Trending 是最接近 Search 的现有实现，两者共同点：

| 维度 | Trending | Search（目标） |
|------|----------|---------------|
| 数据来源 | Starcat Backend | GitHub REST Search API（直连） |
| 不与本地 starred_repos 绑定 | 是 | 是 |
| 分页 | 后端控制 | API 原生支持 page/per_page |
| 语言筛选 | Sidebar 语言列表 | Search 筛选栏 |
| 详情页 | TrendingScaffoldShell → 先查本地再回源 | 同款模式复用 |
| 卡片 | UnifiedRepoRow | UnifiedRepoRow（复用） |

---

## 3. MVP 阶段设计

### 3.1 搜索入口：扩展现有 SmartSearchField

**不新增 UI 控件**。在现有 `SmartSearchField`（toolbar 右侧）的模式菜单中增加第三种模式。

现有搜索组件已支持的两种模式：

| 模式 | 枚举值 | 数据源 | 图标 | 视觉特征 |
|------|--------|--------|------|----------|
| 全文搜索 | `.keyword` | 本地 DB FTS5 | `magnifyingglass` | 灰色胶囊边框 |
| 语义搜索 | `.semantic` | AI Embeddings | `sparkles` | 紫色渐变光晕 + AngularGradient 动画 |

新增第三种模式：

| 模式 | 枚举值 | 数据源 | 图标 | 视觉特征 |
|------|--------|--------|------|----------|
| **GitHub 搜索** | `.github` | GitHub REST Search API | `globe` | 蓝色胶囊边框 + 微弱脉冲光晕 |

**SmartSearchMode 枚举扩展**：

```swift
// AppSettings.swift
enum SmartSearchMode: String, CaseIterable, Identifiable {
    case keyword    // 现有：本地 FTS5 全文搜索
    case semantic   // 现有：AI 语义搜索
    case github     // 新增：GitHub 全站搜索

    var displayName: LocalizedStringKey {
        switch self {
        case .keyword:  return "search.mode.keyword"
        case .semantic: return "search.mode.semantic"
        case .github:   return "search.mode.github"
        }
    }

    var systemImage: String {
        switch self {
        case .keyword:  return "magnifyingglass"
        case .semantic: return "sparkles"
        case .github:   return "globe"
        }
    }
}
```

**UX 交互流程**：

```
用户在 Manage/Trending/Activity 任一页面，看到 toolbar 右侧搜索图标
  ↓
点击搜索图标 Ⓜ → 搜索框展开
  ↓
点击左侧模式图标 ▼ → 下拉菜单展开，显示 3 个选项：
  - 🔍 全文搜索
  - ✨ 语义搜索
  - 🌐 GitHub 搜索    ← 新增
  ↓
用户选择 "GitHub 搜索" → 图标切换为 globe，边框切换为蓝色
  ↓
输入关键词 → Enter / 防抖 500ms
  ↓
中间栏切换为 GitHub 搜索结果列表（临时覆盖当前页面内容）
  ↓
Esc / 清空搜索框 → 退出 GitHub 搜索模式，中间栏恢复原页面
```

**关键设计约束**：
- `.github` 模式下，搜索字段应**在所有 SidebarRootPage 中可见**（而 `.keyword` / `.semantic` 仅对 Manage 有效）。实现方式：`RepoListView.toolbar` 中把 `smartSearchField` 的显示条件从 `if selectedPage == .manage` 改为始终显示（或当 mode == .github 时也显示）
- 模式切换时不清空搜索结果——用户可以在三种模式间对比结果
- GitHub 模式的视觉效果应区别于语义搜索（蓝色而非紫色），避免用户混淆"AI 语义搜索"和"GitHub 远程搜索"

### 3.2 搜索模式下的中间栏布局

搜索模式下，中间栏内容从原来的 repo 列表切换为搜索结果：

```
┌──────────────────────────────────┐
│  🔍 搜索框（已在 toolbar 中）     │
│  [Language ▼] [Sort ▼] [Stars ▼]│  ← 筛选器行
├──────────────────────────────────┤
│  UnifiedRepoRow                  │
│  UnifiedRepoRow                  │  ← 可滚动结果列表
│  UnifiedRepoRow                  │     (Infinite Scroll)
│  ...                             │
│  (加载更多指示器)                 │
└──────────────────────────────────┘
```

筛选器行在搜索激活时才显示，与搜索框一起构成搜索面板的顶部固定区域。

### 3.3 搜索框与筛选器

**搜索框（复用 SmartSearchField）**：
- 模式切换为 `.github` → 搜索行为、placeholder、视觉样式切为 GitHub 搜索
- 防抖 500ms 后自动发起搜索
- 按 Enter 立即搜索（跳过防抖）
- 搜索历史存储在 UserDefaults，不设条数上限。每条历史支持**删除按钮（×）**，顶部提供**一键清空**按钮。历史面板在 `.github` 模式下的搜索框获得焦点时下拉展示

**GitHub 专属筛选器**（仅在 `smartSearchMode == .github` 时显示，替换 toolbar 中的 statusFilterMenu / sortMenu）：

```
Toolbar（Manage 页面，.github 模式激活时）：
[Language ▼] [Stars ▼] [Sort ▼] [Created ▼]    [🌐 🔍 GitHub 搜索框                    ×]
```

- **Language**：下拉选择编程语言，数据源复用项目已有的 `LinguistLanguages.generated.swift`
- **Sort**：Best match（默认）/ Stars / Forks / Updated / Help wanted issues
- **Order**：Desc / Asc（仅当 Sort ≠ Best match 时可用）
- **Stars**：范围筛选（Any / >10 / >100 / >1000 / >10000）
- **Created**：时间范围（Any / 近一周 / 近一月 / 近一年）

任一筛选条件改变 → 自动重置分页并发起新搜索

### 3.4 搜索结果列表

**直接复用 `UnifiedRepoRow`**，数据适配路径：

```
GitHub Search API Response (JSON)
  → GitHubSearchRepoDTO (解码)
  → RepoCardViewData (通过扩展转换)
  → UnifiedRepoRow (渲染)
```

每张卡片显示：
- owner / repo 名 + avatar
- description
- language · stars · forks · license
- topics（最多显示 3 个，超出显示 "+N"）
- updatedAt（相对时间）

**与 Manage 列表的差异**：搜索结果卡片上增加一个**小星标图标**表示"已在你的 Stars 中"（通过 `StarredRegistry.contains` 查），帮助用户识别已收藏的仓库。

### 3.5 分页策略

- 使用 GitHub Search API 的 `page` + `per_page`（每页 30 条）
- **Infinite Scroll**：滚动到列表底部自动加载下一页
- 加载更多时底部显示 `ProgressView`，不阻塞已加载结果的交互
- GitHub Search API 最多返回 1000 条结果（硬限制），到达时显示提示

### 3.6 右侧详情面板

点击搜索结果 → 右侧显示详情。关键挑战：**搜索到的 repo 可能不在本地 DB 中**。

复用 Trending 已有的解决方案 —— `RepoDetailScaffold` 的 `backendHint` 机制：

```
选中搜索结果
  ↓
GitHubSearchDetailView
  ↓
SearchScaffoldShell（类比 TrendingScaffoldShell）
  ├─ 查询本地 DB：starred_repos 表是否有此 repo？
  │   ├─ 命中 → RepoDetailScaffold（完整三段，与 Manage 体验完全一致）
  │   └─ 未命中 → RepoDetailScaffold（ephemeral Repo，三段隐藏，仅 README + 基础信息）
  └─ 同时回源 GitHub API 拉取完整 repo 元数据
```

**Ephemeral Repo 模式**（未 star 的搜索结果）：
- Hero 区域显示 owner/repo、description、stars/forks/language/license（从搜索结果 DTO 已有字段直接渲染）
- Star 按钮显示为空心 ☆，点击触发 star 操作 → star 成功后刷新为实心 ⭐ → 三段（tags/notes/releases）解锁
- README 加载：通过 GitHub API 直接拉取（不经过本地缓存表，使用 `ReadmeHTMLAPI` 端点）
- 右上角不显示分享/AI 按钮（未 star 的仓库没有私人面板）

**与现有 RepoDetailView 的集成**：

当前 `RepoDetailView` 有三个分支：manage / trending / empty。Search 作为第四分支加入：

```swift
// RepoDetailView.swift 新增分支
} else if let searchItem = selectedSearchItem {
    SearchScaffoldShell(searchItem: searchItem)
        .id(searchItem.id)
        .detailContentTransition()
}
```

`selectedSearchItem` 由 `HomeViewModel` 新增属性提供（或由 `GitHubSearchViewModel` 通过回调写入 `HomeViewModel`）。

或者更简洁的方案：搜索结果的选择状态由 `GitHubSearchViewModel` 自治管理，`RepoDetailView` 增加一个 search 分支，通过 Environment 获取选中的 search item。这需要重新考虑 HomeViewModel 与 GitHubSearchViewModel 的职责边界。

### 3.7 服务层设计

**GitHubSearchService**（业务逻辑层，`@Observable` 注入 AppDependencies）：

```swift
@MainActor
@Observable
final class GitHubSearchService {

    // MARK: - GitHub 专属筛选状态（独立于 Manage 筛选器）

    var selectedLanguage: String?
    var selectedSort: GitHubSearchSort = .bestMatch
    var selectedOrder: GitHubSearchOrder = .desc
    var selectedStarsRange: GitHubSearchStarsRange = .any
    var selectedCreatedRange: GitHubSearchCreatedRange = .any

    // MARK: - 分页状态

    var currentPage: Int = 1
    var totalCount: Int = 0
    var hasMorePages: Bool = true
    var isLoadingMore: Bool = false

    // MARK: - 搜索历史

    var searchHistory: [String] = []  // UserDefaults 持久化，不设上限

    // MARK: - 依赖

    private let client: any GitHubAPIClientProtocol
    private let starredRegistry: StarredRegistry

    // MARK: - 方法

    func search(query: String) async throws -> [RepoCardViewData]
        // 发起搜索（重置分页），返回卡片数据供 HomeViewModel 写入 items
    func loadNextPage(query: String) async throws -> [RepoCardViewData]
        // 加载下一页，追加到现有结果
    func deleteHistoryItem(_ item: String)
    func clearAllHistory()
}
```

**与 HomViewModel 的协作**：

- `HomeViewModel.reloadItems()` 在 `smartSearchMode == .github` 时调用 `gitHubSearchService.search(query:)`
- 返回的 `[RepoCardViewData]` 写入 `HomeViewModel.rawItems`（GitHub 搜索结果不是 Repo，需适配）
- 保留 `GitHubSearchRepoDTO` 原始数据用于详情页回源
- 筛选状态（Language / Sort / Stars / Created）由 `GitHubSearchService` 管理，避免污染 `HomeViewModel` 的 Manage 筛选器

### 3.8 API 层设计

MVP 采用**客户端直连 GitHub REST API**：

```
Starcat App → GitHub REST API (GET /search/repositories)
```

使用用户 OAuth token 认证（复用现有 `GitHubAPIClient` + `KeychainTokenProvider`）。

**Rate Limit 约束**：
- 已认证请求 30 req/min（Search API 单独计费）
- 未认证请求 10 req/min
- 响应头 `X-RateLimit-Remaining` 实时可读，ViewModel 可据此展示剩余配额
- 触发 429 → 读取 `Retry-After` 头，展示倒计时

**搜索端点封装**：

在现有 `GitHubAPIClient` 上新增 `searchRepositories` 方法，走 `GET /search/repositories`，与 `starredRepos`、`repo` 平级。不引入额外的网络层。

**模块组织**（在现有 `GitHubAPIClient` 上扩展，不新建独立 API 模块）：

```
Starcat/Core/Network/GitHubAPI/
├── GitHubAPIClient.swift             (现有)
├── GitHubAPIClientProtocol.swift     (现有，新增 searchRepositories 方法)
├── GitHubDTOs.swift                  (现有，新增 GitHubSearchRepoDTO / GitHubSearchResponse)
└── RepoAPI.swift                     (现有)
```

### 3.9 与 HomeViewModel / SmartSearchField 的关系

**核心决策：`.github` 模式复用现有 SmartSearchField 框架，不走 `HomeViewModel.reloadItems()`**。

`HomeViewModel` 已有 `smartSearchMode` 属性和 `isSearching` 计算属性：

```swift
// HomeViewModel.swift（现有逻辑）
var smartSearchMode: SmartSearchMode = .keyword   // ← 新增 .github case
var isSearching: Bool { !searchQuery...isEmpty }  // ← GitHub 搜索也走此路径
var isSemanticSearching: Bool { isSearching && smartSearchMode == .semantic } // 不变
```

**新增 `isGitHubSearching`**：

```swift
var isGitHubSearching: Bool {
    isSearching && smartSearchMode == .github
}
```

**搜索结果数据源派发**（`reloadItems` 中现有 switch 增加分支）：

```swift
// 搜索分支内
if self.isSearching {
    if self.smartSearchMode == .semantic { ... }     // 不变
    else if self.smartSearchMode == .github { ... }   // 新增：走 GitHubSearchService
    else { ... }                                      // 不变：FTS5
}
```

**GitHub 搜索结果由 `GitHubSearchService` 返回**，转换为 `[RepoCardViewData]` 后直接写入 `HomeViewModel.items`，无需额外的 `GitHubSearchViewModel` 管理 UI 状态。`HomeViewModel` 已有的 `isLoading`、`loadError`、`items`、`itemsRevision` 全部复用。

**中间栏搜索模式覆盖**（`RepoListView.contentBody` 修改）：

```swift
// 现有代码中 isSearching 时展示统一的搜索/骨架/空/错误/结果列表
// GitHub 搜索复用同一套 view，但筛选器行不同：
// - keyword/semantic：显示现有的 statusFilterMenu / sortMenu（Manage 内筛选）
// - github：显示 GitHubSearchFilterBar（Language / Stars / Sort / Created）
```

**Toolbar 可见性**：

```swift
// 现有：smartSearchField 仅在 .manage 显示
if selectedPage == .manage {
    ToolbarItem(placement: .primaryAction) { smartSearchField }
}
// 改为：所有页面显示（或至少 Manage + Trending + Activity 都显示）
// 或最小改动：smartSearchField 在 .manage 始终显示，其他页面仅 mode == .github 时显示
```

**切换模式时不清空已加载数据**。三种搜索模式之间切换复用同一个 `searchQuery`，让用户对比结果。

### 3.10 本地缓存策略

**搜索结果不缓存到本地 DB**。每次搜索实时请求 GitHub API，保证结果时效性。

**Ephemeral Repo 的 README 也不缓存**。搜索结果详情页的 README 每次实时拉取，不写入 `readmes` 表。原因是：
- 搜索结果可能只访问一次，缓存价值低
- 不与已 star 仓库的 README 缓存（`readmes` 表）混淆
- 用户 star 该仓库后，后续访问走 Manage 路径，那时再正常走缓存逻辑

### 3.11 空状态与错误状态

```
搜索前（无 query）：   🔍 输入关键词搜索 GitHub 全站仓库
搜索中（loading）：    骨架屏（复用 RepoSkeletonListView）
搜索无结果：          🔍 未找到 "{query}" 相关仓库，试试其他关键词
网络错误：            ⚠️ 搜索请求失败，[重试] 按钮
Rate Limit：          ⏱️ 请求过于频繁，请稍后再试（显示 retry-after 倒计时）
到达 1000 条上限：    📋 已显示全部搜索结果（GitHub 限制 1000 条）
```

---

## 4. AI 增强阶段

AI 阶段建立在 MVP 数据管道之上，核心思路是**AI 不改变搜索流程，而是在搜索结果上增加一层智能分析层**。

### 4.1 AI 搜索查询增强

**自然语言 → 搜索参数**：

用户在搜索框输入自然语言描述，AI 将其转换为结构化搜索参数：

```
用户输入："最近一周热门的 SwiftUI 开源组件"
       ↓ AI 解析
{
  keyword: "SwiftUI component",
  language: "Swift",
  sort: "stars",
  order: "desc",
  createdAfter: "2026-06-05",
  minStars: 100
}
```

**UX 设计**：
- 搜索框右侧增加一个 ✨ AI 按钮（类似 Cursor 的 "Ask AI"）
- 点击后展开一个小面板：显示 AI 解析出的搜索参数 + 自然语言改写
- 用户可手动调整参数后再搜索，或直接使用 AI 的建议
- 这个功能是可选的，不影响常规搜索体验

### 4.2 搜索结果 AI 分析

在搜索结果列表中，每张卡片新增 **"AI 快速分析"入口**：

```
┌──────────────────────────────────────────┐
│  owner/repo                    ⭐ 1.2k   │
│  A beautiful SwiftUI component library   │
│  Swift · 1.2k stars · MIT · 2d ago      │
│  [tag1] [tag2]                           │
│  ─────────────────────────────────────   │
│  🤖 AI 摘要: "这是一个高质量的..."       │  ← 可展开/折叠
│  📊 AI 评分: ★★★★☆ 4.2/5               │  ← 基于多维度评估
│  🏷️  AI 推荐标签: [UI] [Component]      │  ← 可一键采纳
└──────────────────────────────────────────┘
```

**展开 AI 分析**有以下几个维度：
- **一句话摘要**：AI 根据 README + description 生成的简短总结
- **质量评分**：基于 stars 趋势、维护活跃度、文档完整度的综合评分
- **相似推荐**：在当前搜索结果中推荐 3 个相似仓库
- **标签推荐**：AI 推荐的标签（如果用户决定 star，可以一键应用）

**触发时机**：
- 不自动触发（避免 token 浪费）
- 用户在卡片上点击 "AI 分析" 按钮 → 展开分析面板 → 按需调用 AI

### 4.3 与 Starcat 生态联动

搜索结果中展示仓库在 Starcat 生态中的状态（需求初稿中提到的差异化能力）：

```
┌─────────────────────────────────────────┐
│  Starcat 生态状态                        │
│  ✅ 已收藏 (2026-05-15)                  │
│  📝 有 2 条笔记                          │
│  🏷️ 标签: [AI] [SwiftUI]                │
│  📖 README 已缓存                        │
│  🤖 已生成 AI 摘要                       │
│  🔗 CodeGraph 已索引                     │
└─────────────────────────────────────────┘
```

这些信息在卡片底部以紧凑的一行 icon 呈现（类似 GitHub 的 repo 状态栏），展开后显示详情。数据来自本地 DB（starred_repos / repo_notes / repoTags / readmes 表），实时查询无需网络。

### 4.4 跨数据源搜索（未来扩展点，非 MVP/AI 阶段交付）

需求初稿中提到的最终目标：

```
GitHub Search + Starcat Local Index + AI Analysis
+ Trending + Show HN + AI Activity
```

这个阶段需要**统一搜索入口**（类似 Spotlight），一处输入同时搜索：
- 本地已 Star 仓库（FTS5）
- GitHub 全站（Search API）
- Trending 榜单
- AI 活动流

这不是 MVP 或 AI 第一版的范围，但设计时应预留扩展空间：
- `GitHubSearchViewModel` 的搜索接口设计为通用协议，未来可替换为聚合搜索
- 结果列表的 `RepoCardViewData` 已支持 `CardBadge`，未来各数据源 badge 可区分展示

---

## 5. 数据流总结

### 5.1 MVP 数据流

```
用户点击 toolbar SmartSearchField → 展开
  ↓
点击左侧模式图标 ▼ → 下拉菜单选择 "🌐 GitHub 搜索"
  ↓（mode 切换为 .github，边框变蓝）
用户输入搜索词 →
  ↓ SmartSearchField.onSubmit → HomeViewModel.submitSearch(query)
  ↓ HomeViewModel.reloadItems() 进入 isSearching 分支
  ↓ smartSearchMode == .github → GitHubSearchService.search(params)
  ↓
GitHubAPIClient.searchRepositories(params)   // 直连 GitHub REST API
  ↓
GitHub REST API GET /search/repositories
  ↓
JSON → GitHubSearchResponse (total + [GitHubSearchRepoDTO])
  ↓
.asCardData(starredRegistry) → [RepoCardViewData]
  ↓
HomeViewModel.items = cards → itemsRevision += 1
  ↓
UnifiedRepoRow × N（中间栏，复用现有列表渲染）
  ↓ (用户点击某行 → selectedRepoID = dto.ghRepoId)
  ↓
SearchScaffoldShell（右侧详情）
  ├─ 本地 DB 命中 → 完整三段详情（tags/notes/releases/readme）
  └─ 本地 DB 未命中 → Ephemeral 详情（基础信息 + README + ☆ star 按钮）

用户清空搜索框 / 切回 keyword 或 semantic 模式
  ↓
退出 GitHub 搜索 → 中间栏恢复原列表内容
```

### 5.2 AI 增强数据流（在 MVP 之上叠加）

```
用户点击 "AI 分析" 按钮（某张搜索卡片上）
  ↓
RepoAISearchAnalysisService.analyze(repo:)
  ↓ (并行)
├─ AI 摘要生成（prompt: description + topics → 一句话总结）
├─ AI 评分计算（stars / forks / 活跃度 / 文档质量 → 综合评分）
└─ AI 标签推荐（与现有 `RepoAIInsightViewModel.generate(includeTags:)` 复用）
  ↓
结果展示在卡片展开面板中
```

---

## 6. 关键设计决策

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| 1 | Search 入口位置 | 扩展现有 SmartSearchField，新增 `.github` 模式 | 侧边栏已满；SmartSearchField 已有 keyword/semantic 双模式，扩展比为第三种最自然 |
| 2 | 是否复用 HomeViewModel | 复用，GitHub 搜索结果写入 HomeViewModel.items | HomeViewModel 已有 isSearching / items / loadError 状态机，扩展 smartSearchMode 派发即可 |
| 3 | 卡片组件 | 复用 UnifiedRepoRow | 已支持多数据源适配（RepoCardViewData），无需新建 |
| 4 | 详情页方案 | 复用 RepoDetailScaffold + 新增 SearchScaffoldShell | 与 Trending 同构，共用骨架，scene-aware ContentView |
| 5 | 搜索结果缓存 | 不缓存，每次实时请求 | 保证时效性；搜索结果多为一次性访问，缓存价值低 |
| 6 | API 架构 | 客户端直连 GitHub REST API | MVP 不引入 Backend 中间层，复用现有 GitHubAPIClient + OAuth token |
| 7 | AI 触发时机 | 用户主动点击触发，不自动 | 避免 token 浪费，用户按需使用 |
| 8 | Ephemeral Repo | 未 star 的搜索结果用临时 Repo(id=0) 渲染详情，README 不落缓存 | 与 Trending 行为保持一致，不与已 star 仓库缓存混淆 |
| 9 | 搜索历史 | 不设条数上限，支持单条删除 + 一键清空 | 用户数据自主管理，不给用户设限 |

---

## 7. 需要新增/修改的文件清单

### 新建文件

```
Starcat/
├── Features/Search/
│   ├── GitHubSearchViewModel.swift     # 搜索状态管理
│   ├── GitHubSearchView.swift          # 搜索页主视图（中间栏）
│   ├── GitHubSearchFilterBar.swift     # 筛选器组件
│   ├── GitHubSearchDetailView.swift    # 搜索结果详情（右侧面板）
│   └── SearchScaffoldShell.swift       # 搜索场景详情壳（类比 TrendingScaffoldShell）
└── Shared/Models/
    └── GitHubSearchRepoDTO+CardData.swift  # DTO → RepoCardViewData 转换扩展
```

### 修改文件

```
Starcat/
├── Core/Settings/
│   └── AppSettings.swift               # SmartSearchMode 枚举新增 .github case + displayName/systemImage
├── Shared/Components/
│   └── SmartSearchField.swift          # 新增 .github 模式的视觉样式（蓝色边框 + 脉冲光晕）
├── Features/Home/
│   ├── RepoListView.swift              # toolbar 中 smartSearchField 显示条件调整；中间栏搜索模式覆盖逻辑
│   ├── HomeViewModel.swift             # smartSearchMode 派发新增 .github 分支；新增 isGitHubSearching；新增 GitHubSearchFilterState
│   ├── HomeView.swift                  # 注入 GitHubSearchService
│   └── RepoDetailView.swift            # 右侧新增 search 分支
├── Core/Network/GitHubAPI/
│   ├── GitHubAPIClientProtocol.swift    # 新增 searchRepositories 方法
│   └── GitHubDTOs.swift                # 新增 GitHubSearchRepoDTO + GitHubSearchResponse
├── App/
│   └── AppDependencies.swift           # 注入 GitHubSearchService
└── Resources/
    └── Localizable.xcstrings           # 新增搜索相关 i18n 键
```

---

## 8. UX 关键交互细节

### 8.1 搜索框行为
- 折叠态：toolbar 右侧显示当前模式图标（🌐 = GitHub 搜索模式），点击展开
- 展开态：左侧模式下拉菜单（🔍 全文 / ✨ 语义 / 🌐 GitHub），中间输入框，右侧清空按钮
- 模式切换为 `.github` → placeholder 变为"搜索 GitHub 全站仓库…"，边框切换为蓝色
- 输入中显示清除按钮（×）
- 搜索历史面板（仅在 `.github` 模式下显示）：
  - 每行左侧 globe icon + 搜索词，右侧删除按钮（×）
  - 面板底部"清空全部历史"按钮（仅当有历史时显示）
  - 行数不限，面板内 ScrollView 滚动
- 搜索中 → 搜索框右侧显示转圈 ProgressView
- 切回 `.keyword` / `.semantic` 或清空搜索框 → 退出 GitHub 搜索，中间栏恢复原页面

### 8.2 筛选器交互
- 任一筛选条件改变 → 自动重置分页并发起新搜索
- 筛选器行在有活跃筛选时高亮显示计数（如 "3 filters active"）
- 清除所有筛选按钮（仅在有活跃筛选时显示）

### 8.3 结果卡片与 Manage 的差异
- 搜索结果卡片左侧不显示多选 checkbox（Search 不支持批量操作）
- 卡片右上角显示 ⭐/☆ 快速 star/unstar 按钮（复用 `StarActionService.toggle`）
- Star 成功后卡片上星标图标实时更新

### 8.4 详情页行为
- Ephemeral repo star 成功后 → 详情页无缝升级为完整三段模式（`Repo.isStarred` 变为 true）
- 详情页 README 拉取失败 → 显示重试按钮 + 在 GitHub 打开链接
- 点击 "Open in GitHub" → 浏览器打开

### 8.5 键盘导航
- `Cmd+F`：聚焦 SmartSearchField（现有行为，所有模式通用）
- ↑↓：在搜索结果列表中移动高亮行
- Enter：选中高亮行 → 打开右侧详情
- Esc：清空搜索框，退出搜索模式 / 退出详情选中
- Tab：在筛选器之间切换焦点（仅在 GitHub 模式下筛选器可见时）

---

*文档版本：v3.0，2026-06-12*
*变更记录：v3.0：搜索入口改为扩展现有 SmartSearchField（新增 .github 模式），复用 HomeViewModel 状态机而非独立 ViewModel；v2.0：搜索入口从 Sidebar 改为 Toolbar；v1.1：API 直连、不缓存、历史不限条数*
