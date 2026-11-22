# 全仓性能优化 Checklist

> 状态：已交付待验收（计划内修复全部提交：P0-1、P1-1~P1-8、P2-1~P2-8、P2-11；P2-9 / P2-10 / P2-12 实测后暂缓不动。含四笔补充提交：P1-5 联调暴露的两处编译错误修复（rtk 代理过滤会吞掉编译诊断与失败退出码的教训）、P1-3 分块查询跨块去重（`0bd607e5`）、P1-4 对抗审查折入三处修复（`065b6931`）、P2-8 隔离回归修复（`1daaac81`，utility 闭包调 MainActor 隔离方法动态检查崩溃，详见 P2-8 条目）。2026-11-22 全量重跑 4819 用例 / 520 suites 全绿（1 known issue 为预存 E2E fixture 缺失跳过）+ 双渠道构建通过（App Store / Direct 均 BUILD SUCCEEDED 与产物校验）；人工验收清单已一次性交付，待 dong4j 逐一验收）
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
- [x] **P1-2 README 翻译缓存写后全量 reload**（已实现并提交，全量重跑全绿，待 dong4j 人工验收）
  - 位置：`DiskReadmeTranslationCache.swift:58`（`@MainActor`）、`:192`（upsert 后 reload）、`:301`（同步遍历解码全部译文）。
  - 方案：普通写入只更新单条与聚合统计（对照 `RepoContextStorage` 等 summary-first 路径）；sweep / 淘汰 / 旧格式清理 / 强刷各自最小 reload。
  - 验收：普通写入不再解码无关译文（目标 0 次）；sweep、淘汰、强刷行为不变；既有测试通过。
    - 实现（2026-11-22）：普通写入改增量统计——upsert / 删除只对受影响语言条目做单条更新与聚合字节差值累加，不再全量 reload 解码无关译文；sweep、淘汰、旧格式清理、强刷各自保留最小 reload 语义，对外缓存口径不变。
    - 回归：`StarcatTests/ReadmeTranslationRepositoryTests` 新增普通写入不触碰无关条目、聚合统计与逐条累加对拍、sweep / 强刷行为不变等用例（`DiskReadmeTranslationCache` suite 20 用例随全量重跑全绿，2026-11-22）。
- [x] **P1-3 语义搜索打分在主 actor**（已实现并提交，全量重跑全绿，待 dong4j 人工验收）
  - 位置：`SemanticSearchService.swift:176,272-317`；候选来源 `LocalSemanticSearchProvider.swift:42`、`HomeViewModel.swift:2616`；`RepoEmbeddingRepository.swift:37`（单条 IN 全量取向量）。
  - 方案：余弦打分 / 排序 / 截断调度出主 actor；向量取数核对分块（对照 `:55` 计数实现）。
  - 验收：5k 候选排名与现实现一致；主 actor 连续占用与总耗时采样下降；取消行为不变。
    - 实现（2026-11-22）：余弦打分 / 排序 / 截断移出主 actor（`SemanticSearchService` 打分段改后台计算，主 actor 只收结果）；取向量改 500-ID 分块查询（`RepoEmbeddingRepository.fetchEmbeddings`，与 `countEmbeddings` 对齐；分块在同一 read 快照内，评分输入不跨快照）。
    - 已知约束：本条提交内 `fetchEmbeddings` 分块参数有一处切片形态的存在类型转换编译错误（Array 直传合法、ArraySlice 不合法），2026-11-22 P1-5 联调时暴露，已补元素级上转型单独修复（见 §6 fix 记录）。
    - 补充修复（2026-11-22）：对抗审查暴露跨块重复 ID 问题——IN 去重只在块内天然成立，重复候选 ID 落进不同分块时同一行被各块分别返回 / 计数（语义评分对重复向量叠加、Search Center 覆盖率虚高；全量测试含重复 ID 用例确定性暴露 1201/1200）。`deduplicatedIDs` 分块前按值去重，顺带减少分块数（`0bd607e5`）。
    - 回归：`StarcatTests/SemanticSearchTests` 新增 5k 候选排名与旧实现对拍、分块边界、取消语义等用例（`Semantic Search` suite 23 用例随全量重跑全绿，含跨块去重补充用例，2026-11-22）。
