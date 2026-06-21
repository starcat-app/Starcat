# Manage 列表客户端分页 + 首次登录第一页上屏（R-07）

> **状态**：✅ 已实施；2026-06-22 补充 DB 分页 `OFFSET + append` 修正
> **范围**：客户端 Starcat（macOS）—— `HomeViewModel` / `RepoListView` / `HomeView` / `SyncManager`
> **关联**：进度文档 `工程进度/功能实现总览.md` §6.6 R-07
> **互补文档**：R-06.4 `31-Trending-Weekly缓存改造.md`（Weekly 同款客户端分页范式来源）

---

## 1. 背景与问题

dong4j 2026-06-15 同时反馈两个体验问题，根因相关、解法协同：

| 问题 | 现状 | 体感 |
|---|---|---|
| **A：首次登录上屏慢** | `SyncManager` 分页拉 1800 条 stars（19 页），每页写 DB，但 UI 只在 `state == .completed` 才 `reloadItems` 一次 | 登录后看到空白 / 骨架屏数十秒，直到全部拉完才一次性出现 |
| **B：Manage 列表卡顿** | `HomeViewModel.items` 一次性持 1800 条全量；`RepoListView` 把 1800 行交给 `List + ForEach`；每行挂 `listRowReveal` + `readmePrefetch` + 3 个 `@Observable` 字典订阅 | 滚动卡、切分类卡（19 行 vs 1800 行 view-tree）、切详情时 1800 行 row body 全部重算 |

对比组：Weekly 缓存 4000 条但列表只渲染 20 条（R-06.4 `localPageSize: 20`），滚动 / 切换全程丝滑。

**协同关系（关键）**：若只做 A 不做 B，A 收尾时"100 → 1800"的列表替换会触发整栏 `itemsRevision++` → 1800 行 view-tree 重建 + stagger 入场动画，产生第二次明显卡顿；做了 B 之后那次切换对用户透明（items 永远只是 filteredSorted 的前 20 条切片）。所以两件事必须同 PR 内一起做。

---

## 2. 总体方案

### 2.1 双改造拓扑

```
┌─────────────────── 问题 B：客户端分页 ───────────────────┐
│                                                          │
│   rawItems (1800)                                        │
│       │ filter + sort                                    │
│       ▼                                                  │
│   filteredSorted (≤1800)  ← Cmd+A / multi-select retain  │
│       │ prefix(currentPage × 20)                         │
│       ▼                                                  │
│   items (20, 40, 60, ...) ← UI 渲染只这一层              │
│                                                          │
└──────────────────────────────────────────────────────────┘
                            ▲
                            │ 触发 reloadItems 的边沿
                            │
┌─────────────────── 问题 A：首页上屏边沿 ─────────────────┐
│                                                          │
│   SyncManager.runSync                                    │
│       │                                                  │
│       ▼ (page=1, upsertStarred 写完)                     │
│   firstPageWrittenAt = Date()    ← 新增 @Observable     │
│       │                                                  │
│       ▼                                                  │
│   HomeView.onChange(of: firstPageWrittenAt)              │
│       └─→ refreshSidebar + reloadItems(forceRefresh:t)   │
│                                                          │
│   (后续页继续静默拉 → .completed 再 reload 一次)         │
└──────────────────────────────────────────────────────────┘
```

### 2.2 两轨在一起的效果（首次登录视角）

| 时间 | 事件 | items 切片 | 用户感受 |
|---|---|---|---|
| T+0 | 完成 Device Flow → `state = .authenticated` | `[]`（DB 空） | 骨架屏 |
| T+1.5s | SyncManager 写完 page 1（100 条） → `firstPageWrittenAt = Date()` | 触发 reload → rawItems=100 → filteredSorted=100 → items 切到前 20 | **看到前 20 条**，可滚动 |
| T+2~25s | 后续 page 2..19 静默写 DB（HomeView 不响应） | 不变 | 无感（无重建、无滚动跳） |
| T+25s | SyncManager 完成 → `state = .completed` | 触发 reload → rawItems=1800 → filteredSorted=1800 → items 仍是前 20（用户没滚 → page=1） | **无感**：当前可视行不变 |
| 用户滚到底 | onAppear 倒数第 3 行 → loadMoreIfNeeded | items 追加 20 | 无重建，平滑追加 |

---

## 3. 改造细节

### 3.1 HomeViewModel 数据流改造

**新增字段**：

