# Cline-style Agent Loop 专项进度

> 状态: 计划中
> 创建: 2026-07-07
> 目标分支: `feature/agent`
> 前置分析: `docs/4-工程进度/AgentCline参考实现专项/Cline-Agent实现分析与Starcat落地方案.md`
> 前置专项: `docs/4-工程进度/Agent底层框架专项/checklist.md` / `docs/4-工程进度/AgentRun持久化专项/checklist.md`
> 当前问题: 现有 Agent 仍是线性工具编排 v1,LLM 不能自主选择工具,Prompt 也仍是单 Agent 字符串拼接,还不能按 Cline-style loop 交付。

## 1. 目标

把 Starcat Agent 从“固定工具序列 + LLM 最终润色”升级为面向 GitHub Star 知识库的 Cline-style Agent Runtime:

1. 建立 Prompt Pipeline,统一构建 system prompt、mode guardrails、locale、工具可见性、External Search 策略和上下文预算。
2. 建立 messages contract,让 `user / assistant / tool` 消息成为 run 可回放事实源。
3. 让 tool 具备模型可见 schema,模型可以基于工具描述和参数 schema 主动发起 tool-call。
4. Runtime 改为 `model -> tool-call -> tool-result -> model` 的循环,而不是按 `AgentDefinition.toolIDs` 固定顺序执行。
5. 写入型工具必须进入确认等待态,用户确认后继续执行原 tool-call,拒绝后把拒绝结果回灌给模型。
6. GitHub Weekly Report 迁移为首个 Cline-style loop Agent,产物按执行顺序出现在底部。
7. UI 按 message timeline 展示,每个 tool-call / tool-result 都能展开审计输入、输出、错误、耗时和来源。
8. 单测、文档、工程进度、审查报告和结果报告全部一致。

## 2. 不做范围

- [ ] 不做通用 Coding Agent。
- [ ] 不开放 shell / 文件编辑 / apply_patch 类高权限工具。
- [ ] 不新增第二套 AI Provider 设置。
- [ ] 不新增第二套 External Search 设置或 API key 存储。
- [ ] 不绕过现有 External Search provider / cache / privacy 策略。
- [ ] 不自动写 tag / note / status / unstar。
- [ ] 不做多 Agent team / subagent。
- [ ] 不做定时后台 Agent。
- [ ] 不 push。

## 3. 架构硬约束

- [ ] Prompt Pipeline 和 Runtime Loop 必须同时落地;不能只做更复杂的 prompt,也不能只做工具循环。
- [ ] `AgentPromptBuilder` 是 prompt 构建单一入口,不得继续把核心提示词散落在 `OpenAIAgentTextGenerator.systemPrompt(for:)`。
- [ ] messages 是 run 可回放事实源;trace / tool output / artifact 是 UI 或审计投影,不能反向成为事实源。
- [ ] 所有 tool 必须有模型可见 `name`、`description`、`inputSchema`、`permission` 和可选 `completesRun`。
- [ ] 模型可见工具集合必须由 mode 和 Agent 定义共同决定;模型看不到的工具不能调用。
- [ ] 网络搜索必须复用现有 External Search 设置页、provider、API key、匿名模式、缓存和私有仓库边界。
- [ ] External Search 关闭时,`external.search` 必须返回 skipped tool-result,不得失败或伪造外部来源。
- [ ] provider 失败时,tool-result 必须携带错误,模型可继续基于本地上下文收敛。
- [ ] 写入型 tool-call 必须暂停为 `waitingForConfirmation`,不得在用户确认前执行。
- [ ] 用户拒绝确认后,Runtime 必须把拒绝结果作为 error tool-result 回灌给模型。
- [ ] Artifact 必须按执行顺序生成,不得默认置顶显示结果。

## 4. 实施 checklist

### 4.1 专项文档与边界修正

- [x] 新增 Cline-style Agent Loop 专项 checklist。
- [x] 对照 Cline 分析文档完成 checklist 覆盖性审查。
- [ ] 修正旧专项中容易误导的“闭环”表述,明确当前已完成的是线性工具编排 v1。
- [ ] 更新 `docs/功能实现总览.md`,新增 Cline-style Agent Loop 条目和变更日志。

### 4.2 Prompt Pipeline

- [ ] 新增 `AgentExecutionMode`:
  - `readonlyPlanning`
  - `reportGeneration`
  - `approvedAction`
  - `backgroundDigest`
