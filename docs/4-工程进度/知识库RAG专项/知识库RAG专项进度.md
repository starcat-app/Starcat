# 知识库 RAG 专项进度

> 状态: 验收中（代码整体交付已完成，专项测试与真实数据人工验收完成前不关闭）
> 创建: 2026-07-03
> 启动: 2026-07-10
> 实施分支: `codex/knowledge-rag-full-delivery`
> 独立 worktree: `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-rag-full-delivery`
> 需求讨论: `docs/2-产品/需求讨论/知识库RAG需求讨论.md`
> 正式方案: `docs/2-产品/需求讨论/正式方案/知识库RAG正式方案.md`
> 详细设计: `docs/3-设计/详细设计/30-本地RAG设计.md`

## 1. 整体交付约束

本专项允许内部按 Batch 实施，但不做分批产品交付。只有实现、自动化验证、真实数据人工验收和
文档同步全部完成后，才能在主进度索引中标记完成。

- [x] Batch A：RAG schema、稳定分片、知识库范围增量索引和本地混合检索。
- [x] Batch B：AI Query Planner、结构化候选过滤、repo 聚合与执行状态机。
- [x] Batch C：Generator、streaming、citation、无证据拒答与取消机制。
- [x] Batch D：真实工作台、`@repo`、模型切换、历史、附件和 GitHub 临时上下文。
- [x] Batch E：Meilisearch / Qdrant 可选 Provider、设置、连接测试和本地回退。
- [~] Batch F：自动化验证已通过；真实数据人工验收待执行。

## 2. 范围决策

- [x] RAG 默认数据源固定为 `repo_notes.library_state = 'in_library'`，不是所有 starred repo。
- [x] RAG 是独立知识库问答工作台，不并入 Agent Workspace 作为唯一入口。
- [x] 第一版只读，不修改 tags、notes、status、star 或 libraryState。
- [x] issues / PR / releases 等 GitHub 数据是本轮临时上下文，不写 `rag_chunks`。
- [x] 用户主动开启的 External Search 结果只作为本轮临时上下文，不写索引或远程正文历史。
- [x] 附件和图片是本轮临时上下文，不写索引、notes 或 CloudKit。
- [x] 本次交付包含可选 Meilisearch / Qdrant 客户端能力，但不要求用户部署服务。
- [x] 本次不做 Code RAG、Agent/MCP 联动、CloudKit 会话同步和 reranker。
- [x] 不为未实施的 reranker 提前增加空协议或 Settings 选项。

## 3. 索引与更新

- [x] 新增 `RAGChunk`、`rag_chunks`、FTS5 表和同步 triggers。
- [x] source 支持 `readme / notes / summary / metadata`。
- [x] chunk 保存 `parent_type / parent_key / parent_title / chunk_key / chunk_index / content_hash`。
- [x] `(repo_id, source, source_id, chunk_key)` 唯一约束支持稳定 source diff。
- [x] embedding 状态支持 `pending / ready / failed / stale`，失败原因可追踪。
- [x] Float32 BLOB 复用 `RepoEmbedding` 编解码。
- [x] 内容 hash 不变时复用 embedding；变化时只把对应 chunk 置为 pending。
- [x] source 中消失的稳定 key 在同一事务删除；其它 source 不受影响。
- [x] embedding model 变化后旧向量进入 stale。
- [x] 覆盖率统计包含知识库 repo、已索引 repo、ready/pending/failed/stale chunks。
- [x] README 按 heading/段落切分，支持 small section 合并和超长 section 滑窗。
- [x] 默认参数为 target 700、min 180、max 1100、overlap 80、hard max 1600 tokens。
- [x] 代码块不在中间硬切；超长代码块保留首尾并标记 truncated。
- [x] 大表格按行拆分并保留表头。
- [x] notes、已有 AI summary、repo metadata 分别生成独立 source chunks。
- [x] metadata 包含 fullName、description、topics、language、stars/forks/watchers/issues、license、
  archived/fork/starred、status、tags 和 libraryUpdatedAt；数值字段 bucket 化。
