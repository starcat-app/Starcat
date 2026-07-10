# Cline-style Agent 全量交付总 checklist

> 状态: 实现与自动化验证完成,待验收文档、六轮审查和最终报告
> 创建: 2026-07-07
> 重构: 2026-07-10
> 目标分支: `codex/agent-cline-loop`
> 独立 worktree: `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-agent-full-delivery`
> 前置分析: `docs/4-工程进度/AgentCline参考实现专项/Cline-Agent实现分析与Starcat落地方案.md`
> 当前基线: 模型驱动 Agent loop 已落地并通过专项与全量回归,正在执行交付审查。

## 1. 交付约定

- [x] 本专项以“一次性完成全部 Agent 需求”为唯一交付口径,不把中间批次作为最终交付。
- [x] 允许按模块分批开发、测试和提交,但所有批次、审查、修复、文档和验收全部完成后才能宣布交付。
- [x] 每个小功能单独提交,commit message 使用中文,不 push。
- [x] 使用基于 `main` 的独立 worktree 开发,不再使用已废弃的 `feature/agent`。
- [x] 不为未上线代码保留旧 Runtime 兼容分支;新 Loop Runtime 验证完成后直接删除被替代的线性执行路径。
- [x] 发现 checklist 遗漏时先补入清单再实现,不得以“后续 TODO”绕过本次交付。

## 2. 本次范围

### 2.1 必须完成

- [x] Prompt Pipeline: 环境、mode、locale、规则、工具可见性、External Search 策略和上下文预算。
- [x] Message Contract: `user / assistant / tool` 消息及 text、reasoning、tool-call、tool-result 内容块。
- [x] Tool Schema: 模型可见 schema、参数校验、权限、完成语义、超时和重试策略。
- [x] LLM Adapter: OpenAI-compatible tools/tool choice/tool-call/usage/流式 delta 解析。
- [x] Loop Runtime: `model -> tool-call -> tool-result -> model` 多轮循环。
- [x] Run Session: 稳定 runID、命令通道、取消、审批暂停/恢复和终态一致性。
- [x] Persistence: messages、tool calls、tool results、usage、approval、artifact 和统一执行顺序持久化。
- [x] Approval: 写入型工具暂停、批准、拒绝、恢复和拒绝结果回灌。
- [x] External Search: 复用现有设置/provider/API key/cache/privacy,由模型主动调用。
- [x] GitHub Weekly Report: 完整迁移到 Loop Runtime,生成真实可审计 artifact。
- [x] Agent Workspace: message timeline、可展开输入输出、流式文本、审批和通用 Inspector。
- [ ] 单测、验收文档、工程进度、多轮审查、修复和最终结果报告。

### 2.2 明确不做

- [x] 不做通用 Coding Agent。
- [x] 不开放 shell、文件编辑、`apply_patch` 或任意命令执行工具。
- [x] 不新增第二套 AI Provider 设置、API key 或 Keychain 读取路径。
- [x] 不新增第二套 External Search 设置、provider、API key、缓存或隐私策略。
- [x] 不绕过私有仓库和匿名模式边界。
- [x] 不自动写 tag、note、status、star/unstar;写入能力只能在用户确认后执行。
- [x] 不做多 Agent team、subagent 或后台定时 Agent。
- [x] 不 push。

## 3. 架构硬约束