- [ ] 新增 `AgentPromptEnvironment`,包含 app、版本、平台、日期、locale、workspace、mode。
- [ ] 新增 `AgentPromptContext`,包含 Agent 定义、run context、可用工具、规则、语言、External Search 策略。
- [ ] 新增 `AgentPromptBuilder`,统一构建 system prompt 和 turn request。
- [ ] 从 `OpenAIAgentTextGenerator.systemPrompt(for:)` 迁移到 `AgentPromptBuilder`。
- [ ] Prompt 注入 Starcat 产品边界: 本地优先、只读默认、用户确认后写入。
- [ ] Prompt 注入 mode guardrails,区分只读计划、报告生成和确认写入。
- [ ] Prompt 注入 locale / preferred language,和工作台 i18n 保持一致。
- [ ] Prompt 注入 External Search 开关、provider 状态和隐私边界。
- [ ] Prompt 注入 tool visibility 摘要,但具体参数以 tool schema 为准。
- [ ] 新增 `AgentContextBudgeter`,控制 repo snapshot、external search、tool result 和 artifact 草稿长度。
- [ ] 补 PromptBuilder 单测:
  - mode guardrails
  - locale / preferred language
  - External Search enabled / disabled
  - tool visibility
  - context budget

### 4.3 Message Contract

- [ ] 新增 `AgentMessageRole`: user / assistant / tool。
- [ ] 新增 `AgentMessagePart`: text / reasoning / toolCall / toolResult。
- [ ] 新增 `AgentToolCall`,包含 id、name、input。
- [ ] 新增 `AgentToolResultMessage`,包含 toolCallID、toolName、output、isError。
- [ ] 新增 `AgentUsage`,记录输入、输出、缓存和成本字段。
- [ ] 扩展 `AgentRunRepository`,持久化 messages、tool calls、tool results 和 usage。
- [ ] 历史 run 恢复时以 messages 重建 timeline,不是靠 demo step。
- [ ] 补 message contract 单测:
  - tool-call 与 tool-result 关联 ID
  - 失败 tool-result
  - 历史恢复顺序
  - artifact 与 messages 关联

### 4.4 Tool Schema

- [ ] 新增 `AgentJSONValue`。
- [ ] 新增轻量 `AgentJSONSchema`,第一版支持 object / string / number / boolean / array / enum / required。
- [ ] 新增 `AgentToolDefinition`,包含 name、description、inputSchema、permission、completesRun。
- [ ] 扩展 `AgentTool`,提供模型可见 definition。
- [ ] Tool Registry 支持按 name 查找 tool-call 目标。
- [ ] Tool 执行前校验 input schema,非法输入返回 error tool-result。
- [ ] 迁移现有只读工具到 schema 形式。
- [ ] `external.search` 暴露 query / maxResults / allowedDomains / recency 等 schema。
- [ ] `artifact.build_weekly_report` 标记为可完成 run 的 artifact 工具。
- [ ] 补 tool schema 单测:
  - duplicate name
  - unknown tool
  - invalid input
  - permission mapping
  - completesRun

### 4.5 LLM Tool Call Adapter

- [ ] 扩展 `AIChatRequest`,支持 tools / tool choice / model metadata。
- [ ] 扩展 `AIChatResponse` 或新增 stream event,支持 text delta / reasoning delta / tool-call delta / usage / finish。
- [ ] 新增 `AgentLoopModelClient`,复用现有 AI Provider / OpenAI-compatible client。
- [ ] 实现 OpenAI-compatible `tool_calls` 解析。
- [ ] 不新增第二套 provider 配置或 keychain 读取路径。
- [ ] provider 不支持 tool calls 时给出明确失败,不得静默降级为 demo。
- [ ] 补 LLM adapter 单测:
  - text only
  - one tool call
  - multiple tool calls
  - invalid JSON arguments
  - provider error
  - missing API key

### 4.6 Loop Runtime

- [ ] 新增 `LoopAgentRuntime` 或等价新路径,保留旧 Runtime 作为迁移期 fallback。
- [ ] Runtime 初始化 user message 和 system prompt。
- [ ] Runtime 每轮调用模型并解析 assistant message。
- [ ] Runtime 无 tool-call 时完成 run。
- [ ] Runtime 有 tool-call 时执行工具并追加 tool-result message。
- [ ] Runtime 将 tool-result 回灌给下一轮模型。
- [ ] Runtime 支持 maxIterations,超过后失败并持久化。
- [ ] Runtime 支持 cancel,取消时写入终态。
- [ ] Runtime 支持错误 tool-result 回灌,而不是直接吞掉。
- [ ] Runtime emits 适配现有 `AgentRunEvent`,保证 UI 可渐进迁移。
- [ ] 补 LoopRuntime 单测:
  - 模型主动选择工具
  - 多轮 tool-call
  - 无 tool-call 完成
  - unknown tool
  - maxIterations
  - cancel
  - provider failure

### 4.7 Approval 闭环

