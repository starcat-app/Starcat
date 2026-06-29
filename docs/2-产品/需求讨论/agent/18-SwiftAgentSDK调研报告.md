# Swift Agent SDK 调研报告

> **文档定位**: 记录 2026-06-28 对开源 Swift Agent SDK / runtime 的实时调研结论,用于决定 Starcat Agent 底层是否引入第三方 SDK,还是自研 `AgentRuntime`。
> **状态**: 调研结论稿(2026-06-28)。
> **关联文档**:
> - [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md)
> - [`17-GitHubWeeklyReportAgent技术实现方案.md`](17-GitHubWeeklyReportAgent技术实现方案.md)
> - [`04-AgentRunKit-Swarm-SwiftAgent-对比分析.md`](04-AgentRunKit-Swarm-SwiftAgent-对比分析.md)

---

## 一、结论

Swift 生态已经有开源 Agent SDK,但没有一个能零妥协直接作为 Starcat 的默认底座。

推荐路线:

> 保持 Starcat 自有 `AgentRuntime` / `AgentTool` / `AgentRunEvent` / `AgentArtifact` 抽象,先对 **AgentRunKit** 做 2-3 天 spike。如果 spike 证明能顺利接入 Starcat 现有 OpenAI-compatible provider、tool registry、streaming UI、approval、quota,则把 AgentRunKit 作为 `AgentRuntime` 的一个实现;否则按 `16-Agent底层平台技术方案.md` 自研 runtime。

不建议现在直接把 Swarm / SwiftAgent 作为默认依赖,主要原因是 macOS 26 / Swift 6.2 路线与 Starcat 当前 macOS 15 + Swift 5 语言模式基线冲突。

---

## 二、Starcat 评估约束

| 约束 | 当前状态 | 对 SDK 选择的影响 |
|---|---|---|
| 最低系统 | macOS 15 | 排除 macOS 26-only 方案作为默认底座 |
| Swift 语言模式 | Swift 5 | Swift 6.2 / Strict Concurrency 重依赖需谨慎 |
| AI 调用 | 已有 `AIClient` / OpenAI-compatible / BYOK | 第三方 SDK 不能绕过现有 provider / quota |
| UI | 规划覆盖式 Agent Workspace | SDK 不应决定 UI 形态 |
| Tool 边界 | Starcat 自有 GitHub / Weekly / Trending / RepoContext 服务 | SDK 只应承载 loop,不替代领域服务 |
| AI 保守策略 | 写入 / 导出 / 高成本操作必须确认 | 需要 approval / confirmation hook |
| 未来扩展 | 多内置 Agent | 需要可替换 runtime,不能绑死单 Agent 场景 |

---

## 三、候选 SDK

### 3.1 AgentRunKit

仓库: <https://github.com/Tom-Ryder/AgentRunKit>

调研摘要:

- Swift 6 agent SDK
- type-safe tools
- streaming
- cloud + on-device inference
- Swift Package Index / README 标注 macOS 15.0+、iOS 18.0+、Swift 6.0+
- MIT License

Starcat 适配判断:

| 维度 | 判断 |
|---|---|
| 平台 | 最接近 Starcat 当前 macOS 15 基线 |
| Tool calling | 值得验证,能力方向匹配 |
| Streaming | 与 Agent Workspace 时间线可对接 |
| 依赖风险 | 社区小,需要 spike 看 API 稳定性 |
| 接入建议 | **优先 spike** |

需要 spike 的问题:

1. 能否复用 Starcat 现有 OpenAI-compatible provider 配置?
2. tool schema 是否能由 Starcat `AgentTool` 自动生成?
3. streaming event 是否能稳定映射到 `AgentRunEvent`?
4. approval / cancellation / retry 是否能接 Starcat UI?
5. SPM 依赖是否影响当前 Xcode / Swift 语言模式?

结论:

> AgentRunKit 是当前最值得试的候选,但不应绕过 Starcat 自有 runtime 抽象直接深入业务层。

---

### 3.2 Open Agent SDK Swift

仓库: <https://github.com/terryso/open-agent-sdk-swift>

调研摘要:

- open-source Swift Agent SDK
- 进程内完整 agent loop
- native Swift concurrency
- streaming responses
- 34 built-in tools
- sub-agent orchestration
- MCP integration
- session persistence
- multi-provider LLM support
- 文章说明 Swift 6.1、macOS 13+

Starcat 适配判断:

| 维度 | 判断 |
|---|---|
| 平台 | macOS 13+ 看起来满足 Starcat |
| 功能 | 很完整,但明显偏通用 agent / coding agent |
| 重量 | 34 built-in tools 与 Starcat 自有工具体系重叠 |
| UI | 可借鉴执行可观测性,不应接管 Starcat 工作台 |
| 接入建议 | 借鉴设计,不作为默认依赖 |

主要风险:

- 功能面太宽,容易把 Starcat Agent 平台拖向通用桌面 agent
- 内置 tools / session / MCP / provider 与 Starcat 自有能力大量重叠
- 社区与生态信号仍早期

结论:

> 适合作为 Agent loop、session、observability 的参考实现;不建议直接引入主工程作为 P0 底座。

---

### 3.3 Swarm

仓库: <https://github.com/christopherkarani/Swarm>

调研摘要:

- Swift framework for agents and multi-agent workflows
- Swift 6.2
- MIT License
- SPM compatible
- 设计上强调 multi-agent workflow、tool、checkpoint、MCP 等能力

Starcat 适配判断:

| 维度 | 判断 |
|---|---|
| 产品形态 | 最像长期理想 Agent workflow |
| Workflow | 强,适合多 Agent 编排 |
| MCP | 契合 Starcat 未来外部 tool 生态 |
| 平台风险 | Swift 6.2 / macOS 26 路线与 Starcat P0 冲突 |
| 接入建议 | 长期观察,macOS 26 门控增强 |

结论:

> Swarm 是长期路线里最值得观察的 SDK,但不能作为 Starcat 当前默认底座。

---

### 3.4 1amageek/SwiftAgent

仓库: <https://github.com/1amageek/SwiftAgent>

调研摘要:

- Swift Package Index 描述为 type-safe declarative AI agent framework
- 支持 Steps、Agents、structured outputs、tool integration
- 支持 FIFO session、MCP、distributed actor communication
- 生态方向偏 SwiftUI-like declarative pipeline

Starcat 适配判断:

| 维度 | 判断 |
|---|---|
| 抽象 | Step pipeline 类型安全,适合可测试工作流 |
| Agent 自主性 | 更偏声明式 pipeline,不是 Starcat P0 的 tool loop 主路径 |
| 平台 | 相关生态明显偏 Swift 6.2 / macOS 26 |
| 接入建议 | 观察,不作为当前底座 |

结论:

> 可借鉴 Step / structured output 思路;不适合作为 Starcat macOS 15 默认 runtime。

---

### 3.5 SwiftedMind/SwiftAgent

仓库: <https://github.com/SwiftedMind/SwiftAgent>

调研摘要:

- Native Swift SDK for building AI agents
- 有 OpenAI / Anthropic 场景记录与测试 fixture 相关工具
- README 明确还在快速演进

Starcat 适配判断:

| 维度 | 判断 |
|---|---|
| API 设计 | 可参考 provider adapter / fixture 记录方式 |
| 成熟度 | 风险偏高 |
| 接入建议 | 只做参考,不进入 P0 spike |

---

### 3.6 AgentSDK-Swift

仓库: <https://github.com/fumito-ito/AgentSDK-Swift>

调研摘要:

- Swift implementation of OpenAI Agents SDK
- 支持 tools、guardrails、multi-agent workflows
- README 标注 early development
- MIT License

Starcat 适配判断:

| 维度 | 判断 |
|---|---|
| 方向 | OpenAI Agents SDK Swift port,概念契合 |
| 成熟度 | Early development,暂不适合压核心路径 |
| 接入建议 | 观察,不进入 P0 spike |

---

## 四、横向对比

| SDK | macOS 基线 | Runtime / Loop | Tool calling | MCP | 成熟度 | Starcat 建议 |
|---|---|---|---|---|---|---|
| AgentRunKit | macOS 15+ | 有 | 有 | 有 | 早期但最贴近 | **优先 spike** |
| Open Agent SDK Swift | macOS 13+ | 完整 | 有 | 有 | 早期,功能重 | 借鉴,不默认引入 |
| Swarm | macOS 26 路线 | 强 | 强 | 强 | 活跃 | 长期观察 |
| 1amageek/SwiftAgent | macOS 26 路线 | Step pipeline | 有 | 有 | 活跃 | 观察 |
| SwiftedMind/SwiftAgent | 未作为主线确认 | 有 | 有 | 未确认 | WIP | 参考 |
| AgentSDK-Swift | 未作为主线确认 | OpenAI Agents port | 有 | 未确认 | Early | 观察 |

---

## 五、推荐决策

### 5.1 不直接全量自研

完全自研的风险:

- tool calling loop、stream event、retry、approval、checkpoint 都容易重复造轮子
- 后续接多 provider / MCP 时会继续扩大成本
- Swift agent 生态正在快速出现,过早闭门自研可能错过成熟实现

### 5.2 也不直接押第三方 SDK

直接引入的风险:

- 现有 SDK 多数很新,API 仍可能大幅变化
- Starcat 已有 AI provider、quota、权限、工具体系,不适合被 SDK 反向支配
- Swarm / SwiftAgent 等理想形态受 macOS 26 约束

### 5.3 推荐路线

```text
Phase A: 保持 Starcat 自有协议
  AgentRuntime / AgentTool / AgentRunEvent / AgentArtifact

Phase B: AgentRunKit spike
  用同一套 Starcat AgentTool 包一组最小 tools
  跑通 GitHub Weekly Report Agent 的 tool loop

Phase C: 决策
  如果 AgentRunKit 适配顺利:
    AgentRunKitAgentRuntime 实现 AgentRuntime
  如果不顺:
    自研 DefaultAgentRuntime

Phase D: 长期观察
  Swarm / Foundation Models / SwiftAgent 作为 macOS 26 门控增强
```

---

## 六、AgentRunKit Spike 清单

目标: 2-3 天内证明它能否作为 Starcat P0 runtime 实现。

验证项:

1. SPM 引入后 Starcat 是否能编译
2. 能否用 Starcat 现有 OpenAI-compatible provider 调模型
3. 能否注册一个 `trending.fetchRepos` tool
4. 能否把 SDK stream event 映射到 `AgentRunEvent`
5. 能否做 tool approval / cancellation
6. 能否把 tool result compact 后回传模型
7. 能否用 mock LLM 做单测
8. 是否引入过重依赖或 About 致谢负担

最小验证场景:

```text
用户: 生成本周热门 Swift repo 周刊
  ↓
LLM calls trending.fetchRepos
  ↓
LLM calls repo.getOverview
  ↓
LLM returns WeeklyReportDraft
  ↓
Starcat builds Markdown artifact
```

成功标准:

- 不破坏 Starcat 现有 AI 设置
- 不绕过 quota / Pro gate
- 事件可显示到 Agent Workspace timeline
- 失败和取消可控

---

## 七、落地到现有文档的影响

对 [`16-Agent底层平台技术方案.md`](16-Agent底层平台技术方案.md):

- 保持自有 `AgentRuntime` 协议不变
- 增加 `AgentRunKitAgentRuntime` 作为可能实现
- 不把 SDK 类型泄漏到 Agent UI / Tool / Artifact 层

对 [`17-GitHubWeeklyReportAgent技术实现方案.md`](17-GitHubWeeklyReportAgent技术实现方案.md):

- Weekly Agent 的工具、Artifact、上下文模型不变
- Spike 只替换 runtime loop
- 若 spike 失败,继续走自研 runtime

---

## 八、最终建议

结论一句话:

> 有开源 Swift Agent SDK,但 Starcat 不能直接把底层押给它们。最稳路线是“Starcat 自有 Agent 抽象 + AgentRunKit spike + 可替换 runtime”。如果 spike 失败,再自研;如果 spike 成功,也只把 AgentRunKit 放在 runtime 实现层,不让它侵入业务 Agent 和 UI。

---

## 九、参考来源

- AgentRunKit GitHub: <https://github.com/Tom-Ryder/AgentRunKit>
- AgentRunKit Releases: <https://github.com/Tom-Ryder/AgentRunKit/releases>
- Open Agent SDK Swift GitHub: <https://github.com/terryso/open-agent-sdk-swift>
- Open Agent SDK Swift 介绍: <https://dev.to/terryso/open-agent-sdk-swift-build-ai-agent-applications-with-native-swift-concurrency-kne>
- Swarm GitHub: <https://github.com/christopherkarani/Swarm>
- Swarm Swift Package Index: <https://swiftpackageindex.com/christopherkarani/Swarm>
- 1amageek/SwiftAgent Swift Package Index: <https://swiftpackageindex.com/1amageek/SwiftAgent>
- 1amageek/SwiftAgent Swift Forums: <https://forums.swift.org/t/swiftagent-a-swift-native-agent-sdk-inspired-by-foundationmodels-and-using-its-tools/81634>
- SwiftedMind/SwiftAgent GitHub: <https://github.com/SwiftedMind/SwiftAgent>
- AgentSDK-Swift GitHub: <https://github.com/fumito-ito/AgentSDK-Swift>

---

## 十、变更记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-06-28 | 初稿:开源 Swift Agent SDK 调研报告 | Codex |
