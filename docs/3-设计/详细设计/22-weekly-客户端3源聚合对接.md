# Starcat 客户端 weekly 3 源聚合对接方案（R-05）

> **状态**：关键契约已拍板（2026-06-12，待 R-04 后端接口稳定后施工）
> **依赖**：[`21-weekly-api-后端3源聚合改造.md`](./21-weekly-api-后端3源聚合改造.md)
> **影响范围**：客户端网络层、Activity / Weekly 列表、详情页、Weekly 语言筛选
> **不影响**：客户端 GRDB schema、Manage、Trending、Activity 其它分类
> **兼容策略**：项目未上线，直接替换旧 Weekly 接口，不保留双栈

---

## 0. 结论

R-04 后端把阮一峰周刊、ZRead 周趋势、Show HN 三源聚合成统一 repo feed。客户端不再理解三套数据源，只消费：

```text
GET /api/v1/repos
GET /api/v1/repos/{gh_repo_id}
GET /api/v1/repos/languages
```

客户端改造目标：

1. Weekly 列表展示三源去重后的统一 feed；
2. 保留当前已经实现的分页、加载更多、防旧请求回写和列表动画机制；
3. 点击列表项时立即使用列表 DTO 的 `gh_repo_id` 和完整 Repo Card 构造首帧 `Repo`，不等待详情网络请求；
4. 后台按 `gh_repo_id` 拉取详情，补齐完整 Repo Card 更新；来源只在 `full_name` 同行显示来源图标 + 短时间/期号标签；
5. 继续沿用 `UnifiedRepoRow`、`RepoDetailScaffold`、`WeeklyDetailScaffoldShell` 和 `StarActionService`；
6. 公共发现数据仍不写入客户端 SQLite，只有用户主动 Star 后才进入本地私有数据体系。

列表和详情页都展示同款轻量来源标识：repo name / full_name 右侧显示来源小圆图标 + 短标签，不单独占据详情页纵向空间。

---

## 1. 最新客户端现状

### 1.1 Weekly 列表已经具备分页能力

当前 `WeeklyContentViewModel` 已实现：

- `page / total / hasMore` 状态；
- `loadMoreIfNeeded()` 追加下一页；
- 接近列表底部时自动加载；
- `generation` 丢弃筛选切换前的旧请求；
- 分页追加时按 item ID 去重；
- `itemsRevision` 控制列表入场动画是否重播。

R-05 不重做分页框架，只把旧 `WeeklyAPI.fetchProjects` 和旧模型替换为聚合接口及聚合模型。

### 1.2 Weekly 详情采用 Shell 重建模式

当前详情链路为：

```text
WeeklyDetailView
  -> WeeklyDetailScaffoldShell
  -> RepoDetailScaffold
  -> WeeklyDetailContent
```

`WeeklyDetailView` 通过 `.id(project.id)` 重建 Shell，并使用 `.detailContentTransition()` 实现与 Trending 同款的 hero 入场动画。R-05 必须保留这套结构。

### 1.3 当前 DTO 已支持真实 GitHub ID，但 Weekly Shell 仍需改造

当前 `StarcatRepoCardDTO.toEphemeralRepo()` 已经会把 `gh_repo_id` 写入 `Repo.id`。目标态下，未 Star 的公共 repo 必须是：

```text
Repo.id        = gh_repo_id
Repo.isStarred = false
```

Tags / Notes / Releases、Share、AI 等私有功能通过 `repo.isStarred` 控制，而不是通过 `repo.id != 0` 判断。

但当前 `WeeklyDetailScaffoldShell.makeFallbackRepo(from:)` 仍构造 `id=0` fallback，并在本地未命中后直调 GitHub `/repos/{owner}/{repo}`。R-05 必须删除这条 Weekly 专用 fallback 语义，改为用 `WeeklyFeedItem.card.toEphemeralRepo()` 构造首帧 `Repo`。项目未上线，不保留 `id=0` Weekly 兼容路径。

### 1.4 当前 Weekly Shell 未使用 RepoResolver

当前 `WeeklyDetailScaffoldShell.resolveRepo` 的实际顺序是：

1. 按 `gh_repo_id` 或 owner/name 查本地 repo；
2. 未命中时直接调用 GitHub `/repos/{owner}/{repo}` 做 silent upgrade。