- [x] `AgentPromptBuilder` 是 system prompt 和 turn request 的唯一构建入口。
- [x] `AgentMessage` 是 run 可回放事实源;trace、step、tool output 和 artifact 只能由消息或运行事件投影。
- [x] 每个 run 从创建起拥有稳定 runID,Runtime、Repository、Workspace 和 Approval 全程使用同一 ID。
- [x] `AgentRunSession` 使用 actor 或等价串行隔离维护 loop 状态,UI 通过命令通道发送 cancel/approve/reject。
- [x] 所有持久化事件拥有单调递增 `sequence`,历史恢复严格按 sequence 重建 timeline。
- [x] 所有工具必须声明模型可见 `name`、`description`、`inputSchema`、`permission`、`completesRun`、`timeout` 和 `retryPolicy`。
- [x] Runtime 在调用宿主工具前强制校验工具可见性、参数 schema 和权限,不能依赖工具自行保护。
- [x] 模型可见工具集合由 Agent 定义和 execution mode 共同决定;External Search 产品开关保留工具可见性,由结构化 skipped result 向模型反馈禁用状态。
- [x] AI Provider 不支持 tool-calling 时明确失败,不能静默回退到固定工具序列或伪造结果。
- [x] 流式 tool-call 必须按 choice/index/callID 聚合参数 delta,完整 JSON 形成后才能执行。
- [x] Runtime 同时限制 max iterations、总工具调用数、总 token、上下文长度、总耗时和单工具超时。
- [x] 错误、跳过、超时、用户拒绝都作为结构化 tool-result 回灌给模型。
- [x] 写入型工具在执行前进入 `waitingForConfirmation`,批准前不得产生副作用。
- [x] Artifact 只在模型或完成工具明确提交后生成,并按统一 sequence 出现在 timeline 底部。
- [x] 缺少 AI 配置、模型失败或数据不足时明确失败,不得生成 fake artifact。

## 4. 迁移前基线(已替换)

- [x] Agent 与 RAG 已使用独立 workspace window。
- [x] Agent 工作台具备三栏壳层、左右栏折叠、置顶和自适应输入框。
- [x] GitHub Weekly Report 和 Repo Insight 可读取真实本地 repo snapshot。
- [x] 迁移前已有 `AgentTool`、Tool Registry 和线性只读工具序列;现已由模型可见 schema 与 `LoopAgentRuntime` 替换。
- [x] 已复用现有 External Search 设置/provider/cache 链路。
- [x] 迁移前已有 run、step、trace、tool output、artifact v1 持久化;现已收敛为 run/message/approval/artifact 事实表。
- [x] 迁移前 trace 节点可展开输入、输出和日志;现由 message timeline 投影同一组可审计事实。
- [x] 缺少 AI 配置时不生成假 artifact。
- [x] 上述内容只记录迁移起点,不作为当前 Cline-style 架构事实。

## 5. 分批实施 checklist

### 5.1 文档与边界修正

- [x] 将旧 Cline Loop checklist 重构为本全量交付总 checklist。
- [x] 修正旧专项中容易误导的“闭环”表述,明确已完成的是线性工具编排 v1。
- [x] 更新 `docs/功能实现总览.md`,新增 Cline-style Agent 全量交付进行中条目和变更日志。
- [x] 新增第二轮 checklist 完整性审查报告,记录本轮新增约束和结论。

### 5.2 Prompt Pipeline 与上下文预算

- [x] 新增 `AgentExecutionMode`: `readonlyPlanning`、`reportGeneration`、`approvedAction`、`backgroundDigest`。
- [x] 新增 `AgentPromptEnvironment`: app/version/platform/date/locale/workspace/mode。
- [x] 新增 `AgentPromptRule` 和 `AgentPromptContext`: Agent 定义、run context、可用工具、产品规则、语言和 External Search 策略。
- [x] 新增 `AgentPromptBuilder`,统一构建 system prompt 与每轮模型请求。
- [x] Prompt 注入本地优先、只读默认、确认后写入、真实来源和禁止伪造约束。
- [x] Prompt 注入 mode guardrails、preferred language、工具可见性和 External Search 开关/provider/privacy。
- [x] 新增 `AgentContextBudgeter`,分别限制 repo snapshot、历史消息、tool-result、外部搜索和 artifact 草稿。
- [x] 新增 `AgentMessageCompactor`,超预算时保留 system、最近轮次和 tool-call/tool-result 关联摘要。
- [x] 删除 `OpenAIAgentTextGenerator.systemPrompt(for:)` 中分散的核心提示词。
- [x] 补 PromptBuilder/ContextBudgeter/Compactor 单测: mode、locale、search 开关、tool visibility、预算边界和关联消息保留。