- [x] **P1-4 README WebView 正文双路翻译提取**（已实现并提交，待 dong4j 人工验收）
  - 位置：`ReadmeWebView.swift:2134,2141`（常规正文同时触发两套提取）；`:1836` 深克隆、`:1895` TreeWalker、`:1926` 桥传；条数 / 字符上限在 `:2217` 接收端才执行。
  - 方案：按消费者与模式触发提取；上限前移到 JS 侧，Web 进程不再白做被截断丢弃的遍历与桥接。
  - 验收：提取次数与桥接字节数下降可测；切仓后文档与译文对应正确；字号 CSS 旁路不受影响。
    - 实现（2026-11-22）：消费者视图把 `translationMode`（settings 读取或 nil）传进 WebView：nil 零提取；有消费者只建当前模式一套 targets（分段克隆候选块 / 全文 TreeWalker），切模式先 `resetTranslationDOM` 恢复原文再按新模式重抽；上限前移 JS 侧（分段 2000 候选 / 全文 8000 文本节点、单段 20,000 字素）；requestID + 模式 + 导航令牌三重校验丢弃迟到消息；缓存译文挂起等 targets 就绪后回放。快照只喂翻译按钮发起翻译，无自动重放路径。涉及 `ReadmeWebView` / `RepoDetailView` / `RepoFileBrowserSheet` / `RepoFileTextPreview` / `RepoSkillDetailPane`。
    - 对抗审查（workflow 三视角审查 + 人工逐条裁决）折入三处修复（`065b6931`）：① 模式往返（源码↔渲染）清 `lastAppliedTranslationRevision`，否则缓存译文被「已应用」记账挡住无法回放到新 targets、译文永久消失；② 分段 / 全文提取排除列表补 `.starcat-mermaid-error`，异步插入的渲染失败提示不再占用正文编号（否则提取时序不同产生两套编号，主题重载按旧 ID 回放错位）；③ 全文配额用尽即 break，`nextNode()` 级联过滤不再横扫剩余整份文档。另两条裁决不修：切 Skill 同帧模式变化时旧文档多跑一次提取（正确性无碍、触发罕见，记录为已知小浪费）；UTF-16 回退保守丢段（已文档化取舍，macOS 15 WebKit 必有 `Intl.Segmenter`，实际影响≈0）。
    - 回归：`StarcatTests/ReadmeDocumentReadyWebKitTests` 新增 10 用例（nil 不提取、分段 / 全文单模式单套 targets、切模式恢复原文重抽、缓存挂起回放、迟到消息三重校验、分段配额 / 超长跳号、全文配额，含对抗审查后的「模式往返后同一 revision 译文重新回放」）；2026-11-22 定向重跑 14/14 绿。
- [x] **P1-5 搜索合并在主 actor 逐个 firstIndex（最坏二次复杂度）**（已实现并提交，统一定向重跑确认中，待 dong4j 人工验收）
  - 位置：`RepoRepository.swift:559,582,595`（非空 FTS 相关性查询无限量）；`LocalKeywordSearchProvider.swift:35`；`RepositorySearchMerger.swift:24,54`；`SearchCoordinator.swift:168,196,239`（来源交付与追加页时在主 actor 重建）。
  - 方案：仓库身份字典索引化合并；保持排序、去重与来源归并语义；交付批次结构暂不动，后续另行评估。
  - 验收：固定样本对拍合并结果与现实现一致；合并工作量从最坏二次降为线性。
    - 实现（2026-11-22）：`RepositorySearchMerger.merge` 改双字典查表——「数字 ID 首现下标 + 规范化名称首现下标」两张字典等价复刻 `firstIndex` 语义（匹配集合 = ID 命中 ∪ 名称命中、取更小下标），合并整体从最坏 O(n·m) 降为 O(n+m)；合并只改来源与本地状态字段、不改 `identity`，多轮合并无需重建字典；`isSameRepository` 与调用方不变。
    - 回归：`StarcatTests/SearchCoordinatorTests` 新增 12 场景对拍测试（`mergeMatchesLegacyFirstIndexReference`，冻结旧 firstIndex 实现为参照）：空批次、nil ID 退化名称匹配、ID 0 可匹配 / 不同名不匹配、同名不同 ID、双键冲突取更小下标、来源归并、链式命中、本地状态补入等逐一与旧实现对拍。
