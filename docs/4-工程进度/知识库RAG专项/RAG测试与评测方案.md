# Starcat 知识库 RAG 测试与评测方案

> 状态: 方案已定；本地向量性能已有真实大库基线，检索/回答质量仍待脱敏金标集验收
>
> 日期: 2026-07-14
>
> 范围: 仅覆盖以 `repo_notes.library_state = 'in_library'` 为数据边界的知识库 RAG；不把所有 GitHub Stars、Code RAG 或 Agent 的通用回答质量混入本方案。
> 附件边界: 当前正式支持文本、Markdown、JSON 与源码；PDF/图片不进入当前评测门禁。
>
> 关联文档: [本地 RAG 设计](../../3-设计/详细设计/30-本地RAG设计.md)、[脱敏评测集模板](脱敏评测集模板.md)、[知识库 RAG 专项进度](知识库RAG专项进度.md)

## 1. 目标与原则

RAG 不是一个可以由单一“准确率”概括的功能。用户得到一条回答，背后至少经过候选仓库筛选、关键词与向量召回、RRF 融合、父章节扩展、上下文打包、模型生成、引用解析和流式展示。因此测试必须能回答两个不同的问题：

1. **答案是否值得信任**：答案是否回答了问题、是否完整、是否只基于可核验的本地证据，以及没有证据时是否明确拒答。
2. **系统是否可用**：在真实知识库规模、网络和 Provider 条件下，是否足够快、稳定、可取消，且不越过知识库和隐私边界。

以下原则是所有评测的前提：

- **先拆层，后看总分**：检索差与生成幻觉需要不同修复手段；不能用回答“看起来不错”掩盖召回漏证据。
- **真实问题优先**：评测问题保留用户表达，不能把问题改写成刚好命中 README 的关键词。
- **同条件比较**：比较调参前后结果时，固定知识库快照、评测集版本、embedding 模型、Provider、Top K、Prompt 与运行环境；每次只改变待验证的变量。
- **可追溯优先于高分**：每个质量结论都应能回到问题、预期证据、实际命中、最终引用和 trace，而不是只保留一个平均分。
- **离线门禁与线上观察并存**：离线金标集用于阻止回归；线上匿名统计、显式反馈和抽样复核用于发现评测集遗漏的真实需求。
- **不把外部评测 SaaS 设为运行时依赖**：Starcat 是 Local-First、BYOK 的 macOS App。评测数据、指标计算和结果归档优先留在仓库/本地；Ragas、LangSmith、Phoenix 等只作为方法参考或离线分析工具。

## 2. 业界如何评测 RAG

业界的成熟做法不是让一个模型替代用户打一个总分，而是建立“离线基准 + 可观测 trace + 人工校准 + 线上反馈”的闭环。

| 层次 | 常见做法 | 要解决的问题 | Starcat 对应做法 |
| --- | --- | --- | --- |
| 检索 | 金标问题标注相关文档/片段，以 Recall@K、MRR、nDCG 等评估排名 | 必要证据是否进入 Top K，且是否排在前面 | 以 repo 别名、source、section 描述标注证据，评估真实 FTS + vector + RRF 输出 |
| 生成 | 参考答案或评分 rubric；人工与 LLM-as-a-Judge 结合 | 回答是否正确、完整、相关、基于证据 | 用“关键结论”和“可接受表述”评分，而非强制文字完全一致 |
| Grounding / 引用 | 判断回答中的原子主张是否被上下文或引用支持 | 模型是否补写、编造或错引 | 核验 `[S<n>]` 是否来自本轮 matched child，关键结论是否有足够证据 |
| 拒答 | 构造无证据、索引缺失、范围外问题，统计混淆矩阵 | 该拒答时是否拒答；有证据时是否误拒答 | 独立记录 `refuse` case，评估拒答准确率、误答率和误拒答率 |
| 鲁棒性与安全 | 多语言、长尾表达、冲突/过期资料、Prompt Injection、权限边界 | 真实输入是否让系统越界或不稳定 | 中文/英文/混输、私有笔记、远程失败、未入库 repo、恶意附件等分组测试 |
| 性能与成本 | 分阶段 trace、冷/热启动、并发压测，记录 percentile、吞吐、错误率和 token 成本 | 瓶颈在检索、网络、首 token 还是渲染 | 记录 Planner、keyword、embedding/vector、packing、remote、TTFT、streaming 与总耗时 |
| 生产闭环 | 保存匿名 trace、用户反馈、失败样本，定期回灌金标集 | 离线集是否仍代表真实使用 | 用户主动提交的差评或人工复盘问题先脱敏，再进入候选评测集 |