- [x] 不为了建索引临时触发 AI summary。
- [x] 加入知识库、README 更新、notes 更新、AI summary 更新和 metadata 同步均接入 source 级刷新。
- [x] README 由 `ReadmeRepository` 按正文 diff 发送统一事件，覆盖详情页、后台预取和语义索引补全；
  全量 README cache 清理触发一次知识库 source diff。
- [x] AI summary 由 `AISummaryRepository` 写入事件统一触发，批量与单 repo 生成不维护重复 RAG 回调。
- [x] notes 变化使用 1.5 秒 debounce；移出知识库后保留缓存但 SQL 不再召回。

## 4. Planner 与检索

- [x] AI Query Planner 只输出结构化 JSON，不直接回答问题。
- [x] 支持 `semantic_only / filtered_semantic / structured_only / needs_clarification`。
- [x] schema 包含 filters、sort、candidateLimit、remoteContextRequests、webSearchRequests、requiresLiveEvidence、confidence 和 userVisiblePlan。
- [x] 本地验证枚举、日期、字段和范围；invalid JSON 重试一次，仍失败则降级语义检索。
- [x] remote `maxRepos/perRepoLimit` 在本地钳制，普通问题不声明远程请求。
- [x] SQL candidates 支持 status、language、tags、stars/forks、license、日期、archived/fork 等条件。
- [x] 精确数值筛选和排序走 repo 字段，不依赖 metadata embedding。
- [x] `@repo` 的 only/prefer/exclude 由本地候选层强制执行，不信任 Planner 扩大范围。
- [x] keyword 使用 SQLite FTS5，vector 使用 query embedding + 本地 cosine。
- [x] RRF 融合记录 keyword/vector/hybrid，叠加 source weight 和 explicit repo boost。
- [x] 每 repo child cap、总 topK、top repo 和 token hard cap 均生效。
- [x] child hits 按 repo 聚合为 `RepoContextBundle`，再扩展 section parent/siblings。
- [x] 分别返回 no knowledge repos、no candidates、no index 和 no relevant chunks。
- [x] 低证据或无索引时不调用 Generator。

## 5. 生成、引用与历史

- [x] `KnowledgeRAGService` 完成 Planner -> candidates -> retrieval -> remote -> attachments -> Generator 状态机。
- [x] 支持 `AsyncThrowingStream` streaming 和 Task cancellation。
- [x] Prompt 明确区分 local indexed、GitHub / External Search 临时网络上下文和 attachment context。
- [x] 本地为 matched child 分配 `[S<n>]`，生成前绑定 citation metadata。
- [x] 只恢复答案实际保留且属于本轮映射的 citation marker。
- [x] citation 包含 repo/chunk/source/section/score/hitKind/sourceURL。
- [x] 新增 `rag_conversations / rag_messages / rag_message_citations`。
- [x] 保存完整问题、回答、模型、时间和 citation metadata，不保存 chunk 正文快照。
- [x] 新增 `rag_message_remote_contexts`，历史只保存 resource/source URL/fetchedAt/降级原因，不保存远程正文。
- [x] chunk 删除后 citation 的 `chunk_id` 置空，历史仍可恢复 repo/source/section。
- [x] 多轮会话保留近期 3 轮原文；更早消息按覆盖水位压缩为持久化语义摘要，压缩失败时使用受限本地摘要且原文不丢失。
- [x] 支持新建、继续和删除会话，支持复制与导出 Markdown。
- [x] 用户数据库切换前取消当前问答并销毁工作台，同时暂停 source 监听并等待所有在途索引任务退出，防止旧账户历史或 chunk 误写新账户数据库。
- [x] 统一证据门禁只接受 structured rows、本地命中 bundles、成功非空的网络 blocks 或真实附件；semantic candidates 和 URL 不冒充证据，实时问题还必须取得成功网络证据。
- [x] 支持 attachment-only / remote-only 生成；所有来源均无证据时不调用 Generator，返回明确不足说明与最多 3 个推荐问题。
- [x] 推荐问题随 assistant message 持久化；点击后恢复原轮显式 repo scope，再作为新问题发送。

