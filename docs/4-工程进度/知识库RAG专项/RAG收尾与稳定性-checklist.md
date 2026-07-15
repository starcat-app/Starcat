# RAG 收尾与稳定性 Checklist

> 状态: 第 2 轮代码审查已完成，正确性整改、性能与架构技术债、真实环境与大数据人工验收待执行。本清单按用户可感知风险、前置依赖和数据路径相关性排序。

## 目标与执行规则

- 先消除会话错位、输入丢失、长回答卡顿等 P1 主链风险，再增加 Context Usage 与语义压缩能力。
- 每个小项均先补回归测试，再实施最小改动；完成一项才勾选一项、更新主进度索引并提交一次中文 commit，不 push。
- RAG 已随正式版收口：schema 变更走 `v7-knowledge-rag`（`ensureKnowledgeRAGSchema`）；不得再回写 v1 草稿或启动期旁路。
- 每个阶段至少运行相关 Suite；阶段 2、4、6 完成后运行全量 `xcodebuild test`。真实 Provider、慢网络和大数据场景另列人工验收，不以单测替代。

## 阶段 0：基线与测试支架

- [x] 为会话选择、浏览器选择、失败恢复、流式快照、滚动请求、上下文预算和历史压缩建立可注入的延迟/错误 mock。
- [~] 固化基线：100/200 条历史会话读取固定为 4 次关联查询，回归用例通过（整组 0.095s）；1万+ chunk / 大 PDF 的 P50/P95、峰值内存和取消响应时间待真实数据采集。
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

## 阶段 3：检索、附件与远程调用上界

- [x] **大知识库检索**：ready 检查改为存在性查询；向量扫描只读取必要字段、使用有界 Top-K 后再 hydrate；大量 repo ID 分批传入 SQL。
- [x] **大附件处理**：PDF/文本边提取边累计到上限并检查取消，不先拼接所有页再裁剪。
- [x] **远程请求规划**：确认前对 remote requests 规范化、去重并限制总工作量；fetch 采用有界并发且保持输出顺序。
- [x] **远程进度与取消**：展示真实完成数，超时和取消立即停止剩余工作，不把失败写入缓存。

完成条件：1万+ chunk 和超长 PDF 不出现无界加载；重复远程 request 不重复请求；慢网络下进度、超时和取消可理解且可验证。

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
- [~] 关闭 Xcode 后运行相关 Suite 与全量 `xcodebuild test`；自动化通过，真实 GitHub/AI/自托管、长会话、慢网络、快速切换、大知识库和大 PDF 人工验收待执行。

完成条件：长会话可持续问答而不超上下文，原文不丢；全量测试通过；专项进度、主进度索引与结果报告同步完成。

## 阶段 7：第 2 轮审查正确性整改

- [ ] **Embedding 写回一致性**：为索引任务增加串行化或分片 claim 机制；向量写回必须同时校验 chunk id、`content_hash` 和 pending 状态，旧请求不得把旧向量标记为新内容的 ready 向量。
- [ ] **Meilisearch 同步 SQL**：修复 `fetchKeywordSearchableChunks` 中未插值的 `placeholders`，增加 Repository 回归测试，并验证 `fallbackToSQLite` 开启与关闭时的错误语义。
- [ ] **PDF / 图片附件入口**：让文件选择器的 UTType、`RAGAttachmentHandling` 和 `RAGAttachmentProcessor` 能力一致；真实 UI 必须可选 PDF / 图片，不得只在处理器和单测中可达。
- [ ] **RAG 固定文案 i18n**：移除 `RAGUserVisiblePlan`、Planner 和 Service 兜底路径中的硬编码中文，固定文案统一走 `Localizable.xcstrings`，不翻译模型生成内容。

完成条件：每项先有可稳定复现的失败测试，再实施最小修复；并发索引不产生过期 ready 向量，Meilisearch 同步可执行，PDF / 图片可从真实工作台发送，英文环境不泄漏固定中文。

