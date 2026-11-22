# 全仓性能优化 Checklist

> 状态：开发中（P0 / P1-1 自动化验收通过，待 dong4j 人工验收；下一项 P1-2 待 dong4j 授权）
>
> 开工日期：2026-11-22
>
> 分支 / 工作区：`dong4j/docs-app-wide-performance` @ bonnethead worktree
>
> 审查基线：`d436acf6`（2026-11-22 全仓静态审查 + 三组独立复核）。审查报告全文已落盘：本目录 `审查报告-全仓性能审查.md`（诊断快照，不随修复进度更新）；本清单条目自含位置 / 方案 / 验收，是修复进度的单一信任源。
>
> 范围：页面流畅度——主线程占用、重复计算与请求、缓存复用、外部 API 超时与异常处理、UI 重复布局。保留现有动画与交互语义；P0 属数据安全修复，语义修正以条目说明为准。

## 1. P0 数据安全

- [x] **P0-1 聊天 SQLite 后端 LRU 淘汰会删光全部会话**（已实现，自动化验收通过，待 dong4j 人工验收）
  - 位置：`Starcat/Shared/Services/DiskChatHistoryStore.swift:1156`。`lruSweep` 用 db / wal / shm **物理大小**做 `while` 停止条件；事务内 DELETE 只释放页、不缩文件，条件恒真 → 会把会话删到只剩 0 条。
  - 触发：聊天历史使用 SQLite 后端且累计超过 100 MiB 配额（默认后端为 JSON，`AppSettings.swift:2162`）。
  - 方案：与 JSON 后端 `lruSweep`（`:653`，逐条 `bytes -= entry.size`）对齐：改用**逻辑字节**（消息 content + reasoning + 会话 title / carried_over_summary 的 UTF-8 字节数）做配额比较与逐条扣减；逻辑字节未超配额直接返回（避免碎片 / WAL 虚高触发空扫与 VACUUM）；VACUUM 仅在确有删除时执行且留在事务外；SQLite 后端配额可通过 init 注入，支撑小配额回归测试。淘汰语义与 JSON 后端一致：`updated_at` 最旧优先、删到达标即停，不加「保留最后一条」新语义。
  - 验收：新增回归测试——略超配额多会话按最旧优先删到达标即停（保留集断言，旧实现会删光）；save 隐式 sweep 路径同验；未超配额 no-op。`StarcatTests/DiskChatHistoryStoreTests` 通过（2026-11-22：28/28 passed，含新增 `sqliteLruSweepStopsAtQuota` / `sqliteLruSweepDeductsPerSession` / `sqliteLruSweepDefaultQuotaNoop`；实现侧一处测试写法修正：`#require` 包抛错表达式必须内层 `try`，即 `try #require(try ...)`）。

## 2. P1 主线程卡顿