- [x] **P1-6 智能集合逐规则重复查询**（已实现并提交，统一定向重跑确认中，待 dong4j 人工验收）
  - 位置：`SmartCollectionsOverviewView.swift:365,435`；`HomeViewModel.swift:2182` 起（每条规则重复取候选 / 状态 / 非空笔记 ID）。
  - 方案：同一刷新、同 scope 内共享查询与规则上下文；`IndexedSnapshot.swift:38` 快照是否同时携带摘要与 README 先测字节量再决定缩减。
  - 验收：N 条规则的查询次数从 O(N) 次独立取数收敛为共享；刷新结果与现实现一致；`SmartCollectionPerformanceTests` 防线保持。
    - 实现（2026-11-22）：`SmartCollectionCountBatch` 一次构建候选 / 状态 / 非空笔记 ID 基础集，N 条规则共享同一批查询，逐规则 countRepos 从 O(N) 次独立取数收敛；数组版对完全相同的规则复用首现计数；概览页 `loadUserCounts` 改走批量入口一次回填全部计数；`buildSmartCollectionFilterContext` 增加共享 batch 参数，列表加载路径 batch=nil 行为与原实现等价。
    - 回归：`StarcatTests/HomeViewModelFilterSortTests` 新增批量计数与逐规则计数逐条对拍（含重复规则复用断言）。
- [x] **P1-7 Trending / Activity / Explore 的 `.task(id:)` 身份携带候选构造**（已实现并提交，无相关单测，待 dong4j 人工验收）
  - 位置：`TrendingView.swift:157`、`ActivityView.swift:323`、`ExploreView.swift:262`。筛选关闭时（guard 之前的 `id` 求值）仍构造 skillCandidates（筛选 / 临时 Repo 构造 / 查 starred registry）。
  - 方案：筛选关闭用常量任务身份；开启用覆盖候选、筛选与分页变化的身份；候选构造移入任务体。
  - 验收：筛选关闭时候选构造 0 次；开启时补扫正常；Activity 池上限（200 / 120 / 100）不变。
    - 实现（2026-11-22）：三视图 `.task(id:)` 改三元身份：技能筛选关闭时用常量身份（候选数组构造无消费方、任务体 guard 天然 no-op），开启时才拼候选 ID + 筛选维度的组合身份；关闭时字符串拼接与任务重启都消失，开启时身份粒度与原先完全一致。
    - 回归：纯 `.task` 身份构造调整，无相关单测；任务体逻辑未动，Activity 池上限与开启筛选路径行为不变。
- [x] **P1-8 每日推荐命中判断前全量取已收藏列表**（已实现并提交，统一定向重跑确认中，待 dong4j 人工验收）
  - 位置：`DailyRecommendationStore.swift:122`（缓存命中判断前 `fetchAllStarred()`）；宿主监听 `DailyRecommendationHost.swift:77`。
  - 方案：复用路径改为仅查询已收藏 ID；保留 `DailyRecommendationPreparation.swift:28` 的同 key 单飞与异 key 取消。
  - 验收：同日重复激活不重复全量取数；手动换批、新 Star 排除行为不变。
    - 实现（2026-11-22）：`load()` 新增 `fetchStarredIDs` 轻量读：当日缓存命中路径在早退前用 ID 集排除新 Star，不再为一次重看拉完整 Stars 列表；完整列表延后为需要种子 / 补页路径的第二读，两读间新 Star ID 并入排除集。Host 注入 `fetchStarredRepoIDs`。
    - 回归：`StarcatTests/DailyRecommendationTests` 既有用例补读 1 参数适配，语义不变。

