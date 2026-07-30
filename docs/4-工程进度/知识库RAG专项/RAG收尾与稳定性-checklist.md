# RAG 收尾与稳定性 Checklist

> 状态: 阶段 1 至 9、七轮代码/文档审查、全量自动化门禁与真实大库取证已完成；UI 人工交互和脱敏金标评测待关闭。本清单按用户可感知风险、前置依赖和数据路径相关性排序。

## 目标与执行规则

- 先消除会话错位、输入丢失、长回答卡顿等 P1 主链风险，再增加 Context Usage 与语义压缩能力。
- 每个小项均先补回归测试，再实施最小改动；完成一项才勾选一项、更新主进度索引并提交一次中文 commit，不 push。
- RAG 已随正式版收口：任何后续 schema 变更必须追加新 migration；不得回写 `v7-knowledge-rag`、v1 草稿或启动期旁路。
- 每个阶段至少运行相关 Suite；阶段 7、8、9 完成后运行全量 `xcodebuild test`。真实 Provider、慢网络和大数据场景另列人工验收，不以单测替代。

## 阶段 0：基线与测试支架

- [x] 为会话选择、浏览器选择、失败恢复、流式快照、滚动请求、上下文预算和历史压缩建立可注入的延迟/错误 mock。
- [~] 固化基线：100/200 条历史会话读取固定为 4 次关联查询；18,465 个真实向量 chunk 已记录 P50/P95、峰值内存和取消延迟；超长文本附件及真实长会话的视觉/交互手感仍待人工采集。
- [x] 建立脱敏真实问答集的固定模型、Provider、Top K 和评测记录模板。

完成条件：测试能稳定复现竞态和失败路径；性能指标可在同一设备重复采集。

## 阶段 1：工作台主链稳定性

- [x] **会话选择竞态**：为 `selectConversation` 增加取消与最新请求 generation，较慢的旧请求不得覆盖最新选择。
- [x] **知识库浏览器竞态**：为 `selectRepository` 使用相同的 selection guard，快速切换后不显示过期分片。
- [x] **历史定位末尾**：仅在消息加载且首轮布局完成后滚到底部；历史恢复、滚到底部按钮和流式跟随统一使用 `ScrollPosition` 的 edge 定位。
- [x] **用户问题恢复**：生成、附件或 Provider 失败时持久化用户问题或恢复草稿，提供重试与编辑后重试；取消语义不回归。
- [x] **字号实时联动**：RAG 工作台、知识库浏览器与独立窗口接入 `InterfaceScale`，系统预设正文样式统一迁入 RAG typography。

完成条件：延迟 mock 下 A→B 快速切换始终显示 B；任意长会话切换后直接落在最后一条；失败不要求重新输入；四档字号即时生效且布局无重叠。

## 阶段 2：流式渲染与会话读取性能

- [x] **增量 Markdown**：RAG 复用 `StreamingMarkdownSnapshot` / `StreamingMarkdownAssembler`，按时间或字符阈值提交，不在每个 token 重解析完整 Markdown。
- [x] **历史关联批量读取**：`loadConversation` 按 message IDs 批量读取 citation 和 remote audit，再内存分组，消除 N+1。
- [x] **调试轨迹上界**：为 debug trace 加条数与字节 FIFO 上限，并在导出前提示可能含敏感内容。

完成条件：长回答保持可取消、尾部跟随和最终 Markdown 一致；100/200 条历史的关联读取查询数为常数级；长调试会话内存受上限保护。

## 阶段 3：检索、文本附件与远程调用上界

- [x] **大知识库检索**：ready 检查改为存在性查询；向量扫描只读取必要字段、使用有界 Top-K 后再 hydrate；大量 repo ID 分批传入 SQL。
- [x] **大附件处理底层上界**：文本按上限累计并检查取消；底层 PDF 提取分支同样有界，但 PDF 未接入当前产品入口，不作为已支持能力。
- [x] **远程请求规划**：确认前对 remote requests 规范化、去重并限制总工作量；fetch 采用有界并发且保持输出顺序。
- [x] **远程进度与取消**：展示真实完成数，超时和取消立即停止剩余工作，不把失败写入缓存。

