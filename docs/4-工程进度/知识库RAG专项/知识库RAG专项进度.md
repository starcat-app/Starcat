# 知识库 RAG 专项进度

> 状态: 方案已确认, 待实施
> 创建: 2026-07-03
> 需求讨论: `docs/2-产品/需求讨论/知识库RAG需求讨论.md`
> 正式方案: `docs/2-产品/需求讨论/正式方案/知识库RAG正式方案.md`
> 详细设计: `docs/3-设计/详细设计/30-本地RAG设计.md`

## 1. 目标

把早期“已 star 仓库本地 RAG”调整为“知识库 RAG”:

1. RAG 默认只使用 `libraryState == .inLibrary` 的 repo。
2. 新增 chunk-level Hybrid RAG 索引,支持 keyword + vector 双路召回和具体证据片段引用。
3. 新增独立“知识库问答”工作台,与 Agent Workspace 同级。
4. 回答支持 streaming、citation chip 和 evidence inspector。
5. issues / PR / releases 等网络数据只作为本轮远程临时上下文,不进入 RAG chunk 索引。
6. 第一版只读,不自动写 tags、notes、status、star 或 libraryState。

## 2. 不做范围

- [x] 不把所有 starred repo 作为 RAG 默认数据源。
- [x] 不把 RAG 合并进 Agent Workspace 作为唯一入口。
- [x] 不做通用联网 web RAG;只允许对本轮候选 repo 拉取受控的远程临时上下文。
- [x] 不要求用户必须部署 Meilisearch / Qdrant。
- [x] 不自动修改 tags / notes / status / star / libraryState。
- [x] 不做 CloudKit 同步 RAG 会话历史。
- [x] 不把 repo-level semantic search 强行迁移到 chunk-level。

## 3. 实施分层

### 3.1 MVP 必做

MVP 只做能闭环“知识库 repo 问答”的最小集合:

- DB 与 chunk repository。
- README / repo metadata / notes / AI summary chunk builder。
- 知识库范围索引器。
- Query Planner 的基础结构化过滤、语义改写、no_index / no_evidence 状态。
- Local Hybrid Retriever: SQLite FTS5 keyword + local vector + fusion。
- Generator + citation parser。
- Debug gate 下的知识库问答工作台。
- 工作台内历史 rail、新建会话、继续会话。
- 本地保存完整 RAG 会话历史: 用户问题、模型回答、使用模型、时间戳、citation metadata。
- Command Composer 基础 `@repo` mention、多 repo 对比、context chip 删除。
- 输入框模型下拉,支持本轮切换模型但不修改全局设置。
- Evidence Inspector 展示 chunk、section parent、命中方式 keyword / vector / hybrid。
- issues / releases / PR 类问题只提示“需要 GitHub 临时上下文,当前版本暂未启用”,不实际拉取。

### 3.2 MVP 后置

以下能力不阻塞第一版问答闭环,放到 MVP 稳定后:

- GitHub issues / PR / releases 远程临时上下文真实拉取。
- 真实远程上下文启用后的确认/删除流程。
- 附件 / 图片真实解析和 vision 调用。
- 复制/导出回答。
- Settings 中完整 RAG Backend / Provider 配置 UI。
- toolbar / 知识库页正式入口。

### 3.3 高级增强

以下能力作为高级增强,不进入 MVP:

- Meilisearch provider。
- Qdrant provider。
- Cloud / local reranker。
- 代码文件索引与 Code RAG。
- Repo Research Agent / Agent Workspace 联动。
- MCP 暴露 RAG evidence 查询能力。

## 4. PR-1: DB 与 Chunk Repository [MVP 必做]