- [x] **P1-1 聊天落盘阻塞主线程且整会话重写**（已实现，自动化验收通过，待 dong4j 人工验收）
  - 位置：`RepoAIChatViewModel.swift:531,548,653,688,738,873`（主 actor 同步保存）；`DiskChatHistoryStore.swift:579,741`（JSON 后端重写当前会话全部分块 + 遍历全库目录统计）、`:1085`（SQLite 后端删全消息重插）。
  - 方案：保留「先存用户消息」恢复语义；JSON 后端改增量写受影响分块，全库字节统计移出保存热路径；SQLite 后端按 ordinal 增量 upsert。
  - 验收：200 条消息会话的写入量对比；成功 / 取消 / 失败路径回归；落盘不再造成可感主线程卡顿。
    - 实现（2026-11-22）：JSON 后端追加保存只重写受影响尾部 chunk——200 条会话每回合从 10 chunk 全量重写降为 1~2 chunk + metadata（mtime 断言 chunk 0-9 不触碰），同数保存（取消 / 失败补存）跳过分块写；全库字节统计移出保存热路径改增量维护（与 reload 重算口径对拍一致）；SQLite 后端按 ordinal 增量 upsert——200 删 + 200 插降为 1~2 insert（rowid 快照断言逐行原地保留）。
    - 独立复核发现并修复 3 个增量写回归风险：① 迁移同 UUID 同消息数不同内容会因增量保留旧前缀导致回读校验失败（`saveSession` 增加 `replacingExisting` 参数，迁移写入整体替换，恢复「传入即权威」）；② SQLite 消息数回退分支只删不插，传入的截断窗口与新消息丢失（恢复全量重插语义）；③ metadata messageCount 损坏为负会负下标崩溃、chunks 目录缺失时增量写永久丢前缀（负数归一化按损坏重建 + 缺失降级全量重建恢复数据）。
    - 已知约束：保存中途失败重试的字节差统计可能漏计 1~2 chunk，偏差有界且 `reload()` 全量重算自愈；不为罕见异常路径引入失败时全库扫描。
    - 回归：`DiskChatHistoryStoreTests` 36/36 + `DiskChatHistoryMigrationTests` 10/10 通过（含迁移 merge / 并发写 / 损坏源回归）；双渠道构建通过。
- [ ] **P1-2 README 翻译缓存写后全量 reload**
  - 位置：`DiskReadmeTranslationCache.swift:58`（`@MainActor`）、`:192`（upsert 后 reload）、`:301`（同步遍历解码全部译文）。
  - 方案：普通写入只更新单条与聚合统计（对照 `RepoContextStorage` 等 summary-first 路径）；sweep / 淘汰 / 旧格式清理 / 强刷各自最小 reload。
  - 验收：普通写入不再解码无关译文（目标 0 次）；sweep、淘汰、强刷行为不变；既有测试通过。
- [ ] **P1-3 语义搜索打分在主 actor**
  - 位置：`SemanticSearchService.swift:176,272-317`；候选来源 `LocalSemanticSearchProvider.swift:42`、`HomeViewModel.swift:2616`；`RepoEmbeddingRepository.swift:37`（单条 IN 全量取向量）。
  - 方案：余弦打分 / 排序 / 截断调度出主 actor；向量取数核对分块（对照 `:55` 计数实现）。
  - 验收：5k 候选排名与现实现一致；主 actor 连续占用与总耗时采样下降；取消行为不变。
- [ ] **P1-4 README WebView 正文双路翻译提取**
  - 位置：`ReadmeWebView.swift:2134,2141`（常规正文同时触发两套提取）；`:1836` 深克隆、`:1895` TreeWalker、`:1926` 桥传；条数 / 字符上限在 `:2217` 接收端才执行。
  - 方案：按消费者与模式触发提取；上限前移到 JS 侧，Web 进程不再白做被截断丢弃的遍历与桥接。
  - 验收：提取次数与桥接字节数下降可测；切仓后文档与译文对应正确；字号 CSS 旁路不受影响。
- [ ] **P1-5 搜索合并在主 actor 逐个 firstIndex（最坏二次复杂度）**
  - 位置：`RepoRepository.swift:559,582,595`（非空 FTS 相关性查询无限量）；`LocalKeywordSearchProvider.swift:35`；`RepositorySearchMerger.swift:24,54`；`SearchCoordinator.swift:168,196,239`（来源交付与追加页时在主 actor 重建）。
  - 方案：仓库身份字典索引化合并；保持排序、去重与来源归并语义；交付批次结构暂不动，后续另行评估。
  - 验收：固定样本对拍合并结果与现实现一致；合并工作量从最坏二次降为线性。