Ragas 将 Context Precision/Recall、Faithfulness、Response Relevancy 等指标拆开；LangSmith 也明确建议分别评估 retrieval 与 generation；NVIDIA 的基准实践则将质量评测与 TTFT、端到端 P95/P99、吞吐和错误率的性能压测分离。这些方法论适用于 Starcat，但指标实现必须服从 Starcat 的本地数据边界与 Provider 可变性。

## 3. Starcat RAG 的评测对象

Starcat 的一次问答可按如下链路观测：

```text
问题
  -> Query Planner / SQL candidates
  -> keyword FTS 与 embedding/vector 并行召回
  -> RRF + source weight + explicit repo scope
  -> RepoContextBundle / parent-sibling packing
  -> 可选 GitHub 临时上下文与附件
  -> Generator streaming
  -> citation parser / 历史审计 / UI 展示
```

因此每条完整 case 必须至少保留以下可脱敏信息：

- 问题、语言、问题类型和应否拒答；
- 预期 repo/source/section 证据及相关度等级；
- 实际 Top 5/Top 10 命中、命中方式和排名；
- 最终答案的关键结论、实际 citation、拒答或降级状态；
- 各阶段耗时、Provider/模型、知识库快照与评测配置版本。

对 `@repo`、SQL filter 和远程上下文，必须额外记录期望范围。它们不是“更好的相关性”问题，而是产品边界：显式 `.only` 不能扩展到其它 repo；未入库 repo 不能成为本地证据；远程 GitHub 正文不能写入 `rag_chunks` 或历史正文快照。

## 4. 指标体系

### 4.1 检索质量

| 指标 | 定义 | 用途 | 注意事项 |
| --- | --- | --- | --- |
| Recall@5 / Recall@10 | Top K 是否至少包含一条直接相关证据 | 发现漏召回 | 对多证据问题应记录“全部关键证据召回率”，不能只看任一命中 |
| MRR | 首条直接相关证据排名的倒数均值 | 衡量用户最早看到证据的速度 | 适合每题有明确主证据的 case |
| nDCG@10 | 使用 2/1/0 相关度的折损累计增益 | 同时衡量相关性与排名 | 与现有模板的相关度定义保持一致 |
| Context Precision / 噪声率 | Top K 中有帮助的 chunk 占比 / 无关 chunk 占比 | 判断 Top K 是否塞入过多无关上下文 | 噪声会挤占 token budget，也可能诱发错误回答 |
| 范围正确率 | 实际召回是否严格落在知识库、SQL 候选和 explicit repo 范围 | 验证产品边界 | 这是 100% 门禁，不是可用平均分抵消的指标 |
| 索引新鲜度 | 预期 source 更新后可被检索的比例与延迟 | 发现 source diff 或 embedding stale 问题 | README、notes、summary、metadata 分开统计 |

### 4.2 回答、引用与拒答质量

| 指标 | 定义 | 评分方式 |
| --- | --- | --- |
| 回答正确性 | 关键结论是否符合预期证据 | 人工 rubric 为主；LLM Judge 只能作辅助 |
| 回答完整性 | 是否覆盖问题要求的全部关键子结论、比较维度或条件 | 逐项检查，不以篇幅代替完整 |
| 回答相关性 | 是否直接回应问题，避免无关展开 | 0/1 或 1–5 rubric |
| Faithfulness / Groundedness | 答案中的事实主张是否能由本轮可见证据支持 | 按原子主张抽检；结论不能只由模型常识支撑 |
| Citation Precision | 实际 citation 指向的 chunk 是否支持其附近主张 | 逐 citation 人工或 Judge 判断 |
| 关键结论引用覆盖率 | 所有关键结论中带有足够引用支持的比例 | Starcat 的核心信任指标；只统计用户可见正文中的有效 marker |
| 伪造 citation 率 | citation 不存在、越过本轮映射、或无法支持主张的比例 | 必须为 0；任何出现均阻断发布 |
| 拒答准确率 | 应拒答且实际明确拒答，或应回答且实际回答的比例 | 需同时报告误答率与误拒答率，防止“全部拒答”虚高 |
| 降级可解释性 | remote/provider 失败时是否说明范围与限制，且仍只使用现有证据 | 人工检查状态文案和最终回答 |