R-05 将第二步替换为聚合详情接口，但不强制把 Weekly Shell 改造成 `RepoResolver` 调用方。`BackendAggregateRepoSource` 仍需要同步升级，供其他真正使用 `RepoResolver` 的路径复用。

---

## 2. 设计原则

| 原则 | 说明 |
|---|---|
| 后端负责聚合 | 去重、来源集合、`latest_event_at`、排序和语言统计全部由后端完成 |
| `gh_repo_id` 统一身份 | 列表 identity、selection、Shell `.id`、详情请求全部使用 Int64 ID |
| 列表 DTO 负责首帧 | 点击 row 后立即用列表 DTO 构造 Repo 和 hero，不等待详情请求 |
| 详情请求只做增量补全 | 拉最新 Repo Card，到达后替换公共字段；来源标识沿用列表项的 source snapshot |
| 私有数据边界不变 | 公共 repo 不落客户端 DB；Star 后由现有写路径入库 |
| 保留现有 UI 骨架 | 不新建另一套列表行、详情页或分页状态机 |
| 配置热更新不变 | 新 API actor 沿用现有 baseURL / API Key 动态更新机制 |

---

## 3. 网络层设计

### 3.1 聚合 API Actor

新增一个职责明确的聚合 API actor，替换 Weekly 列表和详情请求。命名建议 `WeeklyFeedAPI`，避免使用过于宽泛的 `RepoAPI` 与 GitHub Repo API 混淆。

它沿用 `WeeklyAPI` 当前已经验证的模式：

- actor 隔离；
- 注入 `URLSession`，便于 `URLProtocolStub` 测试；
- baseURL 和 API Key 可热更新；
- Bearer 鉴权；
- `StarcatEnvelope` 解码；
- 非 2xx 优先解码 `StarcatErrorEnvelope`；
- 记录不支持的 `schema_version` warning。

公开方法语义：

```swift
func fetchRepos(query: WeeklyFeedQuery) async throws -> WeeklyFeedPage
func fetchDetail(repoID: Int64) async throws -> WeeklyRepoDetail
func fetchLanguages() async throws -> [AggregatedLanguage]
```

### 3.2 列表查询模型

```swift
struct WeeklyFeedQuery: Equatable, Sendable {
    let language: String?
    let sort: WeeklyFeedSort
    let order: SortOrder
    let page: Int
    let pageSize: Int
}

enum WeeklyFeedSort: String, Sendable {
    case latestEventAt = "latest_event_at"
    case stars
    case pushedAt = "pushed_at"
}
```

客户端 Weekly 页面不暴露 source filter。请求固定覆盖三源，不需要显式发送 `source=weekly,zread,discovery`；不传 `source` 即表示全部来源。

默认请求：

```text
?page=1&page_size=30&sort=latest_event_at&order=desc
```

### 3.3 DTO 分层

不要继续把三源聚合结果硬塞进旧 `WeeklyProject`。新模型应反映真实语义：它是 Weekly 分类下的统一发现 repo，而不是“阮一峰项目”。

建议分为三层：

```text
WeeklyFeedRepoDTO       网络列表单项
WeeklyRepoDetailDTO     网络详情响应：repo + events
WeeklyFeedItem          UI 领域模型，列表与 selection 共用
```

`WeeklyFeedItem` 至少保留：

- `ghRepoId`；
- 完整 Repo Card 字段；
- `sourceTypes`；
- `firstEventAt / latestEventAt`；
- weekly / zread / discovery 代表数据快照。

`Identifiable.id` 直接返回 `ghRepoId`：

```swift
var id: Int64 { ghRepoId }
```

### 3.4 统一 Repo Card DTO 的处理

现有 `StarcatRepoCardDTO` 已覆盖主要 GitHub 字段，并能转换为真实 ID 的 ephemeral `Repo`。R-05 有两种实现选择：

1. 扩展现有 DTO，加入 `source_types`、事件时间和三源扩展；
2. 新建 `WeeklyFeedRepoDTO`，内部组合一个共享 Repo Card DTO 与 Weekly feed 字段。

采用第二种：

```swift
struct WeeklyFeedRepoDTO: Decodable, Sendable, Equatable {
    let card: StarcatRepoCardDTO
    let sourceTypes: [WeeklySource]
    let firstEventAt: String
    let latestEventAt: String
    let weekly: WeeklySnapshot?
    let zread: ZreadSnapshot?
    let discovery: DiscoverySnapshot?
}
```