- [ ] 新增 `RAGChunk` database model。
- [ ] 新增 `rag_chunks` migration。
- [ ] `rag_chunks` 支持 readme / notes / summary / metadata source。
- [ ] `rag_chunks` 增加 `parent_type`: repo / readme_section / notes / summary / metadata。
- [ ] `rag_chunks` 增加 `parent_key` 与 `parent_title`。
- [ ] `rag_chunks` 使用 `(repo_id, source, source_id, chunk_key)` 唯一约束。
- [ ] `rag_chunks` 增加 `(repo_id, parent_type, parent_key)` 索引。
- [ ] `rag_chunks.chunk_key` 用于稳定 diff,`chunk_index` 只用于展示顺序。
- [ ] `rag_chunks` 增加 `embedding_status`: pending / ready / failed / stale。
- [ ] `rag_chunks` 增加 `embedding_error` 记录 embedding 失败原因。
- [ ] embedding 使用 Float32 BLOB,与现有 `RepoEmbedding` 编解码风格一致。
- [ ] 新增 `RAGChunkRepositoryProtocol`。
- [ ] 实现 chunk upsert。
- [ ] 实现按 repo/source 删除 stale chunks。
- [ ] 实现按当前 embedding model 查询可用 chunks。
- [ ] 查询可用 chunks 时只返回 `embedding_status = ready` 的 chunk。
- [ ] 实现知识库 RAG 覆盖率统计。
- [ ] 覆盖率统计包含 pending / failed / stale chunk 数。
- [ ] 单测覆盖同 repo 多 source 多 chunk。
- [ ] 单测覆盖 child chunk 正确保存 parent_type / parent_key / parent_title。
- [ ] 单测覆盖 README 中间插入章节后,未变 chunk 通过 `chunk_key` 复用 embedding。
- [ ] 单测覆盖 content_hash 不变时不重复写 embedding。
- [ ] 单测覆盖 content_hash 变化时 chunk 进入 `pending`。
- [ ] 单测覆盖 embedding 成功后 chunk 进入 `ready`。
- [ ] 单测覆盖 embedding 失败后 chunk 进入 `failed` 并记录错误。
- [ ] 单测覆盖换 embedding model 后覆盖率变 stale。

## 5. PR-2: Chunk Builder 与索引器 [MVP 必做]

- [ ] 新增 `RAGChunkBuilder`。
- [ ] README 按 markdown heading 切分。
- [ ] README 切分默认参数: target 700 / min 180 / max 1100 / overlap 80 / hard max 1600 tokens。
- [ ] 小 section 合并。
- [ ] 大 section 优先按 child heading 拆分。
- [ ] child heading 后仍超长时按段落滑窗拆分。
- [ ] 只有超长 section 拆分时使用 overlap,普通 section 不加 overlap。
- [ ] 代码块不在中间硬切。
- [ ] 超长代码块超过 hard max 时保留开头和结尾,中间用 `...` 标记。
- [ ] 大表格保留表头,按行切分或截断。
- [ ] 被截断 chunk 记录 truncated 标记,Inspector 可展示“内容已截断”。
- [ ] 清理 badge / 图片 / 目录列表等低价值内容。
- [ ] 用户 notes 生成高权重 `notes` chunk。
- [ ] 已存在 AI summary 生成 `summary` chunk。
- [ ] repo metadata 生成 `metadata` chunk,包含 fullName / description / topics / language / stars / forks / watchers / issues / license / archived/fork / 是否 starred / status / tags / libraryUpdatedAt。
- [ ] 不为了 RAG 索引临时触发 AI summary。
- [ ] 新增 `RAGIndexBuilder`。
- [ ] `RAGIndexBuilder` 默认只取 `fetchKnowledgeRepos()`。
- [ ] repo 加入知识库后排队索引该 repo。
- [ ] README 缓存更新后,若 repo 在知识库则更新 readme chunks。
- [ ] README 更新只处理 `source = readme`,不重建 notes / summary / metadata。
- [ ] notes 保存后,若 repo 在知识库则 debounce 更新 notes chunk。
- [ ] notes 更新只处理 `source = notes`,notes 为空时删除或 stale notes chunk。
- [ ] AI summary 生成后,若 repo 在知识库则更新 summary chunk。
- [ ] AI summary 从无到有时新增 `summary` chunk。
- [ ] AI summary 重新生成时只更新 `source = summary`。
- [ ] metadata 更新只处理 `source = metadata`。
- [ ] metadata 数字字段 stars / forks / watchers / issues 使用 bucket 或节流,避免轻微变化反复 embedding。
- [ ] 精确 star / fork / issue 排序走结构化字段查询,不依赖 metadata embedding 文本。
- [ ] 移出知识库不立即删除 chunk 和 embedding。
- [ ] 单测覆盖已 star 未入库 repo 不进入 RAG 索引默认候选。
- [ ] 单测覆盖未 star 已入库 repo 进入 RAG 索引默认候选。
- [ ] 单测覆盖 README 更新不影响 notes / summary / metadata chunks。
- [ ] 单测覆盖 5k tokens README 可切成稳定的 6-10 个 readme chunks。
- [ ] 单测覆盖小 section 与相邻 section 合并。
- [ ] 单测覆盖超长 section 按 child heading 优先拆分。
- [ ] 单测覆盖 child heading 仍超长时按段落滑窗拆分并带 overlap。
- [ ] 单测覆盖代码块不会被中间切断。
- [ ] 单测覆盖超长代码块 hard truncate 并记录 truncated。
- [ ] 单测覆盖大表格保留表头。
- [ ] 单测覆盖 notes 更新不影响 readme / summary / metadata chunks。
- [ ] 单测覆盖 summary 从无到有只新增 summary chunk。
- [ ] 单测覆盖 metadata 数字字段未跨 bucket 时不重建 embedding。

