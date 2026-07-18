# Repo List 切换性能优化 Checklist

> 状态：实施中（42 / 60 项完成）
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

## 2026-07-19 最终方案：三模块会话缓存与分类快照

### 1. 本轮确认的问题

- Explore 与 Activity 的 ViewModel 目前由条件分支内的子 View 持有。离开模块后实例会被销毁，模块内已有的内存缓存也随之丢失；再次进入时仍会重新创建 ViewModel、读取本地缓存、派生列表并发布首屏。
- Manage 的 `HomeViewModel` 生命周期稳定，但常用数据库分页分类没有完整的“分类首屏快照”。切回分类时仍可能重新执行本地查询并补齐 status / library map。
- 发现、热门、新发布复用了同一份 Discovery bulk 原始数据，但每次查询身份变化仍会重新过滤、排序；缓存的是事实源，不是已经准备好的列表结果。
- Trending 按 query identity 保存原始快照，但命中后仍会重新执行排序、过滤、评分和推荐派生。
- Weekly 的 bulk 本地筛选、排序仍存在 MainActor 同步路径，数据量上升后会直接占用主线程预算。
- Activity 已有按分类的 `filteredItemsCache`，但其生命周期只覆盖当前 `ActivityView`；跨模块切换后缓存失效。Activity 分类切换又刻意不 bump `itemsRevision`，导致现有 row reveal 无法重放。
- Activity 当前动画 index 使用 repo ID 哈希映射到 `0...13`，既不代表真实列表顺序，也会让 15 行以后的卡片继续进入动画逻辑，无法满足“仅首屏前 15 张”的产品要求。

### 2. 用户体验契约

| 场景 | 目标行为 |
|---|---|
| 缓存命中 | 选中状态先切换；下一次列表提交直接发布缓存快照，不展示骨架屏；前 15 张卡片播放一次入场动画。 |
| 缓存过期但可用 | 立即展示旧快照，刷新图标进入刷新态；后台完成 SWR，成功后静默替换，失败则保留旧快照。 |
| 首次进入且无缓存 | 先完成模块 / 分类选中，再仅在 Repo List 区域展示骨架屏；首屏准备完成后发布数据并播放前 15 张卡片动画。 |
| 手动刷新 | 保留当前卡片，只显示刷新状态；不回退骨架屏、不重放整批卡片动画。 |
| 加载更多 | 只追加下一页，不替换已显示前缀、不 bump 分类入场动画版本。 |

### 3. 状态所有权

- 在 Repo List 窗口会话层持有 Explore 与 Activity 的长期 ViewModel；`ExploreView`、`ActivityView` 改为接收稳定实例，不再自行创建模块事实源。
- Manage 继续复用现有 `HomeViewModel`，不再额外创建第二套 Manage 状态。
- 只持有数据、查询状态与快照缓存，不把三个完整 SwiftUI 模块同时隐藏在 `ZStack` 中，避免不可见 View 的 task、Observation 和动画继续消耗资源。
- 用户切换、数据库切换或退出登录时，窗口会话统一取消旧任务并清空三个模块的内存状态，禁止跨用户复用快照。

### 4. 分类快照设计

| 模块 | Cache Key | 快照内容 | 初始容量策略 |
|---|---|---|---|
| Manage | selection + sort + 全局筛选 + 临时筛选 + 数据修订版本 | 首屏 40 条 Repo、total、hasMore、分页位置、status map、library map | 最近使用 24 项 LRU |
| Discovery | mode + language / topic / platform + sort + 数据修订版本 | 已过滤并排序的完整派生数组、首屏 20 条、total、nextPage、summary | 每个事实源最近使用 12 项 LRU |
| Trending | period + language + sort + 全局筛选 + 推荐上下文 + 数据修订版本 | 已排序、过滤、评分和推荐完成的 prepared snapshot | 最近使用 12 项 LRU |
| Weekly | source + coverage + language + sort + 归档 / fork / stars / recency 筛选 + 数据修订版本 | 已过滤排序结果、首屏、total、hasMore | 最近使用 12 项 LRU |
| Activity | category + category sort + 聚合修订版本 | 每个固定分类的完整过滤结果、首屏、分页状态和分类计数 | 固定分类全部保留 |

