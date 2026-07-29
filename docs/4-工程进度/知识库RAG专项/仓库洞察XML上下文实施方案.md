# 仓库洞察 XML 上下文实施方案

> 状态：已确认，实施中
> 日期：2026-07-30
> 范围：仓库洞察、仓库 AI 摘要与对话、知识库特殊分片、RAG 问答全链路
> 关联清单：`仓库洞察XML上下文Checklist.md`

## 1. 背景与目标

仓库洞察已经能够复用本地 SQLite、远端洞察缓存和 Star 历史仓储，为仓库 AI 摘要与对话生成 `<repository_insights>` 聚合上下文。但当前产物仍是 Prompt 专用字符串：安全提示与 XML 混在一起，没有独立 metadata、内容 hash、文件生命周期和 RAG 审计语义，也没有在仓库洞察页面完成加载后自动形成可复用文件。

本专项把仓库洞察提升为一个仓库级上下文资产：

- 生成合法、稳定、可校验的 `insights.xml`；
- 仓库洞察页面、仓库 AI 摘要、仓库 AI 对话与知识库 RAG 共用同一份结构化快照；
- XML 作为知识库特殊托管分片展示，但不写 `rag_chunks`、不向量化、不参与普通召回与索引覆盖率；
- 用户可以查看、复制、导出、删除和重新生成 XML，删除不影响真实洞察数据；
- RAG 在显式仓库和最终检索命中仓库范围内按独立预算注入 XML，并覆盖 Plan、时间线、Context、Evidence、Debug Trace、引用和历史审计；
- 避免新增第二套洞察请求、聚合缓存或 Prompt 专用数据模型。

## 2. 产品与数据边界

### 2.1 单一数据来源

洞察 SQLite 和 Star 历史仓储仍是真实数据来源。`insights.xml` 是可删除、可重建的派生产物，不拥有业务真相：

- 删除 XML 不删除 `repo_insights_snapshots`、Release、Health、OpenSSF、Community、Star 历史或其它本地缓存；
- XML 不写 CloudKit、notes、普通聊天消息或 External Search query；
- AI 摘要、AI 对话与 RAG 都消费同一个 Document，不各自拼装不同口径；
- 原始洞察缓存继续使用既有 TTL、ETag、single-flight、LRU 和 stale fallback。

### 2.2 XML 内容

根节点固定为 `<repository_insights>`，至少包含：

- `schema_version`、repo id、full name；
- `generated_at`、`source_updated_at`、`source_hash`；
- 最新 Release 与发布节奏；
- 健康度、OpenSSF、社区规范和安全聚合；
- PR / Issue 活动统计；
- 提交活动趋势；
- 贡献者集中度与安全处理后的 Top Contributors；
- Star 当前值、30 天 / 365 天增长和降采样趋势点；
- 各数据集的 `fetched_at`、`stale`、`partial` 与覆盖范围。

Issue / PR 标题、安全公告正文和其它高 Prompt Injection 风险文本不进入 XML。所有外部字符串必须 XML escape。

### 2.3 自动生成

- 仓库洞察默认数据准备完成后，在后台生成或更新 XML；
- AI 摘要 / 对话先触发时，等待本轮 Document 准备完成并写盘，再使用同一 XML；
- 洞察手动刷新成功后，根据新的 `sourceHash` 更新 XML；
- RAG 查询只读取已有 XML；若文件缺失但本地缓存已具备完整默认快照，可纯本地重建，不为 RAG 额外触发 GitHub / Discovery 网络请求；
- `sourceHash` 不变时不重复渲染和写盘；
- 同仓库并发生成使用 single-flight 合并。

### 2.4 删除抑制

RepoContext 只在显式请求时生成，删除后不需要 tombstone；洞察 XML 会自动生成，因此必须增加版本级删除抑制：

- 用户删除时移除 `insights.xml`，保留被删除版本的 `sourceHash`；
- 源数据 hash 未变化时，后台准备和 RAG 读取不得立即重建；
- 洞察刷新产生新 `sourceHash` 后允许自动重新生成；
- 用户主动点击“重新生成”时可忽略当前删除抑制；
- 删除抑制只控制派生 XML，不影响洞察页面和 AI 的真实数据缓存。

### 2.5 只读派生产物

RepoContext XML 允许手工编辑，因为它是用户可管理的代码上下文缓存；洞察 XML 是真实统计的派生投影，不允许手工修改。知识库 UI 支持查看、复制、下载、删除和重新生成，不显示保存编辑入口。