## 6. 远程临时上下文

- [x] 支持 GitHub issues、pull requests、releases、contributors、commit activity 和 security advisories。
- [x] Planner 先声明资源，用户确认保留项后才发起网络请求，不使用 slash command。
- [x] Provider 只接收知识库 SQL 筛选后的 top candidates，不从全网反向扩大 repo 范围。
- [x] Issues 输出 query、issue number/state/updatedAt/comments/labels/title/body excerpt 和 observed themes。
- [x] raw JSON 转成稳定的 LLM 友好文本。
- [x] 默认 top 5 repos，issues/PR 每 repo 10 条，releases 每 repo 5 条。
- [x] 15 分钟进程内 TTL cache 按 GitHub token 不可逆指纹隔离账户；普通网络缓存清理动作可同时清除。
- [x] 单 repo/resource 失败返回 degradation block，继续使用已取得的本地证据。
- [x] Inspector 展示 resource、fetchedAt、source URL、正文摘要或降级原因。
- [x] 历史恢复时 Inspector 展示远程上下文审计 metadata，不回放临时网络正文。
- [x] 远程确认粒度收敛为 `repo × resource`；目标 repo 只来自显式选择或实际检索命中，不用任意知识库前 5 个兜底。
- [x] Issues / PR 统一调用 `/search/issues`，固定目标 repo 与类型，清洗范围 qualifier 并二次过滤跨 repo / 类型错误结果。
- [x] 执行层为最新 Issues / PR / Release 等高置信实时问题兜底，Planner 漏报时仍生成受限 GitHub 请求。
- [x] Composer 主动联网复用 AnySearch、Tavily、Exa 或 Brave Search；GitHub 已可精确回答时不重复普通 Web Search。
- [x] 对话步骤统一为可折叠“联网搜索”，请求前出现，完成后自动折叠；展示 Provider/query、network/cache、HTTP、结果数、耗时、脱敏 endpoint 与最多 5 条结果链接。
- [x] 未授权的私有仓库身份不进入 External Search query；Web 正文不持久化，旧联网审计可兼容解码。

## 7. 工作台 UI/UX

- [x] 删除 `KnowledgeRAGDemoData`，所有可见状态来自真实 ViewModel 和本地存储。
- [x] 三栏分别承载会话历史、问答流、Evidence/Plan/Index Inspector。
- [x] Debug toolbar 和 Smart Collections -> 知识库页都可打开同一独立工作台。
- [x] `@` picker 只列知识库 repo，并搜索 fullName、description、topics、language、tags 和 status。
- [x] 工作台打开期间监听知识库边界和索引完成事件，实时刷新 `@repo` 列表、选中上下文与覆盖率。
- [x] 支持多 repo chips 和 only/prefer/exclude 模式切换。
- [x] `@repo` picker 支持上/下高亮、Enter 插入和 Esc 关闭；范围模式仅由显式菜单改变。
- [x] 模型下拉只切换本轮 Planner/Generator，不修改全局设置或 embedding model。
- [x] 附件 chip 显示文件名、MIME、大小和处理方式；可删除并同步执行上下文。
- [x] 附件右侧新增联网开关；开启即授权本轮 External Search 与 GitHub 请求，关闭时 GitHub 继续逐项确认。
- [x] 支持文本、源码、JSON、PDF 和图片；单轮 5 个、单文件 10 MB、总计 20 MB。
- [x] 不支持或超预算附件在发送前阻断。
- [x] OpenAI-compatible 无统一 vision capability 字段，不按模型名猜测；图片按 multimodal content
  parts 发送，服务端拒绝时展示原始错误。