```swift
private var filteredSorted: [Repo] = []     // rawItems 经 filter + sort 后的全集
private(set) var items: [Repo] = []          // 语义变化：filteredSorted 的前 currentPage × pageSize 条
private(set) var currentPage: Int = 1        // 当前已展示到第几页
private(set) var hasMore: Bool = false       // 是否还有更多可追加
static let pageSize: Int = 20                // 与 weekly 同款
```

**`applyView()` 拆成两步**：

```text
applyFiltersAndSort()                      → 重算 filteredSorted（rawItems 不变时跳过）
  ├─ statusFilter + hideArchived + hideForks 过滤
  ├─ selectedTagIds OR 过滤（HOM-179）
  ├─ semanticScoreThreshold 过滤（HOM-197）
  └─ sortOption 排序

sliceToCurrentPage(bumpRevision: Bool)     → 切片到 items
  ├─ items = filteredSorted.prefix(currentPage * pageSize)
  ├─ hasMore = filteredSorted.count > items.count
  └─ if bumpRevision { itemsRevision += 1 }
```

**`itemsRevision` bump 策略**（决定流畅度的关键）：

| 触发场景 | currentPage | bump revision |
|---|---|---|
| selection / sort / filter / statusFilter / selectedTagIds / searchQuery 变化 | → 1 | ✅ |
| 同步完成 reloadItems(forceRefresh: true) | → 1 | ✅ |
| 标签状态变化（HOM-179 selectedTagIds） | → 1 | ✅ |
| SWR 后台 fetch 完成且数据相同 | 不变 | ❌（沿用 HOM-46） |
| SWR / forceRefresh 完成但数据变化 + 用户未滚动（currentPage == 1） | → 1 | ✅ |
| **SWR / forceRefresh 完成但用户已滚动（currentPage > 1）** | **不变** | **❌（preserveScrollPosition）** |
| **loadMoreIfNeeded 追加下一页** | currentPage++ | **❌（增量插入保滚动位置）** |

> "preserveScrollPosition" 是 A 与 B 协同的核心：A 触发的 .completed 收尾 reload 如果用户已经手动滚到 page 3，不能强制把他拉回 page 1。

### 3.2 多选 / Cmd+A 改用 filteredSorted

| 入口 | 现状 | 改造后 |
|---|---|---|
| `RepoListView.selectAllShortcutButton`（Cmd+A） | `viewModel.items.map { ... }` | `viewModel.filteredSorted.map { ... }` |
| `RepoListView.onChange(viewModel.itemsRevision) → store.retain` | `viewModel.items.map(\.id)` | `viewModel.filteredSorted.map(\.id)` |

语义对齐："理论可见集合"是用户视图（含过滤排序）下应该可选中的全部，而不是当前 page 切片。

### 3.3 外部跳转：ensureRepoVisible

`SearchCenter` / 详情页"上一篇/下一篇"等外部入口可能选到 page 5 的 repo。

```text
HomeViewModel.ensureRepoVisible(repoId: Int64)
  ├─ if repoId in items → no-op
  ├─ if repoId in filteredSorted at index I:
  │   currentPage = ceil((I+1) / pageSize)
  │   sliceToCurrentPage(bumpRevision: true)
  └─ else → no-op（不在当前过滤集合内，不强行切）
```

`HomeView.onChange(of: viewModel.selectedRepoID)` 在外部赋值路径调用一次。

### 3.4 SyncManager 边沿信号

```swift
// SyncManager.swift
@MainActor @Observable
final class SyncManager {
    /// R-07：首次写入 page 1 后的边沿信号（HomeView 监听）。
    var firstPageWrittenAt: Date?
}

// runSync 内部
try await repository.upsertStarred(dtos, userID: userID, syncedAt: syncStartedAt)
if page == 1 {
    firstPageWrittenAt = Date()  // 边沿触发，HomeView 自然响应
}
```

**触发规则**：
- 全量 / 增量路径 page 1 写完都触发（增量时通常 page 1 就 break，是同一帧的）
- 304 早退路径**不触发**（无新数据，registry 已在 304 路径自己刷过）
- 失败路径**不触发**（throw 跳过赋值）

### 3.5 HomeView 接线

```swift
// HomeView.swift
.onChange(of: syncManager.firstPageWrittenAt) { _, newValue in
    guard newValue != nil, authSession.state.isAuthenticated else { return }
    Task { @MainActor in
        await viewModel.refreshSidebar()
        await viewModel.reloadItems(forceRefresh: true)
    }
}
```

