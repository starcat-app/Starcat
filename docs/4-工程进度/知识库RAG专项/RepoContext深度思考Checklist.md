# RepoContext 深度思考 Checklist

> 状态：已完成（自动化与四轮审查收口；人工 UI 点选未执行且未伪造）
> 日期：2026-07-17
> 方案：`RepoContext深度思考实施方案.md`
> 约束：每个小功能独立使用中文 commit message 提交；不 push；先写每轮审查报告，再修复报告发现的问题。

## 0. 开工与边界

- [x] 阅读根目录 `AGENTS.md`、`DESIGN.md` 与相关 UI 强制规范。
- [x] 只读检查 `docs/功能实现总览.md` 和 `docs/1-立项/开发前问题清单.md`。
- [x] 确认当前分支、worktree 和既有未提交改动，避免纳入本需求提交。
- [x] 明确不修改已发布 v7 RAG schema；citation 复用现有 TEXT / nullable chunk id 能力。
- [x] 明确本轮不执行打包、发布、上传和 push。

## 1. 方案与实施清单

- [x] 固化 Composer 顺序：附件 → 联网搜索 → 深度思考 → 发送。
- [x] 固化“恰好一个项目才可开启、附件数量不限”的产品约束。
- [x] 固化与联网开关一致的按会话 Composer 草稿持久化语义。
- [x] 固化独立 `{repoContextSection}` Prompt 协议，不兼容旧自定义模板。
- [x] 固化 RepoContext 独立于 chunk evidence budget、受模型总窗口约束的预算语义。
- [x] 固化 Planner、时间线、Debug、Plan、Evidence、引用、历史与隐私边界。
- [x] 新增并提交 `RepoContext深度思考实施方案.md`。
- [x] 新增并提交本 Checklist。

## 2. 模型、计划与 Prompt 协议

- [x] 新增 `deepThinkingEnabled` Composer / request snapshot 字段。
- [x] 新增本地标准化 `RAGRepoContextRequest`，只接受唯一显式项目。
- [x] Planner 输入和 `RAGQueryPlan` 保存 RepoContext 请求与用户可见说明。
- [x] 新增独立 `RAGContextBudget.Segment.repoContext`。
- [x] Generator 默认模板新增且强制验证 `{repoContextSection}`。
- [x] `KnowledgeRAGPromptBuilder` 独立构建 RepoContext section。
- [x] 新增 XML 感知投影器，保证投影后 XML 合法并记录统计。
- [x] RepoContext 不使用 `evidenceTokenBudget`、topK、child cap 或 chunk hard cap。
- [x] RepoContext 仍服从模型总上下文窗口和输出保留预算。
- [x] 补齐模型、Planner、Prompt、预算和 XML 投影单元测试。

## 3. Provider、Service 与执行状态机

- [x] `AppDependencies` 提升并复用统一 `RepoAIContextProvider`。
- [x] `KnowledgeRAGService` 注入 RepoContext Provider。
- [x] 新增 `runRepoContextPhase`，顺序位于本地检索之后、联网之前。
- [x] 单项目约束在 Service 边界再次校验。
- [x] Provider cache hit / generated / degraded / cancellation 语义保持正确。
- [x] 成功非空 RepoContext 可单独通过证据门禁。
- [x] 普通失败允许其他证据继续生成；取消终止整轮问答。
- [x] 新增 `RAGRepoContextSnapshot` 审计元数据，不复制 XML 到会话正文。
- [x] 补齐 Service 执行、证据门禁、降级和取消测试。

## 4. Composer 与草稿持久化

- [x] 新增 icon-only `brain` 深度思考按钮。
- [x] Composer 控件顺序符合“附件 → 联网 → 深度思考 → 发送”。
- [x] 只有恰好一个显式项目时按钮可开启。
- [x] 附件数量不影响按钮可用性。
- [x] 已开启后 repo scope 变成 0 个或多个时自动关闭。
- [x] 发送快照冻结本轮开关和唯一目标，不受流式期间 UI 操作影响。
- [x] 深度思考按会话保存、切换和重开恢复，语义与联网开关一致。
- [x] 非单项目草稿恢复时强制关闭。
- [x] 按钮具备 tooltip、accessibility label、hover 和 focus 契约。
- [x] 补齐 Composer 状态与草稿持久化测试。

## 5. 时间线与 Debug Trace

- [x] 新增 `RAGExecutionStepKind.repoContext`。
- [x] 新增 prepared / progress / completed RepoContext 执行事件。
- [x] 时间线显示“深度思考”及缓存、下载、生成、投影真实子状态。
- [x] 运行中默认展开、完成后自动折叠、失败显示降级摘要。
- [x] 新增 `repoContextRequest` Debug stage。
- [x] 新增 `repoContextResponse` Debug stage。
- [x] 新增 `repoContextProjection` Debug stage。
- [x] ViewModel 事件转换、持久化、导出和字节统计完整保留结构化 payload。
- [x] Debug 摘要不重复保存 XML；最终 prompt stage 保留实际发送内容。
- [x] Debug 帮助说明完整 Prompt 可能含代码 XML 的本地隐私边界。
- [x] 补齐执行 reducer、历史解码和 Debug payload 测试。

