# 59 — External Agent Runtime 多后端 POC 技术方案

> 日期：2026-08-21
>
> 状态：底座 POC 已实现，产品化门禁未完成
>
> 范围：Direct Debug 的 General Agent / Research Agent；不替换固定业务 Agent
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

固定业务 Agent 的上下文、工具白名单、审批、Artifact 与持久化契约已经稳定，继续锁定 Loop。只有 General / Research POC 显式允许外部后端。

## 2. 声明式路由

`AgentDefinition.runtimePolicy` 是单一路由依据：

| Agent | 允许后端 |
|---|---|
| Weekly / Repo Insight / Alternatives / Untagged | `builtinLoop` |
| General Agent POC | `codexAppServer`、`deepSeekHarness` |
| Research Agent POC | `codexAppServer`、`deepSeekHarness` |

`AgentWorkspaceView` 只负责装配 Router，不按 Agent ID 选择 Runtime。用户偏好不在运行中切换；ViewModel 已有“运行时拒绝替换”约束，保证一次 run 始终使用同一后端。

## 3. 公共 Host

`ExternalAgentRuntimeHost` 统一承担：

- `Foundation.Process`、stdin/stdout/stderr Pipe 生命周期。
- newline-delimited JSON-RPC framing。
- stderr 持续排空，不记录可能含 prompt / credential 的原文。
- 一 run 一个临时工作目录和一个 Sidecar。
- 先尝试协议取消，再有界 SIGTERM / SIGKILL；可建立独立进程组时清理整个组，否则降级清理主进程。
- Provider 原生事件映射成统一文本、reasoning、tool、usage 和终态事件。

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
  → thread/start(ephemeral, read-only, approval=never)
  → turn/start
  → item/agentMessage/delta / reasoning delta / usage
  → turn/completed
```

取消优先发送 `turn/interrupt`。POC 不接 Codex 文件修改、Subagent 和 approval；若收到 approval / user-input request，adapter 明确拒绝。进程运行在 Starcat 创建的空临时目录，使用用户本机 Codex 登录态，不向子进程传 API Key，并通过 developer instructions 禁止命令调用。`read-only` sandbox 仍不等于关闭上游内建命令工具，因此真实 Provider 验证只能使用无敏感数据环境；产品化前必须补充可验证的工具禁用或独立子进程 sandbox。

## 5. DeepSeek Harness adapter

上游固定 `0.1.0-rc.8`。macOS arm64 carrier 必须同时存在：

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

adapter 按 session ID 严格过滤事件，并映射 `assistant/chunk`、`assistant/message`、`tool/call`、`tool/result` 与 `turn/end`。`rc.8` 没有 turn cancel；停止语义是回收当前 run 专属 Sidecar。该限制保留在 capability 中，不以 UI 假状态掩盖。

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
-DebugDeepSeekHarnessProvider deepseek-official
-DebugDeepSeekHarnessModel <model>
```

API Key 不使用 launch argument 或 UserDefaults。Codex adapter 不接收 API Key，只使用本机登录态；DeepSeek adapter 仅按 Provider 白名单透传必要环境变量。

## 7. 当前数据边界

底座 POC 把用户问题、Agent rules、冻结仓库摘要和文本附件拼成只读 prompt。外部 Runtime：

- 不读取 Starcat SQLite。
- 不获得用户仓库目录路径。
- 不获得任何 Starcat 写工具或数据库入口。
- 不持久化外部 Session 或 event watermark。
- 不参与固定业务 Agent 的结构化 Artifact contract。

临时 Loopback MCP Bridge 尚未进入本次底座 POC。产品化前必须补齐随机端口、随机 token、tool allowlist、repo scope、RAG eligible scope 和 Session 结束失效验证，不能复用全局 MCP token 或绕过 Capability。

上述边界只约束 Starcat 注入的能力。外部 Runtime 自带的命令、文件或网络工具必须由 Provider Profile 或独立 OS sandbox 再限制；仅靠 prompt 和空工作目录不构成安全隔离。

## 8. Capability 口径

Capability 表达“Starcat 当前 adapter 实际开放的能力”，不是上游理论能力。Codex 上游虽支持 resume、steer、approval、diff 和 subagent，本 POC 只开放可靠 turn interrupt；DeepSeek `rc.8` 当前连 turn cancel 也不具备。UI 未接入的能力统一为 false。

## 9. 验证

自动化覆盖：

- 固定 Agent 始终路由 Loop。
- General / Research 可切换 Codex / DeepSeek。
- 两套握手、session 过滤、delta、message 和终态 fixture。
- 真实子进程 Pipe / JSONL framing 与终态回收。
- App Store 拒绝、Direct 放行渠道门禁。

已完成编译门禁：`Starcat`、`StarcatDirect` 无签名 build，以及 `StarcatTests` build-for-testing。Xcode 运行期间不执行 `xcodebuild test`，避免争抢 `testmanagerd`。

## 10. 产品化前剩余门禁

- 真实 Codex 长任务、取消和残留进程人工验证。
- DeepSeek 固定 carrier、最小 Cordis Profile 与真实 Provider 验证。
- 上游内建 Shell / FS / Network 工具的硬禁用或独立子进程 sandbox 验证。
- 临时 MCP Bridge 与只读领域工具闭环。
- 进程组创建失败时的确定性清理方案。
- 外部 Session 恢复、稳定 event sequence 与数据库迁移设计。
- 签名、Hardened Runtime、Notarization、Intel 可用性和资源占用验证。

这些门禁完成前，多后端底座 POC 不替换生产默认 Runtime，也不进入发布流程。
