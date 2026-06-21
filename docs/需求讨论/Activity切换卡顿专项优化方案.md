# Activity 切换卡顿专项优化方案

> 创建时间：2026-06-21
> 状态：实施中
> 目标：消除从 Manage / Trending 切到 Activity 时的主线程卡顿和彩虹圈，优先保证流畅度，必要时用空间换时间。

## 1. 问题定义

当前现象：

- 从 Manage 切到 Activity 时体感比优化前更卡。
- 严重时出现 macOS 彩虹圈，说明主线程存在较长时间阻塞。
- 用户明确要求不是小修小补，而是按大数据量场景一次性压住卡顿。

本专项只处理 Activity 切换与 Activity 本地聚合列表性能，不继续扩大 Manage 改造范围。

## 2. 设计原则

1. 首屏优先：切到 Activity 后应先用本地轻量数据快速显示首屏。
2. 主线程预算优先：`makeItems`、去重、排序、过滤、网络补齐、cleanup 不能阻塞 SwiftUI 首帧。
3. 查询优先于内存全量派生：大数据量下不依赖“先取全量再过滤”。
4. 空间换时间：如现有聚合仍卡，允许引入 `activity_feed_items` 物化表。
5. 行为不漂移：Activity 分类、排序、详情跳转、weekly 独立路径不改 UI 语义。

## 3. 分阶段方案

### Phase 1：打点与主线程避让

- 增加 Activity 切换链路打点：
  - `ensureLoaded` 入口
  - prime cache
  - 本地四路读
  - `makeItems`
  - category filter
  - first slice commit
- 把重 CPU 的 `makeItems` 从 `@MainActor` 同步路径搬到后台任务，主线程只做最终小批量 commit。
- 确保 prime 首屏不会被后续相同数据重复 publish。

验收：

- ActivityViewModelTests 通过。
- build 通过。
- 日志能看出切页耗时分布。

### Phase 2：Activity 本地 feed 查询化

- 若 Phase 1 后仍有明显卡顿，新增查询层：
  - 按分类直接读取当前页 feed row。
  - `.all` 只做 SQL/轻量数组 merge 的分页结果，不做全量 `allItems` 现场过滤。

验收：

- 10k feed fixture 下首屏只加载 `pageSize + 1`。
- 分类切换不触发全量 make/filter。

### Phase 3：物化表

- 若查询化仍不足，新增 `activity_feed_items` 物化表。
- releases / events / announcements / repo-backed activity 写入或刷新后同步维护 feed rows。
- Activity 首屏只查 feed table。

验收：

- 切 Activity 不依赖 starred repo 全表扫描。
- `.all` / `.release` / `.announcement` / `.following` 分类分页结果稳定。

## 4. 当前实施记录

- 2026-06-21：专项文档创建。下一步先做 Phase 1，增加打点并把 Activity 聚合计算移出主线程。
- 2026-06-21：Phase 1 已实施第一轮。
  - 关键改动：
    1. `ActivityViewModel.buildItems(from:reason:)` 统一承接 Activity 聚合组装，并通过 `Task.detached(priority: .userInitiated)` 把 `makeItems` 从 MainActor 同步路径移出。
    2. `makeItems` 及其 builder（announcement / release / star / repository / following / suggestion）改为 `nonisolated static`，避免后台组装时隐式回到 MainActor。
    3. ActivityViewModel 内会修改 `@Observable` 状态的内部 `Task` 显式标注 `@MainActor`，避免异步恢复点漂移到后台线程。
    4. DEBUG 下记录 `makeItems` 输入规模、输出条数与耗时，便于继续判断是否需要 Phase 2 查询化。
    5. Activity 常量标注 `nonisolated static let`，消除后台纯函数读取常量时的 actor 隔离警告。
  - 验证：
    - `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/ActivityViewModelTests test`：通过，29 tests。
    - `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build`：通过。
  - 观察：
    - `ActivityViewModelTests` 运行期间仍出现过 SwiftUI 的 `Publishing changes from background threads is not allowed` 日志；显式 `@MainActor` 后仍存在，出现时点靠近测试 fixture 切换，暂未确认是 Activity 本轮改动、测试宿主全局状态，还是既有后台任务残留。后续若真实切页仍卡或日志持续出现，需要单独开线程发布专项排查。
  - 下一步判定：
    - 如果真实 App 内 Manage ↔ Activity 切换仍有彩虹圈，进入 Phase 2：把 Activity feed 查询改成按分类/分页直接读取，减少 SwiftUI 侧一次性 diff 和全量 `allItems` 缓存。
- 2026-06-22：Phase 2 先落地一项低风险分页优化。
  - 问题：
    - `ActivityViewModel.loadMoreIfNeeded()` 原先每次滚到底都用 `Array(source.prefix(page * pageSize))`
      重建完整已加载前缀。数据量不大时可接受，但页数越深，单次 loadMore 的复制成本越高，
      也更容易让 SwiftUI 把它当作整段 replacement。
  - 改动：
    1. 新增 `nextPageSlice(from:alreadyVisibleCount:)`，每次只取下一页。
    2. `loadMoreIfNeeded()` 改为 `items.append(contentsOf:)`，不重建前缀、不 bump `itemsRevision`。
    3. 保持现有 UI、分类、排序和 `hasMoreItems` 语义不变。
  - 验证：
    - 新增 `ActivityViewModelTests.followingPaginationAppendsWithoutReplacingPrefix`，覆盖 60 条 following 数据下：
      首屏 30 条，append 后 60 条，第一页 ID 前缀不变，`itemsRevision` 不变。
    - `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/ActivityViewModelTests test` 通过。