- [x] 粘贴已入库 GitHub repo 链接转 repo chip；已知未入库链接显示明确状态并打开本地详情，外部链接打开 GitHub。
- [x] 回答 GitHub 链接优先打开 Starcat 本地详情，不存在时打开浏览器。
- [x] citation chip 定位 Inspector；展示 chunk、section、score、hitKind 和 truncated 状态。
- [x] no knowledge/no candidates/no index/no evidence/clarification/error/cancel 均有独立 UI 状态。
- [x] 固定文案完成 en/zh-Hans i18n。
- [x] 索引构建与发送问答均在 UI 和 service 装配边界校验 Pro，已有索引不会绕过门禁。
- [x] 明确问候/致谢/告别走本地引导，其他非知识库闲聊由 Planner 返回 `guided_discovery`；两者都不检索、不生成。
- [x] Planner 仅接收当前问题、显式 repo、附件/链接描述、上一条用户问题与上一条回答实际引用 repo，不接收证据正文或完整历史。
- [x] 长 Think 通过无损 buffer 降频发布，流式可变文本不创建 SelectionOverlay；滚动内部状态不参与 Observation，阻断布局反馈环。

## 8. Settings、Storage 与自托管后端

- [x] Settings -> AI 展示索引状态和构建/取消/重建动作。
- [x] 高级设置可选择 SQLite FTS5/Meilisearch 与 SQLite BLOB/Qdrant。
- [x] endpoint/index/collection/vectorName 保存在设置；API key 只进 Keychain。
- [x] Meilisearch/Qdrant 均支持连接测试和配置校验。
- [x] 外部 provider 报错或空命中时按设置回退 SQLite。
- [x] Qdrant 已有 collection 在清理前校验 vectorName 和 embedding dimension。
- [x] provider 切换后显示需要重建索引提示。
- [x] 外部 provider 只同步公开知识库 repo；私有 repo 保持本地检索。
- [x] 当前外部同步使用完整 replace，优先保证 source 删除和更新一致。
- [x] Meilisearch 完整 replace 会等待异步 task 成功，失败/取消/超时不会误报同步完成。
- [x] Storage 展示 RAG index/history 大小，并可分别清理。
- [x] 清理 RAG index 不影响 repo、README cache、notes、summary、repo embedding 或 libraryState。

## 9. 自动化验证

- [x] `rtk xcodebuild -quiet -scheme Starcat -destination 'platform=macOS,arch=arm64' build-for-testing`
- [x] `rtk jq empty Starcat/Resources/Localizable.xcstrings`
- [x] RAG 新增 Swift/i18n key 覆盖检查无缺失。
- [x] `rtk git diff --check`
- [x] `rtk xcodegen generate`
- [x] 运行 `RAGChunkRepositoryTests`、`RAGChunkBuilderTests`、`KnowledgeRAGCoreTests`、`ReadmeContentRepositoryTests`。
- [x] 运行全量 `xcodebuild test`。
- [x] 运行 Debug `xcodebuild build`。
- [x] 启动当前 Debug 构建，验证 RAG 入口、三栏工作台和匿名/空知识库状态（0/0，发送按钮禁用）。

> 2026-07-10: 专项测试与全量测试均已通过。测试运行中暴露的语言全局状态污染已通过测试串行化与与语言无关的行为断言修复；不改变产品逻辑。

> 2026-07-13: RAG 收尾整改后的完整 `xcodebuild test` 为 1377 通过、0 失败、7 跳过、1 项预期失败（总计 1385）；100/200 条历史会话固定关联读取基线用例通过。

> 2026-07-14: 本轮 `KnowledgeRAGCoreTests + AppSettingsTests` 排除既有分页预取断言后 96/96 通过；`DatabaseMigrationsV1Tests` 19/19 通过，确认 Planner 默认模板兼容升级与 v8 `suggested_actions_json`。

> 2026-07-14: 长流式内容修复后 `KnowledgeRAGCoreTests + StreamingMarkdownSnapshotTests + ScrollTailControllerTests` 排除既有分页预取断言后 81/81 通过；10,000 个逐字符 delta 最终内容完整且 UI 发布次数低于 100。

