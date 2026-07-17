# RAG 双语关键词 OR 检索 Checklist

> 状态：已完成
> 日期：2026-07-17
> 方案：`RAG双语关键词OR检索实施方案.md`
> 约束：每个小功能使用独立中文 commit message；不 push；每轮审查先提交报告，再修复报告发现的问题。

## 0. 开工与边界

- [x] 读取根目录 `AGENTS.md`、RTK 规则与 worktree skill。
- [x] 只读检查 `docs/功能实现总览.md` 和 `docs/1-立项/开发前问题清单.md`。
- [x] 从 `dev@eeaffc49` 创建独立 worktree。
- [x] 任务分支为 `codex/rag-bilingual-keyword-or`。
- [x] 主工作区与任务 worktree 均无本需求外未提交改动。
- [x] 明确不修改已发布 `v7-knowledge-rag` schema，不要求用户删库重建。
- [x] 明确不执行打包、发布、上传和 push。
- [x] 明确不修改 `docs/功能实现总览.md`，仅在结果报告中起草待确认同步内容。

## 1. 方案与清单

- [x] 固化 `semanticQuery` 与 `keywordQueries` 的职责边界。
- [x] 固化 Prompt 目标 3～8 项、本地硬上限 8 项与过滤后可少于 3 项。
- [x] 固化普通搜索继续 AND、RAG 专用 FTS5 使用 OR。
- [x] 固化单仓库、多仓库、prefer、exclude 的 repo id scope。
- [x] 固化旧计划、旧 Prompt 和旧 Debug 数据兼容策略。
- [x] 新增并提交 `RAG双语关键词OR检索实施方案.md`。
- [x] 新增并提交本 Checklist。

## 2. Query Plan 与 Planner

- [x] `RAGQueryPlan` 新增兼容的 `keywordQueries` 字段。
- [x] 旧 JSON 缺少字段时解码为 `[]`，不破坏历史回放。
- [x] 默认 Planner Prompt 增加双语关键词输出协议。
- [x] Planner 校验 trim、稳定去重、数量和长度上限。
- [x] Planner 拒绝低信息词并避免自动加入显式 repo identity。
- [x] 旧自定义 Prompt 不覆盖，缺失关键词时允许执行层降级。
- [x] 补齐 Query Plan 与 Planner 单元测试。

## 3. RAG 专用 FTS5 OR 查询

- [x] 新增 RAG 专用关键词查询构造器，不修改普通 `FTSQuery.sanitize` 行为。
- [x] 每个关键词和短语独立安全转义，模型文本不能注入 FTS5 语法。
- [x] 多项使用显式 OR，任意一个关键词命中即可召回。
- [x] 空关键词数组使用 `semanticQuery` 的有界 OR token 降级。
- [x] 最终 FTS5 表达式可进入检索 Trace，但不记录分片正文。
- [x] 补齐转义、OR、短语、去重、数量和降级单元测试。

## 4. Retriever 与仓库范围

- [x] `KnowledgeRAGService` 将 `semanticQuery` 和 `keywordQueries` 分别传入 Retriever。
- [x] Keyword 分支只消费关键词查询，Vector 与 Rerank 继续消费 `semanticQuery`。
- [x] 单仓库 `.only` 只在选中 repo id 内召回。
- [x] 多仓库 `.only` 只在选中 repo ids 内统一召回。
- [x] `.prefer` 保留既有 repo boost，`.exclude` 不被关键词恢复。
- [x] repo 名不作为 FTS 必须命中的关键词。
- [x] Keyword / Vector 保持并行和独立降级语义。
- [x] SQLite 默认路径与 Meilisearch/fallback 路径使用一致的关键词协议。
- [x] 补齐范围、融合、单分支失败与零命中测试。

## 5. Plan、检索漏斗与 Debug