## 3. P2 次级优化

- [x] **P2-1 RAG 外部搜索（Meilisearch）变更触发整库重传**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `KnowledgeRAGIndexBuilder.swift:892,1179`、`RAGExternalSearchProviders.swift:221,273`。无 embedding 客户端时 deleteAll 后每 500 条重传；先评估指纹跳过未变更刷新与 `applyChanges`（`:236`）增量路径；验 DELETE / POST 请求次数与上传文档数。
    - 实现（2026-11-22）：无 Embedding 分支不改用 `applyChanges`（`replaceSource` 会把内容未变的复用分片也登记进变更集，且变更集覆盖不了可见性变更），改为文档指纹（SHA256 请求目标 + 按 ID 排序分批上传投影，与 POST body 共用同一 `documents(from:)`）+ 全量替换：指纹一致跳过整轮 DELETE / POST / 轮询；DELETE 后任何失败清指纹强制重传；增量写 / 切库 / 关闭后端均失效快照。provider 注入传输层供测试捕获真实请求。
    - 回归：`StarcatTests/KnowledgeRAGCoreTests` 新增跳过 / 部分失败重试 / 增量写后强制全量用例（含请求计数防漏）（`Knowledge RAG Core` suite 204 用例随全量重跑全绿，2026-11-22）。
- [x] **P2-2 单仓笔记索引刷新间接全表读摘要**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `RepoNotesSection.swift:575` → `SemanticSearchService.swift:586` → `AISummaryRepository.swift:84`。改走 `fetchLatest(repoId:)`；验 SQL 限定 repo ID。
    - 实现（2026-11-22）：单仓索引刷新的摘要读取改限定 repo 查询，SQL 带 `repo_id` 条件不再全表扫；语义不变。
    - 回归：`StarcatTests/SemanticSearchTests` 新增 SQL 限定断言用例（随 `Semantic Search` suite 23 用例全量重跑全绿，2026-11-22）。
- [x] **P2-3 token provider 疑似逐请求读凭据**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `GitHubAPIClient.swift:410`、`GitHubMarkdownFitWidthImage.swift:160`、`KeychainManager.swift:127`、`CryptoManager.swift:37`。README 图片路径已证实直读；先核 provider 内部缓存，确有需要再做进程内缓存（换号 / 登出必须失效）。
    - 实现（2026-11-22）：确认 provider 无内部缓存后，`KeychainManager` github token 读路径加进程内缓存消除逐请求读文件；换号 / 登出 / 写入路径同步失效缓存。
    - 回归：`StarcatTests/KeychainManagerTests` 新增缓存命中、失效时机（写入 / 登出 / 换号）用例（`KeychainManager` suite 10 用例随全量重跑全绿，2026-11-22）。