### 5.3 Message Contract 与统一顺序

- [x] 新增 `AgentMessageRole`: user/assistant/tool。
- [x] 新增 `AgentMessagePart`: text/reasoning/toolCall/toolResult。
- [x] 新增 `AgentToolCall`: id/name/input/sequence。
- [x] 新增 `AgentToolResultMessage`: toolCallID/toolName/output/isError/status/elapsed/sources/sequence。
- [x] 新增 `AgentUsage`: input/output/cached/reasoning/total token 和可选成本字段。
- [x] 新增 `AgentMessage`、`AgentTurn` 和统一 `AgentTimelineItem` 投影契约。
- [x] 明确 assistant message 可以同时包含 reasoning、text 和多个 tool-call。
- [x] 保证 tool-result 必须关联已存在的 toolCallID,未知或重复 ID 明确失败。
- [x] 补消息编码、关联 ID、多工具调用、错误结果和 sequence 排序单测。

### 5.4 Tool Schema 与执行策略

- [x] 新增可 Codable/Sendable 的 `AgentJSONValue`。
- [x] 新增 `AgentJSONSchema`,支持 object/string/number/integer/boolean/array/enum/required/default/description。
- [x] 新增 `AgentToolDefinition`: name/description/inputSchema/permission/completesRun/timeout/retryPolicy。
- [x] `AgentTool` 改为提供 definition,并按 `AgentToolCall` 执行。
- [x] Tool Registry 按 name 查找,拒绝重复 name 和未知工具。
- [x] 执行前完成 required、类型、enum 和未知字段校验,非法输入返回 error tool-result。
- [x] Runtime 强制执行 readOnly/requiresConfirmation/highCost 策略。
- [x] 超时与重试只允许只读工具自动执行,每次 attempt 的序号、状态、耗时和错误摘要均随 tool-result 持久化。
- [x] 迁移所有现有只读工具到 schema 形式。
- [x] 补 Registry、Schema、权限、超时、重试、unknown tool 和 completesRun 单测。

### 5.5 LLM Tool Call Adapter

- [x] 扩展 AI 请求模型,支持 messages、tools、tool choice、parallel tool calls 和 model metadata。
- [x] 扩展非流式响应,支持 text、reasoning、tool calls、usage 和 finish reason。
- [x] 扩展流式事件,支持 text delta、reasoning delta、tool-call delta、usage 和 completed。
- [x] 新增 `AgentLoopModelClient`,复用现有 AI Provider、模型参数、API key 和 OpenAI-compatible client。
- [x] `OpenAIClient` 发送工具 schema,不再把 tool-call-only 响应当作 empty response。
- [x] 实现流式 tool-call accumulator,正确拼接多个并行 call 的 name 和 JSON arguments。
- [x] 增加 provider capability 检测;不支持 tool-calling 时返回可读错误。
- [x] 明确不同 OpenAI-compatible provider 的 finish reason 和 usage 缺失处理。
- [x] 补 text-only、单/多 tool-call、流式分片、乱序 delta、非法 JSON、缺 key、provider 错误和不支持能力单测。

### 5.6 Run Session 与 Loop Runtime