## 6. PR-3: Query Planner 与执行状态机 [MVP 必做 / 远程上下文后置]

> MVP 只做自然语言优化、结构化筛选、SQL 候选、no_candidate_repos / no_index / no_evidence。`remoteContextRequests` schema 可以先保留,issues / releases / PR 的真实触发与执行放 PR-5。

- [ ] 新增 `KnowledgeRAGQueryPlanner`。
- [ ] Query Planner 使用 AI 小模型层,只输出结构化 JSON,不回答用户问题。
- [ ] Planner prompt 包含 Starcat 支持的筛选字段、字段含义、枚举和日期语义。
- [ ] 支持 `semantic_only` mode: 无结构化筛选时只改写 semanticQuery。
- [ ] 支持 `filtered_semantic` mode: SQL repo filter 后再做 child retrieval。
- [ ] 支持 `structured_only` mode: 只有筛选/排序时不做 child retrieval,直接用 metadata/summary bundle 输出列表。
- [ ] 支持 `needs_clarification` mode: 日期或字段语义不明确时追问,不执行检索。
- [ ] Planner schema 包含 filters / sort / candidateLimit / remoteContextRequests / confidence / clarificationQuestion / userVisiblePlan。
- [ ] Planner 在普通知识库问答中返回空 `remoteContextRequests`。
- [ ] Planner 在 issues / bug / crash / 用户反馈语义中返回 `github_issues` remote request。
- [ ] Planner 在 release / 版本 / breaking change 语义中返回 `github_releases` remote request。
- [ ] Planner 在 PR / 维护活跃度语义中返回 `github_pull_requests` remote request。
- [ ] Planner 输出必须做 JSON schema validation。
- [ ] Planner invalid JSON 时重试一次。
- [ ] Planner 重试仍失败时降级为 `semantic_only(original question)`。
- [ ] Planner 引用不支持字段时丢弃该字段;丢弃后 plan 无效则降级。
- [ ] Planner remote request 的 maxRepos / perRepoLimit 必须本地钳制上限。
- [ ] Planner 不支持的 remote resource 必须丢弃。
- [ ] `confidence = medium` 时执行但 UI chips 可删除/修改。
- [ ] `needs_clarification` 时 UI 只追问,不进入 SQL / retrieval。
- [ ] SQL filter 0 repo 时返回 `no_candidate_repos`。
- [ ] 有候选 repo 但无 ready chunks 时返回 `no_index`。
- [ ] 有 chunks 但低相关时返回 `no_evidence`,不让 Generator 编答案。
- [ ] structured_only 有 repo 时跳过 child retrieval。
- [ ] Query Plan chips 展示范围、筛选、排序和语义改写。
- [ ] Query Plan chips 展示远程临时上下文 request。
- [ ] 单测覆盖无筛选问题返回 `semantic_only`。
- [ ] 单测覆盖筛选 + 语义问题返回 `filtered_semantic`。
- [ ] 单测覆盖只有筛选/排序问题返回 `structured_only`。
- [ ] 单测覆盖模糊日期问题返回 `needs_clarification`。
- [ ] 单测覆盖 invalid JSON 重试与降级。
- [ ] 单测覆盖 unsupported field 丢弃与降级。
- [ ] 单测覆盖普通问题不触发 remote request。
- [ ] 单测覆盖 issues / release / PR 语义触发对应 remote request。
- [ ] 单测覆盖 remote request 预算钳制。
- [ ] 单测覆盖 SQL 0 repo / no_index / no_evidence 三类返回。

