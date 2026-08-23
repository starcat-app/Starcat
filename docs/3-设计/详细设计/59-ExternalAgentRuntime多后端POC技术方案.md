# 59 — External Agent Runtime 多后端 POC 技术方案

> 日期：2026-08-21
>
> 状态：底座 POC 与 Codex 只读工具桥已实现，产品化门禁未完成
>
> 范围：Direct Debug 的多后端切换；Codex 承载兼容的只读业务 Agent，DeepSeek 暂限 General / Research
>
> 关联：`57-Agent工作台与统一能力层详细设计.md`、`58-DeepSeekHarness集成评估与POC技术方案.md`

---

## 1. 决策

Starcat 不在 Codex App Server 与 DeepSeek Harness 之间二选一，也不推翻现有 `LoopAgentRuntime`。正确结构是稳定 Host 加可替换 adapter：

```text
Agent Workspace
  → AgentRuntimeRouter
      → LoopAgentRuntime
      → ExternalAgentRuntime
          → ExternalAgentRuntimeHost
              → CodexAppServerAdapter
              → DeepSeekHarnessAdapter
```

固定业务 Agent 的上下文、工具白名单、审批与 Artifact 契约继续由 Starcat 拥有。Weekly、Repo Insight、Alternatives 可通过 Codex dynamic tools 复用现有只读工具；Untagged 等带审批写入的 Agent 继续锁定 Loop。General / Research POC 显式允许 Codex 与 DeepSeek。

## 2. 声明式路由

`AgentDefinition.runtimePolicy` 是单一路由依据：

| Agent | 允许后端 |
|---|---|
| Weekly / Repo Insight / Alternatives | `builtinLoop`、`codexAppServer` |
| Untagged 与其它带审批写入的 Agent | `builtinLoop` |
| General Agent POC | `codexAppServer`、`deepSeekHarness` |
| Research Agent POC | `codexAppServer`、`deepSeekHarness` |

`AgentWorkspaceView` 只负责装配 Router，不按 Agent ID 选择 Runtime。用户偏好不在运行中切换；ViewModel 已有“运行时拒绝替换”约束，保证一次 run 始终使用同一后端。用户显式选择外部后端后，Router 对不兼容 Agent 返回不可用，不再静默回退 `builtinLoop`；Run Surface Header 展示解析后的实际 Runtime。

## 3. 公共 Host

`ExternalAgentRuntimeHost` 统一承担：

- `Foundation.Process`、stdin/stdout/stderr Pipe 生命周期。
- newline-delimited JSON-RPC framing。
- stderr 持续排空，不记录可能含 prompt / credential 的原文。
- 一 run 一个临时工作目录和一个 Sidecar。
- 先尝试协议取消，再有界 SIGTERM / SIGKILL；可建立独立进程组时清理整个组，否则降级清理主进程。
- Provider 原生事件映射成统一文本、reasoning、tool、usage 和终态事件。
- 接收 adapter 解析出的动态工具请求，调用 Starcat 宿主执行器，再把 Provider 专属响应帧写回 stdin。

Host 不理解 `thread/start` 或 `session/prompt`。方法名、请求顺序和 payload 只存在于 adapter。

## 4. Codex App Server adapter

启动命令：

```text
codex app-server --listen stdio://
```

流程：

```text
initialize
  → initialized
  → thread/start(ephemeral, read-only, approval=never, dynamicTools)
  → turn/start
  → item/tool/call ↔ Starcat read-only tool result
  → item/agentMessage/delta / reasoning delta / usage
  → turn/completed
```

取消优先发送 `turn/interrupt`。`dynamicTools` 只包含当前 definition allowlist 内的自动只读工具；宿主再次校验工具名、schema 和权限，并保留工作流 payload，完成工具产生的 Markdown 继续投影为 Artifact。POC 不接 Codex 文件修改、Subagent 和 approval；若收到 approval / user-input request，adapter 明确拒绝。进程运行在 Starcat 创建的空临时目录，使用用户本机 Codex 登录态，不向子进程传 API Key，并通过 developer instructions 禁止命令调用。`read-only` sandbox 仍不等于关闭上游内建命令工具，因此真实 Provider 验证只能使用无敏感数据环境；产品化前必须补充可验证的工具禁用或独立子进程 sandbox。

## 5. DeepSeek Harness adapter

上游固定 `deepseek-harness-runtime-bin==0.1.1rc1`。Runtime 通过外部路径安装，
不进入 Starcat App 或 DMG；macOS arm64 carrier 必须同时存在：

```text
dsh-jsonrpc-agent-pkg-macos-arm64
dsh-jsonrpc-agent-pkg-macos-arm64-rg
dsh-jsonrpc-agent-pkg-macos-arm64-spawn-helper
```

流程：

```text
initialize(cwd, provider, model, maxTokens)
  → session/prompt(sessionId, contentBlocks)
  → session.event / session.status
  → shutdown
```