“回答准确率”可以作为汇总展示，但只应在 rubric、评审者、样本量和置信度明确后使用；它不能替代以上分项指标。

### 4.3 性能、稳定性与成本

性能数据必须以分段 trace 为准，不能只统计“点发送到看到完成”的总时长。

| 指标 | 必须分组 | 目的 |
| --- | --- | --- |
| Planner、SQL candidates、keyword、query embedding/vector、RRF/packing 耗时 | Local / 网络 Provider；冷缓存 / 热缓存 | 找到实际瓶颈，避免把 Provider 抖动误判为本地检索慢 |
| TTFT | 模型、网络、输出长度 | 衡量用户是否尽快看到首个 token |
| E2E latency P50/P95/P99 | 问题类型、知识库规模、Provider、是否 remote context | 衡量典型体验与长尾卡顿 |
| streaming 吞吐与 UI 更新间隔 | 回答长度、窗口前后台状态 | 发现 markdown 重解析、主线程掉帧或滚动竞态 |
| 吞吐、错误率、取消响应时间 | 单请求与有限并发；超时/断网 | 验证可靠性和资源上界 |
| CPU、峰值内存、磁盘与索引耗时 | chunk 数、README/文本附件长度、长会话、重建/增量更新 | 评估 macOS 本机资源占用 |
| input/output token 与 Provider 费用估算 | 模型、上下文预算、远程/附件有无 | 防止调参以不可接受成本换取小幅质量提升 |

Provider 是用户自行配置的可变外部条件。因此 Starcat 的首个性能门禁应以“同环境不回归”和“本地阶段有明确上界”为主；跨 Provider 的端到端绝对秒数只作分环境参考，不能混成一个全局 SLA。

### 4.4 本地向量扫描基线（2026-07-16）

在 Apple Silicon 开发机上，以真实用户库的只读一致性快照运行 `RAGVectorScanBenchmarkTests`。测试只读取 chunk id、repo id 与 embedding BLOB，不记录数据库路径、仓库名、正文或向量内容；先预热 2 次，再对同一 1024 维 query 向量执行 20 次 Top-20 扫描。

| 实现 | ready chunk | repo | 维度 | P50 | P95 | 峰值物理内存增量 | 取消延迟 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Swift 标量循环 | 18,465 | 1,865 | 1,024 | 4,308.20 ms | 4,372.39 ms | 24.31 MB | 0.20 ms |
| Accelerate/vDSP + query 范数复用 | 18,465 | 1,865 | 1,024 | 178.13 ms | 187.75 ms | 14.05 MB | 0.19 ms |

结论：400 行分页、Top-K 有界保留和逐页取消使内存与取消行为符合预期；共享余弦内核改用系统 Accelerate/vDSP 并复用 query 范数后，同快照 P95 降低约 95.7%（约 23.3 倍）。普通 SQLite B-tree 索引不能解决 BLOB 内部相似度扫描，当前证据也不支持为 1.8 万量级追加 schema migration 或降低召回上限；保留本地检索为默认边界，Qdrant 继续作为更大规模与自托管场景的可选后端。

## 5. 评测集与标注规范

### 5.1 数据集构成

以 [脱敏评测集模板](脱敏评测集模板.md) 为唯一采集入口，首批建立 30–50 条真实脱敏问题，之后逐步扩展。样本至少覆盖：

- 中文、英文与中英文混输；
- 单 repo 事实问答、跨 repo 比较、筛选/发现、版本或状态条件；
- README、notes、summary、metadata 四类 source；
- `@repo` only/prefer/exclude 与未入库 repo；
- 一条或多条关键证据、重复内容、相互冲突或过期信息；
- 无本地证据、未建索引、Provider/远程上下文失败；
- 注入式指令、恶意 Markdown/附件和超长输入；
- 私有知识库 repo 的本地检索与启用远程 BYOK 时的明确数据传输提示。

评测集不得保存 token、私有全名、绝对路径、README/笔记原文、完整模型回答或 API key。repo 可使用稳定别名，section 以概括描述代替原文。

### 5.2 单条 case 的补充字段

现有模板已经定义问题与预期证据。执行完整评测时，可在独立的本地结果文件中补充以下字段；这些结果字段同样必须脱敏：