- [x] **P2-4 AuthSession 同账号恢复双回调**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `AuthSession.swift:238,248,285`、`AppDependencies.swift:1935`。区分首激活 / 资料刷新 / 真换号后合并回调；验缓存命中、缺失、401、离线、换号五路径。
    - 实现（2026-11-22）：以「实际打开的数据库」为准（AppDependencies 注入 `activeDatabaseUserID = { [db] in db.currentUserId }`，只捕获 DatabaseManager 避免与 session 成环），缓存激活已为同账号切库时 `/user` 验证成功跳过第二次完整回调；属性缺失 / currentUserId 为 nil / 不同账号照常触发，保留冷启动、换号、切库失败重试语义。Web / Device / PAT 主动登录路径必须切库，不动。
    - 回归：`StarcatTests/SwitchUserDatabaseTests` 新增同账号跳过与三种照常触发用例（restore 端到端被测试 host Keychain 门控挡住，决策收口为独立方法供单测）（`Multi-account DB switch` suite 12 用例随全量重跑全绿，2026-11-22）。
    - 测试修正（2026-11-22）：换号取消用例修正等待顺序竞态——URLProtocolStub 队头 handler 同步阻塞期间后续请求进不了 stub，`gate.release(0)` 前移到 `waitForRequestCount(2)` 之前，先放行 A 让 B 登记计数；区分力不变（`cb0451d8`）。
- [x] **P2-5 StarredExporter 逐仓串行读取**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `StarredExporter.swift:199`。分批取数与摘录生成；复用 `ShareCardSheet.swift:911` 分阶段反馈；验查询数与峰值内存。
    - 实现（2026-11-22）：导出改批量取数（`ReadmeRepository` / `RepoNoteRepository` 新增批量 API，协议同步扩展），摘录生成移出主线程；分阶段反馈保留。
    - 回归：`StarcatTests/ReadmeContentRepositoryTests` + `RepoNoteRepositoryTests` 批量 API 用例（11 + 31 用例随全量重跑全绿，2026-11-22）。
- [x] **P2-6 DeveloperLanguage 逐仓串行取语言**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `DeveloperLanguageService.swift:175`。有界并发 + 单仓异常隔离；保留 7 天 TTL 与同 login 在途去重；并发只省等待，请求总数独立统计。
    - 实现（2026-11-22）：开发语言快照改有界并发取语言（并发窗口内单仓失败隔离、不中断整批）；7 天 TTL、同 login 在途去重（generation 守卫）与请求总数统计保留。
    - 已知约束：本条提交内 Task 的 `defer` 有一处 `guard ... else { return }`（defer 闭包禁止 return），2026-11-22 P1-5 联调时暴露，已改等价条件清理块单独修复（见 §6 fix 记录）。
    - 回归：`StarcatTests/DeveloperLanguageServiceTests` 新增有界并发、异常隔离、TTL / 去重保留等用例（`开发语言缓存与启动恢复` suite 11 用例随全量重跑全绿，2026-11-22）。
- [x] **P2-7 SearchCenter 计数重复构造候选**（已实现并提交，全量重跑全绿，待 dong4j 人工验收） — `SearchCenterViewModel.swift:215,296`。从同一候选快照派生列表与计数。
    - 实现（2026-11-22）：候选列表与计数共享同一快照派生，消除逐次重复构造。
    - 回归：`StarcatTests/SearchCenterViewModelTests` 同步调整（`Search Center ViewModel` suite 54 用例随全量重跑全绿，2026-11-22）。
- [x] **P2-8 CacheCleaner 主 actor 同步枚举归档**（已实现并提交，修复一次隔离回归，待 dong4j 人工验收） — `CacheCleaner.swift:52,82,181,207`。统计移出主 actor；保留 `SettingsView.swift:2682` 的 500 ms 尾沿防抖。
    - 实现（2026-11-22）：目录枚举与文件属性读取经 `withCheckedContinuation` + utility 队列移出主 actor，主 actor 只等待统计快照；枚举口径（`.skipsHiddenFiles`）与清理逻辑不变。
    - 回归与修复（2026-11-22）：首笔提交（`bb2a61b0`）在 utility 闭包内直接调用了 MainActor 隔离的 `loadArchiveStats()`——Swift 6 编译期仅告警（`@Sendable` 闭包捕获非 Sendable 类型是 warning 非 error），运行期动态隔离检查（`dispatch_assert_queue`）在后台线程陷阱崩溃，当日两批共 6 份同签名 .ips；此前「定向通过」系误判——崩溃用例所在 `CacheCleanerTests` suite 内嵌于 `ReadmeRepositoryTests.swift`，定向筛选未覆盖该 suite。修复（`1daaac81`）：辅助方法改 `nonisolated static`、依赖显式传参不捕获 self（FileManager 非 Sendable，`nonisolated` 实例方法访问属性无法编译）。关键约束：`@MainActor` 类的 static 成员默认同样被类级隔离，必须显式 `nonisolated` 才能在后台队列调用。
    - 回归：`StarcatTests/ReadmeRepositoryTests` 内嵌 `CacheCleanerTests` 3 用例覆盖统计口径（隐藏目录跳过、仅计 ZIP）与清理（保留非 ZIP 文件与根目录）；修复后定向与全量重跑均全绿（2026-11-22）。
