# Repo List 切换性能优化 Checklist

> 状态：实施中（27 / 35 项完成）
>
> 范围：优化 Starred / Manage、Explore（趋势、周刊、发现、热门、新发布）与 Activity 的模块切换、分类切换和首屏 Repo List 上屏链路；不改变列表业务语义，不在首轮引入 AppKit 列表容器或数据库 schema 变更。

## 成功标准

- 缓存分类切换从点击到首个可交互列表帧的 p95 不高于 100ms。
- 本地无缓存分类首批 20 / 40 条上屏 p95 不高于 250ms。
- 同一次查询身份只允许一个有效 generation 发布列表结果；取消的旧任务不得覆盖新分类。
- 用户未滚动时，分类首屏不得因为自动预取从 40 条快速变成 80 条并触发第二次列表发布。
- Repo List 首屏关键路径不执行 Wiki JSON 文件 I/O，不等待 README、Health、OpenSSF 或详情页加载。
- Instruments 的 Animation Hitches 中不出现超过 100ms 的切换卡顿，贡献草坪贪食蛇无肉眼可见停顿。
- 相关定向单测、两个 App scheme 编译、本次相关文件 `git diff --check` 通过；真实交互由人工完成最终体验验收。

## 第一阶段：基线与观测

- [x] 盘点 Manage、Explore、Weekly、Activity 的点击事件、状态路由、缓存、查询、发布和详情联动路径。
- [x] 使用真实用户数据库核对表规模、分页查询、排序计划和裸 SQLite 查询耗时。
- [x] 核对分类切换日志，确认存在同一 selection 的重复 `reloadItems` 请求与 40 → 80 二次发布。
- [x] 采样空闲态主线程，确认问题是切换触发的瞬时主线程压力，而不是持续后台死循环。
- [x] 新增稳定的 `ReloadReason`、查询 generation 和 query identity 日志。
- [x] 用 `OSSignposter` 覆盖 route、cache、DB、派生计算、首次 publish 和完成边界。
- [x] 为 DEBUG 构建补充低开销主线程 stall 观测，记录超过 50ms / 100ms 的事件。

## 第二阶段：请求去重与发布收敛

- [x] 统一 Manage 列表 reload 协调入口，避免 `currentReloadTask` 与 `currentListActionTask` 交叉覆盖。
- [x] 相同 query identity 的并发请求合并；新 generation 启动时取消旧 generation。
- [x] 所有发布点在提交状态前校验 generation、selection 与 query identity。
- [x] 移除普通分类首屏 `hasMore false → true` 自动追加第二页；仅保留真实滚动和首次同步专用边沿。
- [x] 缓存命中且数据身份未变化时，不重建 List、不重复 row reveal、不重置详情选择。

## 第三阶段：首屏关键路径瘦身

- [x] 建立进程内 Wiki availability 快照索引，在后台完成文件读取与 JSON decode。
- [x] Manage / Trending / Discovery / Weekly / Activity 的 View body 和 MainActor 过滤不再调用同步 `DiskWikiCache.load`。
- [x] Manage 分页的 status map 与 library map 改为并行或单次批量读取。
- [x] Discovery / Trending / Weekly 入场不再先等待全量 Library map 才发起 repo 查询。
- [x] OpenSSF 与 Health cache 并行加载，并延后到列表首次 publish 之后。
- [x] 自动打开首条详情时，将 README / WebView 等详情工作延迟到列表首帧之后。

## 第四阶段：SwiftUI 观察与渲染边界

- [x] DEBUG 日志不再让非 Manage 页面订阅 `HomeViewModel.items/itemsRevision`。
- [x] Manage 数据库分页只对首批 40 条走稳定 identity diff，不因普通分类切换强制销毁整个 List。
- [x] 全量 Smart Collection 排序与分页场景保留独立快照策略，避免几千行 move diff 回归。
- [x] row reveal 只覆盖首屏有限行，并且同一用户切换最多执行一次。
- [ ] 将 Repo List、toolbar、详情 tint 与附属 badge 的观察范围拆到最小消费者。

## 第五阶段：模块生命周期与数据路径

- [x] Explore 父层持有 Trending 与 Weekly 的持久 ViewModel，模块回切不重新创建事实源。
- [x] 发现 / 热门 / 新发布只在 query identity 真实变化时重跑本地 filter / sort。
- [x] Activity 保持聚合缓存 + 本地 refilter 快路径，不把其他模块的重建策略反向套入。
- [ ] Smart Collections、用户智能集合和搜索分别建立性能基线，不用普通 Manage SQL 分页指标代替。

## 第六阶段：测试与验收

- [ ] 单测锁定同一 query identity 只发布一个有效 generation。
- [x] 单测锁定首屏 `hasMore=true` 不会自动追加第二页。
- [ ] 单测锁定被取消的旧分类查询不能覆盖新分类。
- [ ] 单测锁定 Wiki availability 批量读取不在 MainActor 执行同步文件 I/O。
- [ ] 运行 Manage / Explore / Weekly / Activity 相关定向 Suite。
- [ ] 关闭 Xcode 后运行全量测试，或记录无法执行的明确外部阻塞。
- [x] 编译 `Starcat` 与 `StarcatDirect`，执行相关文件 `git diff --check`。
- [ ] 按固定切换脚本完成 Instruments 与人工 UI 验收，记录 p50 / p95 与最大主线程 stall。

## 固定验收脚本

1. Starred：`全部 Star → 未分类 → 知识库 → 全部 Star`，分别覆盖缓存命中与首次进入。
2. Starred：启用 / 关闭 Wiki、Health、OpenSSF 筛选后重复上述切换。
3. Explore：`趋势 → 周刊 → 发现 → 热门 → 新发布 → 趋势`。
4. Explore：发现 / 热门 / 新发布分别切换语言、排序和高级筛选。
5. Activity：`全部 → Star → Release → 公告 → 关注 → 全部`。
6. 每轮同时观察 Repo List、右侧详情、同步图标与贡献草坪贪食蛇，确认列表首屏阶段没有附属任务抢占主线程。

## 本轮自动验证记录（2026-07-18）

- `xcodegen generate`：通过，新文件已进入工程。
- `Starcat` / `StarcatDirect`：使用独立 DerivedData 与既有 SPM checkout 编译通过。
- `build-for-testing`：通过；仅出现既有 `KnowledgeRAGCoreTests` actor isolation warning。
- `git diff --check`：通过。
- 定向 / 全量测试：当前 Xcode IDE 仍在运行（PID 61723），按仓库约束未与 IDE 抢占 `testmanagerd`；保持待执行，不伪造完成。

## 明确不在首轮范围

- 改用 `NSTableView` / `NSCollectionView`。
- 为性能优化直接修改已发布 migration 或要求用户删库重建。
- 改变 Discovery / Trending / Weekly 的服务端排序、候选生成或产品内容语义。
- 以隐藏 loading、延长动画或降低刷新频率掩盖真实延迟。