保留现有 `.task(id: syncManager.state)` 的 `.completed` 分支不动 —— 它做收尾的最终全集 reload。

---

## 4. 关键约束 & 风险

| # | 约束 | 处理 |
|---|---|---|
| C1 | `manageMultiSelectionStore.retain` 必须用 filteredSorted | view 层改一行 |
| C2 | Cmd+A 选 filteredSorted 不是 items | 同上 |
| C3 | `loadMoreIfNeeded` 不能走 reloadItems race 防护 | 独立同步方法 `advanceLocalPage()`，不调网络 / DB |
| C4 | selection.didSet 的 eager cache load 命中后要切到 page 1 | `applyView` 重置 currentPage |
| C5 | 详情页 unstar 后 reloadItems 不能抢用户滚动位置 | "preserveScrollPosition" 在 reload 完成后比较 filteredSorted 是否仅"增量增长" |
| C6 | SearchCenter 选中 page N 的 repo 必须能跳到 | `ensureRepoVisible(repoId:)` |
| C7 | HOM-201 hover prefetch modifier 数量 | 自然解决（page 切片后只剩 20 个） |
| C8 | A 的 onChange 在未登录态被触发（理论上 SyncManager 不会跑） | guard `isAuthenticated` 防御 |

---

## 5. 验收标准

### Manage 分页（B）

- [ ] 首屏只渲染 20 行（不论 rawItems 多大）
- [ ] 滚到倒数第 3 行自动追加 20 行，滚动位置不抖动
- [ ] 排序 / 过滤切换：列表瞬切回顶部 page 1，重建只在可视 20 行
- [ ] 切分类（缓存命中）：列表瞬切，与现状一致或更好
- [ ] 详情切换：CPU / 主线程时间对比改造前显著下降
- [ ] SearchCenter 选中外部 repo（page > 1）：自动 ensureRepoVisible + scrollTo
- [ ] Cmd+A 选中 filteredSorted 全集，多选 banner 显示总数正确
- [ ] 详情页 unstar：列表不抢用户滚动位置（preserveScrollPosition 生效）

### 首页边沿（A）

- [ ] 首次登录 1~2s 内看到前 20 条
- [ ] 后续页静默写库无感知（无列表抖动 / 滚动位置丢失 / 入场动画）
- [ ] 同步完成时 sidebar 计数正确更新
- [ ] 304 早退路径不触发 onChange
- [ ] 增量同步 page 1 有新增时正常触发 onChange，新 star 出现在列表顶部
- [ ] 同步失败时不触发 onChange

---

## 6. 改造范围（文件）

| 文件 | 改动 |
|---|---|
| `Starcat/Core/Sync/SyncManager.swift` | +`firstPageWrittenAt` @Observable 字段，page 1 写完后赋值 |
| `Starcat/Features/Home/HomeViewModel.swift` | **核心**：+filteredSorted/currentPage/hasMore/pageSize，applyView 拆分，新增 loadMoreIfNeeded/advanceLocalPage/ensureRepoVisible |
| `Starcat/Features/Home/RepoListView.swift` | row 加 `.onAppear` 触发追加，Cmd+A 与 retain 改用 filteredSorted |
| `Starcat/Features/Home/HomeView.swift` | +`.onChange(firstPageWrittenAt)`，selectedRepoID 外部赋值 → ensureRepoVisible |
| `StarcatTests/HomeViewModelFilterSortTests.swift` | 加分页相关用例 |
| `StarcatTests/SyncManagerTests.swift` | 加 firstPageWrittenAt 触发用例 |

---

## 7. 不做的事

- 不动 GRDB ValueObservation 重构（留作未来 R-XX）
- 不改 `fetchAllStarred` SQL（仍然全量加载到内存，只是 UI 上分页）
- 不做 row 内字典订阅拆分（方案 2，未来优化）
- 不改 weekly / trending / activity 的现有逻辑

---

## 8. R-07.1 follow-up：hasMore false → true 视图层主动 push（2026-06-16）

### 8.1 漏洞描述（dong4j 真机回归发现）

§3.1 bump 策略表第 5 行写「SWR / forceRefresh 完成但用户已滚动（currentPage > 1） | 不变 | ❌（preserveScrollPosition）」、§2.2 表 T+25s 行假设「用户没滚 → page=1 → 无感」——**漏掉一个真实场景**：