## 7. PR-4: Retriever [MVP 必做]

- [ ] 新增 `KnowledgeRAGRetriever`。
- [ ] 新增 `RAGKeywordSearchProvider`。
- [ ] 新增 `RAGVectorSearchProvider`。
- [ ] 新增 `RAGHybridFusionEngine`。
- [ ] 新增 `RAGRerankProvider` protocol,默认 off。
- [ ] Retriever 查询必须 join 当前账号的 `repo_notes.library_state = 'in_library'`。
- [ ] Retriever 只召回 `embedding_status = ready` 的 chunk。
- [ ] 已 star 但未入库 repo 不召回。
- [ ] 未 star 已入库 repo 可以召回。
- [ ] 支持 SQLite FTS5 keyword retrieval。
- [ ] 支持 local vector retrieval。
- [ ] 支持 query embedding。
- [ ] 支持 chunk cosine 排序。
- [ ] 支持 RRF 或 weighted score fusion。
- [ ] 支持命中方式标记: keyword / vector / hybrid。
- [ ] 支持 source 权重: notes > summary > readme > metadata。
- [ ] 支持每 repo 最多 3 个 chunks。
- [ ] 支持 keyword topK 默认 30。
- [ ] 支持 vector topK 默认 30。
- [ ] 支持 fusion topK 默认 20。
- [ ] 支持 rerank topK 默认 8,但第一版 reranker off。
- [ ] 支持 top repos 默认 5。
- [ ] child hits 按 repo_id 聚合。
- [ ] repoScore 综合 max child score、top children average、source boost、metadata boost。
- [ ] Retriever 输出 `RepoContextBundle`,不直接把 flat top chunks 交给 Generator。
- [ ] `RepoContextBundle` 包含 metadata / notes / summary / matched children / section parents / remoteContextBlocks。
- [ ] top repo 的 section parent 可带入 matched child 的 sibling chunks。
- [ ] token budget 按 repoScore 分配,并设置 per repo hard cap。
- [ ] 接收 Query Planner 产出的 candidate repo ids。
- [ ] 接收 Command Composer 产出的 explicit repo ids。
- [ ] `explicitRepoMode = only` 时只检索 explicit repo ids。
- [ ] `explicitRepoMode = exclude` 时排除 explicit repo ids。
- [ ] 无索引时返回 `no_index`,不伪装成无结果。
- [ ] 低相关时返回 `no_evidence`。
- [ ] 单测覆盖知识库边界。
- [ ] 单测覆盖 per repo limit。
- [ ] 单测覆盖 source 权重。
- [ ] 单测覆盖 keyword-only 命中可召回精确关键词。
- [ ] 单测覆盖 vector-only 命中可召回语义相近问题。
- [ ] 单测覆盖 keyword + vector fusion 排序。
- [ ] 单测覆盖命中方式写入 Inspector 所需字段。
- [ ] 单测覆盖 child hits 聚合为 repoScore。
- [ ] 单测覆盖 `RepoContextBundle` 打包 metadata / notes / summary / matched children / section parents。
- [ ] 单测覆盖 `.only` 模式下 explicit repo 无索引时不扩大到其他 repo。
- [ ] 单测覆盖单个 repo 不能吞掉全部 token budget。

## 8. PR-5: Remote Ephemeral Context Provider [MVP 后置]

> MVP 只识别 issues / releases / PR 意图并提示当前版本未启用,不实际拉取远程数据。真实 provider、TTL cache、降级 block 和远程上下文 Inspector 放本 PR。