后端 wire JSON 固定为扁平对象，不嵌套 `card`。`WeeklyFeedRepoDTO` 自定义 `init(from:)`，从同一个 container 解码出 `StarcatRepoCardDTO + feed fields`。这样 `StarcatRepoCardDTO` 继续保持“通用 Repo Card”语义，三源聚合字段只存在于 Weekly feed DTO，不污染 trending-api。

### 3.5 事件 DTO

```swift
struct WeeklySourceEvent: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let source: WeeklySource
    let occurredAt: String
    let url: URL?
    let weekly: WeeklyEventPayload?
    let zread: ZreadEventPayload?
    let discovery: DiscoveryEventPayload?
}

enum WeeklySource: Decodable, Sendable, Equatable {
    case weekly
    case zread
    case discovery
    case unknown(String)
}
```

`WeeklySource` 必须自定义 `init(from:)`：已知值解为 `.weekly/.zread/.discovery`，未知字符串解为 `.unknown(rawValue)`。这样后端以后新增来源时，旧客户端仍能展示中性来源 badge，不会因为一个未知 source 让整个详情解码失败。

后端负责事件排序，客户端保持响应顺序，不二次排序。客户端展示“最近更新”时直接使用后端 `latest_event_at`，不得从 `events[]` 或三源快照自行推导。

---

## 4. 列表对接

### 4.1 ViewModel 保留现有状态机

当前 `WeeklyContentViewModel` 的以下逻辑继续保留：

- 首次进入时仅在 items 为空时加载；
- reload 从 page 1 开始；
- load more 追加数据；
- generation 防止旧请求覆盖新筛选；
- 分页失败保留已有 items；
- `itemsRevision` 只在整批替换时递增；
- `selectionService.applyTotal` 同步 sidebar 数量。

需要替换的部分：

- `WeeklyProject` → `WeeklyFeedItem`；
- `WeeklySort.firstIssueDesc` → `WeeklyFeedSort.latestEventAt`；
- `WeeklyIssueFilter` 删除；
- 旧 `fetchProjects` → 新 `fetchRepos`；
- 追加去重键改成 `ghRepoId`。

### 4.2 语言筛选

删除 `WeeklyContentViewModel.languageOptions` 硬编码数组，改为聚合语言 Store。

行为：

1. 首次进入 Weekly 时懒加载语言列表；
2. 后端 URL 或 API Key 更新时清空并重拉；
3. 失败时使用精简 fallback：全部、未分类和少量常见语言；
4. `__uncategorized__` 复用现有 Trending 语言哨兵语义；
5. 当前选中语言在新响应中不存在时回退到全部，并触发列表 reload。

不要求 App 启动时预拉 Weekly 语言。当前架构更适合按功能首次进入懒加载，避免给启动 bootstrap 增加无必要网络请求。

### 4.3 列表展示

继续使用 `UnifiedRepoRow`：

- 显示头像、full name、description、stars、forks、language；
- 继续显示已 Star 的 ✓；
- repo name 右侧显示来源小圆图标 + 短标签；
- 不单独显示 `latest_event_at` 时间徽章；
- 不使用 weekly issue 作为所有 row 的默认 badge，因为 zread/discovery-only repo 没有期号。

短标签规则：weekly 显示期号、ZRead 显示 week label、Hacker News 显示 `M.d`。

### 4.4 分页触发

沿用当前接近底部触发策略即可，不重新设计为新的 ScrollView sentinel。是否使用倒数第 3 行还是第 5 行属于实现时的体验微调，不是接口契约。

`meta.next_page` 是 `hasMore` 的唯一真源。项目未上线，R-05 不兼容旧 fixture；后端未返回 `next_page` 视为接口错误并进入列表错误处理。

### 4.5 刷新失败语义

| 场景 | 行为 |
|---|---|
| 首次加载失败 | 显示错误空态和重试按钮 |
| 手动刷新失败且已有列表 | 保留旧列表，显示非阻塞错误提示 |
| 加载下一页失败 | 保留已加载页，允许用户显式重试，不把 `hasMore` 永久置 false |
| 筛选切换失败 | 当前查询显示错误状态；旧 generation 响应仍丢弃 |

