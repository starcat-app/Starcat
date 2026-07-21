# Starred 与知识库改造详细设计

> 日期: 2026-07-02
> 状态: 设计方案, 尚未实现
> 范围: 数据模型、Repository、Smart Collections、详情页 ❤️ 入口、AI/MCP/Companion 范围改造

## 1. 设计目标

本设计把 Starcat 的 repo 集合拆成两层:

- GitHub starred 层: 表达用户当前是否在 GitHub 上 star,继续服务同步、Star/unstar、Star Lists 和公开 GitHub 状态。
- Starcat 知识库层: 表达用户是否把 repo 私有加入 Starcat 知识库,作为 Smart Collections 的“知识库”集合和 AI/MCP 的可选范围。

关键约束:

- 本项目尚未上线,不写兼容旧字段/旧版本逻辑。
- 不把 `RepoStatus.using` 扩展成“知识库”状态,避免阅读/使用状态与入库状态混用。
- 不把 `is_starred` 从 GitHub 事实改成 Starcat 入库状态。
- 不机械替换所有 `starred`;必须按语义分类处理。

## 2. 当前代码审计结论

代码扫描覆盖了以下关键模式:

- `fetchAllStarred()`
- `is_starred`
- `isStarred`
- `starredCount`
- `fetchRecentStarred`
- `StarredRepo`
- `starred_repos`
- AI / semantic / MCP / Companion / toolbar / Smart Collections 相关调用点

结论:

1. `repos.is_starred` 当前是大量列表与功能的基础条件。
2. `repo_notes.status` 已承载 `unread/read/using`,但没有“入库”概念。
3. `SemanticIndexBuilder` 和语义搜索候选集当前直接取全量 starred。
4. 详情页 toolbar 已有跨 Manage / Trending / Discovery / Activity / Weekly 的统一动作组,适合接入 ❤️。
5. Companion 当前对 notes/actions/tags 明确要求 repo 已 star,后续应改为“已入库或已 star 的能力分层”。
6. README/Health/OpenSSF 预热当前明显基于 starred,改造后应覆盖 starred 与知识库并集,不能改成只处理知识库。

## 3. 数据模型

### 3.1 新增状态

新增 `LibraryState`:

| case | DB raw value | UI |
|---|---|---|
| `outsideLibrary` | `outside_library` | 未入库 |
| `inLibrary` | `in_library` | 已入库 |

建议文件:

- `Starcat/Core/Database/Models/RepoNote.swift`

原因:

- `RepoStatus` 已在这里定义,`LibraryState` 也是用户私有 repo 状态。
- 放同文件可明确两者区别: `RepoStatus` 是阅读/使用状态,`LibraryState` 是知识库归属。

### 3.2 DB 字段位置

建议在 `repo_notes` 增加:

- `library_state TEXT NOT NULL DEFAULT 'outside_library'`
- `library_updated_at TEXT`

相关文件:

- `Starcat/Core/Database/Migrations/DatabaseMigrationsV1.swift`
- `Starcat/Core/Database/Models/RepoNote.swift`
- `Starcat/Core/Sync/RepoNoteRepository.swift`
- `Starcat/Core/Sync/RepoNoteRepositoryProtocol.swift`

为什么不放 `repos`:

- `repos` 是 repo 元数据缓存,用于保存 owner/name/stars/is_starred 等可从 GitHub 或后端重建的数据。
- `library_state` 是用户私有关系,不能跟随 repo metadata 重建或覆盖。
- 未 star repo 加入知识库时仍要写 `repos`,但那只是写 repo 元数据;真正的入库关系写在 `repo_notes.library_state`。

为什么放 `repo_notes`:

- `starred_repos` 是 GitHub 用户与 repo 的 star 关系表,不应混入 Starcat 私有知识库语义。
- `repos` 是 repo 元数据缓存,可重建;知识库状态是用户私有数据,不应随 repo metadata 重建丢失。
- `repo_notes` 当前已经承载用户私有笔记与 status,同一 repo 至多一行,适合继续承载 library state。
- 多账号场景下,`library_state` 必须与当前 GitHub 用户绑定,语义与 notes/status/tags 一致。A 账号入库不影响 B 账号;同一个 repo 可以在不同账号下分别拥有不同的 `library_state/library_updated_at/notes/status/tags`。
- 退出登录或切换账号不能删除 `repo_notes` 中的用户私有数据。查询层和 UI 层必须按当前登录用户过滤;未登录态不展示用户私有知识库,也不允许修改 `libraryState`。重新登录同一 GitHub 用户后,恢复该用户此前的入库状态和用户数据。
- 清理本地用户私有数据必须绑定显式用户动作,例如“清除本地数据”或“删除账号数据”;普通 logout 不是删除语义。

约束:

- `library_state` 不进入 notes FTS。它是过滤条件,不是全文内容。
- status 更新不能覆盖 library state。
- notes 更新不能覆盖 library state。
- library state 更新不能覆盖 content/status。
- 移出知识库只更新 `library_state`,不得删除 `repos` 元数据、notes、tags、status、Releases 订阅关系、README、Health、OpenSSF 或 embedding 缓存。
- release 轮询 active scope 与其他后台刷新一致: `repos.is_starred = 1 OR repo_notes.library_state = 'in_library'`。移出知识库后若 repo 也未 starred,保留订阅关系但不再自动刷新;重新 star 或重新入库后恢复刷新候选。
- `library_state` 与 `library_updated_at` 后续需要纳入 CloudKit 用户数据同步,冲突解决按最后更新时间胜出。当前 CloudKit 尚未集成,本专项只预留字段和设计约束,不实现同步。
- `library_updated_at` 只在 `libraryState` 实际变化时更新:
  - `.outsideLibrary -> .inLibrary`: 更新。
  - `.inLibrary -> .outsideLibrary`: 更新。
  - 重复加入已入库 repo 或批量加入中已入库项保持不变: 不更新。
  - notes / tags / status 改变: 不更新。
  - 不可访问/恢复可访问: 不更新。
- JSON 导入状态胜出时使用导入文件里的 `libraryUpdatedAt`,不得用当前时间覆盖,否则会破坏冲突解决与知识库排序。
- JSON 导入/导出需要纳入 `libraryState` 与 `libraryUpdatedAt`,语义与 CloudKit 一致: 它们是用户私有知识库关系,不是 repo metadata。
- JSON 导入 `.inLibrary` 时只恢复 Starcat 私有入库状态,不得调用 GitHub star API。
- JSON 导入未 star 已入库 repo 时,需要先写入 repo metadata,保持 `isStarred = false`,再写 `libraryState = .inLibrary`。
- 目标设备已有同 repo 时,导入按 `libraryUpdatedAt` 较新的状态胜出;导入文件缺少 `libraryState` 时默认 `.outsideLibrary`。
- JSON 导入的 `libraryState/libraryUpdatedAt/notes/status/tags` 写入当前登录账号名下,不沿用导出文件来源账号作为归属。跨账号导入是用户主动迁移动作。
- 未登录时不允许执行会写入 `libraryState` 的 JSON 导入;只读预览可以做,但不能落库。
- GitHub repo 被删除、转私有、返回 404/410 或权限不足时,不得自动把 `libraryState` 改为 `.outsideLibrary`。知识库状态是用户私有关系,只能由用户动作、导入或后续 CloudKit 同步改变。
- 不可访问 repo 需要保留 notes/tags/status/README 缓存,并在 UI 上显示不可访问/已失效状态。README / Health / OpenSSF 后台任务应跳过或降频处理这类 repo,避免反复失败。
- 远程可访问性记录在 `repos.access_state/access_reason/access_checked_at`。它属于可重建 repo metadata,只服务 UI 标记与后台降级;不得放进 `repo_notes`,也不得影响 `library_state/library_updated_at`。
- 已入库的私有 repo 或权限 repo 在没有 GitHub token / token 权限不足时,仍允许读取和编辑本地知识库关系、notes、tags、status。
- README 渲染优先使用本地缓存;如果没有缓存且当前 token 无权访问,展示权限不足/内容不可用状态。
- GitHub star/unstar、repo metadata refresh、README fetch、Health/OpenSSF 远程刷新、外部 GitHub 内容访问都必须走权限门控。
- AI/MCP 工具可以读取本地用户数据和已缓存 README/Health/OpenSSF/embedding,但响应中不得暗示已经访问到当前无权限的私有 GitHub 内容。
- 已登录但离线时,允许修改本地已有 repo 的 `libraryState`;写入本地 `repo_notes.library_state` 与 `library_updated_at`,不依赖 GitHub 请求。
- 未登录时禁止修改 `libraryState`。`libraryState` 是用户私有关系,未登录态缺少稳定用户归属,不能写入或变更这类状态。
- 对未落库的外部 repo,离线时不能直接加入知识库,因为缺少可确认的 repo metadata;需要先通过已登录的同步、搜索、Discovery/Trending/Weekly 等数据源落库。
- 已入库未 star repo 允许完整使用本地 notes / tags / status。实现时需要把这些本地知识管理写入路径的前置条件从 `isStarred` 扩展为 `isStarred || libraryState == .inLibrary`。
- Releases 订阅入口也允许已入库未 star repo。订阅关系本身按 `isStarred || libraryState == .inLibrary` 判断,但 release 列表拉取、通知刷新仍按 GitHub token、权限和 repo 可访问性处理。
- Watchers / Forks / Issues 等 GitHub 统计刷新候选应覆盖 active scope,即 `repos.is_starred = 1 OR repo_notes.library_state = 'in_library'`。这些字段属于 repo metadata 展示,未 star 已入库 repo 也应刷新。
- 统计刷新失败边界与 README/Health/OpenSSF 一致: token 权限不足、repo 私有、404/410 或不可访问时跳过或降频,保留已有缓存,不得改变 `libraryState`。
- 手动单 repo README / Health / OpenSSF 刷新入口也按 `isStarred || libraryState == .inLibrary` 放行。它与后台预热/轮询使用同一 active 能力边界,但只作用于用户显式选择的 repo。
- 手动刷新失败不得清空旧缓存,不得修改 `libraryState`,不得触发自动移出知识库;UI 只展示权限/不可访问/刷新失败反馈。
- 仍然必须 star 或必须远程权限的动作不能套用上一条,例如 GitHub star/unstar、远程刷新、私有 GitHub 内容拉取等。