**用户在 sync 期间已主动滚动到 items 尾部**：
- 用户登录后看到首页 20 条（firstPageWrittenAt 触发上屏）
- 用户**主动向下滚动**，倒数第 3 行 `.onAppear` × N 触发 `loadMoreIfNeeded()`，currentPage 推到 5
- items 涨到 100（与 `filteredSorted` 等长）→ `hasMore = filteredSorted.count > items.count` = `100 > 100` = **false**
- 此后用户停在第 100 条尾部，SyncManager 继续静默拉 page 2..N

**sync 完成（state = .completed）触发 reloadItems(forceRefresh: true)**：
- `loadFromCache(stale 100 条)` → `applyView(resetPage: true)` 早 return（filteredIdentical = true，**resetPage 在早 return 路径不生效**）
- 后台 fetch DB 全集（1800 条）→ `idsIdentical = (1800 == 100)` false → `applyView(resetPage: false)`
  - `filteredSorted = 1800` ✓
  - `currentPage` 保留 5（preserveScrollPosition）
  - `sliceToCurrentPage(.recompute)` 算 `endIndex = min(100, 1800) = 100`，`newItems` 前 100 条
  - 与现有 `items` 前 100 条按 starred_at desc 同 ID 同序 → **`itemsIdentical = true` → `items` 不变 / `itemsRevision` 不 bump**
  - 但 `hasMore = filteredSorted.count > items.count = 1800 > 100 = true` ✓

**用户视角**：
- 列表 UI 看似数据没变（itemsRevision 不变 → List 不重建）
- `hasMore` 翻 false → true，但**已显示行的 `.onAppear` 不会重触发**（SwiftUI 只在 row 首次进入视口时调 onAppear）
- 用户在第 100 条尾部往下滚 → 橡皮筋回弹 → 永远卡在 100 条，看不到完整 1800 条

### 8.2 修复方案

在 `RepoListView.unifiedListContent(_:)` 的 List 上加 `.onChange(of: viewModel.hasMore)`，监听 false → true 边沿，主动调一次 `viewModel.loadMoreIfNeeded()`：

```swift
.onChange(of: viewModel.hasMore) { wasMore, hasMore in
    guard !wasMore, hasMore else { return }
    Task { @MainActor in
        viewModel.loadMoreIfNeeded()
    }
}
```

**关键约束**：

1. **用 `Task { @MainActor in }` 包一层**：避免在 SwiftUI body 更新期间同步写 `@Observable` 状态触发"Modifying state during view update"警告。`loadMoreIfNeeded` 是同步 `@MainActor` 方法，但 view body 内同步调用 viewModel 写操作有潜在风险，异步派发更稳。
2. **只 false → true 触发**：true → false（用户加载到底）/ false → false（无变化）/ true → true（持续加载）都不动，防止反复触发。
3. **不破坏 R-07 既有 contract**：`loadMoreIfNeeded` 走 `sliceToCurrentPage(reason: .append)` 不 bump `itemsRevision`（R-07 原设计），滚动位置自然保留；用户继续向下滚动时，新行（位置 100-119）入视口后倒数第 3 行的 `.onAppear` 自然触发后续 loadMore，自然推进到 `filteredSorted.count`。
4. **副作用可接受**：首屏 page 1 写入触发 `firstPageWrittenAt` → reloadItems 让 `hasMore` 从 false → true 时也会命中本分支，首屏 items 从 20 → 40 条。首屏视口只显示 ~10 行，用户视觉无感；既有 `.append` 分支不重建已有行，亦无入场动画干扰。

### 8.3 改造范围

| 文件 | 改动 |
|---|---|
| `Starcat/Features/Home/RepoListView.swift` | +`.onChange(of: viewModel.hasMore)` 在 false→true 边沿调 `loadMoreIfNeeded` |
| `StarcatTests/HomeViewModelPaginationTests.swift` | **新增文件**：R-07 基础行为（4 个）+ R-07.1 修复 contract（2 个）共 6 个用例 |

### 8.4 验收

- [x] 新增 6 个单测全绿（4 R-07 基础 + 2 R-07.1 修复 contract）
- [x] 现有 870 测试 0 回归（合计 876 全绿）
- [ ] dong4j 真机回归：清 keychain + DB，重新登录，sync 期间手动滚到 100 条尾部，等 sync 完成，验证：
  - 列表底部能继续往下滚（自动多出 20 条，用户视觉上看到"列表又长了一节"）
  - 继续滚动能自然加载到 1800 条全部
  - sidebar "全部仓库" 计数与 repo 列表底部计数最终一致