当前代码在分页失败时直接把 `hasMore = false`，刷新失败时会清空 `items`。R-05 必须改为“保留旧列表 + 记录可重试错误”：首次加载失败才显示错误空态；已有列表时不清空 `items`，分页失败也不永久关闭后续加载。

---

## 5. Selection 与导航

### 5.1 选择模型

`WeeklySelectionService` 的选中对象切换为 `WeeklyFeedItem?`。列表 row、详情 Shell 和 sidebar 颜色都从同一对象读取。

主键统一：

```text
row identity        = gh_repo_id
selected item id    = gh_repo_id
WeeklyDetailView id = gh_repo_id
detail task id      = gh_repo_id
```

### 5.2 必须透传完整列表项

点击 row 时传递完整 `WeeklyFeedItem`，而不是只传 `gh_repo_id + owner + name`。

原因：

1. 列表响应已经包含完整 Repo Card 字段；
2. Shell 必须在网络请求前同步构造 hero，保持 D-27 的“同步先行”；
3. 只传 ID 无法渲染首帧；
4. 详情请求应该是增量补全，而不是首帧依赖。

`WeeklyProject.id = fullName`、`selectedProject?.id == project.id`、分页去重按 fullName、Shell `.id(project.id)` 这几处旧 identity 一次性删除。R-05 不保留 owner/name identity 的过渡逻辑。

---

## 6. 详情页对接

### 6.1 保留 Shell 架构

```swift
WeeklyDetailView(item: selectedItem)
    -> WeeklyDetailScaffoldShell(item: item)
        .id(item.ghRepoId)
        .detailContentTransition()
```

Shell 内继续持有：

- `displayRepo`；
- `readmeVM`；
- `detailLoadState`。

### 6.2 `loadAll` 顺序

```text
同步阶段（任何 await 之前）
1. 用 WeeklyFeedItem.card.toEphemeralRepo() 构造 displayRepo，`Repo.id = gh_repo_id`
2. 用 StarredRegistry / 本地查询结果修正 isStarred
3. 立即启动 README 加载

异步阶段
4. 优先按 gh_repo_id 查询本地 Repo
5. 本地命中：用本地 Repo 替换 displayRepo，保留私有状态真值
6. 调 GET /api/v1/repos/{gh_repo_id}
7. 更新公共 Repo 字段，但不能覆盖本地 isStarred 真值
```

详情请求失败时保留列表首帧和 README，不把整个详情页切为空态。
如果详情响应 `repo.is_available == false`，仍按正常详情渲染历史来源标识，并在 hero 附近显示“仓库当前不可用”的非阻塞提示；这不是 404 错误。

### 6.3 公共字段与私有字段合并

详情接口返回的 Repo Card 不知道当前用户是否已 Star。合并规则：

| 字段 | 真源 |
|---|---|
| owner/name/description/stats/topics/license/dates | 详情接口最新值 |
| `isAvailable` | 详情接口 |
| `id` | `gh_repo_id` |
| `isStarred` | 本地 Repo 或 `StarredRegistry` |
| tags/notes/releases | 客户端本地 DB |
| 来源图标与短标签 | 列表项 `source_types` + 三源 snapshot |

禁止直接用 `detail.card.toEphemeralRepo()` 覆盖一个已经本地命中的 `Repo`，否则会把 `isStarred` 重置为 false，导致私有区域收起。

### 6.4 不再调用 GitHub `/repos` 补 hero

聚合列表和详情已经包含 hero 所需字段，Weekly Shell 不再直接调用 `dependencies.apiClient.repo(owner:repo:)`。这可以：

- 避免客户端重复消耗用户 GitHub rate limit；
- 与 Trending“后端字段直出”的既有约束一致；
- 让未登录用户也能看到完整详情。

README 仍按现有 Readme API 路径加载，不由 weekly-api 返回正文。

### 6.5 来源标识位置

来源标识不再单独占据详情页多行区域。详情页与列表卡片保持一致：在 `RepoMetadataHeaderView` 的 `full_name` 同一行右侧显示来源小圆图标 + 短标签。由于来源标识已经表达了阮一峰期号，右侧 `Wiki` 旁边不再重复展示旧的粉色期刊数 badge。

```text
RepoMetadataHeaderView
  full_name  [来源图标组 + 短标签]
RepoLocalSections（仅已 Star）
README
```