完成条件：1 万+ chunk 和超长文本附件不出现无界加载；重复远程 request 不重复请求；慢网络下进度、超时和取消可理解且可验证。

## 阶段 4：类型化错误与用户恢复

- [x] 将 Planner 的格式错误与认证、配置、网络、超时错误区分；仅格式错误允许重试/语义 fallback。
- [x] 定义 RAG 用户错误模型，分别提供重试、打开 AI 设置、检查网络、移除附件或稍后再试动作。
- [x] `RAGWorkspaceErrorSheet` 按错误类型展示简明原因；技术详情仅进入可复制诊断，不泄露到普通文案。
- [x] 覆盖 401、无 API Key、断网、超时、坏 JSON、附件失败与生成失败；每种失败均验证问题可恢复。

完成条件：用户在失败页无需猜测下一步，也不会丢失原问题；错误分类测试覆盖所有外部边界。

## 阶段 5：统一 Prompt、预算与 Context Usage

- [x] 为聊天模型提供 `Context Window` 配置；未知模型使用明确标注的保守默认值。
- [x] 将系统规则、历史、本轮问题、证据、远程上下文、附件和预留输出纳入单一 `Context Budget`。
- [x] 按剩余预算稳定裁剪证据、远程内容和附件；外部文本保持不可信数据标记，证据不足时保留拒答/降级语义。
- [x] 在 Composer 展示 Context Usage 环形指标；点击后展示分段 token、占比、预留输出与本轮实际 Prompt 预览。
- [x] 复用 Markdown 安全扫描范围，citation linkify 与间距处理均跳过 fenced/inline code，避免展示层改写代码内容。

完成条件：发送前估算不超过模型可用窗口；面板构成与实际 Prompt 一致；代码块、链接、转义 citation 不被错误链接化。

## 阶段 6：会话语义压缩与验收收口

- [x] 设计并持久化语义摘要、消息覆盖水位与 token 估算；原始消息始终保留、可恢复查看。
- [x] 超过历史预算时生成摘要并替代旧轮次；压缩失败不删除历史、不伪造摘要。
- [x] 持续压缩、重开会话、模型窗口切换和预算接近阈值均补单测。
- [x] 完成 P2 共享组件收敛，避免 RAG 与 AI 流式展示、选择防竞态和 Markdown 安全逻辑再次分叉。
- [~] 关闭 Xcode 后运行相关 Suite 与全量 `xcodebuild test`；最终 1506 项为 1497 通过、8 跳过、1 项预期失败、0 失败，双 target 编译成功；真实大库、TEI 与 External Search 已取证，GitHub/Generator、慢网络、快速切换和文本类附件 UI 人工验收待执行。

完成条件：长会话可持续问答而不超上下文，原文不丢；全量测试通过；专项进度、主进度索引与结果报告同步完成。

## 阶段 7：正确性与能力边界

- [x] **Embedding 写回一致性**：追加 `v11-rag-embedding-claim`，请求前原子 claim；ready/failed 写回同时校验 chunk id、`content_hash`、pending 状态与 claim id，正文变化或人工覆盖会清空旧 claim — `RAGChunkRepository.swift`、`KnowledgeRAGIndexBuilder.swift` — 2026-07-16。
- [x] **Meilisearch 同步 SQL**：`fetchKeywordSearchableChunks` 已正确展开 placeholders，并由 Repository 回归测试覆盖批量 repo 查询 — 2026-07-15。
- [x] **外部后端回退语义**：Meilisearch/Qdrant 查询与索引同步共用回退错误策略；开启时普通错误或空命中可回退 SQLite，关闭时配置/查询/同步错误原样抛出，`CancellationError` 永不被吞 — `RAGBackendConfiguration.swift`、`RAGExternalSearchProviders.swift` — 2026-07-16。
- [x] **附件能力边界与文档一致性**：当前正式支持文本、Markdown、JSON 与源码附件；PDF/图片底层分支标记为未来能力，不进入当前 UI、测试门禁或 DoD，活文档已与真实入口同步 — 2026-07-16。
- [x] **RAG 固定文案 i18n**：计划、Planner、Service、附件、外部后端、GitHub 远程证据与会话存储错误统一走 `String.l10n` 和 `Localizable.xcstrings`；API/模型内容与 Prompt 协议保持原语义，en/zh-Hans 回归防止文案和标点泄漏 — 2026-07-16。