- [ ] 新增 `KnowledgeRAGRemoteContextProvider`。
- [ ] 定义 `RAGRemoteContextRequest`。
- [ ] 定义 `RAGRemoteContextResource`: github_issues / github_pull_requests / github_releases / github_contributors / github_commit_activity / github_security_advisories。
- [ ] 定义 `RAGRemoteContextBlock`。
- [ ] 定义 `RAGRemoteContextDegradation`: unauthenticated / forbidden / rateLimited / timeout / networkError / unsupported。
- [ ] Provider 只接收 Retriever 输出的 top `RepoContextBundle`。
- [ ] Provider 不允许从全量 GitHub 搜索后绕过知识库边界。
- [ ] GitHub Issues provider 支持按 repo 拉取 issues。
- [ ] GitHub Issues provider 输出 LLM 友好文本,不透传 raw JSON。
- [ ] Issues context 包含 query / sampled_open_issues / source URL / issue number / state / updatedAt / comments / labels / title / body_excerpt。
- [ ] Issues context 可输出轻量 observed_themes。
- [ ] GitHub Releases provider 支持拉取最新 releases。
- [ ] GitHub Pull Requests provider 支持拉取近期 PR。
- [ ] remote context 默认只拉 top 5 repos。
- [ ] issues / PR 默认每 repo 最多 10 条。
- [ ] releases 默认每 repo 最多 5 条。
- [ ] remote context 总 token budget 默认 3000。
- [ ] 支持 15min TTL cache,但不写入 `rag_chunks`。
- [ ] timeout / rate limit / forbidden 返回 degradation block,不让整轮 RAG 失败。
- [ ] remote blocks 合并回 `RepoContextBundle.remoteContextBlocks`。
- [ ] 单测覆盖普通问题不调用 provider。
- [ ] 单测覆盖 provider 只接收 top repo bundles。
- [ ] 单测覆盖 issues 文本格式。
- [ ] 单测覆盖 maxRepos / perRepoLimit / token budget。
- [ ] 单测覆盖 rate limit / timeout / forbidden 降级。
- [ ] 单测覆盖 remote context 不写入 `rag_chunks`。

## 9. PR-6: Generator 与 Citation [MVP 必做]

- [ ] 新增 `KnowledgeRAGPromptBuilder`。
- [ ] System prompt 明确只能基于 Starcat 知识库片段和本轮远程临时上下文回答。
- [ ] Prompt context 使用 repo bundle,包含 repo metadata / notes / summary / matched children / section parent / remote context。
- [ ] Prompt context 中每个 matched child 保留 chunk id / source / section / score。
- [ ] Prompt context 明确区分 local indexed context 与 remote ephemeral context。
- [ ] 新增 `KnowledgeRAGService.ask(...)` streaming 入口。
- [ ] streaming 先发出 `planningStarted` 与 `planCreated`。
- [ ] `needs_clarification` 时发出 `clarificationRequired`,不继续 retrieval。
- [ ] `no_candidate_repos` / `no_index` / `no_evidence` 时发出 `noResult`,不调用 Generator。
- [ ] retrieval 阶段发出 `retrievalStarted/retrievalCompleted` 事件。
- [ ] `retrievalCompleted` 返回 `RepoContextBundle` 列表,不是 flat chunk hits。
- [ ] remote context 阶段发出 `remoteContextStarted/remoteContextCompleted/remoteContextDegraded` 事件。
- [ ] generation 阶段发出 `answerDelta` 事件。
- [ ] 支持用户取消 streaming。
- [ ] 新增 `KnowledgeRAGCitationParser`。
- [ ] citation parser 只接受本轮 `RepoContextBundle` 中出现的 repo。
- [ ] citation parser 把 repo citation 绑定到该 repo 的 top matched children。
- [ ] LLM 引用上下文外 repo 时过滤该 citation。
- [ ] 无命中时不调用 chat 模型。
- [ ] 使用 remote context 时答案说明这是本轮临时获取的信息。
- [ ] remote context 降级时答案说明对应 GitHub 数据不可用。
- [ ] API key 缺失时返回可展示错误。
- [ ] 单测覆盖 prompt 知识库边界。
- [ ] 单测覆盖 prompt 使用 repo bundle 而不是 flat chunks。
- [ ] 单测覆盖 prompt 区分 local indexed context 和 remote ephemeral context。
- [ ] 单测覆盖 remote degradation 会进入最终提示词。
- [ ] 单测覆盖 citation 过滤。
- [ ] 单测覆盖 repo citation 能绑定 matched child chunks。
- [ ] 单测覆盖无命中不调用 chat。

## 10. PR-7: 知识库问答工作台 UI [MVP 必做 / 部分后置]

> MVP 只做 Debug gate 入口、基础工作台、历史 rail、`@repo` mention、context chips、输入框模型下拉、streaming answer、citation 与 Evidence Inspector。toolbar 正式入口、附件真实解析、远程上下文确认流程、完整 model/attachment 能力矩阵后置。