不要把每个来源事件塞进 trailing actions。右上角 `RepoWikiMenu` 是代码文档入口，来源标识是收录事实摘要，两者语义独立。

### 6.6 来源标识渲染

| 来源 | 图标资源 | 短标签 | 点击 |
|---|---|---|---|
| weekly | `WeeklySources/ruanyf` | 期号，如 `186` | 打开 `issue_url` |
| zread | `WeeklySources/zread` | `week_label`，如 `This Week` / `Week 23` | 打开 `https://zread.ai/{owner}/{repo}` |
| discovery | `WeeklySources/hackernews` | 短日期 `M.d`，如 `5.2` | 打开 Hacker News item |

规则：

- 使用 `source_types` 返回顺序；
- 不用 `events[]` 重新计算列表或详情的“最近更新”；最近时间只读 `repo.latest_event_at` / `item.latest_event_at`；
- 未知来源使用中性 SF Symbol，不让整个详情解码失败；
- URL 缺失时来源标识只展示，不可点击；
- 图标放在独立 `WeeklySources` asset folder；不要复用 `WikiSources`，避免不同业务来源混在一个资源命名空间里。

### 6.7 Star / Unstar

继续调用 `StarActionService.toggle(repo:)`：

- ephemeral Repo 已持有真实 `gh_repo_id`，可以直接 Star；
- Star 成功后由现有 repository 写入本地 DB；
- 重新按 `gh_repo_id` 查本地 Repo，更新 `displayRepo.isStarred`；
- Tags / Notes / Releases、Share、AI 自动展开；
- Unstar 后保持公共详情和来源标识可见，只收起私有区域。

---

## 7. BackendAggregateRepoSource

`BackendAggregateRepoSource` 从：

```text
WeeklyAPI.fetchProject(owner:repo:)
```

切换为：

```text
WeeklyFeedAPI.fetchDetail(repoID:)
```

但现有 `RepoSource.tryResolve(owner:name:hint:)` 没有独立 `repoID` 参数。R-05 应把协议调整为显式请求对象：

```swift
struct RepoResolveRequest: Sendable {
    let ghRepoId: Int64?
    let owner: String
    let name: String
    let hint: StarcatRepoCardDTO?
}
```

`BackendAggregateRepoSource` 只有在 `ghRepoId` 存在时调用聚合 ID 详情接口；没有 ID 时返回 nil，让后续 GitHub fallback 处理。不要重新引入 owner/name 聚合详情接口。

Weekly Shell 可以继续使用自己的精简加载路径，不强制绕一圈 Resolver；两者共享 `WeeklyFeedAPI` 和 DTO 转换即可。

---

## 8. 语言 Store 与配置更新

聚合 API 必须接入当前第三方服务配置链：

```text
AppEndpoints
ThirdPartyService.weekly
StarcatAPIKeyResolver
AppDependencies
ServicesSettingsView
```

Weekly 语言列表来自后端三源合并后的 `github_repos` 可见集合，不做 source 维度拆分。Weekly service URL / API Key 变化时：

1. `WeeklyFeedAPI.updateBaseURL/updateAPIKey`；
2. 清空语言 Store；
3. 当前 Weekly 列表下一次 reload 使用新配置；
4. 不主动做启动健康探测，不把设置页“测试连接”与业务请求绑定。

---

## 9. 错误处理

| 场景 | 客户端行为 |
|---|---|
| 列表 200 + 空数组 | 显示当前语言下暂无项目 |
| 列表 401 | 提示 Weekly 服务 API Key 无效，保留已有列表 |
| 列表 5xx / 网络失败 | 保留已有列表，允许重试 |
| 详情 200 + `repo.is_available=false` | 保留 hero、README 和来源标识，显示“仓库当前不可用”提示 |
| 详情 404 | 表示该 `gh_repo_id` 从未建立或没有来源事件；保留列表首帧，显示非阻塞错误 |
| 详情 401 / 5xx | 保留 hero 和 README，只显示非阻塞错误 |
| 语言接口失败 | 使用 fallback 语言，不阻断列表 |
| 某个来源 snapshot 缺字段 | 该来源标识降级展示 source，不丢弃整个详情 |

详情错误不能替换整个右侧面板，因为列表 DTO 已经足够构造可用详情。

---

## 10. UI 决策

### 10.1 列表

