# Cline Agent 设计学习心得

> 文档定位：从 [`cline/cline`](https://github.com/cline/cline) 提炼 Starcat Agent 可复用的底层设计。本文不是引入 Cline SDK 的方案，而是记录 prompt 构建、结构化工具调用、ReAct loop、权限确认与 UI 映射的学习结论。

## 一、核心结论

Cline 值得学习的不是“代码代理能力”，而是它把 Agent 拆成了几条清晰边界：

1. **Prompt 是分层构建的运行时配置**，不是一整段不可维护的大字符串。
2. **LLM 输出结构主要靠 tool schema 和 completion tool 约束**，不是靠“请输出 JSON”。
3. **ReAct loop 是消息块循环**：assistant text / reasoning / tool-call / tool-result 都是稳定 message part。
4. **工具执行有 policy / hook / approval 三层护栏**，适合 Starcat 的“只读优先，写入确认”策略。
5. **UI 消费事件流**，而不是理解每个 Agent 的业务细节。

Starcat 后续应自研 runtime，但可以采用这些边界。

## 二、Prompt 构建方式

Cline 的 system prompt 不是固定文本，而是：

```text
base system prompt
+ runtime environment
+ workspace metadata
+ rules
+ mode
+ user input envelope
```

对应到 Starcat，建议拆成：

```text
Starcat base prompt
+ AgentDefinition
+ PermissionMode(readOnly / confirmBeforeWrite)
+ ContextSnapshot(selected repos / current repo / filters / weekly source)
+ ToolManifest
+ ArtifactSchema
+ UserInputEnvelope
```

示例：

```xml
<starcat_run mode="read_only" agent="github_weekly_report">
  <context>
    <selected_repos count="24" source="manage-selection" />
    <topic value="AI Agent" />
    <permission writes="confirm_required" />
  </context>
  <user_input>
    基于这些 repo 生成一期 AI Agent 专题周报。
  </user_input>
</starcat_run>
```

关键点：repo 上下文、权限、任务类型都要结构化注入，避免让 LLM 从自然语言里猜。

## 三、结构化返回：用 Completion Tool 收口

Cline 支持带 `lifecycle.completesRun` 的终止工具。模型不是随便输出一段最终文本，而是在完成时调用一个 completion tool。

Starcat 应采用同样思路。不同 Agent 的最终结果用不同 completion tool 收口：

| Agent | Completion Tool | 前端渲染类型 |
|---|---|---|
| GitHub 周报 | `submit_weekly_report` | `weeklyReport` |
| 替代品发现 | `submit_comparison_table` | `comparisonTable` |
| 重叠扫描 | `submit_overlap_clusters` | `overlapClusters` |
| Untagged 整理 | `submit_tag_plan` | `tagPlan` |
| 回忆搜索 | `submit_recall_answer` | `recallAnswer` |

这样 UI 可以稳定拿到结构化 artifact，不需要解析自由 Markdown。

## 四、ReAct Loop 形态

Starcat runtime 可以采用下面的循环：

```text
1. build prompt + messages + tools
2. call LLM stream
3. collect message parts:
   - text delta
   - reasoning summary delta
   - tool call
   - usage
4. execute tool calls
5. append tool-result messages
6. continue until:
   - completion tool succeeds
   - max iterations reached
   - user cancels
   - error/fallback
```

对应 Swift 数据模型建议：

```swift
enum AgentMessagePart {
    case text(String)
    case reasoningSummary(String)
    case toolCall(AgentToolCall)
    case toolResult(AgentToolResult)
    case artifact(AgentArtifact)
    case confirmationRequest(AgentConfirmationRequest)
}
```

UI 不直接关心这是 Weekly、替代品还是重叠扫描，只消费统一事件。

## 五、工具定义与 Schema 约束

Cline 对 tool schema 有两个值得照搬的规则：

1. tool input schema 顶层必须是 object。
2. 注册阶段就做 schema normalization，避免 provider 调用时才失败。

Starcat 的 `AgentTool` 建议定义为：

```swift
struct AgentToolDefinition: Sendable {
    let name: String
    let description: String
    let inputSchema: AgentJSONSchema
    let permission: AgentToolPermission
    let completesRun: Bool
}
```

工具分类：

| 类型 | 示例 | 默认权限 |
|---|---|---|
| Read Tool | `repo.resolveSelection`, `repo.getOverview` | 自动执行 |
| Search Tool | `web.search`, `github.searchRepos` | 自动执行，可限额 |
| Analyze Tool | `report.clusterTopics`, `overlap.computeClusters` | 自动执行 |
| Completion Tool | `submit_weekly_report` | 自动执行 |
| Write Tool | `tag.applyBulk`, `repo.unstar` | 必须确认 |
| High Cost Tool | `image.generate`, 大批量 repo 深读 | 必须确认 |

## 六、权限与 Human-in-the-loop

Cline 的 tool policy / hooks / approval 说明一个原则：prompt 里的“不要写入”不够，必须由 runtime 强制。

Starcat 应固化为：

```text
ReadOnly:
  所有写入工具 disabled

ConfirmBeforeWrite:
  写入工具只生成 confirmation request
  用户确认后由 UI 触发 apply tool

Auto:
  仅允许 read / search / analyze / completion 自动执行
```

硬规则：

- Agent loop 不得直接调用 `apply_bulk_tags`、`apply_cluster_actions`、`unstar_repo`。
- 写入类工具只能由 UI 的确认按钮触发。
- confirmation 必须展示影响范围、样例、警告和可撤销性。

## 七、UI 事件映射

统一 Agent 工作台应消费这些事件：

| Runtime Event | UI 显示 |
|---|---|
| `runStarted` | Header 状态切到运行中 |
| `turnStarted` | Timeline 新一轮 |
| `assistantTextDelta` | 中间流式文本 |
| `assistantReasoningDelta` | 折叠的“思考摘要” |
| `toolStarted` | Step card 开始 |
| `toolUpdated` | Step card 进度 |
| `toolFinished` | Step card 输出摘要 |
| `artifactCreated` | 右侧 Artifact Inspector |
| `confirmationRequested` | 右侧行动确认区 |
| `runFinished` | Header 完成 |

因此页面应该只有一套：

```text
Agent Rail
Run Header
Context Bar
Run Timeline
Artifact Inspector
Agent Composer
```

每个 Agent 只改变数据，不改变页面结构。

## 八、Starcat 的取舍

Cline 面向代码代理，Starcat 面向 GitHub star 管理和知识整理。不能照搬：

- 不引入文件编辑、shell、任意代码执行作为默认工具。
- 不把 Plan/Act 原样搬过来。
- 不让 Agent 自主写 tags / notes / status / unstar。

Starcat 更适合的模式是：

| Cline | Starcat |
|---|---|
| Plan | Explore / Draft |
| Act | Confirm / Apply |
| submit_and_exit | submit_agent_artifact |
| code tools | repo / search / report / tag tools |
| workspace metadata | repo context snapshot |

## 九、下一步落地

1. 先升级通用 Agent Workspace UI，让步骤、上下文、artifact、确认区都可见。
2. 扩展 `AgentRunEvent`，补齐 `toolStarted` / `toolFinished` / `reasoningDelta` / `confirmationRequested`。
3. 定义第一批 Starcat tools：`repo.resolveSelection`、`repo.getOverview`、`report.clusterTopics`、`submit_weekly_report`。
4. 把最终结果从 Markdown 字符串升级为 completion tool 的结构化 artifact。
5. 写入类工具保持 UI 确认触发，不进入自动 Agent loop。