- [x] 新增 `AgentRunLimits`: maxIterations/maxToolCalls/maxTokens/maxDuration/toolTimeout。
- [x] 新增 `AgentRunSession` actor,持有 runID、messages、iteration、usage、pendingApproval、terminalState 和 command channel。
- [x] 新增模型驱动 `LoopAgentRuntime`,直接替换线性 `DefaultAgentRuntime` 执行路径。
- [x] Runtime 创建并持久化 user message,使用 PromptBuilder 发起第一轮模型调用。
- [x] 每轮持久化 assistant message、reasoning、usage 和 tool calls。
- [x] 无 tool-call 时以 assistant 最终响应完成 run。
- [x] 有 tool-call 时校验并执行工具,追加 tool-result 后进入下一轮模型调用。
- [x] 多个只读 tool-call 按确定顺序执行;第一版不并行写入工具。
- [x] unknown/invalid/failed/skipped/timeout/rejected 结果均回灌模型。
- [x] `completesRun` 工具提交 artifact 后仍持久化最终 assistant/submit 状态。
- [x] 达到迭代、工具、token 或时间预算时进入明确失败终态。
- [x] cancel 通过 session command channel 生效,只允许写入一次终态。
- [x] 删除人为 UI 演示延迟和被替代的固定工具执行逻辑。
- [x] 补主动选工具、多轮调用、无工具完成、单轮多只读调用、错误回灌、预算耗尽、取消和终态竞争单测。

### 5.7 持久化与历史恢复

- [x] 更新 Agent 数据库 schema,以 messages/parts/tool calls/tool results/usage/approvals 为事实表。
- [x] 所有事实记录保存 runID、turn、sequence、createdAt 和关联 ID。
- [x] artifact 保存创建它的 toolCallID/messageID/sequence。
- [x] pending approval 保存 tool input、policy、状态和决策时间。
- [x] 每次 message/tool-result/approval 追加与 run 状态更新保持事务一致。
- [x] 历史恢复按 sequence 重建完整 message timeline,不依赖 step/trace 猜测顺序。
- [x] 恢复 completed/failed/cancelled/waitingForConfirmation 状态。
- [x] App 重启后可查看 pending approval,但必须由用户明确操作后才能继续执行。
- [x] 删除被新事实表取代的 step/trace/tool-output 投影存储,不保留兼容迁移代码。
- [x] 补完整 run、失败 run、取消 run、pending approval、artifact 关联和顺序恢复单测。

### 5.8 Approval 闭环

- [x] 新增 `AgentApprovalRequest`: runID/toolCallID/toolName/input/policy/status/createdAt/decidedAt。
- [x] 新增 `waitingForConfirmation` run 状态和 Runtime 事件。
- [x] `requiresConfirmation` 工具在执行前暂停 session 并持久化 pending approval。
- [x] approve 命令只执行原 toolCallID 对应工具,执行成功后写入 tool-result 并继续同一 run。
- [x] reject 命令写入结构化 error tool-result,再交给模型收敛。
- [x] 重复、过期、错误 runID/toolCallID 的审批命令明确拒绝。
- [x] 等待审批期间支持取消,取消后审批命令不再生效。
- [x] 中栏显示审批节点,右侧 Inspector 显示参数、风险、批准和拒绝操作。
- [x] 补 requested/approved/rejected/duplicate/cancelled/restored approval 单测。
> 实现: `resumePendingRun` 从持久化 message/approval/artifact 重建同一 session,保持等待态;批准后只执行原 tool-call 一次,拒绝或取消均不执行。

### 5.9 GitHub Weekly Report 与 External Search 迁移

