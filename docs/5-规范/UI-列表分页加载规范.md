# UI 规范：列表分页加载

> **强制，2026-08-28 起生效。**
> 来源：GitHub Issue [#113](https://github.com/starcat-app/Starcat/issues/113) 的全局自动分页修复。
> 实现单一入口：`Starcat/Shared/Components/AutomaticListPagination.swift`。

---

## 目标

Starcat 的交互列表必须在普通滚动、快速滑到底部、筛选后尾部行被隐藏等情况下持续加载下一页，不能要求用户先向上滚动再慢慢回到底部。

本规范统一三类职责：

- View：判断当前可见行是否进入预取窗口，并在列表快照变化后重新评估。
- ViewModel：串行执行 append、维护分页状态、丢弃过期结果。
- Data Source：提供稳定顺序、明确的下一页边界以及可去重的稳定 ID。

## 适用范围

适用于 Starcat macOS App 中所有由用户滚动驱动的增量列表，包括：

- 本地完整数据集的分片分页。
- SQLite / GRDB 的 `limit + offset` 分页。
- REST / GraphQL 的 page、offset 或 cursor 分页。
- `List`、`ScrollView + LazyVStack` 等自动加载列表。

不适用于后台全量同步、离线批处理或必须完整遍历远端 API 的任务；这些流程没有“可见窗口”，应在各自的同步或任务规范中定义并发、重试和断点恢复。独立 `supports/` 仓库的表格页码分页遵循各仓库规则，不能直接套用本规范的滚动触发器。

## 统一术语

| 名称 | 含义 |
|---|---|
| `appearingIndex` | 当前出现行在**过滤后可见数组**中的索引 |
| `visibleItemCount` | 当前已加载数据经过 UI 筛选后实际可见的数量 |
| `loadedItemCount` | 当前查询身份下已经加载到内存或界面的底层数量 |
| `hasMore` | 数据源明确表示仍存在下一页 |
| `isLoading` | 初次加载、刷新、筛选重建或 append 正占用分页通道 |
| `identity` | 查询、筛选、排序、来源等共同组成的列表身份 |
| `prefetchDistance` | 距可见列表尾部多少行时开始预取；全项目固定为 10 |

`prefetchDistance` 是触发距离，不是每页大小。每页大小由数据源与性能要求决定，禁止因为预取距离为 10 就把所有 API page size 强制改成 10。

## 强制规则

### 1. 自动列表只使用共享策略

自动分页行必须使用 `.automaticListPagination(...)`，禁止新增页面自行编写 `.onAppear` 加 `count - N`、`suffix(N)` 或“最后一行出现”判断。

```swift
ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
    row(item)
        .automaticListPagination(
            appearingIndex: index,
            visibleItemCount: visibleItems.count,
            loadedItemCount: viewModel.items.count,
            hasMore: viewModel.hasMore,
            isLoading: viewModel.isLoading || viewModel.isLoadingMore,
            identity: queryIdentity
        ) {
            await viewModel.loadMoreIfNeeded()
        }
}
```

共享策略统一在剩余 10 个可见项时预取。任何页面不得复制 `10` 或另设相近阈值；确有产品差异时，先修改本规范并说明理由，再调整共享策略。

### 2. 索引与数量必须使用同一坐标系

`appearingIndex` 和 `visibleItemCount` 必须同时来自过滤后的 `visibleItems`。不能用过滤后行的索引与未过滤 `items.count` 比较，否则尾部行被筛掉时会永久失去触发机会。

`loadedItemCount` 必须反映底层成功加载后的快照数量。它与 `visibleItemCount` 可以不同，不能为了参数省事无条件传同一个值。

### 3. 快速滚动期间的需求不能丢失

行在 append 或刷新期间出现时，`isLoading` 可以阻止重复请求，但不能把这次需求永久丢弃。共享 modifier 会观察列表身份、可见数量、已加载数量和 `hasMore`；成功 append 形成新快照后，已经出现的尾部行必须重新参与判断。

调用方必须保证：

- 成功 append 后更新 `loadedItemCount`；如果服务端只返回重复项，则必须继续推进权威 next token，或在数据耗尽时更新 `hasMore`。
- `isLoading` 覆盖所有会占用同一分页通道的状态。
- 不用一次性 `onAppear` 代替共享 modifier。

失败时不能伪造新的 `loadedItemCount`。这样共享触发器不会因失败不断自启动，形成无上限重试循环。

### 4. 筛选后不足可见窗口时主动补页

当全局筛选可能隐藏当前已加载页的尾部行时，没有 row 能触发下一页。此类列表应在容器上增加 `.automaticListPaginationFill(...)`：

```swift
.automaticListPaginationFill(
    visibleItemCount: visibleItems.count,
    loadedItemCount: viewModel.items.count,
    hasMore: viewModel.hasMore,
    isLoading: viewModel.isLoading || viewModel.isLoadingMore,
    identity: queryIdentity
) {
    await viewModel.loadMoreIfNeeded()
}
```

该兜底只允许用于以下情况之一：

- 底层是本地完整数据集或数据库分页。
- 远端总量有限且有明确的最大自动补页边界。
- 产品明确允许为了填满窗口继续请求。

对于规模未知或可能无限增长的远端数据，禁止为了寻找筛选匹配项自动遍历全部页面；应把筛选下推到服务端、设置自动补页上限，或提供显式“加载更多”。

### 5. View 与 ViewModel 双层防重入

共享 modifier 的 `isLoading` 是 UI 第一层防护；ViewModel 仍必须用自己的 append 状态防止竞态。任何自动或手动入口都应汇入同一个 `loadMoreIfNeeded`，同一列表同一时间最多执行一个 append。

```swift
@MainActor
func loadMoreIfNeeded() async {
    guard hasMore, !isLoading, !isLoadingMore else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }

    // 获取并验证当前 query identity 后再 append。
}
```

不能依赖网络层“通常不会重复”或 SwiftUI “通常只触发一次”。

### 6. 列表身份变化必须重置分页

`identity` 至少覆盖会改变结果集合或顺序的条件：

- 搜索词与全局筛选。
- 分类、标签、语言、来源、分段。
- 排序字段与排序方向。
- 登录账号、数据库 scope 或远端环境。

身份变化时必须取消或废弃旧请求，并重置 page / offset / cursor、`hasMore`、错误态和已加载结果。旧身份返回的数据不得 append 到新列表。

推荐使用不可变 query identity 或 generation token，在请求返回后再次校验：

```swift
let requestedIdentity = queryIdentity
let page = try await repository.fetchNextPage(...)
guard requestedIdentity == queryIdentity else { return }
append(page)
```

`identity` 不得只由 `items.count` 构成，也不得包含 `isLoading` 等瞬时状态；否则会产生无意义重评估或跨查询串页。

### 7. 下一页边界必须由数据源明确表达

`hasMore` 不能靠 UI 猜测：

- Cursor API：以服务端返回的 `nextCursor` / `endCursor` 为准。
- Page API：优先使用服务端 `nextPage` / `total`；只有 API 契约明确时才能用“返回量等于 page size”推断。
- Offset / 数据库：以稳定查询下的总量、额外一条探测或返回页边界为准。
- 本地分片：`visiblePrefixCount < source.count`。

空页、短页或明确没有 next token 时应及时把 `hasMore` 置为 `false`。数据耗尽后，任何触发器都必须成为幂等 no-op。

### 8. Append 必须稳定、可去重、可丢弃过期结果

- 所有页必须使用确定性排序；数据库分页的排序字段相同时必须补稳定 tie-breaker，例如唯一 ID。
- 新页按稳定 ID 去重，但不能打乱已有顺序或整段替换已经展示的前缀。
- 能尾部 `append(contentsOf:)` 时不要随着滚动深度反复重建 `prefix(page * pageSize)`。
- 请求返回后先验证 query identity / generation，再修改 page、cursor、items 和 `hasMore`。
- page、offset 或 cursor 只在成功接纳该页后推进；失败不能跳页。

### 9. 错误与重试必须可控

自动 append 失败后应停止自动重试，并保留当前已加载内容。页面按现有交互显示紧凑错误提示或显式重试入口；手动重试仍调用同一个 `loadMoreIfNeeded`。

禁止：

- 失败后立即递归调用下一次加载。
- 通过反复修改 revision、identity 或 `loadedItemCount` 诱发自动重试。
- 因追加页失败清空已经成功展示的列表。

### 10. 手动“加载更多”入口可以保留

显式“加载更多”按钮、辅助功能入口和 Smart Collections 已有的双触发机制不要求删除，但必须与自动触发共享同一 ViewModel 状态机和防重入逻辑。按钮不能维护第二套 page / cursor。

## 状态流转

```text
idle
  ├─ 尾部进入 10 行窗口 / 可见窗口不足 / 手动点击
  ▼
appending
  ├─ 成功且有下一页 → append → 更新快照 → idle → 重新评估
  ├─ 成功且数据耗尽 → append → hasMore=false → exhausted
  ├─ 失败             → 保留当前内容 → failed（等待显式重试）
  └─ identity 已变化  → 丢弃旧结果 → 新 identity 的 idle
```

`appending` 期间到达的多个触发只表示“当前窗口仍需要更多数据”，不能启动多个请求。成功更新快照后的重新评估承担需求保留，不需要额外排队多个相同 page。

## 性能约束

- `ForEach` 需要索引时，对当前可见数组一次性 `enumerated()`；禁止每一行调用 O(n) 的 `firstIndex`。
- 长列表使用 `List` 或 lazy 容器，不能一次渲染完整数据集。
- append 的计算量应尽量保持为一页规模，不能随已滚动深度线性放大。
- 本地筛选和排序若必须作用于完整集合，应在 ViewModel 中缓存结果，避免每个 row 重算。
- 加载指示器只表达状态，不能成为唯一分页触发器。

## 反例

```swift
// ❌ 快速滚动时 onAppear 可能恰好发生在 isLoading=true，需求会被永久丢弃。
.onAppear {
    guard !viewModel.isLoading else { return }
    if index >= items.count - 3 {
        viewModel.loadMore()
    }
}
```

```swift
// ❌ filteredIndex 与未过滤 items.count 不在同一坐标系。
if filteredIndex >= items.count - 10 {
    loadMore()
}
```

```swift
// ❌ 自动入口和按钮各自推进 page，可能重复或跳页。
automaticPage += 1
manualPage += 1
```

## 测试要求

新增或调整分页列表时，至少覆盖与改动相关的以下边界：

1. 剩余 10 行触发，剩余 11 行不触发。
2. 短列表、空列表、非法索引和 `hasMore=false` 不越界。
3. 行在请求进行中出现，成功 append 后能重新评估。
4. 连续多个触发最多产生一个并发 append。
5. 筛选后 0～9 个可见项能按边界补页；达到 10 个或耗尽后停止。
6. query / filter / sort / source identity 变化后重置分页并丢弃旧响应。
7. 失败不跳页、不清空当前内容、不形成自动重试循环。
8. 重叠页面按稳定 ID 去重且保持顺序。
9. 空页、短页和 next token 缺失能正确结束。

涉及共享策略时，必须运行 `ListPaginationPolicyTests`；涉及具体 ViewModel 时，再运行对应分页测试。发布或验收前还需在 macOS 上人工验证至少一种本地分片、数据库分页和远端分页列表的快速滑底行为。

## 参考实现

- `Starcat/Shared/Components/AutomaticListPagination.swift`
- `Starcat/Features/Home/RepoListView.swift`
- `Starcat/Features/Activity/ActivityView.swift`
- `Starcat/Features/Explore/ExploreView.swift`
- `StarcatTests/ListPaginationPolicyTests.swift`

## 提交前自检

```bash
# 新增自动分页不应再自定义尾部 onAppear 阈值。
rg -n '\.onAppear|count\s*-\s*[0-9]+|suffix\(' --type swift Starcat/Features/

# 自动分页入口应复用统一组件或统一策略。
rg -n 'automaticListPagination|ListPaginationPolicy' --type swift Starcat/ StarcatTests/
```

逐项确认：索引坐标系一致、identity 完整、ViewModel 防重入、旧请求可丢弃、失败不会自动循环、`hasMore` 有权威来源。