### 3.3 未 star repo 入库

需要支持未 star repo 落本地 `repos`:

- `is_starred = false`
- `starred_at = nil`
- `library_state = in_library`

当前 `RepoRepository.repoFromDTO` 已支持 `isStarred: Bool` 参数,Discovery/Trending/Weekly 的 ephemeral repo 也已有转换路径。实现时需要新增“保存外部 repo metadata”方法,避免把未 star 入库强行写成 starred。

候选接口:

- `upsertLibraryRepo(...)`
- `upsertExternalRepoForLibrary(...)`

建议放在:

- `Starcat/Core/Sync/RepoRepositoryProtocol.swift`
- `Starcat/Core/Sync/RepoRepository.swift`

## 4. Repository 改造

### 4.1 RepoNoteRepository

新增能力:

- 查询单 repo 的 `LibraryState`。
- 批量查询 `repoID -> LibraryState` map。
- 全表查询 library state map。
- 更新 library state。
- 按 library state 查询 repos。
- 统计各 library state 数量。

涉及文件:

- `Starcat/Core/Sync/RepoNoteRepositoryProtocol.swift`
- `Starcat/Core/Sync/RepoNoteRepository.swift`

注意:

- `updateStatus(repoId:status:)` 仍只更新 status。
- `updateContent(repoId:content:)` 仍只更新 content。
- 新增 `updateLibraryState(repoId:state:)` 只更新 library state。
- `markAsReadIfNeeded` 不得影响 library state。

### 4.2 RepoRepository

新增知识库范围查询:

- `fetchKnowledgeRepos()`
- `knowledgeCount()`
- `fetchKnowledgePage(scope:filters:sort:limit:offset:)`
- `searchKnowledgeFTS(query:)`
- `fetchKnowledgeRepoIDs()`

也可以先不新建完整分页接口,而是在现有 `RepoListScope` 扩展 `.library` 并让 `makeListQuery` 可按 scope 追加 `repo_notes.library_state = 'in_library'`。

涉及文件:

- `Starcat/Core/Sync/RepoRepositoryProtocol.swift`
- `Starcat/Core/Sync/RepoRepository.swift`
- `Starcat/Core/Sync/RepoListQuery.swift`

注意:

- 现有 `makeListQuery` 默认 `r.is_starred = 1`,这是 Manage starred 语义,不能直接拿来查未 star 已入库 repo。
- 新的知识库查询必须允许 `is_starred = 0 && library_state = in_library`。
- 原有 `.allStars`、`.language`、`.tag` 若产品仍定义为 stars 管理视图,继续保留 `is_starred = 1`。

## 5. Smart Collections 改造

### 5.1 新增系统集合

新增 `SmartCollectionKind.library`。

涉及文件:

- `Starcat/Features/Collections/SmartCollectionsOverviewView.swift`
- `Starcat/Features/Home/HomeViewModel.swift`
- `Starcat/Features/Home/SidebarView.swift`
- `Starcat/Features/Collections/SmartCollectionRuleSummary.swift`
- `Starcat/Resources/Localizable.xcstrings`
- 相关测试: `StarcatTests/HomeViewModelFilterSortTests.swift`

### 5.2 规则

内置规则:

- 知识库: `libraryState == .inLibrary`

`matchesSmartCollection(...)` 当前只接收 `status`,需要增加 library state 参数或让 `.library` 走 repository 直查,避免在函数内查库。

### 5.3 “正在使用”关系

建议规则:

- 用户的状态真正从非 `RepoStatus.using` 变为 `.using` 时,如果 library state 不是 `.inLibrary`,同步设为 `.inLibrary`;重复保存已有 `.using` 不覆盖用户明确移出后的 `.outsideLibrary`。
- 自动入库时不弹确认,但应给轻量 toast,例如“已标记正在使用,并加入知识库”,避免用户不理解 ❤️ 为什么点亮。
- 用户从 `RepoStatus.using` 改成 `read` / `unread` 时,保持当前 `libraryState` 不变。`using` 是“当前正在使用”的工作状态,知识库归属由用户单独管理,取消使用状态不能推导出加入或移出知识库。
- 用户从知识库移除时只把 `libraryState` 设为 `.outsideLibrary`;即使 repo 仍是 `using` 也不修改阅读状态、不弹状态降级确认。
- 未入库 repo 加入知识库时默认写入 `RepoStatus.unread`;如果是从 `RepoStatus.using` 自动入库,则保持 `using`。

两个状态只保留一次单向联动:真正进入 `using` 时自动入库。后续移出知识库、结束使用状态或重复保存 `using` 都只尊重用户当前操作,不反向覆盖另一状态。

涉及文件:

- `Starcat/Features/Notes/RepoNotesSection.swift`
- `Starcat/Core/Sync/RepoNoteRepository.swift`

## 6. 详情页 ❤️ 入口