- [ ] 新增 `KnowledgeRAGWorkspaceView`。
- [ ] 新增 `KnowledgeRAGWorkspaceViewModel`。
- [ ] 新增 `RAGCommandComposerView`。
- [ ] 新增 `RAGMentionPicker`。
- [ ] 新增 `RAGContextChip`。
- [ ] `HomeView` 增加 `showKnowledgeRAGWorkspace` 覆盖层。
- [ ] Debug 菜单增加 RAG workspace 入口显示开关。
- [ ] toolbar 增加“知识库问答”入口,默认按 Debug gate 控制。
- [ ] Smart Collections -> 知识库页增加打开“知识库问答”的动作。
- [ ] 工作台左侧展示历史 rail。
- [ ] 历史 rail 支持新建会话。
- [ ] 历史 rail 支持继续已有会话。
- [ ] 工作台顶部展示范围: 知识库。
- [ ] 工作台顶部展示知识库 repo 数。
- [ ] 工作台顶部展示 RAG 索引覆盖率。
- [ ] Command Composer 支持 `@repo` mention。
- [ ] `@repo` picker 默认只展示知识库 repo。
- [ ] `@repo` picker 支持 owner/name、description、topics、language、tags、status 搜索。
- [ ] 多个 `@repo` 默认生成 `explicitRepoMode = only`。
- [ ] mention repo 不在知识库时提示“不在知识库,默认不参与 RAG”。
- [ ] context chips 支持删除,删除后同步更新执行上下文。
- [ ] Command Composer 提供模型下拉。
- [ ] 模型下拉默认读取 Settings -> AI 的 RAG chat model。
- [ ] 本轮模型切换不修改全局 Settings。
- [ ] 模型选择器标注缺 API key / 不支持 vision / 不支持附件等不可用原因。
- [ ] Planner 提议 issues / releases 远程上下文时,Query Plan chips 展示可删除确认 chip。
- [ ] MVP 中 Planner 提议 issues / releases 远程上下文时,UI 显示“当前版本暂未启用”。
- [ ] MVP 中回答明确说明未包含实时 issues / releases / PR 数据。
- [ ] 删除远程上下文确认 chip 后,本轮跳过对应 remote request。
- [ ] 附件 chip 展示文件名、类型、大小和是否会发送给模型。
- [ ] 图片附件遇到不支持 vision 的模型时阻断发送。
- [ ] 文本/PDF 附件第一版可先只做 UI 与数据结构,不进入 RAG 索引。
- [ ] 输入框粘贴 GitHub repo 链接时识别 owner/name。
- [ ] GitHub 链接命中已入库 repo 时转成 repo chip。
- [ ] GitHub 链接命中已 star 未入库 repo 时不自动参与 RAG。
- [ ] GitHub 链接未命中 Starcat repo 时作为外部链接 chip。
- [ ] 工作台展示 Query Plan chips: 范围 / 筛选 / 排序 / 语义。
- [ ] 工作台展示 Query Plan chips: GitHub Issues / Releases / PR 临时上下文。
- [ ] `needs_clarification` 时展示追问,不展示伪答案。
- [ ] `no_candidate_repos` 时展示“知识库中没有符合筛选条件的项目”。
- [ ] `no_index` 时展示“符合条件的项目还没有 RAG 索引”并引导构建索引。
- [ ] `no_evidence` 时展示“没找到足够相关内容”,可展示候选 repo 但标注证据不足。
- [ ] 中间 Answer Surface 支持用户提问。
- [ ] 中间 Answer Surface 支持 streaming markdown。
- [ ] 右侧 Evidence Inspector 展示 citations。
- [ ] 右侧 Evidence Inspector 展示 repo parent、section parent 与 matched child。
- [ ] 右侧 Evidence Inspector 展示 chunk 原文、source、section、score。
- [ ] 右侧 Evidence Inspector 展示 Remote Context 区域。
- [ ] Remote Context 区域展示 resource / fetchedAt / query / source URL / 样本数量。
- [ ] Remote Context 区域展示 rate limit / forbidden / timeout 等降级原因。
- [ ] Remote Context 不展示为已索引 chunk,不提供打开 chunk 动作。
- [ ] `RAGCitationChip` 点击后定位右侧 evidence。
- [ ] citation 的“打开详情”能关闭 workspace 并选中 repo。
- [ ] 回答区 GitHub 链接命中 Starcat 已有 repo 时打开内部详情。
- [ ] 回答区 GitHub 链接未命中 Starcat repo 时打开外部 GitHub。
- [ ] 知识库为空时展示引导。
- [ ] RAG 索引缺失时展示构建索引引导。
- [ ] API key 缺失时展示配置引导。
- [ ] 用户取消时 UI 停止 streaming 并保持已有输出。
- [ ] UI 文案补齐 i18n。