> 2026-07-14: 同一修复的全量 `xcodebuild test` 排除既有分页预取断言后退出码 0；Swift Testing 1375 项 / 171 suites 通过（1 个既有 known issue），XCTest 46 项通过、1 项按设计跳过。

> 2026-07-14: 主动联网实现通过 Debug build、xcstrings JSON 与 diff 检查；10 个定向用例覆盖 GitHub 意图兜底、External Search 零本地证据生成、实时证据拒绝旧答案、私有仓库隔离、旧审计解码、持久化边界和 Prompt 迁移，全部通过。组合 Suite 仍命中本专项既有 `addToLibraryPaginationWindowsAndPrefetches` 分页预取断言，与本轮联网链路无关。

## 10. 真实数据人工验收

- [ ] 验证已 star 已入库、已 star 未入库、未 star 已入库三类 repo 的索引边界。
- [ ] 修改 README/notes/summary/metadata，确认只更新对应 source。
- [ ] 验证关键词、语义、结构化筛选、模糊日期追问和 no-result 状态。
- [ ] 用两个 `@repo` 做对比，并验证 only/prefer/exclude。
- [ ] 切换模型、上传文本/PDF/图片和不支持附件，验证本轮上下文与阻断状态。
- [ ] 验证 Issues/Releases/PR 确认、跳过、断网/限流降级和 Inspector 信息。
- [ ] 使用 `@waydabber/BetterDisplay 这个项目最新的 open issues 是什么`，确认无需 Planner 正确声明也会显示“联网搜索”，并按 `updated desc` 返回 open Issues。
- [ ] 开启 Composer 联网后询问知识库外的当前事实，确认显示所选 External Search Provider、query、命中数与可点击结果；关闭后不发起普通 Web Search。
- [ ] 验证无搜索 Provider、断网、零结果和实时证据失败均明确拒答；私有仓库名称只在 Settings 授权后进入外部 query。
- [ ] 验证历史恢复、citation 定位、本地/外部 GitHub 链接分流和 Markdown 导出。
- [ ] 在索引构建和问答进行中切换账号,验证工作台关闭且 chunk/历史不串库。
- [ ] 验证 Local 默认后端不依赖外部服务。
- [ ] 在可用的自托管服务上验证 Meilisearch/Qdrant 连接与回退；未部署时记录为可选环境未执行。
- [ ] 验证所有问答路径均不修改 tags、notes、status、star 或 libraryState。

## 11. Definition of Done

- [x] 核心实现 A-E 全部完成，不再依赖 demo 数据。
- [x] 需求讨论、正式方案和详细设计已与最终实现对齐。
- [x] 专项测试与全量测试通过（Debug build 已通过）。
- [ ] 真实数据人工验收完成并记录结果。
- [ ] `docs/功能实现总览.md` 更新为完成并补 `> 实现:` 与变更日志。

上述 3 个验收项全部完成前，专项保持“验收中”，不以“核心完成”或“编译通过”替代最终完成。

## 12. 质量与性能优化 checklist

> 状态: 进行中（先优化可验证的检索性能；质量调参必须以真实数据评测为准）