### 6.1 接入位置

用户指定入口:

- 详情页中,放在当前 Wiki / 推荐等图标之后。
- 常驻 ❤️ 图标。
- 点击后有动画效果。

当前代码入口:

- `Starcat/Features/Home/RepoDetailView.swift`
- `Starcat/Features/Home/RepoListView.swift`
- `Starcat/Features/Trending/TrendingScaffoldShell.swift`
- `Starcat/Features/Explore/DiscoveryDetailView.swift`
- `Starcat/Features/Activity/ActivityDetailScaffoldShell.swift`
- `Starcat/Features/Activity/WeeklyDetailScaffoldShell.swift`
- `Starcat/Features/Activity/ActivityReleaseDetailScaffoldShell.swift`

`RepoListView.selectedRepoToolbarActions(...)` 已经统一了 external / clone / share 等 toolbar 行为,适合作为 ❤️ 的主要落点。详情页自身 `RepoDetailView.trailingActions(for:)` 当前守卫 `repo.isStarred`,后续要调整为: 知识库按钮常驻,Share 仍按 star 状态守卫。

### 6.2 组件建议

新增组件:

- `LibraryToggleButton`

职责:

- 展示入库/未入库状态。
- 处理点击动画。
- 操作中禁用重复点击。
- 失败时使用短暂错误反馈。
- 详情页不做乐观更新: 点击后进入 loading/disabled,等待 repo metadata 与 `libraryState` 写入成功后再更新 UI 与 `LibraryStateRegistry`。
- 失败时保持原状态并显示 toast/error,不执行先变实心再回滚的交互。

建议放置:

- `Starcat/Shared/Components/LibraryToggleButton.swift`

若新增 Swift 文件,实现阶段必须跑 `xcodegen generate`。

### 6.3 ViewModel / Service

新增服务:

- `LibraryStateService`

职责:

- 根据 repo 判断当前 library state。
- 加入知识库。
- 取消入库。
- 对未 star repo 先落 metadata,再写 library state。

建议放置:

- `Starcat/Core/Library/LibraryStateService.swift`

或沿用现有分层放在:

- `Starcat/Core/Sync/LibraryStateService.swift`

### 6.4 多选批量操作

当前代码已有多选框架:

- `Starcat/Shared/Components/Toolbar/MultiSelectButton.swift`
- `Starcat/Features/Home/RepoListView.swift`
- `MultiSelectionStore`
- `SelectionSnapshot`

第一版只接入批量加入知识库:

- 多选菜单增加 `加入知识库`。
- 对选中的 `SelectionSnapshot` 批量写 `libraryState = .inLibrary`。
- 已入库 repo 跳过或保持不变。
- 未入库 repo 默认写 `RepoStatus.unread`。
- 不调用 GitHub star。
- 成功后刷新 `LibraryStateRegistry` 和列表 ❤️ 标识。

第一版不接入批量移出知识库。原因是批量移出会引入 `using` repo 统计、二次确认、状态降级和误操作恢复问题,应作为后续独立交互设计。

### 6.5 Repo 卡片入库标识

用户要求在 Manage / Trending / Discovery / Weekly / Activity 的 repo 卡片上,在 repo logo 左上角展示 ❤️,表示该 repo 已进入 Starcat 知识库。

当前统一卡片结构:

- `Starcat/Shared/Models/RepoCardViewData.swift`
  - 已有 `isStarred: Bool`,用于跨场景表达 GitHub star 状态。
  - `Repo.asCardData(...)` 服务 Manage / Activity 等本地 repo。
  - `TrendingRepo.asCardData(...)`、`WeeklyFeedItem.asCardData(...)`、`StarcatRepoCardDTO.asCardData(...)` 服务远端/推荐来源。
- `Starcat/Shared/Components/UnifiedRepoRow.swift`
  - `showStarredCheckmark && card.isStarred` 控制标题行绿色 ✓。
  - `avatarWithKindBadge` 当前在头像右下角承载 Activity kind icon。
- `Starcat/Shared/Components/RepoRowSurface.swift`
  - 负责 row 背景、hover、selected,不应塞业务状态。

建议改造:

1. `RepoCardViewData` 新增 `isInLibrary: Bool` 或 `libraryState: LibraryState`。
2. `UnifiedRepoRow` 在头像区域新增 `avatarWithOverlays`,统一渲染:
   - 左上角: 知识库 ❤️,仅 `isInLibrary == true` 显示。
   - 右下角: Activity kind icon,沿用现有 `.activityKind`。
3. ❤️ 用固定尺寸覆盖在 40pt avatar 左上角,不改变 row 高度、不挤占标题/chip 行。
4. ❤️ 是只读状态标识,不在 row 内处理点击;点击 row 仍按当前逻辑选择/打开详情。
5. GitHub Star 的标题行 ✓ 继续由 `showStarredCheckmark` 控制,不要复用为知识库状态。

视觉边界:

- Manage: 即使 Manage 主列表默认主要来自 starred,也要展示已入库 ❤️,因为用户需要区分“已 star 未入库”和“已 star 已入库”。
- Trending / Discovery / Weekly: 继续展示 GitHub Star ✓,同时可叠加知识库 ❤️。
- Activity: 当前注释说明 Activity repo-backed 行不展示 star ✓,因为过滤后大多是 starred。知识库 ❤️ 不应套用这个规则,只要 `libraryState == .inLibrary` 就展示。
- Search Center 搜索结果需要展示入库状态,并允许直接通过空心/实心 ❤️ 加入或移出知识库。若复用 `UnifiedRepoRow`,应单独提供 row 外或 trailing action 入口,不要把 logo 左上角小标识变成可点击控件。
- Search Center 直接移出知识库时沿用详情页规则:只更新 `libraryState`,不修改阅读状态。
- 推荐弹窗若复用 `UnifiedRepoRow`,也可自然获得 ❤️;正式需求先验收 Manage / Trending / Discovery / Weekly / Activity。

数据接入点:

| 场景 | 当前 row 入口 | 当前 star 来源 | library state 接入 |
|---|---|---|---|
| Manage | `Starcat/Features/Home/RepoListView.swift` | `Repo.isStarred` | `HomeViewModel` 或 repository 批量加载 `RepoNote.libraryState` 后传入 `Repo.asCardData(...)` |
| Trending | `Starcat/Features/Trending/TrendingView.swift` | `StarredRegistry.contains(ghRepoId:)` | 新增 `LibraryStateRegistry.contains(ghRepoId:)` 或批量查询结果 |
| Discovery | `Starcat/Features/Explore/ExploreView.swift` | `StarredRegistry.contains(ghRepoId:)` | 同 Trending,优先按 `repoID/ghRepoId` 匹配 |
| Weekly | `Starcat/Features/Activity/WeeklyContentView.swift` | `StarredRegistry.contains(ghRepoId:)` | 同 Trending,按 `project.ghRepoId` 匹配 |
| Activity | `Starcat/Features/Activity/ActivityView.swift` | `Repo.isStarred` | `ActivityViewModel` 或全局 registry 回填 `repo.id` 的 library state |

registry 建议:

- 新增 `LibraryStateRegistry`,职责与 `StarredRegistry` 对称,但只维护 `libraryState == .inLibrary` 的 repo id 集合。
- 详情页 ❤️ 更新成功后同步更新 registry,让列表卡片即时刷新。
- registry 需要支持未 star 已入库 repo,不能从 `StarredRegistry` 派生。
- 对远端 DTO,优先使用 GitHub 数字 id;只有 id 缺失时才允许 fallback 到 `owner/name`。

## 7. AI 与语义搜索改造

### 7.1 范围模型

AI/语义搜索不做“只允许知识库”的限制。新的范围模型应同时支持:

| 范围 | 规则 | 用途 |
|---|---|---|
| `starred` | `is_starred = 1` | 保留现有 stars AI/语义搜索能力 |
| `library` | `library_state = in_library` | 用户私有入库范围 |
| `all` | starred 与 library 并集 | embedding、预热、全局搜索默认候选 |

这意味着已 star 但未入库的 repo 仍可被语义搜索和 MCP 使用,只是 UI 需要让用户知道当前使用的是哪个范围。

### 7.2 需要改造的文件

- `Starcat/Features/AI/SemanticIndexBuilder.swift`
  - 当前全量构建直接取 `fetchAllStarred()`。
  - 改为支持 `starred/library/all` 候选集合,默认可用 `all`。

- `Starcat/Features/Home/HomeViewModel.swift`
  - 语义搜索候选当前取 `repository.fetchAllStarred()`。
  - 改为根据搜索范围取 starred、library 或并集候选。
  - FTS 加权应与当前搜索范围一致。

- `Starcat/Features/AI/SemanticSearchService.swift`
  - 注释和候选集语义需更新为“调用方传入当前范围候选”。

- `Starcat/Features/MCP/StarcatMCPFacade.swift`
  - `searchRepos(query:nil)` 当前返回 all starred。
  - `semanticSearch` 当前候选 all starred。
  - `resources()` 当前 recent starred。
  - 增加范围参数或工具分支,支持 starred、library、all,不得移除 starred 能力。

### 7.3 可保留单 repo 显式触发

以下不强制要求已入库:

- `RepoAIInsightService.generateInsight(...)`
- `RepoAIInsightViewModel.generate(...)`
- `RepoAIContextProvider.prepareContext(...)`
- CodeFlow / Codebase 单仓库上下文准备

理由:

- 用户在 Discovery/Trending 详情页可能想先快速看摘要,再决定是否加入知识库。
- 这是单次显式动作,不会污染全局知识库。

### 7.4 embedding 与索引清理

embedding 不按“是否在知识库”清理。只要 repo 属于 starred 或 knowledge 任一集合,都应保留或生成 embedding,因为语义搜索会覆盖两类数据。

清理规则:

- `is_starred = 1` 的 repo 保留 embedding。
- `library_state = in_library` 的 repo 保留 embedding。
- 同时不在 starred 与 knowledge 中的 repo,后续可作为缓存清理候选。
- 移出知识库时不立即删除 embedding。若 repo 仍 starred,embedding 继续保留;若 repo 同时不在 starred 与 knowledge,只是不再属于 active scope,后续是否清理 embedding 由独立缓存清理策略决定。

