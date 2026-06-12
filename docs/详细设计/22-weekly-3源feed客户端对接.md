# Starcat 客户端「weekly 3 源 feed」对接方案

> **状态**: 设计中（2026-06-12，待 dong4j 拍板施工）
> **依赖**: 必须先有 [`21-weekly-api-3源feed改造.md`](./21-weekly-api-3源feed改造.md)（R-04 后端）落地上线
> **影响范围**: Starcat 客户端 — 网络层 / Activity-weekly 列表与详情页 / sidebar weekly 区
> **不影响**: GRDB schema（无新增表 / 列） / 持久化层 / Manage / Trending / Activity 其它分类
> **本文档不涉及**: 代码细节、文件清单、PR 切分 — 这些在施工阶段再补

---

## 0. TL;DR

后端 R-04 把阮一峰 + ZRead + Show HN 三源在 DB 层去重聚合到一张主表，对外只暴露 1 个聚合接口 `GET /api/v1/repos`。**客户端要做的事就两件**：

1. **把 weekly 分类的列表换成"3 源合并、按时间倒序、后端分页"的统一 feed**
2. **详情页加一条"来源时间线"chip 行，把这个 repo 在 3 个源被命中的所有事件全部按时间倒序铺出来**

> 列表和 sidebar 上**不**展示来源标识，不展示时间徽章 — 这两个决定已经在与 dong4j 的对话中拍板（`source_filter=no` / `row_time_chip=no`）。来源信息是详情页的事。

核心一句话：**客户端只展示和筛选，不参与去重 / 聚合 / 排序，所有这些在后端 SQL 内完成**。

---

## 1. 当前现状与痛点

### 1.1 weekly 分类的数据通路只有阮一峰一条

| 维度 | 现状 | 痛点 |
|---|---|---|
| 数据来源 | 客户端 `WeeklyAPI.fetchProjects` 只调 `/api/v1/weekly`（阮一峰）| ZRead 后端早已就绪（cron 每周一抓），但客户端**根本没对接**；Show HN AI Discovery 后端也已就绪，客户端**根本没看见** |
| 排序 | 客户端按 `firstIssue.number` 倒序 | 三源命中时间各不相同（阮一峰按期号、ZRead 按周、Show HN 按投稿时间），客户端无法统一比较 |
| 去重 | 客户端按 `WeeklyProject.id`（owner+name 派生）天然去重 | 三源各自的 (owner, name) 可能大小写不同 / repo rename 后断裂，单独客户端做去重不可靠 |
| 语言下拉 | 客户端硬编码 8 个语言选项 | 与实际数据脱钩 — 大量后端有数据的语言（Rust、Zig、Solidity 等）筛不到，硬编码里有的语言后端可能也没数据 |

### 1.2 详情页缺"来源时间线"概念

当前 weekly 详情页只显示阮一峰的 issue_number 和推荐语，**完全无法表达"这个 repo 还在 ZRead 上周排第 3、上上周排第 7、Show HN 上周也被投了 234 分"**。dong4j 在对话中明确「列表上不展示来源，详情页中标识数据来源」 — 详情页是来源信息**唯一**的展示位。

### 1.3 网络层缺"后端分页 + 增量加载"基础设施

现有 `WeeklyAPI.fetchProjects(page:pageSize:lang:sort:)` 已支持后端分页，但 `WeeklyContentView` 的 list 是一次性把所有页面平铺给 ForEach。`page` 状态被 ViewModel 持有但**滚动到底部触发下一页加载**没做。三源合并后总量可达数千条，客户端必须有真正的"懒加载"。

### 1.4 BackendAggregateRepoSource 也只接了阮一峰单源

`Core/Network/RepoSource/BackendAggregateRepoSource.swift` 当前调 `weeklyAPI.fetchProject(owner:repo:)`，是 R-01 v1.2 设计「未在本地 DB 命中时去后端聚合补齐 ephemeral repo」的入口。R-04 上线后，这个 source 应该改成调聚合接口而非阮一峰接口 — 但**这个升级路径在客户端层是"网络层换实现，调用方零改动"**，因为 `RepoResolverChain` 上层不感知具体源。