- [x] keyword 与 vector 召回并行执行，保留双路独立降级与双失败报错语义 — `KnowledgeRAGRetriever.swift` — 2026-07-13
> 实现：并行启动互不依赖的 FTS 与 embedding/vector 分支，降低首个证据的串行等待。
- [x] parent context 使用批量读取，消除命中章节扩展的 N+1 SQLite 查询 — `RAGChunkRepository.swift`、`KnowledgeRAGRetriever.swift` — 2026-07-13
> 实现：以 repo 与 parent 的复合身份批量加载 siblings，保持知识库和当前 embedding 模型门槛。
- [x] citation 解析仅接受正文可见区域的本轮 marker，过滤代码、转义文本、链接标签与伪造编号 — `KnowledgeRAGPromptBuilder.swift` — 2026-07-13
> 实现：生成历史 citation 前先做轻量 Markdown 语法过滤，不把示例文本误记为回答证据。
- [x] 知识库浏览器查询关联 chunk override，已排除 chunk 不再触发 SQL 错误或泄漏到浏览列表 — `RAGChunkRepository.swift` — 2026-07-13
> 实现：读取时显式关联 override 表，以相同的排除状态过滤浏览器数据。
- [x] 提供脱敏真实问答的采集模板与统一指标口径 — `脱敏评测集模板.md` — 2026-07-13
> 实现：固定快照、模型、Provider 和 Top K，避免把合成关键词或不同运行条件混入质量结论。
- [x] 建立 RAG 测试与评测方案，覆盖质量、性能、可靠性、安全与发布门禁 — `RAG测试与评测方案.md` — 2026-07-14
> 实现：拆分检索、回答、引用、拒答和性能指标，以脱敏真实样本和同条件基线驱动调参。
- [x] 修复长 Think / 长回答的 SwiftUI 布局活锁，并建立 10,000 delta 无损降频回归测试 — `StreamingMarkdownSnapshot.swift`、`RAGAssistantMessageBlock.swift`、`ScrollFollowTail.swift` — 2026-07-14
> 实现：运行态采样定位 SelectionOverlay 与 AttributeGraph 热点；Think 使用 150ms/256 字快照，动态文本移除选择层，滚动状态只发布真实变化。
- [ ] 建立脱敏真实问答评测集，记录 Recall@K、nDCG、引用覆盖率、拒答准确率与 P50/P95 耗时。
- [ ] 完成中文与中英文混合查询的 FTS/语义召回对比，根据评测决定是否增加查询扩展或分词策略。
- [ ] 仅在评测证明 RRF/source weight 不足后，单独设计 reranker 的本地/云端隐私边界。
- [ ] 在大规模知识库或自托管后端成为瓶颈后，评估外部索引的 chunk 级增量同步。

## 13. RAG 收尾工作

> 状态: 自动化整改完成，真实环境人工验收待执行（2026-07-13）

### 13.1 字号设置实时联动

- [x] RAG 工作台、知识库浏览器和关联独立窗口在保持打开时，实时响应 Settings 的 `InterfaceScale` 变更。
- [x] 将 RAG 独立窗口中的系统预设字体迁入 `StarcatTypography` / `RAGWorkspaceTypography`，不保留会绕过字号倍率的 `.font(.title3)`、`.font(.caption)` 等正文调用。
- [x] 保持主窗口、Agent 工作台和 RAG 工作台同一字号档位语义；不通过关闭重开窗口或局部缩放补偿实现。

验收：依次切换 compact、standard、comfortable、large，RAG 三栏、消息、Inspector、Composer 和知识库浏览器均即时更新，布局无截断或重叠。

### 13.2 会话尾部滚动可靠性

- [x] 将“切换会话”与“历史消息已加载并完成首轮布局”拆成两个状态；只在后者发生后定位底部，避免仅监听 `selectedConversationID` 早于 `LazyVStack` 内容出现。
- [x] 历史会话、滚到底部按钮和流式回答统一通过 `ScrollPosition` 定位中栏 edge，不依赖 `LazyVStack` 子项锚点。
- [x] 用户手动上滚后才显示滚到底部按钮；点击按钮必须强制抵达最后一条；用户停留底部时流式回答才自动跟随。

验收：在长会话之间反复切换均直接展示最后一条；上滚、点击快捷按钮、继续流式输出和点击左侧大纲导航不会互相抢夺滚动位置。

### 13.3 Prompt 与统一上下文预算