- [x] **P2-9 Spotlight 全库读取 + 指纹**（实测后暂缓，2026-11-22） — `RepositorySpotlightService.swift:171`。已有命中跳过与单行刷新；先测稳态重复读行数再定投影。
    - 实测（2026-11-22）：2.1k 仓真实库合格行 2,104，窄投影全量查询 1.2ms、投影字节约 314KB；rebuild 在 utility 后台任务执行且指纹命中跳过系统索引替换。开销远低于可感阈值，暂不动。
- [x] **P2-10 Manage pin JOIN 排序与深页 OFFSET**（实测后暂缓，2026-11-22） — `RepoRepository.swift:1170`、`HomeViewModel.swift:255`。`EXPLAIN QUERY PLAN` + 10k 仓靠后页实测后再决定 keyset。
    - 实测（2026-11-22）：2.1k 仓真实库 pin 查询单页 4.9-8.4ms（含 JOIN 排序），远低于可感阈值；深页劣化预计 >5k 仓才进入可感区间。暂不动，后续库规模到 5k+ 再评估 keyset。
- [~] **P2-11 启动期主 actor 开池 / 迁移 / repair**（埋点已实现并提交，Instruments 分项采样待 dong4j 人工验收，2026-11-22） — `DatabaseManager.swift:168`、`AppDependencies.swift:2060`。先分项测量开池 / 迁移 / repair / 账号屏障耗时，再定优化目标。
    - 测量（2026-11-22）：匿名库开池实测 1.05ms，无需单独优化；其余分项（正式迁移 / 开发库修补 / 账号屏障）静态无法从代码判定，需 app 内采样。方案：埋点分项 signpost（匿名库初始化与账号库重开分别记录开池 / 正式迁移 / 开发库修补，账号切换回调独立计时；账号屏障包含数据库子区间，Instruments 按嵌套判读避免重复相加），埋点后在 Instruments 分项采样再定优化目标。
    - 实现（2026-11-22）：`PerformanceSpan` 新增 `database.open` / `database.migrate` / `account.switch_barrier` 三段 signpost，init 与 reopen 同口径包裹，账号回调整体区间包含嵌套子区间；纯遥测无行为变化，无专属单测，靠编译 + Instruments 人工采样。