## 3. 架构

### 3.1 洞察上下文分层

拆分当前 `DefaultRepositoryInsightsAIContextProvider`：

1. `RepositoryInsightsContextService`
   - 准备默认结构化洞察快照；
   - 复用 `RepositoryRemoteInsightsProviding` 与 `RepoStarHistoryRepositoryProtocol`；
   - 合并同仓库并发准备；
   - 支持正常准备和 cache-only 准备。
2. `RepositoryInsightsXMLRenderer`
   - 纯函数生成合法 XML；
   - 计算 source hash / XML hash；
   - 控制趋势点和 Top Contributors 上限；
   - 不负责网络或磁盘。
3. `RepositoryInsightsContextStorage`
   - 管理 `insights.xml`、`metadata.json` 和删除抑制；
   - 原子写入、schema/root 校验、读取、导出、删除与重新生成；
   - 文件真源位于 App Support 的独立 `repository-insights-context` 根目录；
   - 不复用 RepoContext 用户自选输出目录，避免两个生命周期互相污染。
4. `RepositoryInsightsContextCoordinator`
   - 串联 prepare → render → storage；
   - 对页面、AI、RAG 暴露清晰入口；
   - 不变 hash 零写盘，失败保留上次有效 XML。

### 3.2 Document 模型

```swift
struct RepositoryInsightsDocument: Sendable, Equatable {
    let xml: String
    let metadata: RepositoryInsightsDocumentMetadata
}
```

metadata 至少保存 repo identity、schemaVersion、sourceHash、xmlHash、generatedAt、sourceUpdatedAt、tokenCount、dataset 状态摘要和 generationCount。

### 3.3 RAG 特殊上下文抽象

RepoContext 与 Repository Insights 共享“不是数据库分片，但会进入 Prompt / 引用 / Inspector”的语义。只抽取真实重复的展示和审计能力，不强行合并两个 Storage：

- `RAGSpecialContextKind`：`repoContext` / `repositoryInsights`；
- 各自保留类型化 Document 和 Snapshot；
- Knowledge Browser 联合列表支持两个特殊项；
- Prompt、Context Usage、Citation Source、Hit Kind、Execution Step 和 Debug Stage 分别保留可解释类型；
- XML 投影器按 schema 独立实现，避免把 RepoContext `<file>` 裁剪规则错误用于洞察趋势节点。

## 4. 知识库特殊分片

### 4.1 展示顺序与统计

固定顺序：

1. Metadata；
2. Repository Insights XML；
3. RepoContext XML；
4. 其它普通分片。

缺 Metadata 时特殊项置顶并保持 Insights 在 RepoContext 之前。分别显示“仓库洞察 `0 / 1`”与“RepoContext `0 / 1`”；普通分片数量和 embedding 状态不变。

### 4.2 交互

- 点击洞察 XML 行打开只读 XML sheet；
- 复用 RepoContext 编辑器的密度、等宽正文、下载和关闭样式，但不提供编辑/保存；
- 行尾删除使用破坏性确认；
- header 支持“生成 / 重新生成仓库洞察 XML”；
- 自动生成期间不显示全页加载态，不清空旧 XML；只用稳定的行内状态；
- 切换仓库、移出知识库和关闭窗口取消当前主动生成任务并拒绝迟到结果回写。

## 5. RAG 注入策略

### 5.1 目标选择

洞察 XML 比代码 XML 小，不使用 RepoContext 的“深度思考 + 单仓库”限制：

- 显式选择仓库：优先纳入所选仓库的洞察 XML；
- 普通检索：只为最终保留的 `RepoContextBundle` 仓库读取洞察 XML；
- 不扫描全知识库，不让 Planner 发明仓库目标；
- 多仓库按最终相关度与独立 token budget 加入，空间不足时整份移除，禁止字符级截断成非法 XML。

### 5.2 Prompt 与预算

Generator 增加独立占位符：

```text
{repositoryInsightsSection}
```

新增 `RAGContextUsageSegmentKind.repositoryInsights`。洞察 XML 不占普通 evidence budget，但服从模型总窗口与输出预留。Builder 使用 XML 感知投影，优先保留根节点、摘要指标和最近趋势点。

### 5.3 引用、证据门禁与历史