| 项目 | 决策 |
|---|---|
| 默认排序 | `latest_event_at desc` |
| 来源标识 | repo name 右侧显示来源小圆图标 + 短标签 |
| 事件时间 badge | 不单独显示 |
| 已 Star ✓ | 显示 |
| 周刊期号 badge | 不作为统一 row badge |
| stars / forks / language | 显示 |

### 10.2 详情

| 区域 | 决策 |
|---|---|
| Hero | 列表 DTO 首帧，详情完整 Repo Card 增量更新 |
| 来源标识 | full_name 同行显示来源小圆图标 + 短标签，不单独占行 |
| Wiki Menu | 保持现有位置和语义 |
| 私有区域 | `repo.isStarred` 控制 |
| README | 保持现有 WebView / ReadmeViewModel 链路 |

### 10.3 Sidebar

| 项目 | 决策 |
|---|---|
| 分类名称 | 保持“周刊 / Weekly” |
| 来源选择器 | 不做 |
| 语言列表 | 后端聚合接口动态返回 |
| 数量 | 使用列表 meta.total |
| 头像背景色 | 继续跟随选中 item 的 language |

---

## 11. 实施顺序

| 阶段 | 工作内容 | 验证 |
|---|---|---|
| 1 | 新增聚合 DTO、Query、API actor | URL、鉴权、envelope、空 URL 字段单测 |
| 2 | 替换 Weekly 列表模型与 API | 首屏、筛选、刷新、分页、旧请求丢弃单测 |
| 3 | 动态语言 Store | URL/Key 更新后失效重拉、fallback 测试 |
| 4 | 调整 Selection 和 Shell ID | row、selection、动画都使用 gh_repo_id |
| 5 | 详情首帧与 ID 请求 | 首帧无白屏、详情失败保留 hero |
| 6 | 来源标识 UI | 三源图标、短标签、未知 source、空数组 |
| 7 | 升级 BackendAggregateRepoSource | 有 ID 命中聚合接口，无 ID 继续 fallback |
| 8 | 删除 WeeklyAPI / WeeklyModels 旧残留 | `rg` 确认旧 endpoint 和类型无调用 |
| 9 | 构建、定向测试、全量测试 | 按 AGENTS.md 要求执行 |

新增或删除 Swift 文件后先执行 `xcodegen generate`。

---

## 12. 测试要求

至少覆盖：

1. 列表响应解码三源 `source_types` 和代表数据。
2. `WeeklyFeedItem.id == gh_repo_id`。
3. 默认查询使用 `latest_event_at desc`。
4. `meta.next_page` 控制分页结束。
5. 分页失败后保留 items 且可以重试。
6. 切语言后旧 generation 响应不能覆盖新列表。
7. 点击 row 后无需等待详情请求即可构造完整 hero。
8. 详情请求使用 `/api/v1/repos/{gh_repo_id}`。
9. 详情公共字段更新时不覆盖本地 `isStarred`。
10. 三源来源图标按 `source_types` 顺序正确渲染。
11. 未知 source 或缺失 snapshot 不导致整个详情解码失败。
12. Star 后私有区域展开，Unstar 后公共详情和来源标识仍保留。
13. Weekly service URL / API Key 热更新后，新请求使用新配置。
14. `BackendAggregateRepoSource` 无 ID 时不构造错误的 owner/name 聚合请求。
15. 详情返回 `repo.is_available=false` 时仍展示来源标识，不进入 404 空态。

---

## 13. 最终验收标准

- Weekly 列表同时展示三源 repo，同一 `gh_repo_id` 只出现一次。
- 列表顺序与后端 `latest_event_at desc` 一致。
- 分页、筛选、刷新行为不低于当前 Weekly 实现。
- 点击 row 后 hero 立即出现，没有等待详情接口的白屏。
- 详情按 `gh_repo_id` 请求，并在 full_name 同行展示来源小圆图标 + 短标签。
- 详情返回完整 Repo Card；Weekly Shell 不再使用 `id=0` fallback，也不再调用 GitHub `/repos` 补 hero。
- 未 Star repo 使用真实 GitHub ID 且 `isStarred = false`，不会错误展示私有区域。
- 不增加客户端公共 feed 持久化表。
- 旧 Weekly API 和旧 `WeeklyProject` 语义清理完成。
- 构建、定向测试和全量测试通过后，由 dong4j 运行客户端完成视觉验收。