完成条件：每项先有可稳定复现的失败测试，再实施最小修复；并发索引不产生过期 ready 向量，外部后端失败与回退符合开关语义，附件入口与文档一致，英文环境不泄漏固定中文。

## 阶段 8：性能与资源上界

- [x] **Embedding 队列分批**：待处理总数改用 `COUNT(*)` 独立统计，正文按 `embeddingBatchSize` 分批读取与 claim，移除 `Int.max` 全量加载和循环 `removeFirst`，并对非法 batch size 设置 1 的下限 — `RAGChunkRepository.swift`、`KnowledgeRAGIndexBuilder.swift` — 2026-07-16。
- [x] **README 重建上界**：缺失 README 拉取改为“收一个补一个”的 3 任务有界并发，只在主线程按完成数发布单调进度；保留 GitHub 限流、in-flight 去重、15 秒超时、单仓降级和取消传播 — `KnowledgeRAGIndexBuilder.swift` — 2026-07-16。
- [x] **分片计算移出主线程**：Repository 快照读取、数据库写入和状态发布仍由 `@MainActor` 协调；Markdown 解析与 README/Notes/Summary/Metadata chunk build 改由 detached worker 执行，显式桥接父任务取消，回归测试锁定输出不变 — `RAGChunkBuilder.swift`、`KnowledgeRAGIndexBuilder.swift` — 2026-07-16。
- [x] **外部索引增量同步**：source debounce、批量重建与 embedding 写回共用修订号变更集；进程首次或配置/模型变化才全量初始化，后续按 chunk upsert/delete Meilisearch 与 Qdrant，人工编辑、恢复、下架和永久删除同样接入；Metadata 仅同步 Meilisearch — `RAGExternalSearchProviders.swift`、`KnowledgeRAGIndexBuilder.swift`、`RAGChunkRepository.swift`、`KnowledgeRAGWorkspaceWindowController.swift` — 2026-07-16。
- [x] **本地向量扫描基线**：以 18,465 个真实 ready chunk、1024 维、20 次热扫描记录 P50/P95、峰值内存和取消延迟；共享余弦内核改用 Accelerate/vDSP 且复用 query 范数，P95 由 4,372.39 ms 降至 187.75 ms，内存增量由 24.31 MB 降至 14.05 MB；证据支持保留当前本地上限与可选 Qdrant，不追加 migration — `SemanticSearchService.swift`、`RAGSearchProviders.swift`、`RAGVectorScanBenchmarkTests.swift`、`RAG测试与评测方案.md` — 2026-07-16。
- [x] **Source-aware 重建读取**：用显式读取计划约束 source 依赖；README/Notes/Summary 只读自身数据，Metadata 才读 Note、Tags 与本地事实缓存；单仓摘要改为 `ORDER BY generated_at DESC LIMIT 1`，全库重建仍一次批量预取 — `KnowledgeRAGIndexBuilder.swift`、`AISummaryRepository.swift`、`KnowledgeRAGCoreTests.swift` — 2026-07-16。
- [x] **候选仓库轻量查询**：`@repo` picker 改用轻量投影并预计算归一化搜索文本；知识库不超过 500 个仓库时保留内存过滤，超过阈值后使用 120ms 合并的 SQL 首屏分页，选中时才批量还原完整 Repo；索引问题名称与 GitHub URL 精确匹配不依赖当前页 — `RAGRepoCandidateRepository.swift`、`RAGMentionPickerLogic.swift`、`KnowledgeRAGWorkspaceViewModel.swift` — 2026-07-16。
- [x] **元数据快照版本缓存**：追加 `v12-rag-metadata-revision`，知识库边界、Repo、标签、摘要与索引相关写入在事务内推进单调版本；Planner、Generator、Inspector 与“我的洞察”知识库范围按账号、版本、Health / OpenSSF 修订和 embedding model 共用 actor 缓存并合并并发读取，滚动时间口径最多复用 60 秒，切库强制清空 — `KnowledgeBaseMetadataSnapshot.swift`、`MyInsightsSnapshotProvider.swift`、`DatabaseMigrationsV1.swift`、`AppDependencies.swift` — 2026-07-30。
- [x] **会话持久化增量更新**：`appendTurn` 返回事务实际写入的 summary、用户/助手消息、稳定 ID、时间戳、引用与远程审计；回答完成后对当前投影和后台 LRU 快照只追加本轮并局部更新会话摘要，不再重载全部消息、引用或会话列表；切换会话、取消/失败恢复仍走全量读取 — `RAGConversationStore.swift`、`KnowledgeRAGWorkspaceViewModel.swift` — 2026-07-16。
- [x] **Debug 磁盘保留上界**：每会话 Debug JSON 同时限制为最新 24 个文件和 8 MiB；写入后立即裁剪，首次读取旧目录前也先按文件名与文件大小收敛，不解码被淘汰内容；进程内缓存随裁剪失效，避免内存展示已被磁盘删除的记录 — `RAGConversationStore.swift`、`KnowledgeRAGCoreTests.swift` — 2026-07-16。
- [x] **会话预取缓存预算**：完整展示快照缓存同时限制为 24 项、600 条消息和 4 MiB 估算文本；成本在首次构建时计算，回答增量只追加本轮成本；后台预取不驱逐已访问项，首个超预算快照立即停止后续读取，用户主动打开的超预算会话仍完整展示但不缓存。100/200 条长会话四查询热读取基线分别为 P50 1.404/2.526 ms、P95 1.504/2.708 ms、峰值物理内存增量 0.031/0.062 MB — `KnowledgeRAGWorkspaceViewModel.swift`、`KnowledgeRAGCoreTests.swift`、`RAG测试与评测方案.md` — 2026-07-16。