### 8.5 长期改进方向（未做，留 P2）

- **SyncManager 增量进度信号**：每写完 N 页（如每 5 页 = 500 条）翻一次中间边沿，让列表逐步增长而非到最后憋一次性追上。优点是 sidebar 与列表的"边沿一致性"更好；缺点是 sync 期间多次刷新增加抖动概率，与 R-07 "page 2..N 静默写库无感知"的设计意图冲突，需要重新平衡。
- **applyView 早 return 路径修复 resetPage**：当前 `applyView(resetPage: true)` 在 `filteredIdentical = true` 时直接 return，`resetPage` 不生效；这是个独立小漏洞（不影响 R-07.1 修复路径），未来如有其它路径依赖"filteredSorted 相同时也要重置 currentPage"再修。

---

## 9. R-07.2 follow-up：DB 分页改为真实 OFFSET 追加（2026-06-22）

### 9.1 问题复盘

dong4j 真机回归发现 Manage 有两个问题：

- 列表已有数据后仍闪一次，像是又刷新了一遍。
- 1800+ stars 滚到底没有加载完，且触底后可能被自动定位回顶部。

根因不是“分页页大小不够”，而是旧 DB 分页实现仍按“累计前缀”工作：

```text
loadMoreIfNeeded
  currentPage += 1
  fetchListPage(limit: currentPage * pageSize + 1)
  items = visibleRows
  itemsRevision += 1
```

这会导致每次触底都重新查询并替换已加载的全部 rows。第 90 页附近不是追加 20 条，而是让 SwiftUI 重新 diff/替换 1800 条左右的数组；如果同时 bump `itemsRevision`，`List.id(itemsRevision)` 会整栏重建，滚动位置也可能丢失。

### 9.2 修正方案

DB 分页路径改为真正的 `OFFSET + LIMIT`：

```text
首次 / 筛选 / 排序：
  fetchListPage(limit: pageSize + 1, offset: 0)
  items = firstPage
  itemsRevision += 1（仅 ID 序列变化时）

滚动触底：
  fetchListPage(limit: pageSize + 1, offset: items.count)
  items.append(nextPage)
  rawItems = items
  filteredSorted = items
  不 bump itemsRevision

同步完成保页刷新：
  fetchListPage(limit: max(pageSize, items.count) + 1, offset: 0)
  若已加载前缀 ID 不变，不 bump itemsRevision
```

关键约束：

1. `RepoRepositoryProtocol.fetchListPage` 新增 `offset` 参数，Repository SQL 追加 `OFFSET ?`。
2. `HomeViewModel.reloadDatabasePagedItems` 拆分 `.reset / .append / .refreshPreservingPage` 三种意图，避免追加和刷新共用同一套“整栏替换”状态写入。
3. DB append 有 `isDatabasePageAppendInFlight` 互斥，防止尾部 row 连续 `.onAppear` 时同一 offset 重复追加。
4. `RepoListView` 仍沿用 R-07 的倒数第 3 行 `.onAppear` 触发方式；ViewModel 侧用 `OFFSET + append` 承接下一页。

### 9.3 验收

- [x] `HomeViewModelPaginationTests`：新增 1856 条一路滚到底用例，验证最终 `items.count == 1856`。
- [x] 同一用例验证所有 append 都不 bump `itemsRevision`，避免滚动过程整栏重建。
- [x] `RepoRepositoryTests`：10k starred repos 首屏查询仍只取 `limit` 行，全集多选继续走轻量 projection。
- [x] `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/HomeViewModelPaginationTests test` 通过。
- [x] `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RepoRepositoryTests test` 通过。
- [x] `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build` 通过。

### 9.4 后续注意

- 普通 Manage DB 分页不要再回退到“累计前缀替换”；触底追加成本必须稳定在单页大小。
- 若后续要进一步优化 10k+ 深分页，可在 Repository 层从 `OFFSET` 升级为 keyset cursor，但 ViewModel 的 append contract 不应再变。
- `filteredSorted` 在 DB 分页模式下只镜像已加载 rows；Cmd+A / 多选全集语义继续使用 `selectionSnapshotsForCurrentQuery()` 的轻量 projection。

---
*最后更新：2026-06-22 01:45（R-07.2 DB 分页 OFFSET append 修正）*