- [ ] **P1-6 智能集合逐规则重复查询**
  - 位置：`SmartCollectionsOverviewView.swift:365,435`；`HomeViewModel.swift:2182` 起（每条规则重复取候选 / 状态 / 非空笔记 ID）。
  - 方案：同一刷新、同 scope 内共享查询与规则上下文；`IndexedSnapshot.swift:38` 快照是否同时携带摘要与 README 先测字节量再决定缩减。
  - 验收：N 条规则的查询次数从 O(N) 次独立取数收敛为共享；刷新结果与现实现一致；`SmartCollectionPerformanceTests` 防线保持。
- [ ] **P1-7 Trending / Activity / Explore 的 `.task(id:)` 身份携带候选构造**
  - 位置：`TrendingView.swift:157`、`ActivityView.swift:323`、`ExploreView.swift:262`。筛选关闭时（guard 之前的 `id` 求值）仍构造 skillCandidates（筛选 / 临时 Repo 构造 / 查 starred registry）。
  - 方案：筛选关闭用常量任务身份；开启用覆盖候选、筛选与分页变化的身份；候选构造移入任务体。
  - 验收：筛选关闭时候选构造 0 次；开启时补扫正常；Activity 池上限（200 / 120 / 100）不变。
- [ ] **P1-8 每日推荐命中判断前全量取已收藏列表**
  - 位置：`DailyRecommendationStore.swift:122`（缓存命中判断前 `fetchAllStarred()`）；宿主监听 `DailyRecommendationHost.swift:77`。
  - 方案：复用路径改为仅查询已收藏 ID；保留 `DailyRecommendationPreparation.swift:28` 的同 key 单飞与异 key 取消。
  - 验收：同日重复激活不重复全量取数；手动换批、新 Star 排除行为不变。

## 3. P2 次级优化

- [ ] **P2-1 RAG 外部搜索（Meilisearch）变更触发整库重传** — `KnowledgeRAGIndexBuilder.swift:892,1179`、`RAGExternalSearchProviders.swift:221,273`。无 embedding 客户端时 deleteAll 后每 500 条重传；先评估指纹跳过未变更刷新与 `applyChanges`（`:236`）增量路径；验 DELETE / POST 请求次数与上传文档数。
- [ ] **P2-2 单仓笔记索引刷新间接全表读摘要** — `RepoNotesSection.swift:575` → `SemanticSearchService.swift:586` → `AISummaryRepository.swift:84`。改走 `fetchLatest(repoId:)`；验 SQL 限定 repo ID。
- [ ] **P2-3 token provider 疑似逐请求读凭据** — `GitHubAPIClient.swift:410`、`GitHubMarkdownFitWidthImage.swift:160`、`KeychainManager.swift:127`、`CryptoManager.swift:37`。README 图片路径已证实直读；先核 provider 内部缓存，确有需要再做进程内缓存（换号 / 登出必须失效）。
- [ ] **P2-4 AuthSession 同账号恢复双回调** — `AuthSession.swift:238,248,285`、`AppDependencies.swift:1935`。区分首激活 / 资料刷新 / 真换号后合并回调；验缓存命中、缺失、401、离线、换号五路径。
- [ ] **P2-5 StarredExporter 逐仓串行读取** — `StarredExporter.swift:199`。分批取数与摘录生成；复用 `ShareCardSheet.swift:911` 分阶段反馈；验查询数与峰值内存。
- [ ] **P2-6 DeveloperLanguage 逐仓串行取语言** — `DeveloperLanguageService.swift:175`。有界并发 + 单仓异常隔离；保留 7 天 TTL 与同 login 在途去重；并发只省等待，请求总数独立统计。
- [ ] **P2-7 SearchCenter 计数重复构造候选** — `SearchCenterViewModel.swift:215,296`。从同一候选快照派生列表与计数。
- [ ] **P2-8 CacheCleaner 主 actor 同步枚举归档** — `CacheCleaner.swift:52,82,181,207`。统计移出主 actor；保留 `SettingsView.swift:2682` 的 500 ms 尾沿防抖。
- [ ] **P2-9 Spotlight 全库读取 + 指纹** — `RepositorySpotlightService.swift:171`。已有命中跳过与单行刷新；先测稳态重复读行数再定投影。
- [ ] **P2-10 Manage pin JOIN 排序与深页 OFFSET** — `RepoRepository.swift:1170`、`HomeViewModel.swift:255`。`EXPLAIN QUERY PLAN` + 10k 仓靠后页实测后再决定 keyset。
- [ ] **P2-11 启动期主 actor 开池 / 迁移 / repair** — `DatabaseManager.swift:168`、`AppDependencies.swift:2060`。先分项测量开池 / 迁移 / repair / 账号屏障耗时，再定优化目标。
- [ ] **P2-12 首次标签 bootstrap 全量读 README** — `HomeView.swift:2499`、`ReadmeRepository.swift:150`、`TagTaxonomyBootstrapService.swift:487`。按实际内存峰值评估读取截断投影或分批。