约束：

- 缓存保存数据快照，不缓存 `View`、`UnifiedRepoRow` 或其他 SwiftUI 节点。
- TTL 只判断“是否需要后台刷新”，不决定“能否立即展示”。非正确性失效场景允许 stale snapshot 先上屏。
- 账号和数据库切换属于正确性边界，必须硬失效，不允许 stale-while-revalidate。
- 任意后台结果发布前继续校验 generation、query identity 与 source revision，取消的旧任务不得覆盖新分类。

### 5. 缓存失效矩阵

| 事件 | 失效范围 | UI 处理 |
|---|---|---|
| 登录、退出、切换 GitHub 用户、切换数据库 | 三模块全部内存快照与进行中任务 | 清空后按首次进入处理 |
| Stars 全量 / 增量同步、Star / Unstar | Manage 中依赖 Star 成员关系的分类快照 | 当前分类保留到新数据提交；Explore / Activity 仅局部更新 StarredRegistry 展示状态 |
| 标签增删、Repo 标签关系变化 | Manage 的 tag、untagged 及依赖标签的 Smart Collection | 精准提升 tag revision，不清空 Explore / Activity 事实源 |
| GitHub Stars List 成员变化 | 目标 list、ungrouped 及相关 Manage 快照 | 当前列表静默刷新，不触发整窗重建 |
| 阅读状态、笔记、知识库状态变化 | 先局部 patch 可见 metadata；仅当字段参与筛选 / 分类归属时失效对应派生快照 | 不重放列表入场动画 |
| Discovery / Trending / Weekly / Activity 拉到新事实源 | 只提升对应 source revision，并淘汰该事实源的旧派生快照 | 保留旧首屏直到新快照准备完成 |
| 切换分类、语言、Topic、平台、排序、筛选 | 生成新的 query key，不主动删除旧 key | 切回旧条件时允许直接命中 |
| 手动刷新失败、网络不可用 | 不删除最后一次成功快照 | 展示缓存警告，列表保持可用 |
| 内存压力或超过容量 | 按模块独立 LRU 淘汰最久未访问项 | 被淘汰分类下次按 miss 处理 |

### 6. 主线程与视图树边界

- Discovery、Trending、Weekly、Activity 的全量过滤、排序、评分、推荐和去重在后台 task / actor 中完成；MainActor 只提交已经准备好的首屏值和少量状态。
- Weekly 当前同步 `applyFiltersLocally` 路径改为可取消的后台派生，并在发布前校验查询身份。
- 缓存命中不得再次执行数据库查询、全量过滤或排序；只做轻量快照提交。
- Repo List 的分类动画不再依赖整个 `List.id` 变化。`List` 宿主保持稳定，数据列表使用稳定 repo identity 做 diff，动画使用独立 revision。
- Wiki、README、OpenSSF、Health、详情自动选择继续在首屏发布后异步补齐，不进入首屏缓存命中预算。

### 7. 卡片动画统一规则

- Manage、Discovery、Trending、Weekly、Activity 统一以“用户完成一次模块 / 分类导航，并且目标快照已经提交”为动画触发边界。
- Activity 新增独立 `rowRevealRevision`，不再复用 `itemsRevision`；分类切换命中缓存同样可以重放入场动画，但刷新和分页不触发。
- Activity 通过 `enumerated()` 使用真实可见顺序，严格只有 index `0...14` 的前 15 张卡片 / 活动行参与动画，第 16 张起直接展示。
- 继续复用 `listRowReveal(... replayAfterSnapshotCommit: true)` 的提交后启动能力，并遵守 macOS“减少动态效果”设置。
- 动画只作用于 Repo List 行，不通过重建根窗口、Sidebar、toolbar 或详情区实现。

### 8. 性能验收门槛

