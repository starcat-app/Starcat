# RAG Wiki 元数据实施方案

> 状态：已确认，待按 Checklist 实施
> 日期：2026-07-17
> 范围：Wiki 链接缓存、知识库 Metadata 分片、RAG Prompt 与知识库浏览器
> 关联清单：`RAG-Wiki元数据Checklist.md`

## 1. 目标与边界

本方案不抓取 DeepWiki、ZRead、CodeWiki 的正文，也不新增 Wiki 专用分片。Starcat 只查询公开仓库是否已被这些站点收录，将有效站点链接写入仓库现有的唯一 `.metadata` 分片，并让 RAG 在使用某个仓库内容时必定携带该仓库的完整 Metadata。

最终语义是：

- 每个入库仓库继续只有一个 `metadata:0` 分片；
- Metadata 在知识库浏览器中可查看、可编辑，但不可删除或排除；
- Wiki 查询统一通过本地磁盘缓存，网络补齐不阻塞详情页、索引或问答；
- 任何进入最终证据集合的仓库，都携带该仓库的完整 Metadata；
- 完整 Metadata 可用时不再重复生成精简元数据；缺失时才使用精简兜底；
- 维持“没有独立 `{metadataSection}`”，完整 Metadata 仍属于 `{evidenceSection}` 的仓库上下文头；
- Wiki 链接可在知识库分片列表和 LLM Markdown 回答中点击打开。

### 1.1 不做事项

- 不抓取、解析、索引 Wiki 正文；
- 不创建 Wiki 专用 `rag_chunks` source 或数据库 schema；
- 不新增 `{metadataSection}`、Wiki 执行步骤、Debug stage、引用类型或独立 token budget；
- 不向 DeepWiki、ZRead、CodeWiki 发送私有仓库 identity；
- 不把 Metadata 伪装成额外检索命中或额外 citation。

## 2. Wiki 查询与缓存

### 2.1 统一入口

详情页、全局搜索详情、Repo AI Chat、Companion 与后台补齐统一使用 `WikiContextService`，不允许各入口直接调用 `WikiAPIService.fetchStatus` 后只保留内存结果。

服务只接受 `owner/name` 和仓库公开性，输出 DeepWiki、ZRead、CodeWiki 中状态为 `indexed` 且 URL 为 `http` / `https` 的链接。私有仓库直接返回空结果，不发网络请求。

### 2.2 cache-first 语义

| 缓存状态 | 前台读取 | 后台行为 |
|---|---|---|
| fresh | 立即返回缓存 | 不联网 |
| stale | 立即返回旧值 | 低优先级刷新 |
| miss | 立即返回空值 | 低优先级探测 |

详情页、RAG 索引和问答均不等待 Wiki 网络请求。需要用户主动强制刷新时，仍可使用显式 blocking refresh，但结果必须写入同一磁盘缓存。

详情页与全局搜索详情在 cold miss / stale 刷新完成后监听缓存 change 事件，identity 与当前仓库一致时只读缓存并原地回填链接；缓存 reset 时同步移除仍在屏幕上的旧链接。Repo AI 与 Companion 保持一次请求快照语义，不在流式回答中途改变上下文字段。

### 2.3 后台补齐协调器

新增有界后台队列，负责：

- App 当前用户数据库就绪后扫描已有知识库仓库；
- 新仓库加入知识库时自动入队；
- fresh 缓存跳过、stale/miss 入队；
- 同一 `owner/name` 在排队和执行期间去重；
- 固定小并发执行，避免同时请求大量外部站点；
- 网络失败静默降级，沿用缓存 TTL 在后续扫描重试；
- 账号或数据库切换时取消旧任务、清空旧队列并推进 generation，旧请求完成后不得写入新账号的 RAG 数据库；
- 私有仓库在入队前与执行前双重拦截。

`DiskWikiCache` 是公开仓库 Wiki 状态的跨账号磁盘缓存；知识库 Metadata 重建则只针对当前用户数据库。缓存保存、更新或清空后发布变更事件，由当前数据库的索引构建器按仓库精确刷新。

## 3. Metadata 分片

### 3.1 内容格式

继续由 `RAGChunkBuilder.buildMetadata` 生成一个 `metadata:0`、`keyword_only` 分片。在现有仓库、标签、Release、Health、OpenSSF 等内容后按固定顺序追加有效链接：

```text
Wiki DeepWiki: https://...
Wiki ZRead: https://...
Wiki CodeWiki: https://...
```

未收录、查询失败、空 URL、非 `http` / `https` URL 一律省略，不写 `Unknown`。

### 3.2 重建触发

`KnowledgeRAGIndexBuilder` 只读取 `DiskWikiCache`，不得在索引任务内等待网络：

- Wiki 缓存首次保存或内容变化：只重建对应 repo 的 Metadata source；
- 清空 Wiki 缓存：重建受影响仓库 Metadata，移除旧链接；
- 其它 Metadata 本地事实变更：沿用现有 repo 合并刷新机制；
- 内容无变化时由现有 hash/diff 语义避免无意义写入与 Embedding 工作。