## 4. 观测与低优（先测量后动手）

以下不直接修，先在对应场景采样确认构成可感卡顿或资源浪费，再单独立项：

- [ ] OBS-1 `ReleaseAssetDownloader.swift:86` 本地落盘失败换第二来源重下
- [ ] OBS-2 `ScreensaverViewModel.swift:105` 停用后仍有 2 秒 revision 检查
- [ ] OBS-3 `FollowGraphViewModel.swift:83` 搜索重复排序
- [ ] OBS-4 `RepoFileSourcePreview.swift:199` 行号标尺相关重绘枚举
- [ ] OBS-5 `RepoFileTree.swift:209` 同子树两次枚举
- [ ] OBS-6 `ReleaseTimelineView.swift:188` 构造 `Array(enumerated())`
- [ ] OBS-7 `RepoIssuesWorkspaceViewModel.swift:190` 500 行兜底
- [ ] OBS-8 后台任务类：RAG 每批进度聚合、Direct 技能窗口 30 秒兜底扫描、预热重复 JOIN、CodebaseMemory 解析期短轮询

## 5. 验证与门禁

- [ ] 每项修复附定向测试，或写明「无相关测试」；入口 `make test TEST_ARGS="-only-testing:StarcatTests/XXX"`。
- [ ] 涉及非 UI 逻辑的批次完成后跑 `make build-appstore` / `make build-direct`；新增 / 删除 Swift 文件先 `xcodegen generate`。
- [ ] CLI / MCP 能力暴露评估：本专项全部为内部性能与数据安全修复，不新增、不改变任何可独立执行的业务动作 → **不适用**（无公共目录登记需求；若某项意外新增动作，按规范单独登记）。
- [ ] i18n：不新增用户可见文案；若涉及设置页统计口径文案变更，按全语言交付流程处理。
- [ ] 提交遵循 `docs/5-规范/Git-提交规范.md`；首次提交批次同步更新 `BRANCH.md`（分支用途扩展为性能审查 + 修复）。
- [ ] `docs/功能实现总览.md` 保持只读；专项收口回写 checkbox 待 dong4j 单独确认。

## 6. 计划提交

- [x] `docs(perf): 建立全仓性能优化专项清单`（含审查报告落盘、LESSONS 登记、BRANCH.md 分支用途扩展）— `bb69fece`
- [x] `fix(chat): 修复 SQLite 聊天历史 LRU 淘汰删光全部会话`（P0-1；原计划 `perf(chat)`，按提交规范 type 与语义一致原则改为 `fix`）— `b6620693`
- [x] `test(chat): 补 SQLite 聊天历史 LRU 淘汰回归`（P0-1）— `5d3ba662`
- [x] `perf(chat): 聊天落盘改增量写消除整会话重写`（P1-1 实现；含迁移替换语义与异常态数据完整性修复）— `b848ecf`
- [x] `test(chat): 补聊天落盘增量写回归`（P1-1）— `b3571f8`
- [ ] 后续每项独立 `perf(...)` + `test(...)` 提交