- `Manage → Explore → Activity → Manage` 重复第二轮时，命中窗口会话缓存的模块不展示骨架屏，不重新创建事实源 ViewModel。
- 分类 `A → B → A` 命中 prepared snapshot 时，不出现数据库查询、全量 filter / sort 或网络请求 signpost。
- 缓存命中从点击到首个可交互列表帧 p95 不高于 100ms；MainActor 单次 Repo List 发布目标不超过一个 16.7ms 帧预算。
- Activity 每个分类严格只有前 15 行播放一次动画；第 16 行、分页追加、后台刷新和 metadata 局部更新不播放。
- Repo List 准备期间，贡献草坪贪食蛇与骨架 shimmer 持续运行，无肉眼可见停顿。
- 自动验证只覆盖可观测的单元测试、定向 Suite、编译与 `git diff --check`；动画连续性和主窗口体感继续由固定短时 UI / Instruments 脚本人工验收，不以长时间无人值守运行代替。

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
- [x] 将 Repo List、toolbar、详情 tint 与附属 badge 的观察范围拆到最小消费者。

## 第五阶段：模块生命周期与数据路径

- [x] Explore 父层持有 Trending 与 Weekly 的持久 ViewModel，模块回切不重新创建事实源。
- [x] 发现 / 热门 / 新发布只在 query identity 真实变化时重跑本地 filter / sort。
- [x] Activity 保持聚合缓存 + 本地 refilter 快路径，不把其他模块的重建策略反向套入。
- [x] Smart Collections、用户智能集合和搜索分别建立性能基线，不用普通 Manage SQL 分页指标代替。

## 第六阶段：主线程预算与稳定视图树

- [x] Trending 按 query identity 保留进程内快照；相同分类回切不清空列表、不重读缓存、不重新展示骨架。
- [x] Trending 周期 / 语言变化统一走单一查询协调入口，移除 property observer 与 View task 的重复 reload。
- [x] Trending 的排序、筛选、评分和 identity 派生移出 MainActor，主线程只提交不可变首屏快照。
- [x] Trending SwiftUI 首屏只构造 20 条，后续页面仅由真实滚动追加，不再同帧构建完整榜单。
- [x] Trending loading 改为稳定 List surface 内局部覆盖，加载态与内容态切换不销毁整个列表宿主。
- [x] Explore 分类切换默认跳过 row reveal，并把详情选择、Wiki、Health、OpenSSF 延后到首个列表帧之后。
- [x] Discovery 全量候选的本地 filter / sort 移出 MainActor，只向 UI 发布当前查询的首批 20 条稳定快照。
- [x] 拆分 Home / RepoList / Explore 的观察边界，避免 list、toolbar、tint、detail 与根层 AnyView 因单个列表状态共同重算。

> 2026-07-19 范围澄清：第五、六阶段的“持久 ViewModel / 进程内快照”只覆盖 `ExploreView` 存活期间，尚未覆盖 Manage / Explore / Activity 跨模块切换；“默认跳过 row reveal”也是上一轮防卡顿策略。第八至十一阶段将其升级为窗口会话级状态，并以本文件“用户体验契约”和“卡片动画统一规则”为最终准则。

## 第七阶段：测试与验收

- [x] 单测锁定同一 query identity 只发布一个有效 generation。
- [x] 单测锁定首屏 `hasMore=true` 不会自动追加第二页。
- [x] 单测锁定被取消的旧分类查询不能覆盖新分类。
- [x] 单测锁定 Wiki availability 批量读取不在 MainActor 执行同步文件 I/O。
- [x] 运行 Manage / Explore / Weekly / Activity 相关定向 Suite。
- [x] 关闭 Xcode 后运行全量测试，或记录无法执行的明确外部阻塞。
- [x] 编译 `Starcat` 与 `StarcatDirect`，执行相关文件 `git diff --check`。
- [ ] 按固定切换脚本完成 Instruments 与人工 UI 验收，记录 p50 / p95 与最大主线程 stall。

## 第八阶段：窗口会话级状态持有