- [x] Weekly Agent 使用 `LoopAgentRuntime`,`toolIDs` 仅作为 allowlist,不再声明固定执行顺序。
- [x] 暴露 `context_resolve_repos` schema,支持 repoIDs 范围、数量和排序参数。
- [x] 暴露 `external_search` schema: query/maxResults/allowedDomains/recency/repoIDs。
- [x] `external_search` 查询由模型参数驱动,不再固定搜索前 3 个仓库。
- [x] 搜索继续复用现有设置/provider/API key/匿名模式/cache/Pro 和隐私边界。
- [x] 搜索关闭时返回 skipped tool-result;provider 失败时返回 error tool-result并允许本地收敛。
> 实现: 模型参数经类型化请求直达现有 External Search 编排器;缓存指纹包含筛选条件,Provider 落地域名与时间范围,私有仓库在网络请求前按设置拦截。
- [x] 暴露 `repo_cluster_topics` 和 `artifact_build_*` 完成工具;由 `completesRun` 工具承担 artifact 提交语义,不重复增加 `run_submit_artifact`。
- [x] Weekly Prompt 注入 repo ID/private 标记,要求使用真实冻结快照、列明来源并禁止伪造 live GitHub 信息。
- [x] 周刊 artifact 包含执行范围、模型分析主题、真实仓库条目、来源、限制说明和可追溯引用。
> 实现: 模型提交结构化摘要/章节/repo IDs/限制,宿主拒绝越界 ID 并用冻结快照的真实 URL、Stars、Topics 和 External Search 来源渲染最终 Markdown。
- [x] `completesRun` 工具成功后以独立 sequence 提交 artifact 并直接结束 run,产物位于 timeline 底部。
- [x] 缺 AI 配置、核心本地上下文读取失败或 Weekly/Repo Insight 仓库为空时明确失败且不生成 fake artifact。
- [x] Repo Insight 同步使用 Loop Runtime、参数驱动选仓与结构化 artifact,验证框架不是 Weekly 专用脚本。
- [x] 补 Weekly/Repo Insight 模型选工具、search disabled/failed、artifact 顺序、真实数据和缺配置单测。

### 5.10 Workspace Timeline 与 Inspector

- [x] 中栏改为统一 message timeline:user 靠右,assistant/tool/artifact 靠左。
- [x] assistant reasoning/text 支持真实流式追加,完成后与持久化消息一致。
- [x] tool-call 节点展示 name、arguments、状态和 sequence,可展开。
- [x] tool-result 节点展示 output/error/elapsed/sources/retry,可展开并关联 tool-call。
- [x] approval 节点展示等待、批准、拒绝和取消状态。
- [x] artifact 节点按 sequence 位于实际生成位置,点击联动右侧 Inspector。
- [x] Inspector 只展示当前选中 artifact、pending approval 或 run summary,不按 Agent 写专用假面板。
- [x] 复制、导出、artifact 选择继续使用真实状态,剪贴板与写盘失败均返回用户可见错误。
- [x] 删除固定 step kind 猜测、completed fallback、空附件按钮、静态演示延迟和其他占位行为。
- [x] 附件按钮接入真实 UTF-8 文本选择、大小限制、冻结上下文、持久化和 Prompt budget;不保留空 action。
- [x] 空工作台不注入 demo prompt、demo plan、demo message 或 demo artifact。
- [x] 补 timeline ordering、流式合并、展开数据、artifact selection、approval 操作、历史恢复和空态单测。

### 5.11 i18n、日志与可观测性

- [x] 新增 Agent 固定 UI、能力标签、状态、权限和宿主错误文案全部接入 `Localizable.xcstrings` 的 en/zh-Hans。
- [x] 动态模型输出、用户输入、仓库元数据和工具原始输出保持原语义。
- [x] 用户可见错误统一脱敏 API key、Authorization/Bearer 凭证并限制 Provider 错误长度;私有仓库正文不进入错误路径。
- [x] Runtime 日志包含 runID/turn/sequence/toolCallID/status,但不记录密钥和完整敏感输入。
- [x] usage、预算终止、provider 能力失败和 approval 决策具备可诊断日志。
- [x] 使用 `jq empty` 校验 `.xcstrings`,并运行 i18n 缺 key 与禁用 API 扫描。

### 5.12 测试与验收