| 字段 | 说明 |
| --- | --- |
| `expectedClaims` | 必须覆盖的关键结论或比较维度，不保存证据原文 |
| `acceptableAnswerRubric` | 正确、部分正确、错误、应拒答的判定条件 |
| `expectedScope` | 知识库范围、`@repo` 模式、允许的远程资源 |
| `retrievedEvidence` | Top K 的 repo/source/section 别名、rank、hit kind、相关度 |
| `citationAssessment` | 每条 citation 支持/不支持的判定和原因 |
| `answerAssessment` | 正确性、完整性、grounding、拒答、降级说明评分 |
| `traceMetrics` | 分阶段耗时、TTFT、总耗时、错误/取消状态 |
| `judgeVersion` | 人工评审者或 Judge prompt/model 版本，用于复现 |

### 5.3 人工与 LLM Judge 的分工

LLM-as-a-Judge 适合快速筛查大量回答、给出统一 rubric 的初判，却不能被视为真值来源。Starcat 使用下列规则：

1. 每个首批 case 的证据、应拒答判断和关键结论均由人工建立。
2. Judge 只看到问题、脱敏预期 rubric、实际回答和有限的脱敏证据描述；不允许凭世界知识替 RAG 补答案。
3. 每一批次至少抽取 20% 结果由人工双检；对 Judge 与人工分歧、低置信或安全相关样本全部人工裁决。
4. 记录 Judge 的 prompt、模型、温度和版本；Judge 变更后不得和旧分数直接比较，必须以同一基线复跑。

## 6. 测试分层与执行方式

| 层级 | 覆盖内容 | 触发时机 | 通过标准 |
| --- | --- | --- | --- |
| 单元测试 | chunk、embedding 状态、范围过滤、RRF、packing、citation parser、预算与状态机 | 每次代码修改 | 所有确定性不变量通过 |
| 集成测试 | 真实 SQLite/FTS、模拟 embedding/chat/remote Provider、索引增量与失败降级 | RAG 核心改动 | 链路可复现，错误不越界、不串库、不写入不该持久化的内容 |
| 固定离线评测 | 脱敏金标问题的检索、回答、引用与拒答评分 | 改 chunk、检索、Prompt、模型、Provider 策略前后 | 同条件可比；无 P0 回归，关键指标不低于已接受基线 |
| 性能基准 | 小/中/大知识库、冷/热缓存、单请求/有限并发、长回答 | 检索、索引、流式 UI 或 Provider 策略改动 | 本地阶段不回归；记录 P50/P95/P99、资源和瓶颈 |
| 人工验收 | 工作台可读性、citation 核验、取消、失败恢复、真实 Provider | 准备发布前 | 覆盖专项进度中的真实数据验收项 |
| 线上观察 | 匿名化阶段 trace、明确反馈、抽样复盘 | 发布后持续 | 新失败样本脱敏回灌候选评测集 |

现有 `StarcatTests/RAG*` 已覆盖大量确定性不变量；知识库管理器的“召回测试”会绕过 Planner 与生成、复用真实混合检索，适合作为检索层人工采样入口。完整问答评测必须额外检查回答、citation、拒答和 trace，不能用该入口代替端到端验收。

## 7. 发布门禁与回归判定

### 7.1 P0 不变量：任一失败即阻断

- 召回或引用任何不在知识库的数据，或突破 `@repo` / SQL candidate 范围；
- 本轮 citation 不属于本轮已分配的 matched child，或 citation 指向内容不能支持附近关键主张；
- 无证据、无索引或远程降级时仍编造确定性结论；
- 私有 repo 被同步到 Meilisearch/Qdrant，或远程上下文/附件正文被写入不允许的持久化位置；
- 切换账号、取消请求或 Provider 失败造成跨库数据写入、无法恢复的崩溃或持续卡死。

### 7.2 指标门禁：以已接受基线为准

首批真实样本不足以定义跨所有知识库都合理的绝对阈值。正确流程是：先建立并人工复核基线，再对同一快照、相同配置的重复运行设定回归门槛。

- **检索**：Recall@10、nDCG@10、范围正确率、按语言/source/问题类型切片的结果均不得无解释下降。
- **回答**：关键结论引用覆盖率、grounding、正确性/完整性、拒答混淆矩阵不得退化；不得以“更多拒答”掩盖回答质量下降。
- **性能**：Local 阶段 P95、TTFT、E2E P95、取消响应时间、峰值内存和错误率均与同环境基线比较；性能改善也必须重新跑质量集。
- **变更解释**：每项显著变化都要归因到知识库快照、模型/Provider、chunk/检索/Packing/Prompt 变更或外部网络，不允许只提交一张平均分表。