- [x] Plan 展示实际 `semanticQuery` 与校验后的 `keywordQueries`。
- [x] Retrieval Trace 保存最终 FTS5 表达式，Retrieval Snapshot 只保存两路安全 failure code。
- [x] 检索漏斗区分成功零命中、执行失败与已跳过。
- [x] 检索漏斗继续展示候选、召回、融合、重排和最终证据真实数量。
- [x] 历史会话与 Debug JSON 缺少新增字段时仍可恢复。
- [x] 所有新增固定文案补齐 en / zh-Hans i18n。
- [x] 补齐 Inspector read model、历史解码与 Debug payload 测试。

## 6. 正式文档与工程进度

- [x] 更新 `docs/3-设计/详细设计/29-关键词与全文检索设计.md`，明确普通 AND 与 RAG OR 的边界。
- [x] 更新 `docs/3-设计/详细设计/30-本地RAG设计.md`，记录双查询协议和双语规则。
- [x] 更新 `docs/1-立项/开发前问题清单.md`，记录正式设计决策。
- [x] 更新 `docs/4-工程进度/知识库RAG专项/知识库RAG专项进度.md`，同步真实实现和验证状态。
- [x] 核对文档中的字段名、数量、降级和 repo scope 与代码完全一致。

## 7. 自动化验证

- [x] 新增 Swift 文件后执行 `xcodegen generate`（本次没有新增 Swift 文件，已生成工程核对）。
- [x] `rtk git diff --check` 通过。
- [x] `rtk jq empty Starcat/Resources/Localizable.xcstrings` 通过。
- [x] Query Plan、Planner、FTS5、Retriever 与 Inspector 定向测试通过。
- [x] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build-for-testing` 通过。
- [x] RAG 相关定向 Suite 通过。
- [x] 全量 `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test` 通过。
- [x] `Starcat` Debug target build 通过。
- [x] `StarcatDirect` Debug target build 通过。
- [x] 无新增 Swift 编译 warning 或 error；Direct Debug 缺少独立 changelog 时有一条预期资源回退 warning。

## 8. 第一轮审查：协议、兼容与范围

- [x] 先新增并提交第一轮审查报告。
- [x] 对照方案审查 Query Plan、Planner Prompt、默认模板升级与旧 JSON 兼容。
- [x] 审查 OR 构造的安全性、边界输入和 fallback。
- [x] 审查单仓库、多仓库、prefer、exclude 是否可能越界。
- [x] 报告发现的问题逐项修复并按小功能提交。
- [x] 修复后重跑相关定向测试并回填报告。

## 9. 第二轮审查：检索、可观测性与测试

- [x] 先新增并提交第二轮审查报告。
- [x] 审查 Keyword / Vector / Rerank 查询职责和独立降级。
- [x] 审查漏斗、Plan、Debug、历史恢复展示的是否为真实执行值。
- [x] 审查零命中、执行失败和已跳过是否正确区分。
- [x] 对照实现审查测试是否存在缺口或仅测试了 helper。
- [x] 报告发现的问题逐项修复并按小功能提交。
- [x] 修复后重跑相关定向测试并回填报告。

## 10. 第三轮审查：文档、工程进度与最终门禁

- [x] 先新增并提交第三轮审查报告。
- [x] 对照代码、测试、正式设计文档、专项进度和本 Checklist 逐项核验。
- [x] 只读核对 `docs/功能实现总览.md`，起草待 dong4j 确认的同步内容。
- [x] 核对所有小功能和审查修复均有独立中文 commit。
- [x] 执行最终定向、全量、双 target build 与静态检查。
- [x] 报告发现的问题逐项修复并按小功能提交。
- [x] 修复后再次执行最终门禁并回填报告。

## 11. 最终收口

- [x] 至少三轮审查完成，最后一轮无遗留功能缺口。
- [x] 本 Checklist 全部项目均有真实证据并已回填。
- [x] 新增并提交 `RAG双语关键词OR检索结果报告.md`。
- [x] 结果报告列出实现、验证、提交、已知边界和工程总览待确认内容。
- [x] 确认任务分支没有 push。
- [x] 确认 worktree 干净，所有改动均已提交。