- 新增 `RAGCitationSource.repositoryInsights` 与 `RAGHitKind.repositoryInsights`；
- citation `chunkID = nil`，标题为 `insights.xml · <更新时间>`；
- 洞察 XML 是仓库级事实证据，可与普通分片共同支持回答；只有洞察 XML 时也可通过证据门禁；
- 会话只保存 hash、token、时间、投影和 citation 等审计数据，不复制 XML 正文；
- 历史回放只有 repo + sourceHash + xmlHash 匹配时才加载当前磁盘 XML，否则显示不可回放；
- 删除 XML 后历史 citation 不显示“分片已删除”，而显示“当轮仓库洞察上下文当前不可回放”。

### 5.4 RAG 可见面

必须覆盖：

- Plan Inspector；
- 执行时间线；
- Context Window 分段；
- Evidence Inspector、引用定位、XML 全文、复制；
- Debug Trace request / load / projection stages；
- Prompt preview / 最终 Prompt；
- 会话持久化与历史回放；
- Knowledge Browser 特殊分片；
- RAG Prompt 设置占位符说明和默认模板迁移；
- i18n、隐私提示和帮助文案。

## 6. 性能、并发和失败边界

- 洞察网络请求继续由既有 provider single-flight 合并；
- Artifact 生成增加 repo-scoped single-flight；
- XML 渲染可在后台执行，文件写入使用原子替换；
- RAG 多仓库读取使用有界并发并按最终 bundle 集合读取，不在主线程逐仓库同步 IO；
- Knowledge Browser 同时加载普通分片与两个特殊文档，结果受 repo selection generation gate 保护；
- 自动生成失败保留旧 XML并记录可读状态，不阻断洞察页面或 AI；
- RAG cache-only 缺失视为可解释的 skipped，不触发联网；
- 账号切换和数据库 scope 变化使旧准备结果失效，不能把旧账号 XML 写入新账号上下文。

## 7. 数据库与迁移

本专项不修改已发布 v7 RAG schema，不新增 `rag_chunks` source。洞察 XML metadata 和删除抑制使用文件系统派生产物，不需要数据库 migration。若实施中发现必须持久化账号级关系，必须先停下审查是否需要追加新 migration，禁止回写 v1/v7。

## 8. 测试与门禁

### 8.1 单元测试

- XML schema、escape、趋势降采样、hash 稳定性；
- Storage 原子写入、命中、删除抑制、源变化自动恢复、主动重建；
- 页面 / AI / RAG 共用同一 Document，重复调用零网络与零重复写盘；
- Artifact single-flight、失败回退、取消、账号 scope；
- Knowledge Browser 两个特殊项顺序、独立统计、只读、删除和迟到结果；
- RAG 多仓库目标选择、独立预算、XML 投影、citation、证据门禁；
- Plan、时间线、Context、Evidence、Debug、历史 round-trip；
- Prompt 默认值迁移与自定义 Prompt 保留；
- 私有仓库、收藏且协作仓库和 Star History 权限边界。

### 8.2 工程门禁

- 相关定向 Suite；
- 全量 `StarcatTests`；
- `Starcat` 与 `StarcatDirect` Debug build；
- `xcodegen generate`（新增 / 删除 Swift 文件后）；
- `jq empty Localizable.xcstrings`；
- i18n 禁用 API 与 String Catalog 格式扫描；
- `git diff --check`；
- 主进度文档只读保护；
- 人工 UI 项与自动化证据分开记录。

## 9. 提交与审查

- 方案与 Checklist、每个小功能、测试和文档分别使用中文规范 message 提交；
- 不 push，不启动应用，不执行打包、发布或上传；
- 至少三轮正式审查和一轮清洁复审；
- 每轮先新增并提交审查报告，再修复并单独提交；
- 审查范围依次为：
  1. 架构、数据、缓存、hash、删除抑制、账号与性能；
  2. Knowledge Browser、RAG 全链路、Prompt、UI、i18n、隐私与功能遗漏；
  3. 单元测试、构建、文档、工程进度、Checklist 和提交边界；
  4. 清洁复审确认无新增问题；
- 最后回填 Checklist并新增结果报告；
- `docs/功能实现总览.md` 只读，等待 dong4j 单独授权后再同步。

## 10. 明确不做

- 不把洞察 XML 写入 `rag_chunks`；
- 不向量化或参与普通召回；
- 不批量预取所有收藏仓库；
- 不为 RAG 查询额外触发整套远端洞察请求；
- 不允许手工编辑洞察 XML；
- 不删除真实洞察数据；
- 不复制一套 GitHub Metrics / Star History 请求实现；
- 不把 XML 写入普通消息、CloudKit 或 External Search；
- 不修改受保护的 `docs/功能实现总览.md`；
- 不 push、打包、发布或上传。