本功能复用已发布 RAG schema，不新增 migration。

## 4. Prompt 与检索语义

### 4.1 最终仓库必带完整 Metadata

Retriever 完成召回、过滤、重排和最终仓库分组后，批量读取所有最终仓库的有效 `metadata:0`。这里的 Metadata 是附加到仓库 bundle 的固定上下文头，不新增 hit，不改变 score、retrieval funnel 或 citation 数量。

仓库最终 bundle 规则：

1. 存在未排除的完整 Metadata：使用完整正文；
2. 完整 Metadata 不存在或被排除：使用现有精简元数据兜底；
3. `structured_only` 没有普通 repo bundle，继续使用精简元数据，不强制加载全库 Metadata；
4. 完整 Metadata 已使用时，禁止再输出精简元数据，避免重复；
5. Metadata 本身被 FTS 命中时，仍归一为同一个仓库上下文头，不重复输出。

### 4.2 Prompt 协议

维持现有 Generator 协议：

- `{evidenceSection}`：每个仓库的完整 Metadata 头 + 被选中的普通分片正文与 citation marker；
- `{questionSection}`：知识库聚合元数据快照与用户问题；
- `{repoContextSection}`：深度思考 RepoContext XML；
- `{remoteSection}`：GitHub / External Search 临时上下文；
- `{attachmentSection}`：附件。

不新增 `{metadataSection}`。仓库 Metadata 是 evidence 内的无 citation 背景事实，普通分片继续使用原有 `[S<n>]` marker。

### 4.3 预算优先级

Metadata 不受“某一个分片是否命中”的限制，但仍占用模型总输入窗口。组装 evidence 时优先保证最终保留仓库的 Metadata 完整性：

1. 第一阶段先为所有可保留的最终仓库装配完整 Metadata，期间不加入任何普通分片；
2. 第二阶段再按现有得分和上下文规则为这些仓库加入普通分片；
3. 空间不足时先裁剪/移除低优先级普通分片，不对 Metadata 做半行或字符硬截断；
4. 若连 Metadata 与最小问题上下文都无法容纳，则减少最终仓库数量，而不是保留仓库却丢掉其 Metadata；
5. RepoContext XML 继续使用独立 `{repoContextSection}` 和既有总窗口预算，不受本方案改变。

## 5. 知识库浏览器与链接

### 5.1 Metadata 禁删

Metadata 是仓库上下文完整性的系统分片，删除或排除都会破坏“命中仓库必带元数据”的契约，因此需要多层防线：

- UI：Metadata 行不显示删除按钮；
- ViewModel / service：拒绝 Metadata 的软删除、排除与永久删除请求；
- Repository / domain：根据 source / chunk key 再次拒绝，防止未来新增入口绕过 UI；
- 其它 README、Notes、Summary 分片的删除与恢复行为保持不变。

本需求只禁止删除和排除，不禁止查看、打开编辑器或保存 Metadata override。

### 5.2 Wiki 链接展示

知识库右侧分片列表在 Metadata 行解析 `Wiki <Provider>: <URL>`，以紧凑的 provider 链接展示。点击使用 `NSWorkspace` 打开经过 `http` / `https` 校验的外部 URL，不使用私有 URL scheme，也不触发分片编辑按钮。

LLM 已能从完整 Metadata 看到这些 URL；回答正文继续复用现有 Markdown 外链处理，不新增渲染协议。

## 6. 测试与验收

至少覆盖：

- `WikiContextService` fresh/stale/miss、URL 过滤、写缓存与私有仓库零请求；
- 后台队列有界并发、repo 去重、启动扫描、新入库触发、失败降级、账号切换取消与旧 generation 防写；
- Wiki 缓存变化触发对应 repo Metadata 精确重建，清缓存移除链接；
- Metadata 输出顺序、空值省略、只读缓存且不发网络；
- 最终 repo bundle 必带完整 Metadata、完整优先、精简 fallback、无重复、`structured_only` 保持精简；
- Metadata 优先预算策略与不新增 citation/hit；
- Metadata UI 无删除入口，ViewModel 与 Repository 均拒绝删除/排除；
- Wiki URL 解析仅接受 `http` / `https`，点击走系统浏览器；
- `Localizable.xcstrings` en / zh-Hans、RAG 定向测试、全量测试与双 target Debug build。

人工 UI 验收若无法自动观察，必须在结果报告中明确列为待人工验证，不能伪造完成。

## 7. 交付与审查流程

- 基于 `dev` 的独立 worktree / `codex/rag-wiki-metadata` 分支实施；
- 方案、Checklist 与每个小功能均使用独立中文 commit；
- 不 push，不执行打包、发布或上传；
- 至少进行三轮审查：架构与数据边界、UI 与 Prompt 语义、测试与文档工程一致性；
- 每轮先新增审查报告并提交，再修复报告发现并独立提交；
- 最后一轮必须无新增功能缺口；
- Checklist 全部回填后新增结果报告；
- `docs/功能实现总览.md` 只读，需同步时仅提供草案，等待 dong4j 单独授权。