## 阶段 8：性能与架构技术债收敛

- [ ] **Embedding 队列分批**：禁止 `limit: Int.max` 一次性加载全部待向量化正文；按 `embeddingBatchSize` 分批读取或 claim，独立统计总数，消除循环 `removeFirst` 数组搬移。
- [ ] **README 重建上界**：缺失 README 拉取改为 2～4 个任务的有界并发，保留 GitHub 限流、超时、取消和稳定进度语义。
- [ ] **分片计算移出主线程**：将 Markdown 解析和 chunk build 等纯计算移出 `@MainActor`，只在主线程发布状态和进度。
- [ ] **外部索引增量同步**：合并短时间内的索引变更，按 chunk upsert / delete 同步 Meilisearch 与 Qdrant；Metadata-only 更新不得触发 Qdrant 全量 `replaceAll`。
- [ ] **本地向量扫描基线**：在 1 万+ chunk 真实数据上记录 P50/P95、峰值内存和取消延迟；依证据决定是否增加索引、调整本地上限或引导使用 Qdrant。Schema 调整必须追加新 migration。
- [ ] **Source-aware 重建读取**：单 source 刷新只读取当前 source 所需的 Summary、Note、Tags、README 和 Metadata，避免为单仓库读取全库 Summary 或无关数据。
- [ ] **候选仓库与元数据快照**：为 `@repo` picker 使用轻量投影、缓存归一化搜索文本，大库达到阈值后改用分页查询；元数据快照按数据修订版本缓存，不得盲用可能过期的 UI 快照。
- [ ] **会话持久化增量更新**：回答完成后直接追加本轮持久化结果，不每轮重载全部消息与引用；保留全量重载作为切换会话和错误恢复路径。
- [ ] **Debug 磁盘保留上界**：在已有内存 FIFO 上限之外，增加每会话文件数或总字节数上限，读取时不全量解码无限历史 JSON。
- [ ] **会话运行态收敛**：将 `activeAnswerStates`、`activeRetrievals`、`activeQueryPlans`、`activeRemoteBlocks` 等并行字典合并为 `[UUID: RAGConversationRuntimeState]`，先保持 `KnowledgeRAGWorkspaceViewModel` 是唯一可观察协调器。
- [ ] **Service 内部分阶段**：把 `KnowledgeRAGService.ask` 收敛为 Planner、Retrieval、Remote Context、Prompt 和 Generation 等可单测的内部阶段；不将 `runQuestion` 抽成第二个 God Object。
- [ ] **Rerank 与索引读模型复用**：抽取 TEI / Cohere 共用的候选编号、HTTP 请求、认证和结果映射，保留各自 DTO；工作台与知识库浏览器共用轻量索引状态读模型。

完成条件：优化前先固化可重复基线，优化后不改变知识库边界、隐私语义、召回结果和取消行为；两个 App target 编译通过，相关 Suite 与全量测试通过，真实性能数据回填专项评测记录。

## 执行顺序

阶段 0 → 阶段 1 → 阶段 2 → 阶段 3 → 阶段 4 → 阶段 5 → 阶段 6 为已完成的第 1 轮整改主线。第 2 轮按阶段 7 → 阶段 8 → 真实数据与真实 Provider 验收执行；阶段 7 的正确性风险必须先于阶段 8 的性能与架构收敛。

## 实施记录（2026-07-13）

- 阶段 1 至 6 的代码整改与回归测试已完成；每个切片均以中文 commit 独立提交，未 push。
- 最终全量测试：`rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test`，结果为 1377 通过、0 失败、7 跳过、1 项预期失败（总计 1385）。
- 阶段 0 的 100/200 条历史会话基线已固化为自动化用例；真实 Provider、1万+ chunk、大 PDF、慢网络和真实长会话仍需要在有凭据与真实数据的环境中按本清单人工验收。
