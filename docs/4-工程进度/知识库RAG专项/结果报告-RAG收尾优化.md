# 知识库 RAG 收尾优化结果报告

> 状态: 代码、自动化、文档整改与可自动取证的真实环境验证完成；UI 人工交互和脱敏金标评测待关闭
> 日期: 2026-07-16
> 执行清单: `RAG收尾与稳定性-checklist.md`
> 审查报告: `审查报告-第3轮.md`、`审查报告-第4轮.md`、`审查报告-第5轮.md`、`审查报告-第6轮.md`、`审查报告-第7轮.md`
> 真实证据: `真实环境验收记录-2026-07-16.md`

## 1. 交付判断

本次收尾优化的代码实现、定向回归、全量测试、双 target 编译、七轮代码/文档审查和可自动取证的
真实环境验证已经完成。阶段 7 至 9 的 correctness、performance、resource bound、architecture 和
reuse 项全部关闭，未发现遗留的 P0/P1 代码问题。

RAG 专项尚不能标记为整体完成：当前自动化环境无法取得 Starcat 可见窗口，工作台真实交互未能
形成可信证据；首批 30–50 条脱敏问答也尚未由人工标注预期证据和相关度。相应 checkbox 保持
未关闭，主进度索引继续使用 `[~]`。

## 2. 已完成实现

### 2.1 正确性与能力边界

- embedding 请求使用数据库 claim；ready/failed 写回同时校验 chunk id、`content_hash`、pending 状态和 claim id，旧请求不能覆盖新正文。
- Meilisearch/Qdrant 的查询与同步共用明确 fallback 语义；取消不被吞，关闭 fallback 时保留原始错误。
- 当前附件范围统一为文本、Markdown、JSON 与源码；PDF/图片只保留底层未来分支，不进入 UI、DoD 或发布承诺。
- RAG 用户可见固定计划、错误、远程证据和存储文案统一进入 `Localizable.xcstrings`；Provider/模型正文保持原文。
- `v11-rag-embedding-claim`、`v12-rag-metadata-revision` 均以追加 migration 实现，未回写已发布的 `v7-knowledge-rag`。

### 2.2 性能与资源上界

- embedding 队列按 batch count/claim/读取，不再用 `Int.max` 一次加载全部正文，也不再循环 `removeFirst`。
- README 缺失拉取使用 3 任务有界并发；Markdown 解析与 chunk build 移出主线程，仅在主线程发布状态。
- 外部索引以 revision 变更集执行 chunk upsert/delete；仅首次、配置或模型变化时全量初始化，Metadata-only 不触发 Qdrant。
- 本地向量内核改用 Accelerate/vDSP 并复用 query 范数；source rebuild 只读取目标 source 所需数据。
- `@repo` 候选使用轻量投影、归一化缓存和大库 SQL 分页；元数据快照按数据库修订号缓存并合并并发加载。
- 回答完成后增量追加会话投影；Debug 磁盘、会话预取条目、消息数和文本字节均有上界。

### 2.3 架构与复用

- 会话回答展示态收敛为 `[UUID: RAGConversationRuntimeState]`，任务取消生命周期继续独立管理。
- `KnowledgeRAGService.ask` 收敛为 Planning、Retrieval、Remote Context、Prompt/Gate、Generation 五阶段编排。
- TEI/Cohere Rerank 共用候选快照、正文截断、认证、HTTP 和 index 映射，各协议 DTO 保持独立。
- Repository、IndexBuilder、工作台和知识库浏览器共用唯一 `RAGIndexStatusProjection`，重复 coverage 类型已删除。

## 3. 性能结果

| 场景 | 优化前 | 优化后 | 结论 |
| --- | --- | --- | --- |
| 18,465 chunk × 1,024 维向量热扫描 P50 | 4,308.20 ms | 178.13 ms | 降低约 95.9% |
| 向量热扫描 P95 | 4,372.39 ms | 187.75 ms | 降低约 95.7%，约 23.3 倍 |
| 向量扫描峰值内存增量 | 24.31 MB | 14.05 MB | 降低约 42.2% |
| 向量扫描取消延迟 | 未固定 | 0.19 ms | 满足快速取消 |
| 100 条会话加载 P50/P95 | — | 1.404 / 1.504 ms | 固定 4 次关联查询 |
| 200 条会话加载 P50/P95 | — | 2.526 / 2.708 ms | 固定 4 次关联查询 |