完成条件：优化前先固化可重复基线，优化后不改变知识库边界、隐私语义、召回结果和取消行为；两个 App target 编译通过，相关 Suite 与全量测试通过，真实性能数据回填专项评测记录。

## 阶段 9：架构与复用技术债

- [x] **会话运行态收敛**：回答状态、用户消息、流式正文/快照、计划、检索、Context Usage、远程块、执行步骤与冻结耗时合并为 `[UUID: RAGConversationRuntimeState]`，统一 restore/update/clear；generation、计时 Task、标题任务与授权 actor 保留独立生命周期容器，`KnowledgeRAGWorkspaceViewModel` 仍是唯一可观察协调器 — `KnowledgeRAGWorkspaceViewModel.swift`、`KnowledgeRAGCoreTests.swift` — 2026-07-16。
- [x] **Service 内部分阶段**：`ask` 只负责 `Planning → Retrieval → Remote Context → Prompt/证据门禁 → Generation` 编排、终止和错误收口；五个阶段使用独立输入/输出类型并共用单向 `RAGServiceEventSink`，分别拥有 Planner/元数据、附件/本地召回、授权/网络、证据充分性/预算和流式模型职责；不新增第二个协调器，也不改 `runQuestion` 的 UI 协调边界 — `KnowledgeRAGService.swift`、`KnowledgeRAGCoreTests.swift` — 2026-07-16。
- [x] **Rerank 传输层复用**：TEI / Cohere 共用不可变候选快照、正文截断拼装、API Key 归一化、JSON POST、HTTP 错误语义和 index 回填排序；两套请求/响应 DTO 继续由各 Provider 独立持有，越界结果统一忽略 — `RAGSearchProviders.swift`、`KnowledgeRAGCoreTests.swift` — 2026-07-16。
- [x] **索引状态读模型复用**：Repository、IndexBuilder、工作台与知识库浏览器直接共用唯一纯值 `RAGIndexStatusProjection`，统一空态、仓库/向量覆盖和问题计数语义，不保留平行 coverage 类型；两个窗口的交互与任务状态机仍独立 — `RAGChunk.swift`、`RAGChunkRepository.swift`、`KnowledgeRAGWorkspaceViewModel.swift`、`KnowledgeRAGWorkspaceWindowController.swift` — 2026-07-16。

完成条件：每次只抽取一个稳定边界；重构前后行为与数据归属不变，定向 Suite 和全量测试通过，ViewModel 与 Service 的职责可独立验证。

## 执行顺序