- [x] 在保留现有 citation marker、数据边界和 prompt-injection 防护的前提下，将生成请求明确拆成稳定系统规则、会话历史、本轮问题、检索证据、远程上下文和附件。
- [x] 建立单一 `Context Budget`：从模型窗口扣除预留输出后，统一分配系统规则、历史、证据、远程上下文与附件；不再只依赖各段独立 token 上限。
- [x] 证据、远程上下文和附件按剩余预算稳定裁剪；任何外部文本均标记为不可信数据，证据不足或远程降级时不得生成确定性结论。
- [~] 用脱敏评测集覆盖有证据、无证据、远程失败、中文及中英文混合问题，避免 Prompt 调整只凭主观感受；评测模板已具备，真实 Provider 样本待执行。

验收：请求估算不超过模型可用上下文；引用、拒答和降级语义不回归；固定评测集可对比记录引用覆盖率与回答质量。

### 13.4 会话语义压缩与 Context Usage

- [x] 为聊天模型增加可配置的 `Context Window`；未知模型使用显式标注的保守默认值（32K），用户可在模型设置改为真实值。
- [x] 替换当前“最近 3 轮 + 字符截断摘要”：超过历史预算时调用压缩 Prompt 生成语义摘要，持久化摘要、覆盖消息水位和估算 token；原始对话始终保留并可恢复查看。
- [x] 压缩过程失败时不删除历史、不伪造摘要；若本轮问题或附件本身超过剩余预算，阻止发送并说明占用来源。
- [x] 在 Composer 右下角展示 Context Usage 环形占比；点击后展示 `已用 / 模型窗口`、分段进度条，以及系统规则、历史摘要、近期对话、本轮问题、证据、远程上下文、附件和预留输出的 token 与占比。
- [x] Context Usage 面板可展开查看本次实际将发送的内容预览，并明确 token 是本地估算值，不作为 Provider 精确计费数。

验收：长会话压缩后重开仍可继续问答且原文不丢；每次发送前的 Context Usage 与实际 Prompt 构成一致；模型窗口接近阈值时给出可理解状态而非服务端上下文超限错误。

### 13.5 数据与验证约束

- [x] RAG 已随正式版收口：最终 schema 走 `v7-knowledge-rag`；已从 v1 草稿与 `ensurePrelaunchRAGSchema` 抽离。
- [x] 为预算分配、历史压缩、水位恢复、Prompt 结构、Context Usage 计算和会话选择滚动事件补单测。
- [~] 关闭 Xcode 后运行相关 Suite 与全量 `xcodebuild test`；自动化已通过，真实长会话的字号、滚动、压缩、Context Usage 和 Prompt 质量人工验证待执行。

## 14. 代码审查与整改

> 状态: 第 1 轮 P1/P2 自动化整改完成；性能压测与真实环境验收待执行。

- [x] 优化流式 Markdown 的增量渲染，避免长回答逐 token 全文重解析。
- [x] 消除历史会话加载中的 citation/remote audit N+1 查询，并为长会话建立回归基线。
- [x] 为会话与知识库浏览器选择增加请求取消和最新结果保护，避免快速切换后旧数据覆盖。
- [x] 限制、去重并有界并行远程上下文抓取；将 Planner 的认证/网络/配置错误转为可操作提示。
- [x] 失败时保留用户问题，完善重试/设置/附件等错误恢复动作。
- [x] 为大知识库与大 PDF 建立有界检索/提取路径；收敛调试轨迹与 Markdown/citation 的共享组件。

> 审查：详见 `审查报告-第1轮.md`；P1 共 7 项、P2 共 4 项均已整改，完整测试于 2026-07-13 通过；长会话和大数据压测仍待执行。

## 15. 收尾与稳定性执行清单

> 状态: 阶段 1 至 6 自动化实施完成；阶段 0 的大数据指标与真实环境人工验收待执行。

> 清单：`RAG收尾与稳定性-checklist.md` 是本专项后续实现、逐项测试、commit 与验收收口的唯一执行顺序。
> 结果：自动化整改与测试证据见 `结果报告-收尾与稳定性.md`；真实环境验收记录完成后再关闭专项。