## 6. Plan、引用与 Evidence Inspector

- [x] Plan 展示启用状态、目标、理由、配置预算和执行结果。
- [x] Plan 展示 commit、cache、原始/发送 token 和投影状态。
- [x] 新增独立 citation source `repoContext`，不污染 `RAGChunkSource`。
- [x] RepoContext citation 使用 `chunkID = nil` 且不显示“分片已删除”。
- [x] Prompt marker、回答引用解析和持久化 citation 一致。
- [x] Evidence 新增“项目代码上下文”独立区，不计入普通分片。
- [x] 即使回答未引用，只要成功注入也展示 RepoContext 区。
- [x] 展示 repo、commit、hash、cache/generated、token 与投影状态。
- [x] 展示实际发送 XML 的 5 行预览、完整 popover 与复制反馈。
- [x] 点击正文 RepoContext 引用可切换 Evidence、展开并定位。
- [x] 历史仅在 repo + commit + hash 匹配时重载 XML；不匹配时明确不可回放。
- [x] 补齐 citation、Inspector read model 和历史回放测试。

## 7. i18n、文档与隐私

- [x] 所有新增固定文案进入 `Localizable.xcstrings`，en / zh-Hans 完整。
- [x] `jq empty Starcat/Resources/Localizable.xcstrings` 通过。
- [x] 更新 `docs/3-设计/详细设计/30-本地RAG设计.md` 的正式运行链路。
- [x] 更新 `docs/1-立项/开发前问题清单.md`，记录 RepoContext 产品与隐私决策。
- [x] 更新 `知识库RAG专项进度.md`，但不伪造人工验收完成。
- [x] 不修改 `docs/功能实现总览.md`；另列拟同步条目等待 dong4j 明确确认。
- [x] RepoContext XML 不写 `rag_chunks`、notes、普通消息正文或 CloudKit。
- [x] 私有仓库 identity / XML 不进入 External Search query。
- [x] Debug 本地文件隐私说明和清理边界与实现一致。

## 8. 自动化验证

- [x] 新增 / 删除 Swift 文件后执行 `xcodegen generate`。
- [x] 定向测试覆盖本 Checklist 的核心行为。
- [x] `git diff --check` 通过。
- [x] 固定文案 i18n key 覆盖检查通过。
- [x] `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build-for-testing` 通过。
- [x] RAG 相关定向 Suite 通过。
- [x] 全量 `xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test` 通过。
- [x] `Starcat` Debug target build 通过。
- [x] `StarcatDirect` Debug target build 通过。
- [x] 无新增 warning / error；既有 `KnowledgeRAGCoreTests` MainActor warning 与一次 test host 启动前 signal kill 瞬态已记录，重跑全量通过。

## 9. 第一轮审查：架构、预算与数据边界

- [x] 先新增并提交第一轮审查报告。
- [x] 核对 Provider 是否复用，是否存在重复下载/缓存实现。
- [x] 核对 RepoContext 是否独立于 chunk budget 且没有突破总窗口。
- [x] 核对 XML 投影合法性、证据门禁、降级与取消。
- [x] 核对数据库、历史、Debug、CloudKit 与私有仓库边界。
- [x] 报告发现的问题逐个修复并按小功能提交。
- [x] 修复后重新执行相关定向测试并回填报告。

## 10. 第二轮审查：UI、持久化与可观测性

- [x] 先新增并提交第二轮审查报告。
- [x] 核对 Composer 顺序、单项目限制、附件无关性与可访问性。
- [x] 核对按会话草稿保存、切换、重开与非法恢复。
- [x] 核对时间线真实步骤、自动折叠和错误状态。
- [x] 核对 Plan、Evidence、引用定位、XML 预览与历史准确性。
- [x] 核对 Debug stage UI、payload、导出和历史解码。
- [x] 报告发现的问题逐个修复并按小功能提交。
- [x] 修复后重新执行相关定向测试并回填报告。

## 11. 第三轮审查：测试、文档与工程进度一致性

- [x] 先新增并提交第三轮审查报告。
- [x] 对照方案、代码、测试、i18n、专项进度和 Checklist 逐项检查。
- [x] 核对 `docs/功能实现总览.md` 只读现状并起草待确认同步内容。
- [x] 核对所有小功能与审查修复均有独立中文 commit。
- [x] 执行最终定向测试、全量测试、双 target build 与静态检查。
- [x] 报告发现的问题逐个修复并按小功能提交。
- [x] 修复后再次执行最终门禁并回填报告。

## 12. 最终收口

- [x] 至少三轮审查完成，最后一轮无遗留功能缺口（实际完成四轮）。
- [x] 本 Checklist 全部可自动验证项已回填。
- [x] 人工 UI 验收项如无法自动观察，明确保持未完成，不伪造结果。
- [x] 新增并提交 `RepoContext深度思考结果报告.md`。
- [x] 结果报告列出实现、验证、提交、已知边界和工程总览待确认内容。
- [x] 确认未 push。