adapter 按 session ID 严格过滤事件，并映射 `assistant/chunk`、`assistant/message`、`tool/call`、`tool/result` 与 `turn/end`。当前协议没有 turn cancel；停止语义是回收当前 run 专属 Sidecar。该限制保留在 capability 中，不以 UI 假状态掩盖。

首次安装与配置见 [`DeepSeek Harness Runtime 配置`](../../7-工具与脚本/DeepSeek-Harness-Runtime-配置.md)。Starcat 专用 Cordis 不加载本地 Bash / subprocess；默认 wheel Cordis 不属于可接受配置。

## 6. Direct Debug 入口

POC 入口只存在于 `#if DEBUG` 的 `Who's Your Daddy` 菜单：

- `Off · Loop only`
- `Codex App Server`
- `DeepSeek Harness`

App Store 构建由 `DistributionGate.externalAgentRuntime` 再次拒绝。Release 构建不展示 General / Research POC 定义。

可选启动参数：

```text
-DebugExternalAgentRuntimeBackend codexAppServer
-DebugCodexExecutablePath /opt/homebrew/bin/codex
-DebugCodexModel <optional-codex-model>
```

DeepSeek：

```text
-DebugExternalAgentRuntimeBackend deepSeekHarness
-DebugDeepSeekHarnessExecutablePath /absolute/path/dsh-jsonrpc-agent-pkg-macos-arm64
-DebugDeepSeekHarnessCordisConfigPath /absolute/path/starcat.cordis.yml
```

Provider/Model 由 Agent 工作台选择，不再要求手工写 `defaults`。API Key 不使用 launch argument 或 UserDefaults。Codex adapter 只使用所选 `config.toml` Provider 的本机登录态；声明 `env_key` 的 Provider 不向可运行命令的 Codex 子进程透传凭据，因此在 Starcat 中明确禁用。DeepSeek adapter 复用 Starcat 已验证 AI Provider，并按 profile ID 从 Keychain 注入当前 Run 的最小凭据环境。

## 7. 当前数据边界

底座 POC 把用户问题、Agent rules、冻结仓库摘要和文本附件拼成只读 prompt。Codex 还可通过 App Server dynamic tools 调用 definition 允许的 Starcat 自动只读工具。外部 Runtime：

- 不读取 Starcat SQLite。
- 不获得用户仓库目录路径。
- 不获得任何 Starcat 写工具或数据库入口；宿主拒绝 `requiresConfirmation` 与 `highCost` 工具。
- 不持久化外部 Session 或 event watermark。
- Codex 可参与 Weekly、Repo Insight、Alternatives 的结构化 Artifact contract；DeepSeek 暂不参与。

Codex 当前不需要 Loopback MCP Bridge，dynamic tool 请求直接进入受控宿主执行器。DeepSeek 使用每轮随机端口、随机 token、tool allowlist 且 Run 结束立即失效的临时 Loopback MCP Bridge；Provider/Model 则通过每轮临时 `dsh-llm-pi-ai` Cordis route 注入，配置只保存环境变量引用，不保存 API Key。

上述边界只约束 Starcat 注入的能力。外部 Runtime 自带的命令、文件或网络工具必须由 Provider Profile 或独立 OS sandbox 再限制；仅靠 prompt 和空工作目录不构成安全隔离。

## 8. Capability 口径

Capability 表达“Starcat 当前 adapter 实际开放的能力”，不是上游理论能力。Codex 上游虽支持 resume、steer、approval、diff 和 subagent，本 POC 只开放可靠 turn interrupt；DeepSeek `0.1.1rc1` 当前连 turn cancel 也不具备。UI 未接入的能力统一为 false。

## 9. 验证

自动化覆盖：

- 只读业务 Agent 可路由 Codex，带审批 Agent 在外部偏好下明确不可用且不回退 Loop。
- General / Research 可切换 Codex / DeepSeek。
- Codex dynamic tool 定义、请求解析与结果回写 fixture。
- 两套握手、session 过滤、delta、message 和终态 fixture。
- 真实子进程 Pipe / JSONL framing、动态工具往返与终态回收。
- Loop 通用工具预算保持 32；Weekly、Repo Insight、Alternatives 按 definition 使用 96。
- App Store 拒绝、Direct 放行渠道门禁。

已完成编译门禁：`Starcat`、`StarcatDirect` 无签名 build，以及 `StarcatTests` build-for-testing。Xcode 运行期间不执行 `xcodebuild test`，避免争抢 `testmanagerd`。

## 10. 产品化前剩余门禁

- 真实 Codex 长任务、取消和残留进程人工验证。
- DeepSeek 临时 MCP Bridge 与只读领域工具闭环。
- 上游内建 Shell / FS / Network 工具的硬禁用或独立子进程 sandbox 验证。
- DeepSeek 临时 MCP Bridge 与只读领域工具闭环。
- 进程组创建失败时的确定性清理方案。
- 外部 Session 恢复、稳定 event sequence 与数据库迁移设计。
- 上游 Developer ID 签名 / Notarization、Intel 可用性和资源占用验证。

这些门禁完成前，多后端底座 POC 不替换生产默认 Runtime，也不进入发布流程。