当前证据支持继续使用 SQLite BLOB 作为默认本地后端，不为 1.8 万量级追加向量 schema migration；
Qdrant 保留为更大规模或自托管用户的可选能力。

## 4. 最终自动化门禁

- 运行前已关闭 Xcode 和 Debug App。
- `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test`：退出码 0。
- Swift Testing：1460 项 / 174 suites 通过，1 个已登记的 RepoContextPacker fixture known issue。
- xcresult：1506 项，1497 通过、8 跳过、1 项预期失败、0 失败。
- `Starcat` Debug build：成功。
- `StarcatDirect` Debug build：成功。

known issue 是缺少 `StarcatTests/Fixtures/repo-context/starcat-sample.zip`，属于 RepoContextPacker E2E
fixture，不是 RAG 失败，也未在本次范围内伪造或补入测试资产。

## 5. 真实环境证据

- 主用户库含 1,883 个 repo 和 18,467 个 ready 向量分片；另一个真实用户库覆盖已 star 未入库样本。
- 三类 repo 状态均有真实数据，Retriever 仍只读取 `library_state = 'in_library'`。
- ready 向量统一为 1,024 维，无非法 ready、过期 claim、重复稳定键、孤儿消息或缺失 citation chunk。
- 当前 Local 后端为 SQLite FTS5 + SQLite BLOB，Meilisearch/Qdrant 未运行时真实库读取正常。
- 本机 TEI `/rerank` 使用不含用户数据的探测请求返回 HTTP 200；AnySearch 匿名 Provider 探测返回 HTTP 200 和有效结果。
- Meilisearch/Qdrant 当前未部署，按范围记录为可选环境未执行，不冒充连接通过。

所有记录仅保存聚合数量和性能指标，不保存用户 ID、API Key、仓库全名、正文或模型完整回答。

## 6. 审查与提交

从第 3 轮重审到本报告前共完成 36 个独立中文 commit，范围为 `2bfcb3e9^..6f6ba04a`；每个正确性、
性能、架构、测试或文档切片均单独提交，没有 push。主要提交组如下：

| 提交组 | 范围 |
| --- | --- |
| `4f6e6274`–`1110b019` | embedding 一致性、外部 fallback、核心 i18n |
| `96987a96`–`0c8b7019` | 队列、README、主线程、增量同步、基线、缓存与持久化性能 |
| `56a2d0cf`–`d5bc5f3b` | 会话运行态和 Service 五阶段拆分 |
| `556b5362`–`dc5f7b62` | Rerank 传输复用与唯一索引状态读模型 |
| `d48658db`–`124f71eb` | 第 4/5 轮审查、文档真源与最后固定错误 i18n |
| `bb2ae03c`–`6f6ba04a` | 真实环境记录、第 6 轮审查和最终门禁状态同步 |

## 7. 未关闭项

以下项目需要可操作的真实窗口、受保护的当前 Provider 会话或人工金标，不能由本轮自动化替代：

- README/Notes/Summary/Metadata 的真实 UI 修改与 source 增量观察。
- 中文/中英文混输语义召回、结构化筛选、模糊日期、no-result 和两个 `@repo` 的真实工作台核验。
- 文本类附件、不支持附件、模型切换、历史恢复、citation 跳转、Markdown 导出和 Context Usage 视觉核验。
- GitHub Issues/Releases/PR 的确认/跳过、断网/限流、External Search 开关、Inspector 和私有名称授权。
- 索引/问答中快速切换账号，确认窗口关闭、滚动手感和不串库。
- 首批 30–50 条脱敏真实问题的 Recall@K、nDCG、引用覆盖率、拒答准确率和 E2E P50/P95。

accessibility bridge 的失败只说明当前自动化环境不能形成 UI 证据，不说明功能失败。上述项目完成并
回填 `知识库RAG专项进度.md` 后，才能把两个主进度 `[~]`、Batch F 和 Definition of Done 改为完成。