- [ ] 新增 `AgentPendingApproval`,记录 runID、toolCallID、toolName、input、policy。
- [ ] 新增 `waitingForConfirmation` run 状态。
- [ ] `requiresConfirmation` 工具调用时暂停 Runtime。
- [ ] 用户确认后继续执行原 tool-call。
- [ ] 用户拒绝后写入 error tool-result 并继续交给模型收敛。
- [ ] 确认状态持久化,历史恢复能看到 pending approval。
- [ ] UI 中栏显示 pending approval 节点。
- [ ] 右侧只显示当前 pending approval 详情和操作,不做 Agent 专用假面板。
- [ ] 补 approval 单测:
  - approval requested
  - approval accepted
  - approval rejected
  - stream cancellation during approval
  - restore pending approval

### 4.8 GitHub Weekly Report 迁移

- [ ] Weekly Agent 使用 Loop Runtime。
- [ ] 暴露 `context.resolve_repos`。
- [ ] 暴露 `external.search`。
- [ ] 暴露 `repo.cluster_topics`。
- [ ] 暴露 `artifact.build_weekly_report`。
- [ ] 暴露 `run.submit_artifact`。
- [ ] Prompt 要求 Weekly 使用真实 Starcat 本地 repo snapshot,不得伪造 repo。
- [ ] 网络搜索关闭时,Weekly 仍能本地生成,但必须说明没有外部来源。
- [ ] 网络搜索失败时,Weekly trace / tool-result 保留错误并继续本地上下文。
- [ ] Artifact 按执行顺序在底部生成。
- [ ] 去掉 Weekly 默认 demo 内容。
- [ ] 补 Weekly loop 单测:
  - 模型主动调用 resolve/search/build artifact
  - External Search disabled
  - External Search provider failed
  - artifact at bottom
  - missing AI config fails without fake artifact

### 4.9 UI Timeline 与 Inspector

- [ ] 中栏从固定 step list 迁移为 message timeline。
- [ ] user message 靠右,assistant message 靠左。
- [ ] tool-call 节点可展开查看 tool name、input、状态。
- [ ] tool-result 节点可展开查看 output、error、elapsed、sources。
- [ ] reasoning / assistant text 支持流式追加。
- [ ] Artifact 节点按执行顺序出现在底部。
- [ ] 右侧 Inspector 只展示当前选中 artifact / pending approval / run summary。
- [ ] 删除或隐藏所有 demo 默认内容。
- [ ] 补 ViewModel 单测:
  - message timeline ordering
  - tool-call expand data
  - artifact selection
  - pending approval selection
  - no default demo content

### 4.10 文档、审查与结果报告

- [ ] 更新 Cline-style Agent Loop 验收步骤说明。
- [ ] 第一轮审查: checklist 与 Cline 分析文档覆盖一致性。
- [ ] 第二轮审查: Prompt Pipeline 代码与文档一致性。
- [ ] 第三轮审查: Runtime Loop 代码与 tool schema 一致性。
- [ ] 第四轮审查: UI timeline、Inspector、artifact 顺序一致性。
- [ ] 第五轮审查: 单测、工程进度、验收步骤一致性。
- [ ] 根据审查发现逐项修复,每个修复点单独提交。
- [ ] 新增最终结果报告。

## 5. 验收标准

- [ ] `AgentPromptBuilder` 是 Agent prompt 构建单一入口。
- [ ] 不同 `AgentExecutionMode` 有明确 guardrails。
- [ ] LLM 能看到 tool schema 并主动发起 tool-call。
- [ ] Runtime 不再依赖 `AgentDefinition.toolIDs` 固定顺序完成 Weekly。
- [ ] tool-result 会回灌给下一轮模型。
- [ ] 中栏按执行顺序展示 user / assistant / tool-call / tool-result / artifact。
- [ ] 每个 tool-call / tool-result 都能展开查看输入和输出。
- [ ] `external.search` 由模型主动调用,且复用现有 External Search 设置。
- [ ] External Search 关闭时显示 skipped tool-result,不伪造外部来源。
- [ ] 写入型工具必须等待用户确认。
- [ ] 用户拒绝确认后,模型能收到 error tool-result 并继续收敛。
- [ ] GitHub Weekly Report 能生成真实 artifact,且 artifact 位于执行顺序底部。
- [ ] 缺 AI 配置时明确失败,不生成 fake artifact。
- [ ] 历史 run 可恢复完整 messages、tool results 和 artifacts。
- [ ] 无默认 demo prompt / demo plan / demo artifact。
- [ ] 单测覆盖 Prompt Pipeline、Tool Schema、LLM Adapter、Loop Runtime、Approval、Weekly 迁移和 UI timeline。
- [ ] `docs/功能实现总览.md`、专项 checklist、审查报告、结果报告状态一致。

## 6. 提交要求

- [ ] 每完成一个小功能 commit 一次。
- [ ] commit message 使用中文。
- [ ] 不 push。
- [ ] 不提交无关工作区改动。