## 8. Companion / Browser Plugin 改造

当前 Companion 多处要求 repo 已 star:

- `Starcat/Features/Companion/CompanionNoteWriter.swift`
- `Starcat/Features/Companion/CompanionTagWriter.swift`
- `Starcat/Features/Companion/CompanionActionHandler.swift`
- `Starcat/Features/Companion/CompanionContextProvider.swift`
- `Starcat/Features/Companion/CompanionLocalServer.swift`

改造原则:

- repo-context 应返回 `is_starred` 与 `library_state` 两个状态。
- Notes/Tags 写入可以允许“已入库”repo,不再只看 `isStarred`。
- action open/codeflow/codebase 可以允许已入库 repo。
- Browser Plugin GitHub 页面应展示空心/实心 ❤️ 知识库状态,并提供加入/移出知识库动作。这个入口与详情页逻辑一致,只更新 Starcat 私有知识库状态。
- Browser Plugin 操作失败时显示插件内 toast,并回滚 ❤️ 状态。
- Star 动作仍独立,不和加入知识库绑定。

API 需新增或扩展:

- `PATCH /plugin/v1/library-state`
- repo-context DTO 增加 library state 字段。

错误码建议:

- `repo_not_found`
- `repo_not_in_library`
- `repo_not_starred` 仅用于必须 star 的 GitHub Star 专属能力。

## 9. 搜索 / Discovery / Trending / Weekly

### 9.1 外部 repo 入库

以下来源的 repo 可能未 star:

- `Starcat/Features/Search/GitHubRepositorySearchProvider.swift`
- `Starcat/Features/Explore/DiscoveryDetailView.swift`
- `Starcat/Features/Trending/TrendingScaffoldShell.swift`
- Weekly / Activity 详情中的远端 repo

需要支持:

- 通过 ❤️ 将 ephemeral repo 写入 `repos`。
- `isStarred = false`。
- `libraryState = .inLibrary`。
- 不创建 `starred_repos` 行。
- Search Center 搜索结果需要展示哪些 repo 已入库,并允许直接加入/移出知识库。
- Manage 默认列表仍是 starred 管理视图,不混入未 star 已入库 repo。未 star 已入库 repo 的整库入口是 Smart Collections -> 知识库。
- 知识库集合支持与 Manage 一致的 tag / status / language / archived / fork 筛选。

### 9.2 分享与 Star 状态

分享卡应同时支持 starred 和知识库两个来源:

- stars 分享: 保留现有 GitHub stars 导出/分享语义。
- 知识库分享: 新增或扩展为分享 `library_state = in_library` 的 repo。

当前 toolbar 的 share 逻辑依赖 `isShareAvailable: isStarred`,实现阶段需要重新定义: 已入库未 star 的 repo 也应允许走知识库分享,但不能伪装成“我的 GitHub stars”。

Profile/ShareCard 的文件导出入口需要同步改造:

- 原“导出 Starred”按钮/菜单入口改为“导出到文件”。
- 下拉项固定为:
  1. 导出 Starred 到 HTML.
  2. 导出 Starred 到 Markdown.
  3. 导出 知识库 到 HTML.
  4. 导出 知识库 到 Markdown.
- `StarredExporter` / `StarredMarkdownRenderer` / `StarredHTMLRenderer` 可扩展为接收导出范围,或新增知识库导出 renderer;关键约束是 Starred 与知识库的数据查询和文案必须分开。
- 知识库导出查询 `library_state = in_library`,并允许包含 `is_starred = false` 的 repo。
- 知识库导出排序沿用知识库集合排序: `COALESCE(repos.starred_at, rn.library_updated_at, repos.cached_at) DESC, repos.id DESC`。
- 知识库 HTML / Markdown 需要重新设计输出内容结构,不能把 Starred HTML/Markdown renderer 只换标题后复用。标题、页头、基础排版参考现有 Starred 导出模板;实现阶段应新增 `LibraryMarkdownRenderer` / `LibraryHTMLRenderer` 或等价结构。

知识库导出格式设计要求:

- 标题明确为 Starcat 知识库,不写成 GitHub Stars。
- 汇总区展示 repo 总数、主要语言、主要状态分布、导出时间。
- Repo 条目优先展示 owner/name、description、language、status、tags、notes、是否 starred、library_updated_at。
- 可用时展示 README 摘要、Repo Health、OpenSSF 分数;没有缓存时留空或标记未生成,不触发远程拉取。
- 未 star 已入库 repo 需要正常展示,并可用文案标明“未 GitHub Star,已入库”。
- notes 默认直接包含在知识库 HTML / Markdown 导出中,不提供额外开关。导出文件是用户主动生成的完整知识库资料。
- 摘要策略与现有 Starred HTML / Markdown 导出一致: 有摘要就导出,没有摘要不为导出临时生成。导出链路不得触发 README fetch、AI summary、Repo Health refresh 或 OpenSSF refresh。
- 空状态只针对知识库导出新增处理: 查询到的知识库 repo 数量为 0 时不调用 renderer、不打开保存面板、不生成空文件,直接复用现有 toast/error pattern 提示“知识库为空,暂无可导出的 repo”。Starred 导出的现有行为保持不变。
- ShareCard/Profile 的知识库导出查询不接收 Smart Collections 当前筛选条件,第一版固定导出当前账号下全部 `library_state = in_library` 的 repo。知识库集合页如果后续需要“导出当前筛选结果”,应作为单独入口和单独交互设计。
- 默认保存文件名按导出范围区分:
  - Starred HTML: `starcat-starred-YYYY-MM-DD.html`
  - Starred Markdown: `starcat-starred-YYYY-MM-DD.md`
  - 知识库 HTML: `starcat-library-YYYY-MM-DD.html`
  - 知识库 Markdown: `starcat-library-YYYY-MM-DD.md`