阶段 0 → 阶段 1 → 阶段 2 → 阶段 3 → 阶段 4 → 阶段 5 → 阶段 6 为已完成的第 1 轮整改主线。当前按阶段 7 → 阶段 8 → 阶段 9 → 真实数据与真实 Provider 验收执行；阶段 7 的正确性风险必须先于性能和架构收敛，阶段 8 的基线应先于阶段 9 的大范围重构。

## 实施记录（2026-07-13）

- 阶段 1 至 6 的代码整改与回归测试已完成；每个切片均以中文 commit 独立提交，未 push。
- 最终全量测试：`rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test`，结果为 1377 通过、0 失败、7 跳过、1 项预期失败（总计 1385）。
- 阶段 0 的 100/200 条历史会话基线已固化为自动化用例；18,465 个真实向量 chunk、TEI Rerank 与 AnySearch 已完成实测，超长文本附件、慢网络和真实长会话交互仍需在可操作 UI 的环境人工验收。

## 阶段 7 实施记录（2026-07-16）

- Embedding 写回、外部后端回退、附件能力边界与固定文案 i18n 均已关闭；所有代码切片分别提交且未 push。
- i18n 先以英文环境稳定复现 8 处固定中文泄漏，再补 en/zh-Hans catalog 与运行时查表；`RAGLocalizationTests + KnowledgeRAGCoreTests` 共 107 项通过。
- 阶段完成后运行全量 `xcodebuild test`：173 个 Suite、1438 项测试通过，0 失败，1 项已登记 known issue；真实 Provider 与真实大数据验收仍按阶段 8 后的总验收执行。

## 第 3 轮复审记录（2026-07-16）

- 复审基线为 `main` / `61090a7c`，详细结论见 `审查报告-第3轮.md`。
- Meilisearch SQL 项已由 2026-07-15 的实现与回归测试关闭；PDF/图片改为未来能力，不再作为当前产品验收项。
- 定向运行 RAG Core、Chunk Repository、会话窗口、滚动、流式 Markdown 与数据库迁移共 6 个 Suite，168 项测试全部通过；该结果不替代全量测试和真实数据验收。

## 第 4 轮复审与自动化门禁记录（2026-07-16）

- 审查基线、5 项发现与逐项整改证据见 `审查报告-第4轮.md`；远程证据 i18n、文档真源、压缩语义和唯一索引读模型均已关闭。
- 关闭 Xcode 后运行完整 `xcodebuild test`：Swift Testing 1459 项 / 174 suites 通过（1 个已登记 known issue）；XCTest 46 项中 1 项按设计跳过、0 失败。
- `Starcat`（App Store）与 `StarcatDirect` 两个 Debug target 独立 build 均成功；Direct 仅有无 AppIntents.framework 时跳过 metadata extraction 的工具链提示，不影响产物编译。
- 自动化门禁不能替代真实 Provider、慢网络、真实长会话、超长文本附件和脱敏问答集验收；对应 `[~]` 在取得真实证据前保持未关闭。

## 第 5/6 轮复审与真实环境记录（2026-07-16）

- 第 5 轮发现并关闭 GitHub HTTP 与会话存储错误格式的最后一处 i18n 漏口；Localization + Core 共 124 项通过。
- 第 6 轮未发现新的 P0/P1 代码缺陷；完整 `xcodebuild test` 的 xcresult 为 1506 项、0 失败，`Starcat` 与 `StarcatDirect` Debug build 均成功。
- 真实环境已核对 1,883 个 repo、18,467 个 ready 向量分片、知识库边界、索引完整性、会话引用、TEI Rerank 与 AnySearch；详见 `真实环境验收记录-2026-07-16.md`。
- 当前自动化环境无法通过 accessibility bridge 取得 Starcat 可见窗口，脱敏质量评测也缺少人工金标；相关人工项保持 `[~]`，不得以单测或历史数据伪造通过。

## 第 7 轮清洁复审记录（2026-07-16）

- 第 6 轮两项文档收口问题关闭后重新检查代码、migration、i18n、活文档、链接、提交边界与测试证据，未发现新的代码、测试或文档一致性问题。
- 外部人工门禁与真实环境记录逐项对应，继续保持未关闭；详细结论见 `审查报告-第7轮.md`。
