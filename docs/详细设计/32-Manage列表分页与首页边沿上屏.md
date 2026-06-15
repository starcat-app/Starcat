# Manage 列表客户端分页 + 首次登录第一页上屏（R-07）

> **状态**：📝 方案冻结（2026-06-15 22:30），待实施
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

*最后更新：2026-06-15 22:30（方案冻结，待实施）*