- Markdown / HTML 的标题、页头和基础布局参考现有 Starred 导出模板,不再单独设计导出视觉细节;repo 内容布局应服务知识库而不是 stars 清单。

## 10. 继续保留 starred 语义的模块

以下模块不应改为知识库:

| 模块 | 文件 | 原因 |
|---|---|---|
| GitHub stars 同步 | `Starcat/Core/Sync/SyncManager.swift` | 与 GitHub API `/user/starred` 对齐 |
| Star API | `Starcat/Core/Network/GitHubAPI/StarsAPI.swift` | 公开 Star/unstar 操作 |
| StarActionService | `Starcat/Core/Sync/StarringSubsystem.swift` | 专管 GitHub star 状态 |
| StarredRegistry | `Starcat/Core/Sync/StarringSubsystem.swift` | 内存缓存 GitHub star 集合 |
| Star Lists | `Starcat/Core/Sync/GitHubStarListRepository.swift` | GitHub Star Lists 只对 starred 有意义 |
| sync_state starredCount | `Starcat/Core/Database/Models/SyncStateRecord.swift` | 同步统计是 stars 统计 |
| ShareCard stars 导出 | `Starcat/Features/Profile/ShareCard/*` | 明确是导出/分享 GitHub stars |
| Repo star chip | 多个详情 scaffold | ⭐ 是 GitHub Star,不是知识库 |

## 11. 预热与后台索引范围

以下模块不应改成“只处理知识库”。它们应覆盖 starred 与知识库并集:

| 模块 | 文件 | 建议 |
|---|---|---|
| README 预拉 | `Starcat/Core/Sync/ReadmePrefetchRepository.swift` | 覆盖 starred 与知识库并集 |
| Repo Health 预热 | `Starcat/Core/Health/RepoHealthRepository.swift` | 覆盖 starred 与知识库并集 |
| OpenSSF 预热 | `Starcat/Core/Sync/OpenSSFScoreRepository.swift` | 覆盖 starred 与知识库并集 |
| InitialWarmupCoordinator | `Starcat/Core/Warmup/InitialRepoWarmupCoordinator.swift` | 调度 starred 与知识库并集 |
| Activity starred recently pushed | `Starcat/Features/Activity/ActivityViewModel.swift` | Activity 仍可表达 starred 活动流 |

### 11.1 Health / OpenSSF 后台任务边界

当前代码路径:

- `RepoHealthPoller.performRefresh()` 通过 `isRefreshing` 防止上一轮未结束时重入,每轮调用 `RepoHealthService.refreshStaleStarredRepos(limit: 100, delayBetweenRepos: ...)`。
- `OpenSSFScorePoller.performRefresh()` 同样通过 `isRefreshing` 防重入,每轮调用 `OpenSSFScoreService.refreshStaleStarredRepos(limit: 100)`。
- `RepoHealthService.refreshStaleStarredRepos(...)` 先查 `RepoHealthRepository.staleStarredRepos(...)`,再顺序处理候选,循环内检查 `Task.isCancelled`。
- `OpenSSFScoreService.refreshStaleStarredRepos(...)` 先查 `OpenSSFScoreRepository.staleStarredRepos(...)`,再用 task group 做最多 3 个并发刷新。
- `InitialRepoWarmupCoordinator.runHealthPhase(...)` 依赖 `refreshMissingSnapshotStarredRepos(...)` 和 `coverageSummary().starredTotal` 判断完成或 pause。
- `InitialRepoWarmupCoordinator.runOpenSSFPhase(...)` 依赖 `refreshStaleStarredRepos(...)` 与 `OpenSSFScoreCoverageSummary.starredTotal` 判断完成或 pause。

改造原则:

- 将 `staleStarredRepos` / `missingSnapshotStarredRepos` 语义升级为 active repo scope,即 `repos.is_starred = 1 OR repo_notes.library_state = 'in_library'`。
- coverage 的 total 必须使用同一 active repo scope,不能继续只统计 `WHERE is_starred = 1`。
- fetched/snapshot 统计也必须只统计 active repo scope 内已完成的记录,避免已取消 star 且未入库的历史缓存把 coverage 撑满。
- 方法命名后续应从 `starredTotal` / `staleStarredRepos` 收敛到 `activeTotal` / `staleActiveRepos`,避免实现和语义继续错位。