- [x] **P2-12 首次标签 bootstrap 全量读 README**（实测后降级不动，2026-11-22） — `HomeView.swift:2499`、`ReadmeRepository.swift:150`、`TagTaxonomyBootstrapService.swift:487`。按实际内存峰值评估读取截断投影或分批。
    - 实测（2026-11-22）：`readme_contents` 全表约 10.5MB，峰值受 16k 截断钳制；截断投影仅省约 20% 内存且引入分批复杂度。降级不动。

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
    - 复核重锚定（2026-11-22 静态阅读，仍维持观察）：8a RAG 进度聚合实际每批一次，聚合点在 `KnowledgeRAGIndexBuilder.swift:1024`（GRDB 读队列重新 SUM、关联知识库状态、排除禁用分片，`RAGChunkRepository.swift:404`），频率低于原估；8c README 预热每批候选查询与覆盖率聚合各执行同组 4 个 LEFT JOIN，空候选时服务内部再聚合一次，待重试路径另查最早重试时间（`InitialRepoWarmupCoordinator.swift:225`、`ReadmePrefetchRepository.swift:59`、`ReadmePrefetchService.swift:149`）；8d CodebaseMemory 250ms 短轮询在 `CodebaseMemoryRunner.swift:745` waitForServer（最长 8 秒）、25ms 在 `CodebaseMemoryBinaryResolver.swift:279`（--version 探测），索引子进程走 terminationHandler + 一次性超时兜底，MCP 纯索引入口跳过 UI 启动（`CodebaseMemoryViewModel.swift:488`）。

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
- [x] `docs(perf): 回填性能专项 P0/P1-1 进度` — `1568b204`
- [x] `perf(readme): 翻译缓存写路径改增量统计消除全库重扫`（P1-2）— `6aa72550`
- [x] `perf(search): 语义搜索打分调度出主 actor 并分块取向量`（P1-3）— `c9f2d872`
- [x] `perf(search): 单仓索引刷新摘要读取改限定 repo 查询`（P2-2）— `76696243`
- [x] `perf(keychain): github token 读路径加进程内缓存消除逐请求读文件`（P2-3）— `9d042960`
- [x] `perf(export): 知识库导出改批量取数与离主线程摘录`（P2-5）— `ed1de17c`
- [x] `perf(profile): 开发语言快照改有界并发取语言`（P2-6）— `c27c759a`
- [x] `fix(search): 嵌入分块查询参数切片加存在类型转换`（P1-3 联调暴露的编译错误修复）— `def043a0`
- [x] `fix(profile): 开发语言任务 defer 守卫改条件清理`（P2-6 联调暴露的编译错误修复）— `e66401e8`
- [x] `perf(search): 搜索合并改身份字典查表消除逐个 firstIndex`（P1-5，实现+测试合一提交）— `caee6e7c`
- [x] `perf(view): 技能筛选关闭时任务身份改常量避免候选白算`（P1-7）— `4534ea13`
- [x] `test(perf): 换号取消用例先放行队头再等新请求计数`（P2-4 回归用例竞态修正）— `cb0451d8`
- [x] `perf(recommend): 当日缓存命中改轻量 ID 读免完整 Stars 拉取`（P1-8）— `4c953537`
- [x] `perf(collection): 智能集合批量计数共享查询消除逐规则重复取数`（P1-6）— `a0ff9ebf`
- [x] `perf(search): 搜索中心候选列表与计数共享同一快照派生`（P2-7）— `3d20035f`
- [x] `perf(auth): 同账号启动校验跳过重复切库屏障`（P2-4）— `0434917b`
- [x] `perf(db): 开池迁移与账号屏障分段埋点`（P2-11 埋点）— `056d8902`
- [x] `perf(cache): 归档统计枚举移出主 actor`（P2-8）— `bb2a61b0`
- [x] `perf(rag): Meilisearch 无 Embedding 全量刷新按文档指纹跳过远端重传`（P2-1）— `9bde516b`
- [x] `docs(perf): checklist 回填 P2-1/4/7/8/9/11 状态与实测结论` — `f48daff8`
- [x] `fix(search): 向量 IN 分块查询跨块重复 ID 去重`（P1-3 对抗审查补充修复）— `0bd607e5`
- [x] `perf(readme): 翻译源按消费者模式按需提取`（P1-4，含对抗审查三修复与回归）— `065b6931`
- [x] `fix(cache): 归档统计辅助方法改 nonisolated 静态函数修复后台队列隔离崩溃`（P2-8 隔离回归修复）— `1daaac81`
- [x] 后续每项独立提交（实现+测试合一）已收口；全量重跑（4819 用例 / 520 suites 全绿）+ 双渠道构建（App Store / Direct 均 BUILD SUCCEEDED）已确认，docs 状态翻转即本提交
