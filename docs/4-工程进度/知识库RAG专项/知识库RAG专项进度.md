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
- [x] schema 包含 filters、sort、candidateLimit、remoteContextRequests、confidence 和 userVisiblePlan。
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
- [x] Prompt 明确区分 local indexed、GitHub remote ephemeral 和 attachment context。
- [x] 本地为 matched child 分配 `[S<n>]`，生成前绑定 citation metadata。
- [x] 只恢复答案实际保留且属于本轮映射的 citation marker。
- [x] citation 包含 repo/chunk/source/section/score/hitKind/sourceURL。
- [x] 新增 `rag_conversations / rag_messages / rag_message_citations`。
- [x] 保存完整问题、回答、模型、时间和 citation metadata，不保存 chunk 正文快照。
- [x] chunk 删除后 citation 的 `chunk_id` 置空，历史仍可恢复 repo/source/section。
- [x] 支持新建、继续和删除会话，支持复制与导出 Markdown。
- [x] 用户数据库切换前取消当前问答并销毁工作台，同时暂停 source 监听并等待所有在途索引任务退出，防止旧账户历史或 chunk 误写新账户数据库。

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

## 7. 工作台 UI/UX

- [x] 删除 `KnowledgeRAGDemoData`，所有可见状态来自真实 ViewModel 和本地存储。
- [x] 三栏分别承载会话历史、问答流、Evidence/Plan/Index Inspector。
- [x] Debug toolbar 和 Smart Collections -> 知识库页都可打开同一独立工作台。
- [x] `@` picker 只列知识库 repo，并搜索 fullName、description、topics、language、tags 和 status。
- [x] 工作台打开期间监听知识库边界和索引完成事件，实时刷新 `@repo` 列表、选中上下文与覆盖率。
- [x] 支持多 repo chips 和 only/prefer/exclude 模式切换。
- [x] 模型下拉只切换本轮 Planner/Generator，不修改全局设置或 embedding model。
- [x] 附件 chip 显示文件名、MIME、大小和处理方式；可删除并同步执行上下文。
- [x] 支持文本、源码、JSON、PDF 和图片；单轮 5 个、单文件 10 MB、总计 20 MB。
- [x] 不支持或超预算附件在发送前阻断。
- [x] OpenAI-compatible 无统一 vision capability 字段，不按模型名猜测；图片按 multimodal content
  parts 发送，服务端拒绝时展示原始错误。
- [x] 粘贴已入库 GitHub repo 链接转 repo chip；已知未入库/外部 repo 转链接 chip。
- [x] 回答 GitHub 链接优先打开 Starcat 本地详情，不存在时打开浏览器。
- [x] citation chip 定位 Inspector；展示 chunk、section、score、hitKind 和 truncated 状态。
- [x] no knowledge/no candidates/no index/no evidence/clarification/error/cancel 均有独立 UI 状态。
- [x] 固定文案完成 en/zh-Hans i18n。

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

## 10. 真实数据人工验收

- [ ] 验证已 star 已入库、已 star 未入库、未 star 已入库三类 repo 的索引边界。
- [ ] 修改 README/notes/summary/metadata，确认只更新对应 source。
- [ ] 验证关键词、语义、结构化筛选、模糊日期追问和 no-result 状态。
- [ ] 用两个 `@repo` 做对比，并验证 only/prefer/exclude。
- [ ] 切换模型、上传文本/PDF/图片和不支持附件，验证本轮上下文与阻断状态。
- [ ] 验证 Issues/Releases/PR 确认、跳过、断网/限流降级和 Inspector 信息。
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