当样本增长、硬件与 Provider 分层稳定后，再为不同测试环境分别确定绝对预算；不得把云端模型波动当作 macOS 客户端性能缺陷。

## 8. 推荐执行顺序

### 阶段 A：建立可信基线

1. 按模板采集 30–50 条真实脱敏问题，人工标注预期证据、相关度、关键结论和应拒答状态。
2. 固定一个知识库快照、embedding/chat Provider、模型版本、Top K 和 Prompt 配置。
3. 用“召回测试”记录 Top 5/Top 10；再执行完整问答，记录 citation、拒答和 Debug trace。
4. 对首批结果做人审，填写汇总表；只描述事实，不急于调整 RRF、分词、查询扩展或 reranker。

### 阶段 B：自动化回归与性能基准

1. 在不含私有原文的前提下，将评测 case、期望证据和结果 schema 版本化。
2. 为确定性检索指标提供本地 runner，输出 JSON/CSV/Markdown；Provider 调用以显式、可替换的测试配置执行。
3. 为性能基准构造小/中/大三档 chunk 规模，分别运行冷/热缓存与单请求/有限并发场景。
4. 将阶段 trace、TTFT、P50/P95/P99、内存、错误率与质量结果写入同一批次报告。

### 阶段 C：线上反馈闭环

1. 只在用户明确同意的前提下收集匿名化质量反馈或本地导出的脱敏 trace；不上传 repo 正文、notes、答案或密钥。
2. 对差评、引用纠错、拒答失败和性能异常建立人工复盘流程。
3. 已确认的真实失败模式经脱敏和人工标注后进入候选评测集；评测集版本升级时保留旧集，避免历史指标失去可比性。

## 9. 何时必须重跑哪些测试

| 变更 | 必跑测试 |
| --- | --- |
| chunk 规则、source 清理、embedding 模型、FTS、cosine、RRF、source weight、Top K、parent packing | 单元/集成 + 全量离线检索评测 + 性能基准 |
| Planner、SQL filters、`@repo`、远程候选规则 | 范围边界集 + 离线端到端评测 |
| Generator Prompt、citation parser、上下文预算、历史压缩 | 回答/引用/拒答集 + 长会话人工验收 |
| Provider、模型、超时、streaming、附件、remote context | 端到端评测 + 网络故障/取消测试 + 分环境性能记录 |
| UI 渲染、滚动、Markdown 节流 | 长回答、历史恢复、取消和性能人工验收 |
| 数据库或账号生命周期 | 跨库隔离、取消、索引/会话持久化集成测试 |

## 10. 结果报告模板

每次批次以如下摘要开头，并附可追溯的脱敏 case 结果与 trace 汇总：

| 批次 | 评测集/快照 | 配置 | Case 数 | Recall@5 / @10 | nDCG@10 | 关键结论引用覆盖率 | Grounding | 拒答准确率 | TTFT P50/P95 | E2E P50/P95 | 错误率 | 结论 |
| --- | --- | --- | ---: | --- | ---: | ---: | ---: | ---: | --- | --- | ---: | --- |
| `<batch-id>` | `<dataset-v / date>` | `<model / provider / topK>` | `<N>` | `<% / %>` | `<%>` | `<%>` | `<%>` | `<%>` | `<ms / ms>` | `<ms / ms>` | `<%>` | `<pass / investigate>` |

报告必须列出：运行环境、知识库规模、冷/热缓存、是否启用远程上下文、评审方式、与哪个基线比较、P0 不变量结果，以及显著变化的 case ID。没有这些上下文的平均分不构成质量结论。

## 11. 参考资料

- [Ragas：可用 RAG 指标](https://docs.ragas.io/en/stable/concepts/metrics/available_metrics/)
- [LangSmith：评估 RAG 应用](https://docs.langchain.com/langsmith/evaluate-rag-tutorial)
- [LangSmith：评估概念与生产监控](https://docs.langchain.com/langsmith/evaluation-concepts)
- [Arize Phoenix：检索相关性评估](https://arize.com/docs/phoenix/evaluation/pre-built-metrics/retrieval-rag-relevance)
- [NVIDIA RAG Blueprint：质量与性能基准](https://docs.nvidia.com/rag/latest/performance-benchmarking.html)
- [RAGAS 论文](https://aclanthology.org/2024.eacl-demo.16/)

上述工具和资料用于定义指标与流程；Starcat 的评测实现仍应优先复用自身真实检索链路、Debug trace 和脱敏本地数据，避免因评测工具本身引入新的隐私或运行时依赖。