- [ ] 在 Repo List 窗口会话层建立稳定的 Explore / Activity 状态所有者，不持有不可见模块的完整 View 树。
- [ ] ExploreView 改为注入持久的 Discovery / Trending / Weekly ViewModel，跨模块回切不重新创建事实源。
- [ ] ActivityView 改为注入持久的 ActivityViewModel，保留聚合快照、分类过滤缓存与分页状态。
- [ ] 用户 / 数据库切换时统一取消三模块旧任务并清空窗口会话缓存，增加跨用户隔离测试。

## 第九阶段：模块与分类 prepared snapshot

- [ ] Manage 为数据库分页分类增加 query-keyed 首屏快照，缓存命中同步发布 40 条与可见 metadata。
- [ ] Discovery 为发现 / 热门 / 新发布增加派生结果缓存，命中时不再重新 filter / sort bulk。
- [ ] Trending 缓存 prepared snapshot，命中时不再重新执行排序、过滤、评分与推荐派生。
- [ ] Weekly 建立完整筛选身份快照，并把 bulk 本地过滤、排序移出 MainActor。
- [ ] Activity 保留全部固定分类的过滤结果；分类命中只提交首屏 slice，不重新聚合事实源。
- [ ] 为各模块接入独立有界 LRU 与 source revision，锁定容量和淘汰行为。

## 第十阶段：失效、SWR 与稳定视图树

- [ ] 接入 Stars、标签、GitHub Stars List、状态、知识库、各远端事实源更新的精准 revision 失效矩阵。
- [ ] 统一 stale-while-revalidate：stale 先上屏，成功静默替换，失败保留最后成功快照；账号 / 数据库切换必须硬失效。
- [ ] 手动刷新保留当前列表，只显示刷新状态；分页追加和 metadata patch 不触发分类入场动画。
- [ ] 移除分类动画对整个 `List.id` 重建的依赖，验证排序变化、Smart Collection 与稳定 repo identity 无回归。

## 第十一阶段：Activity 动画与专项验收

- [ ] Activity 使用独立 row reveal revision 与真实 enumerated index，所有分类严格只动画前 15 行。
- [ ] 统一 Manage / Explore / Activity 的“快照提交后动画”语义，并锁定 reduce motion、缓存命中、刷新、分页边界。
- [ ] 增加分类缓存、精准失效、旧 generation 防覆盖、前 15 行动画边界测试，并完成固定短时 UI / Instruments 验收。

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
- Trending 同 query 合并、旧 generation 防覆盖、首屏分页与 Discovery bulk 复用测试已新增并通过。
- 系统 / 用户 Smart Collection、关键字 / 语义搜索已建立四条完整刷新 signpost；Trending 排序、全局筛选、评分、推荐与 identity 已统一由后台 actor 派生。
- Trending 定向 Suite 25 个测试通过，新增全局筛选组合与 Wiki unknown 语义回归测试。
- `DiskWikiCacheTests.batchAvailabilityKeepsUnknownDistinct` 使用线程观察器锁定每次 JSON 检查均不在主线程执行。
- Explore / Activity 的动态计数改由局部 Observation modifier 消费；计数发布不再使 RepoList 根层、toolbar、tint 与 List 宿主共同失效。
- Manage / Explore / Weekly / Activity 等 8 个定向 Suite 共 140 个测试通过；同时修复进入知识库时新查询被 `cancelAll()` 误取消的任务顺序问题。
- Xcode 关闭后全量测试通过：180 个 Suite、1565 个测试，保留 1 个既有 known issue，无新增失败。
- `git diff --check`：通过。
- Instruments 与人工 UI 验收继续保持未完成，不以自动测试代替。

## 明确不在首轮范围

- 改用 `NSTableView` / `NSCollectionView`。
- 为性能优化直接修改已发布 migration 或要求用户删库重建。
- 改变 Discovery / Trending / Weekly 的服务端排序、候选生成或产品内容语义。
- 以隐藏 loading、延长动画或降低刷新频率掩盖真实延迟。