## 11. PR-8: 历史、Storage 与设置入口 [MVP 必做 / 部分后置]

> MVP 必须保存完整本地会话历史,但不保存完整 chunk 内容快照。复制/导出回答、外部 provider 配置 UI 可以后置。

- [ ] 新增 `rag_conversations` / `rag_messages` / `rag_message_citations`。
- [ ] 新增 `RAGConversationStore`。
- [ ] 支持新建会话。
- [ ] 支持会话历史列表。
- [ ] 支持本地保存 cited chunk ids。
- [ ] citation 保存 repo id / chunk id / source / section title / score / hit kind。
- [ ] citation 不保存完整 chunk content snapshot。
- [ ] chunk 被清理后,历史 citation 显示“引用片段已清理或需要重建索引”。
- [ ] 支持复制回答 markdown。
- [ ] 支持导出回答 markdown。
- [ ] Settings -> AI 展示 RAG 索引状态。
- [ ] Settings -> AI 支持开始 / 暂停 / 重建 RAG 索引。
- [ ] Settings -> AI 展示 RAG Backend: Local / Custom。
- [ ] Settings -> AI 展示 Keyword Search Provider: FTS5 / Meilisearch。
- [ ] Settings -> AI 展示 Vector Store Provider: SQLite / Qdrant。
- [ ] Settings -> AI 展示 Reranker: Off / Cloud / Local。
- [ ] Meilisearch / Qdrant 配置默认隐藏在高级设置。
- [ ] Provider API key 存 Keychain,配置只保存 reference。
- [ ] Provider 切换后提示是否需要重建索引。
- [ ] 私有 repo 安全模式默认不上传代码内容到云 embedding 或远程 RAG provider。
- [ ] Settings -> Storage 展示 RAG chunk cache 大小。
- [ ] Settings -> Storage 展示 RAG conversation history 大小。
- [ ] Settings -> Storage 支持清除 RAG 索引。
- [ ] Settings -> Storage 支持清除 RAG 会话历史。
- [ ] 清除 RAG 索引不影响 repo metadata / README cache / notes / AI summaries / repo-level embeddings / libraryState。
- [ ] 清除 RAG 索引不影响 remote context TTL cache。
- [ ] remote context TTL cache 可随普通网络缓存清理。

## 12. PR-9: 自托管检索 Provider 后续增强 [高级增强]

- [ ] 新增 Meilisearch keyword provider。
- [ ] Meilisearch provider 支持 endpoint / API key / indexName 配置。
- [ ] Meilisearch provider 支持连接测试。
- [ ] Meilisearch provider 连接失败时回退 Local FTS5。
- [ ] 新增 Qdrant vector provider。
- [ ] Qdrant provider 支持 endpoint / API key / collectionName / vectorName 配置。
- [ ] Qdrant provider 支持 collection health check。
- [ ] Qdrant provider 检查 embedding dim / vectorName 是否匹配。
- [ ] Qdrant provider 连接失败时回退 Local SQLite vector。
- [ ] provider 切换后索引状态显示 stale / needs_rebuild。
- [ ] 单测覆盖 provider 配置 validation。
- [ ] 单测覆盖 health check 成功 / 失败 / 回退。

## 13. PR-10: Agent / MCP 后续联动 [高级增强]

- [ ] Agent runtime 可把 `KnowledgeRAGRetriever` 作为只读 tool。
- [ ] Agent Artifact 可引用 RAG citations。
- [ ] RAG 回答中的“生成对比报告”可转入 Agent Workspace。
- [ ] MCP 可暴露只读 RAG evidence 查询能力。
- [ ] 所有写入建议仍必须走用户确认,不得由 RAG 或 Agent 自动写库。

## 14. 验证记录