- [x] 新增 Prompt Pipeline 测试套件。
- [x] 新增 Message Contract 与持久化测试套件。
- [x] 新增 Tool Schema 与权限测试套件。
- [x] 新增 LLM Adapter 和流式 tool-call 测试套件。
- [x] 新增 Loop Runtime、预算和取消竞争测试套件。
- [x] 新增 Approval pause/resume 测试套件。
- [x] 新增 Weekly/External Search 端到端 Runtime 测试套件。
- [x] 新增 Workspace ViewModel timeline/Inspector 测试套件。
- [x] 保留并迁移现有 Agent 有效测试,删除只验证旧固定序列的测试。
- [x] 使用独立 DerivedData 运行全部 Agent 相关单测:98 项通过,0 失败。
- [x] 运行完整 `StarcatTests` 回归测试:1379 项,0 非预期失败。
- [x] 运行 Debug build:`Starcat` scheme 编译成功。
- [x] 新增完整人工验收步骤,覆盖正常、搜索关闭、搜索失败、审批、取消、恢复和导出。

### 5.13 多轮审查、修复与报告

- [x] 第一轮: checklist、Cline 分析、产品文档和不做范围一致性审查。
- [x] 第二轮: Prompt Pipeline、Message Contract、Tool Schema 和实现一致性审查。
- [x] 第三轮: LLM Adapter、Loop Runtime、预算、取消和持久化一致性审查。
- [x] 第四轮: Approval、External Search、Weekly/Repo Insight 功能闭环审查。
- [x] 第五轮: Workspace timeline、Inspector、artifact 顺序、i18n 和占位清理审查。
- [ ] 第六轮: 单测、构建、验收步骤、工程进度和提交历史一致性审查。
- [ ] 每轮先新增独立审查报告,再逐项修复;每个修复点独立中文 commit。
- [ ] 所有审查无阻断问题后回填本 checklist 全部适用项。
- [ ] 更新 `docs/功能实现总览.md` 状态、进度仪表盘和变更日志。
- [ ] 新增最终结果报告,列明实现范围、测试证据、提交清单、已知边界和验收入口。

## 6. 最终验收标准

- [ ] LLM 能看到当前 Agent/mode 允许的工具 schema 并主动选择工具。
- [ ] Runtime 不依赖 `AgentDefinition.toolIDs` 固定顺序完成任务。
- [ ] 每个 tool-result 都回灌下一轮模型,直到模型或完成工具结束 run。
- [ ] provider 返回 tool-call-only 响应不会被当作空响应。
- [ ] user/assistant/tool/tool-result/artifact 按统一 sequence 可持久化、恢复和审计。
- [ ] 每个 tool-call 和 tool-result 都能展开查看真实输入、输出、错误、耗时和来源。
- [ ] External Search 由模型主动调用并完全复用现有设置和隐私边界。
- [ ] External Search 关闭或失败时不伪造来源,模型可基于本地数据继续。
- [ ] 写入型工具在用户批准前不会执行;拒绝结果会回灌模型。
- [ ] App 重启后能正确展示 pending approval,不会自动执行。
- [ ] GitHub Weekly Report 和 Repo Insight 都通过同一 Loop Runtime 运行。
- [ ] Weekly 生成真实 Markdown artifact,且 artifact 位于执行顺序底部。
- [ ] 缺 AI 配置、超预算、取消和 provider 失败均有明确终态且不生成假结果。
- [ ] 工作台没有默认 demo 内容、空操作按钮、固定步骤伪装或人为演示延迟。
- [ ] Agent 固定 UI 文案完成 en/zh-Hans 国际化。
- [ ] 新增测试与现有回归测试通过,构建结果有记录。
- [ ] `docs/功能实现总览.md`、专项 checklist、审查报告、验收步骤和结果报告完全一致。
- [ ] 所有小功能和审查修复均已中文 commit,且没有 push。

## 7. 提交检查

- [ ] 每个 commit 只包含一个可说明、可验证的小功能或审查修复。
- [ ] commit message 使用中文。
- [ ] 不提交当前 worktree 之外的其他任务改动。
- [ ] 不 push。
- [ ] 最终交付前检查 `git status` 干净并输出完整 Agent 专项提交列表。