---

## 2. 设计思路

### 2.1 大原则

| 原则 | 说明 |
|---|---|
| **前端只展示和筛选** | 去重 / 聚合 / 时间归一 / 语言聚合 全部在后端 SQL 内完成；前端只做 UI 表达和交互筛选 |
| **API 命名空间收敛** | `WeeklyAPI` 三个 endpoint 全部废弃；新建一个聚合 API actor 调 `/api/v1/repos*`；客户端不再有"按源分散调用"的概念 |
| **沿用既有 4 详情页 Scaffold** | `RepoDetailScaffold` / `UnifiedRepoRow` 是 R-01 三场景共用骨架，weekly 详情页和 weekly 列表行**完全沿用**，不新建一套 |
| **持久化层不动** | weekly / zread / discovery 三源的 repo 不入本地 `repos` 表（除非用户主动 star），与"本地 stars 是用户私域"的产品定位一致 |

### 2.2 weekly 分类下的视图收敛

| 旧视图（即将删除）| 新视图 | 说明 |
|---|---|---|
| `WeeklyContentView`（按阮一峰期号倒序的 row 列表） | 同名复用 — 数据源换成 `/api/v1/repos`；列表行改 `UnifiedRepoRow` | 视觉与 trending 列表对齐 |
| `WeeklyDetailView`（阮一峰单源 hero + readme） | 同名复用 — hero 同 trending；新增"来源时间线"chip 行 | 详情页是来源信息**唯一**展示位 |
| Sidebar weekly 区的硬编码语言下拉 | 同位置 — 数据源换成 `/api/v1/repos/languages?source=weekly,zread,discovery`，与 trending 同款 | 与现有 `TrendingLanguageStore` 模式对齐（参考 [§3.9.7](../工程进度/功能实现总览.md#397-trending-sidebar-语言列表聚合改造2026-06-11-2000)）|

### 2.3 navigation 主键统一为 `gh_repo_id`

R-04 主表 PK 是 `gh_repo_id (Int64)`。客户端把 weekly 路径下所有 row diffing / List selection / 详情页 navigation key **统一切到 gh_repo_id**，与 trending 详情页 R-01 v1.2 的设计完全一致。`WeeklyProject.id`（owner+name 派生 String）退场。

### 2.4 不引入新本地缓存层

后端会做内存 cache + 短期 TTL（详见 R-04 §6 注脚），客户端**不再加自己的一层缓存**：

- 列表数据：每次切语言 / 下拉刷新都直拉后端
- 详情数据：每次进详情页都直拉 `/api/v1/repos/{owner}/{repo}`
- 语言聚合：启动期拉一次，切 trending↔weekly 时不重拉（后端口径稳定）

> 唯一的客户端缓存是 SwiftUI 的 `@State` / `@Observable` 跨视图持有 — 这是行为缓存而非数据缓存。

---

## 3. 数据对接（核心）

### 3.1 三个端点的客户端语义

| 后端端点（R-04） | 客户端调用场景 | 频次 |
|---|---|---|
| `GET /api/v1/repos` | weekly 列表加载 / 切语言 / 下拉刷新 / 滚到底翻页 | 高（每页 30 条，懒加载触发）|
| `GET /api/v1/repos/{owner}/{repo}` | 详情页打开 | 中（点一次进一次）|
| `GET /api/v1/repos/languages` | sidebar weekly 区语言下拉首次加载 + 后端 URL/Key 切换时刷新 | 低（启动一次 + 偶尔切配置）|

### 3.2 列表接口字段映射

| 后端字段（R-04 响应 `data[i]`）| 客户端用途 | 映射目标 |
|---|---|---|
| `gh_repo_id` (Int64) | row diffing 主键 / 详情页 navigation key | UI 模型主键，**唯一信任源** |
| `owner` / `name` / `full_name` | hero 显示 / 详情页 navigate / 跳 GitHub 链接 | 直接透传 |
| `description` | row 副标题 + 详情页 hero | 直接透传 |
| `stars` / `forks` / `watchers` / `open_issues` | row 角标 + 详情页 hero stat 区 | 直接透传，**不再调 GitHub /repos** |
| `language` | row 角标 + sidebar 语言筛选关联 | 直接透传 |
| `license_spdx` / `topics` / `pushed_at` / `created_at` / `updated_at` | 详情页 hero 元信息 | 直接透传 |
| `is_archived` / `is_fork` / `is_private` | row 状态徽章（archived 灰、fork 派生）| 直接透传 |
| `owner_avatar` / `default_branch` | row 头像 + README WebView 渲染 base 地址 | 直接透传 |
| `source_types: ["weekly","zread","discovery"]` | **关键** — 详情页"来源时间线"chip 行的总开关 | 列表上**不消费**（拍板「不展示来源 chip」）；详情页消费 |
| `first_seen_at` / `last_seen_at` | 列表默认排序键 / 详情页 hero 副信息 | 用于 row sort 派生（默认 first_seen_at desc）|
| `weekly: { issue_number, recommendation, ... }` | 详情页"代表数据"展示（首次收录的期号 + 推荐语）| 详情页消费一次 |
| `zread: { week_label, week_start, rank_in_week, description_zh }` | 详情页"代表数据"展示（最新一周 + 中文描述）| 详情页消费一次 |
| `discovery: { category, submission: { hn_id, title, score, ... } }` | 详情页"代表数据"展示（分类 + 最新投稿）| 详情页消费一次 |

> **关键约定**：客户端**不**用 `weekly` / `zread` / `discovery` 这三个内嵌对象判断"该 repo 是否在该源被命中过" — 必须看 `source_types` 数组。三个内嵌对象只是"代表数据"快照，完整时间线走详情接口。

### 3.3 详情接口的"事件时间线"

后端 `GET /api/v1/repos/{owner}/{repo}` 返回 `data.repo`（同 3.2 单条）+ `data.events[]`（按 occurred_at 倒序）。客户端只需消费 events 数组渲染"来源时间线"chip 行：

| events 中的 source | 客户端渲染样式 | 点击行为 |
|---|---|---|
| `weekly` | 紫色 chip — `阮一峰周刊 · 第 342 期 · 2026-04-15` | 点击跳期号原文 markdown 页面（`weekly.issue_url`）|
| `zread` | 蓝色 chip — `ZRead · 2026-06-08 周第 6 名` | 点击跳 zread.ai 对应 repo 页面 |
| `discovery` | 橙色 chip — `Show HN · 234 分 · 2026-05-25` | 点击跳 HN 投稿页面 (`discovery.submission.hn_url`) |

时间归一精度后端会保留（weekly 日级 / zread 周级 00:00:00Z / discovery 秒级），chip 显示用客户端 i18n 相对时间（"4 天前"）+ tooltip 显示 ISO 时间，与 release timeline 现有规范对齐。

### 3.4 语言聚合接口的客户端用法

后端 `GET /api/v1/repos/languages?source=weekly,zread,discovery` 返回 `data: [{key, label, count}]`，客户端：

1. **启动期**预拉一次（参考现有 `TrendingLanguageStore` 模式）
2. **后端 URL / Key 切换时**重拉一次
3. sidebar weekly 区下拉**完全切到这份数据**，不再用本地硬编码列表
4. 哨兵 `__uncategorized__` 与 trending 同款语义（双下划线避命名冲突）；"未分类"标签复用 `trending.language.uncategorized` i18n key
5. 切换 lang 时列表请求带 `?lang=` 透传，后端用 `language IS NULL OR language = ''` 处理哨兵

### 3.5 列表分页与懒加载

| 状态 | 客户端动作 |
|---|---|
| 进入 weekly 分类 | 请求 `?page=1&page_size=30&sort=first_seen_at&order=desc`，展示首屏 |
| 滚动到列表底部触发器（最后 5 行进入可视区）| 自增 page，请求下一页，append 到列表 |
| 切换 lang | 重置 page=1，列表清空，重新请求 |
| 下拉刷新 | 同上（视为新查询）|
| 切走 weekly 分类 | 状态保留在 ViewModel，下次回来不重拉（与 trending 同款行为）|

`meta.next_page` 决定还有没有下一页：null 时停止懒加载（List footer 显示"已到底"）。

### 3.6 navigation：列表 → 详情的参数透传

点击 row → 详情页打开时，客户端**不**把整个列表条目推到详情页 — 只传 `gh_repo_id` + `owner` + `name`，详情页内部 `.task(id: gh_repo_id)` 调 `GET /api/v1/repos/{owner}/{repo}` 拉完整详情。

> 这与 trending 详情页 `TrendingScaffoldShell` 设计一致：列表 row 持有的是"足够快速渲染列表"的字段集，详情页持有的是"足够渲染 hero + 时间线"的完整字段集，**两者用单独的网络请求填充**，避免 row 数据膨胀。
> 列表请求**已经返回完整字段**（详见 3.2 表，包含 R-05 同款 10 个详情字段），所以详情页打开时第一帧用列表透传字段渲染 hero（无白屏），第二帧 events 数组到位后补"来源时间线"chip 行。

### 3.7 错误处理矩阵

| 场景 | 客户端动作 |
|---|---|
| 列表 200 + data 空 | 列表显示「该语言下暂无 repo」空态（与 trending 同款）|
| 列表 401 | 全局认证失败提示（与现有 4 后端 401 处理对齐 — 设置页 API Key 错）|
| 列表 5xx / 网络错 | row 列表保持上次结果不动 + 顶部 toast 提示（与 trending 同款）|
| 详情 404（主表无该 repo）| 详情页显示「该 repo 不在 weekly 索引中」空态 + 一个"在 GitHub 打开"按钮 |
| 详情 401 / 5xx | 同列表 |
| 语言聚合失败 | sidebar 退化到 fallback 列表（仿 `TrendingLanguageStore.fallbackList`），不阻塞列表加载 |

---


## 4. 与既有架构的衔接

### 4.1 R-01 三场景共用骨架完全沿用

R-01 v1.2 设计的「Manage / Trending / Weekly / Activity 4 详情页共用 `RepoDetailScaffold` + `UnifiedRepoRow`」契约**完全沿用**：

| 已有共用组件 | weekly 3 源对接后变化 |
|---|---|
| `UnifiedRepoRow` | 数据源换成 `/api/v1/repos`，行为不变 |
| `RepoDetailScaffold` | hero / readme / 三段（Tags/Notes/Releases）行为不变；新增"来源时间线"插槽 |
| `RepoLocalSections` | `repo.id != 0 && isStarred` 守卫不变 — 三源命中但用户未 star 时三段自动隐藏（与 trending 详情同款）|
| `WeeklyDetailScaffoldShell` | shell 模式不变（D-28 v3 已对齐 trending）；内部解析层 `loadAll` 路径换成调聚合详情接口 |
| `StarActionService.toggle` | star 写入路径不变 — 用户在 weekly 详情页 star 时仍走 GitHub API + 本地 DB upsert |
| `StarredRegistry` | "是否已 star"单一信任源不变 — weekly 列表行 ✓ 标记沿用 R-01 v1.8 决策（"列表 row 显 ✓"由 trending / weekly 两场景显式开启）|

### 4.2 BackendAggregateRepoSource 升级

R-01 v1.2 设计的 `BackendAggregateRepoSource`（`RepoResolverChain` 中本地 DB 未命中的兜底源）**调用方零改动**，只把内部实现从 `weeklyAPI.fetchProject(owner:repo:)` 切到 `repoFeedAPI.fetchDetail(owner:repo:)`。任何场景（trending / weekly / activity / manage）下未本地命中且要拉详情时，都能从聚合接口拿到 ephemeral repo 兜底。

> 升级后这条路径覆盖更广 — 一个 trending 上首次命中的 repo（曾被 ZRead 收录但还没本地 star），从前必须调 GitHub `/repos` 兜底，**升级后可直接从 weekly-api 主表命中**，省一次 GitHub 配额。

### 4.3 ephemeral repo 不入本地 DB

weekly / zread / discovery 命中的 repo 不入本地 `repos` 表 — 与 trending row 的 ephemeral 设计完全一致：

| 状态 | 客户端行为 |
|---|---|
| 用户进 weekly 详情页（未 star）| 走 ephemeral repo（`id=0`），三段隐藏，hero 来自接口字段 |
| 用户在详情页点 star | 走 `StarActionService.toggle` → GitHub PUT + 本地 DB upsert → 本地命中后 `id` 切到真实值，三段展开 |
| 用户切走又切回 | 走 R-01 v2.0 设计：本地命中优先（已 star 的拿真值）/ 未命中拿接口字段（ephemeral）|

### 4.4 详情页时间线与 Wiki Menu 共存

详情页右上角已有 `RepoWikiMenu`（DeepWiki / Zread / Code Wiki 三个外部文档源）— 那是**文档**入口，与"来源时间线"是**索引来源**完全不同的语义。两者位置错开：

```
┌─────────────────── 详情页 hero ───────────────────┐
│  Avatar  owner/repo                       Wiki ▼  │
│          描述行                                    │
│  ★ 12k   ⑂ 234   👁 89    Python  MIT             │
│  ──── 来源时间线 ────────────────────────         │
│  [紫] 阮一峰 · 第 342 期 · 4 天前                 │
│  [蓝] ZRead · 2026-06-08 周第 6 名 · 6 天前       │
│  [蓝] ZRead · 2026-05-25 周第 7 名 · 19 天前      │
│  [橙] Show HN · 234 分 · 21 天前                  │
└────────────────────────────────────────────────────┘
```

时间线插槽位置在 hero 元信息行下方、三段 / readme 之上，与 `RepoMetadataHeaderView` 的 `actions` 插槽是不同的视觉区段。

---

## 5. UI 形态收敛

### 5.1 列表行（cards）

| UI 元素 | 决策 | 备注 |
|---|---|---|
| 默认排序 | `first_seen_at desc`（最近发现）| dong4j 拍板「按时间倒序」+ 后端默认值与之对齐 |
| 来源 chip（左上 / 右上）| **不展示** | dong4j 拍板「列表保持时间倒序，详情页才标识来源」|
| 时间徽章 | **不展示** | 与 D-28（删除 `RelativeDateBadge`）决策一致 |
| ✓ 已 star 标记 | 展示（与 trending 同款）| 沿用 R-01 v1.8：trending / weekly 显式开 `showStarredCheckmark: true` |
| stars / forks / language 角标 | 展示（与 trending row 视觉一致）| 数据直接从聚合接口字段填充 |

### 5.2 详情页

| UI 区域 | 内容来源 | 备注 |
|---|---|---|
| Hero（上半部分基础信息）| 列表透传 + 详情接口字段补全 | 与 trending 详情页同款"轻轻落下"动画（D-28 v3 共享 modifier）|
| 来源时间线 chip 行 | 详情接口 `events[]` | **新增插槽**，渲染规则见 §3.3 |
| 三段（Tags / Notes / Releases）| 本地 DB（`isStarred && id != 0` 守卫）| R-01 v1.4 决策保留 |
| Trailing actions（Wiki / Share / AI）| 本地 / 三方服务 | 与 trending 详情同款，行为不变 |
| README WebView | 详情接口 `default_branch` + `owner_avatar` 渲染 base | R-01 README 路径不变 |

### 5.3 Sidebar weekly 区

| UI 元素 | 决策 |
|---|---|
| weekly 分类总入口 | 保留，名字不动（仍叫"周刊" / "Weekly"）|
| 顶部语言下拉 | 数据源切到 `/api/v1/repos/languages?source=weekly,zread,discovery`，每行带 count（同 trending 同款）|
| 来源选择器（"只看阮一峰" / "只看 ZRead" / "只看 Show HN"）| **不做** | dong4j 拍板「全部塞到周刊分类下」/ 不做 source filter |
| sidebar 头像背景色 | 跟随当前选中 project 的 `language` 色（D-29 已修过 weekly 的语言色联动）| 实现路径不变 |

---

## 6. 风险与未决项

### 6.1 已识别风险

1. **ephemeral repo `id=0` 与本地表的兼容**
   未 star 的三源 repo 走 `id=0` 模式（与 trending 一致），所有依赖 `repo.id != 0` 的守卫（`RepoLocalSections.isVisible` / `trailingActions` 中的 share / ai / translation 显隐）已经在 R-01 v1.4 中收口，weekly 路径下完全沿用，无新风险。

2. **同一 repo 同时在 trending 和 weekly 列表 — 行为是否一致**
   场景：A repo 在 trending 列表（`/api/v1/repos` trending-api）和 weekly 列表（`/api/v1/repos` weekly-api）都出现。两个列表的 row 数据来源是**两套后端服务**（独立 DB），客户端做 navigation 时分别走各自的详情接口。这不是 bug — 是两个独立产品入口（`Sidebar.trending` vs `Sidebar.activity.weekly`）共享同一个 GitHub repo，详情数据不互通。沿用 R-01 v1.2 既有行为。

3. **大列表的 row diffing 性能**
   三源合并后 weekly 总量预估首批 3000+ 条（阮一峰 3077 已存量 + zread 历史 + discovery）。客户端用 `gh_repo_id (Int64)` 作 row diffing 主键 — 与 trending row 的实测数据（最高 800+ 条无卡顿）对齐，3000+ 的体感取决于 ForEach + LazyVStack 的回收复用，按经验**每次只渲染可视区 30~50 行**，性能可控。

4. **discovery `pending` repo 的可见性**
   后端默认只返回 `classified` 状态的 discovery repo（详见 R-04 §6.1 / §9.2 Q4），未配置 `LLM_API_KEY` 时 weekly 列表会少一批；客户端可在设置页加一个"显示未分类的 Show HN 投稿"开关（带 `?include_pending=true` 给后端），首期不做（与 R-04 默认行为一致）。

### 6.2 未决项（请 dong4j 拍板）

| ID | 议题 | 倾向方案 |
|---|---|---|
| **C1** | 列表 page_size | 30（与 trending 一致）；首期不暴露给用户配置 |
| **C2** | 时间线 chip 是否带跳转链接 | 是（详见 §3.3）— 用户研究价值高，链接 URL 后端已经返了 |
| **C3** | 详情页"来源时间线"chip 行是否独立 i18n 键 | 是 — `weekly.detail.timeline.{source}` 三个 key + 复用现有 `relative_time` 格式 |
| **C4** | 详情页 hero 副信息行展示哪个时间字段 | `pushed_at`（与 trending 同款"最近活跃"语义），不要展示 `first_seen_at`（运营时间，对用户无意义）|
| **C5** | sidebar weekly 区是否加 `featured` 入口（精选）| 不做 — 三源已经合并按时间倒序，"精选"维度后端没设计这个字段 |
| **C6** | 列表底部"已到底"提示是否做 | 是 — `meta.next_page == null` 时显示"已到底" footer，视觉与 trending 同款 |

> 与 R-04 后端方案的 6 项未决项（Q1~Q6）一起拍板更高效。

---

## 7. 与 R-04 后端方案的衔接

### 7.1 落地顺序

| 阶段 | 工作内容 | 谁干 |
|---|---|---|
| 阶段 0 | R-04 PR-1 ~ PR-7（后端 schema → enricher → spider → handler）| 后端 |
| 阶段 1 | R-04 PR-7 后端 e2e 验证（curl 三源端到端）| 后端 |
| 阶段 2 | R-04 PR-8 后端 v1.0.0 文档 + CHANGELOG | 后端 |
| **阶段 3** | **本方案落地** — 客户端网络层 + 列表 + 详情 + sidebar | **客户端** |
| 阶段 4 | 真机 / TestFlight 跑一遍三源数据展示，dong4j 验收 | 客户端 + dong4j |
| 阶段 5 | 删除 `WeeklyAPI` / `WeeklyModels` 与 `BackendAggregateRepoSource` 的旧调用方残骸 | 客户端 |

> 阶段 5 是收尾清理 — 项目未上线，不留向后兼容代码。

### 7.2 不做"灰度"

dong4j 在 R-04 已明确「项目未上线，不做兼容」。客户端方案与之对齐：

- `WeeklyAPI` 与新 API 不并存 — 一刀切
- 不做"按 feature flag 切流量"
- 不做"老接口降级兜底"

### 7.3 阶段 3 客户端工作的粗粒度划分（不细化为 PR）

| 工作块 | 粗时间 |
|---|---|
| 网络层（actor + DTO + envelope 解码 + 错误映射）| ~0.8 天 |
| 列表 ViewModel 改造（懒加载分页、切语言重置、下拉刷新）| ~0.5 天 |
| 列表视图（沿用 `UnifiedRepoRow`，更换数据源）| ~0.3 天 |
| 详情 ViewModel 改造（详情接口 + events 时间线）| ~0.5 天 |
| 详情视图（hero 沿用 / 时间线 chip 行新建 / 三段沿用）| ~0.5 天 |
| Sidebar 语言下拉对接（仿 `TrendingLanguageStore`）| ~0.3 天 |
| `BackendAggregateRepoSource` 升级 | ~0.2 天 |
| i18n（来源 chip 文案 + 时间线行文案 + 空态文案）| ~0.2 天 |
| 单测（仿 `TrendingTests` / `WeeklyDTOTests` envelope wire 模式）| ~0.5 天 |
| 旧代码清理（`WeeklyAPI` / `WeeklyModels` / 阮一峰单源残骸）| ~0.2 天 |
| **合计**（粗估）| **~4 天** |

> 这是粗估，不是 PR 拆分；具体施工时按情况自由切分。

---

## 8. 文档关联

- **本文档** = 客户端「weekly 3 源 feed」对接方案
- 后端方案 = [`docs/详细设计/21-weekly-api-3源feed改造.md`](./21-weekly-api-3源feed改造.md)（R-04）
- 三场景共用骨架 = [`docs/详细设计/18-三场景共用架构.md`](./18-三场景共用架构.md)（R-01 v1.2 / v1.7 / v2.0 / v2.1 / D-28 v3）
- README 翻译共用路径 = [`docs/详细设计/14-AI集成落地记录.md`](./14-AI集成落地记录.md)
- Wiki menu 协同 = [`docs/详细设计/20-wiki-api-对接.md`](./20-wiki-api-对接.md)
- trending 同款语言聚合 = `功能实现总览.md` §3.9.7

---

## 9. 总结

> **客户端在这个方案中是"显示器"和"筛选器"，所有重活儿（去重、聚合、时间归一、语言聚合）在后端 R-04 完成。客户端的对接复杂度集中在"分页懒加载 + 详情页时间线渲染"两个新事，其余全部沿用 R-01 既有架构。**

如果 dong4j 拍板 C1~C6 的倾向方案，本方案与 R-04 后端方案配合，可在阶段 3 ~4 天内交付端到端可用版本。