停止边界:

- 周期 poller: 如果 `isRefreshing == true`,跳过本轮;如果 active 候选为空,本轮正常结束并记录 `lastRefreshCount = 0`。
- Health 顺序刷新: 循环内 `Task.isCancelled` 时停止当前批次;已写入的 snapshot 保留,下一轮从 active stale/missing 候选继续。
- OpenSSF 并发刷新: 第一版沿用最多 3 并发;如果外层 task 被取消,不再继续 enqueue 新候选。已完成子任务写入结果,未开始候选留给下一轮。
- Initial warmup Health: `healthTotal == 0` 或 `healthCovered >= healthTotal` 才 complete;`refreshed == 0` 但 coverage 未满时 pause retry,这个判断必须基于 active scope,否则会因为 total/candidate 范围不一致而永久重试。
- Initial warmup OpenSSF: `openSSFTotal == 0` 或 `openSSFCovered >= openSSFTotal` 才进入下一 phase;`refreshed == 0` 但 coverage 未满时 pause retry,同样必须基于 active scope。
- 用户在后台任务运行中取消入库: 不需要中断已经开始的单 repo 请求;下一批候选和下一次 coverage 统计会自然排除不再 active 的 repo。
- 用户在后台任务运行中加入知识库: 不抢占当前批次;下一轮 poller 或 warmup retry 会补齐新 active repo。
- 取消入库不删除已存在的 README、Health、OpenSSF 缓存。active scope 只决定后续是否继续预热/刷新,不是缓存删除条件。
- 对私有 repo 或权限 repo,如果当前没有 GitHub token 或 token 权限不足,后台任务必须把它视为远程不可刷新,但不得删除本地缓存或改变 `library_state`。

SQL 形态建议:

- active scope 用 `LEFT JOIN repo_notes rn ON rn.repo_id = repos.id`。
- 条件统一为 `(repos.is_starred = 1 OR rn.library_state = 'in_library')`。
- 知识库集合排序采用 `COALESCE(repos.starred_at, rn.library_updated_at, repos.cached_at) DESC, repos.id DESC`。未 star 已入库 repo 没有 `starred_at`,主要按 `library_updated_at DESC` 排序。

## 12. 设置与本地化

涉及:

- `Starcat/Resources/Localizable.xcstrings`
- `Starcat/Core/Settings/AppSettings.swift`
- `Starcat/Features/Settings/SettingsView.swift`

新增 i18n key 建议:

- `library.state.outsideLibrary`
- `library.state.inLibrary`
- `library.action.add`
- `library.action.remove`
- `smartCollections.kind.library`

若新增设置:

- 不新增“AI 只能使用知识库”固定规则。
- 可新增 AI/MCP 范围选择: starred / knowledge / all。
- README/Health/OpenSSF 预热默认覆盖 starred 与知识库并集,不提供“只预热知识库”作为第一版目标。

## 13. 测试计划

新增/调整测试:

- `DatabaseMigrationsV1Tests`
  - `repo_notes` 包含 library state。
  - status/content/library state 互不覆盖。

- `RepoNoteRepositoryTests`
  - update/fetch library state。
  - fetch library state map。
  - counts by library state。

- `RepoRepositoryTests`
  - 未 star repo 可作为 inLibrary 入库。
  - knowledge 查询包含未 star inLibrary repo。
  - allStars 查询不包含未 star inLibrary repo。

- `HomeViewModelFilterSortTests`
  - Smart Collection `library` 命中 inLibrary。
  - `using` 与 `library` 的关系。

- `SemanticSearchTests`
  - starred 范围包含 starred repos。
  - library 范围包含 inLibrary repos。
  - all 范围包含 starred 与 library 并集。

- `CompanionContextProviderTests` / `CompanionLocalServerTests`
  - repo-context 返回 library state。
  - 已入库未 star repo 可写 notes/tags。
  - 必须 star 的动作仍拒绝未 star。

- toolbar/UI 相关测试如已有模式可补:
  - ❤️ 状态映射。
  - 未 star 详情页仍展示 ❤️。

## 14. 实施顺序

1. 数据模型与 repository。
2. Smart Collection `library`。
3. 详情页 ❤️ 入口。
4. AI/MCP 范围选择与并集候选。
5. Companion 与外部来源入库。

每一步完成后同步专项 checklist,最后再同步 `docs/功能实现总览.md` 的对应功能条目。

## 15. 风险点

1. 机械替换 `fetchAllStarred()` 会破坏 GitHub star 同步/分享/Star Lists。
2. 只用 `RepoStatus` 承载知识库会导致 `read/unread/using` 与入库语义混乱。
3. 详情页 ❤️ 如果仍被 `repo.isStarred` 守卫,未 star repo 无法入库。
4. 知识库查询如果沿用 `r.is_starred = 1`,会漏掉未 star 已入库 repo。
5. MCP/语义搜索若只查单一范围,会误伤 starred 或知识库其中一侧的用户预期。
6. Companion 若仍返回 `repo_not_starred`,Browser Plugin 无法服务已入库未 star repo。