- [ ] `rtk xcodegen generate`
- [ ] `rtk jq empty Starcat/Resources/Localizable.xcstrings`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RAGChunkRepositoryTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RAGChunkBuilderTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/KnowledgeRAGQueryPlannerTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/KnowledgeRAGRetrieverTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RAGHybridFusionEngineTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RAGBackendConfigurationTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/KnowledgeRAGRemoteContextProviderTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/KnowledgeRAGServiceTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build`
- [ ] `rtk git diff --check`

## 15. 人工验证流程

### 15.1 准备数据

- [ ] 准备 A: 已 star 且已入库 repo。
- [ ] 准备 B: 已 star 且未入库 repo。
- [ ] 准备 C: 未 star 且已入库 repo。
- [ ] 准备 D: 知识库为空的测试账号或临时库。
- [ ] 准备 E: 有 README / notes / AI summary 的 repo。
- [ ] 准备 F: 有近期 issues / releases 的已入库 public repo。

### 15.2 索引

- [ ] RAG 索引只统计知识库 repo。
- [ ] B 不进入 RAG 默认索引候选。
- [ ] C 能进入 RAG 默认索引候选。
- [ ] 修改 notes 后,RAG notes chunk 更新。
- [ ] 修改 README 缓存后,RAG readme chunk 更新。
- [ ] 移出知识库后,chunk 保留但不再被 RAG 召回。

### 15.3 问答

- [ ] 打开知识库问答工作台。
- [ ] 提问后先显示检索状态,再 streaming 输出回答。
- [ ] 输入 `@` 能弹出知识库 repo list。
- [ ] 选择两个 `@repo` 后提问对比,回答只围绕这两个 repo。
- [ ] 删除 repo chip 后重新提问,不再限制到该 repo。
- [ ] 提问涉及 issues 时,Planner 识别 GitHub Issues 临时上下文需求。
- [ ] MVP 中 issues 类问题显示“当前版本暂未启用 GitHub 临时上下文”。
- [ ] MVP 中回答明确说明未包含实时 issues / releases / PR 数据。
- [ ] 精确关键词问题能通过 keyword 命中召回。
- [ ] 语义描述问题能通过 vector 命中召回。
- [ ] Evidence Inspector 展示 keyword / vector / hybrid 命中方式。
- [ ] 本轮切换模型后,Settings 中全局模型不变化。
- [ ] 上传不支持的附件时展示不可发送状态。
- [ ] 粘贴已入库 GitHub repo 链接时转成 repo chip。
- [ ] 粘贴外部 GitHub repo 链接时保留外部链接 chip。
- [ ] 回答引用 A / C 这类已入库 repo。
- [ ] 回答不引用 B 这类已 star 未入库 repo。
- [ ] 引用 chip 点击后右侧 evidence 定位到对应 chunk。
- [ ] 点击“打开详情”能回到 repo 详情。
- [ ] 回答中的 GitHub 链接命中已有 repo 时打开 Starcat 详情。
- [ ] 回答中的外部 GitHub 链接打开浏览器。
- [ ] 知识库资料不足时,回答明确说明不足。
- [ ] 知识库为空时,不允许进入伪问答状态,而是展示引导。

### 15.4 自托管 Provider 设置

- [ ] 默认 Local backend 无需 Meilisearch / Qdrant 即可使用 RAG。
- [ ] 打开高级设置后可填写 Meilisearch endpoint / API key / index。
- [ ] 打开高级设置后可填写 Qdrant endpoint / API key / collection / vectorName。
- [ ] 连接测试失败时不影响 Local backend。
- [ ] provider 切换后提示需要重建索引。

### 15.5 远程临时上下文

- [ ] 提问“这些项目最近有没有集中反馈的问题”时,Query Plan chips 显示 GitHub Issues 临时上下文。
- [ ] 真实远程上下文启用后,用户删除 GitHub Issues 确认 chip 时本轮不拉取 issues。
- [ ] 远程上下文只对已入库候选 repo 拉取。
- [ ] 右侧 Inspector 展示 issues resource / fetchedAt / source URL。
- [ ] 断网或 rate limit 时,回答说明 GitHub Issues 暂不可用,并继续基于本地知识库回答。
- [ ] issues 数据不出现在 RAG chunk 索引统计中。

### 15.6 只读边界

- [ ] RAG 提问不修改 tags。
- [ ] RAG 提问不修改 notes。
- [ ] RAG 提问不修改 status。
- [ ] RAG 提问不调用 GitHub star/unstar。
- [ ] RAG 提问不修改 libraryState。
