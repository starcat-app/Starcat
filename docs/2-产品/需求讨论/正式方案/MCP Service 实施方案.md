# Starcat MCP Server 与 MCP Client 专题实施方案

> 创建：2026-06-20
>
> 更新：2026-08-30
>
> 状态：MCP Server v1.3 实现中；MCP Client 方案已冻结、待后续单独授权开发
>
> 范围：本文同时约束两个独立方向：① Starcat 作为 MCP Server 向外部 Agent 提供工具；② Starcat 作为 MCP Client 调用外部 MCP Server。两者共享 Pro 权益和设置入口，但运行时、权限、凭据与审计边界不得混用。

## 1. 路线

Starcat App 内置 MCP Service 仍是唯一业务入口。外部 Agent 不再直接配置 Streamable HTTP endpoint 和 Local API Key，而是统一安装跨平台 `starcat` CLI：

- Agent MCP 配置：`command=<starcat 绝对路径>`、`args=["mcp"]`、`transport=stdio`。
- CLI 内部桥接到 Starcat MCP Streamable HTTP。
- 同机默认走 loopback HTTP；远程设备走 pinned HTTPS。
- Skill 只调用 CLI，不直接实现 HTTP/MCP client。

## 2. 请求门控

- MCP Service 仍为 Pro-only。
- 每个 MCP 请求重新检查服务开关、Pro、Bearer credential 和细分隐私/写权限。
- Bearer credential 可以是既有 Local API Key，或用户确认后签发的逐设备 token。
- 私有笔记读取、本地写入、批量写入、替换/删除式写入默认关闭并分层授权。
- 写入统一支持 `dry_run` 和 JSONL 审计。

## 3. 配对与凭据

- 设置页生成五分钟、一次性 pairing URI，不复制长期 token。
- CLI 兑换邀请时，Starcat 显示设备名、平台、架构和 CLI 版本确认 sheet。
- 每台设备获得独立 token，保存到其操作系统安全存储。
- Starcat 设置页列出已配对设备并支持单独撤销。
- `/pairing/exchange` 只负责 invitation 兑换，不提供仓库业务能力。

## 4. 网络安全

- 默认只监听 `127.0.0.1`。
- 可信网络开关默认关闭；开启后强制 TLS 1.3 并绑定网络接口。
- 每台 Mac 生成独立 P-256 TLS identity；CLI pin certificate SHA-256。
- 明文 HTTP 永远只允许 loopback。
- 第一阶段只支持可信 LAN 或 Tailscale/WireGuard，不提供公网 relay。

## 5. MCP 工具

### 读取与生成

- `starcat.get_capabilities`
- `starcat.search_repos`
- `starcat.semantic_search`
- `starcat.get_repo`
- `starcat.get_repo_context`
- `starcat.get_repo_summary`
- `starcat.generate_repo_summary`
- `starcat.get_readme`
- `starcat.list_tags`
- `starcat.get_repo_note`

### 本地写入

- `starcat.upsert_repo_note`
- `starcat.set_repo_status`
- `starcat.create_tag`
- `starcat.add_repo_tags`
- `starcat.remove_repo_tags`
- `starcat.set_repo_tags`

工具实现继续复用 `StarcatMCPFacade`、`StarcatMCPWriteFacade` 和 `StarcatMCPToolRegistry`，CLI 不复制业务逻辑。

## 6. 设置页

「设置 → MCP 服务」顶部采用「提供工具 / 使用外部工具」双方向切换。其中「提供工具」沿用现有 MCP Server 设置，提供：

- 服务开关、端口、可信网络、私有笔记与三层写权限。
- 复制 CLI 安装说明。
- 复制一次性配对命令。
- 复制 MCP stdio 配置说明。
- 复制公开 `starcat-skill` 安装请求。
- 已配对设备列表与撤销操作。

复制入口统一使用 `CopyFeedbackButton`。公开安装说明不包含 endpoint、Local API Key 或长期 token。

## 7. 外部项目

- `https://github.com/starcat-app/starcat-cli`：Go CLI，开发路径 `supports/starcat-cli`。
- `https://github.com/starcat-app/starcat-skill`：Agent 工作流，开发路径 `supports/starcat-skill`。

两者都是独立 Git 仓库，由父仓库 `supports/*` ignore，不纳入 Starcat 主项目构建与提交。

## 8. 验证

```bash
cd supports/starcat-cli
go test ./...
go vet ./...
go build ./cmd/starcat

cd ../..
make test TEST_ARGS="-only-testing:StarcatTests/StarcatMCPRuntimeTests -only-testing:StarcatTests/MCPAgentSetupPromptTests -only-testing:StarcatTests/StarcatMCPPairingTests"
```

运行 Starcat 单测前必须关闭 Xcode IDE。同时校验 `Localizable.xcstrings`、禁用 i18n API 扫描、Skill `quick_validate.py` 和 `git diff --check`。

## 9. 暂不做

- 公网 relay 与云端转发。
- GitHub 远端 star/unstar。
- Stateful SSE/server push。
- 独立数据库 CLI、共享数据库路径或第二套 REST 业务 API。

---

## 10. MCP Client 产品结论

Starcat 新增通用 MCP Client 后，由 Starcat 主动连接用户配置的外部 MCP Server，将经过兼容性检查和用户选择的外部 Tool 转换成现有 `AgentTool`，再复用 Agent 工作台的权限确认、超时、取消、运行历史、Timeline、Inspector 与审计能力。

这一方向必须与下面两条既有链路严格区分：

- `外部 Agent → starcat CLI / MCP → Starcat`：Starcat 是 MCP Server，向外部提供领域工具。
- `Starcat → Codex / DeepSeek ExternalAgentRuntime`：Starcat 托管外部 Agent Runtime，由 Runtime 执行推理。
- `Starcat Agent → MCP Client → 外部 MCP Server`：本方案新增链路，由 Starcat 统一调用外部 Tool。

禁止直接放开 Codex 等 Runtime 自己继承的用户 MCP 配置。所有外部 MCP Tool 都必须经过 Starcat 的统一 Tool Adapter、Allowlist、审批和审计，避免绕过宿主安全边界。

当前项目已经锁定官方 [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) `0.12.1`，该版本具备 MCP Client、Streamable HTTP、stdio、OAuth、Tool 发现、调用、进度和取消能力。本方案继续复用现有依赖，不引入第二套 MCP 实现，也不以本功能为由升级版本。

## 11. 产品闭环

完整用户路径固定为：

```text
添加外部服务
→ 验证 URL 或本地命令
→ MCP initialize
→ 分页读取 tools/list
→ 检查 Tool Schema 兼容性
→ 用户选择允许的 Tool 和权限策略
→ 保存非敏感配置，凭据写入 Keychain
→ Agent 工作台选择本次 Run 可用的外部 Tool
→ 创建 Run 并冻结 Server / Tool / 配置 revision
→ 模型发起 Tool Call
→ Starcat 展示服务、目标、工具和完整参数并请求确认
→ MCP Client 执行 tools/call
→ 结果限流、映射、脱敏
→ 写入 Timeline / Inspector / Audit
→ Agent 继续推理
→ 取消或超时时发送 MCP cancellation，并回收连接或进程
→ 历史恢复时校验配置 revision，不一致则失败关闭
```

只有连接、发现、选择、执行、审批、结果、取消、失败和恢复都具备明确状态，才允许对外宣称支持外部 MCP Tool。

## 12. 总体架构

```text
设置 → MCP Client 配置 ──────────────┐
设置 → Keychain 凭据 ───────────────┤
                                     ▼
Agent 工作台选择 Tool → AgentRunContext 快照
                                     │
                                     ▼
                              AgentToolRegistry
                                     │
                                     ▼
                            MCPClientAgentTool
                                     │
                      ┌──────────────┼──────────────┐
                      │              │              │
                  权限确认       Schema 校验    超时/取消/审计
                      └──────────────┼──────────────┘
                                     ▼
                       MCPClientConnectionManager
                                     │
                      ┌──────────────┴──────────────┐
                      ▼                             ▼
          HTTPClientTransport          StdioTransport + Process Host
                      │                             │
                      └──────────────┬──────────────┘
                                     ▼
                              外部 MCP Server
```

### 12.1 分层职责

| 层 | 职责 | 明确不负责 |
|---|---|---|
| Configuration Store | 保存非敏感 Server Profile、Tool 快照和权限策略 | 不保存 Token、OAuth secret、敏感环境变量 |
| Credential Store | 按 Server ID 将凭据存入 Keychain | 不向模型、外部 Runtime、日志或诊断包暴露凭据 |
| Connection Manager | 按 Server 管理连接、握手、能力变化和空闲回收 | 不决定 Agent 是否可以使用某个 Tool |
| Tool Catalog | 发现 Tool、检查 Schema、生成稳定别名和兼容状态 | 不根据 MCP annotation 自动授予权限 |
| Agent Tool Adapter | 参数转换、调用、取消、错误和结果映射 | 不允许模型修改 Endpoint、命令或认证配置 |
| Agent Runtime | 复用已有 Tool Registry、Approval 和 Run 生命周期 | 不直接持有 MCP Client 或凭据 |
| Presentation | 设置、选择、Timeline、Inspector 和诊断 | 不持久化原始协议 payload 或秘密 |

### 12.2 并发模型

- `MCPClientConfigurationStore`、`MCPClientService` 使用 `@MainActor @Observable`，仅发布 UI 所需的稳定状态。
- `MCPClientConnectionManager`、单个 `MCPClientSession`、stdio Process Host 使用 actor 隔离连接和进程生命周期。
- 每个 Server 同一时刻只有一个握手状态；并发 Tool Call 是否允许由 Server capability 和 Starcat 策略共同决定。
- 连接按需创建，空闲五分钟后回收；App 退出、Server 停用或配置变化时立即断开。
- 配置 revision 变化后旧 Session 失效，禁止继续复用旧 Endpoint 或旧凭据。

## 13. 设置页面 UI

### 13.1 MCP 双方向入口

现有「设置 → MCP 服务」保留单一导航入口，页面顶部增加 segmented picker：

```text
┌──────────────────────────────────────────────┐
│ MCP                                          │
│                                              │
│          [ 提供工具 ] [ 使用外部工具 ]         │
└──────────────────────────────────────────────┘
```

- 「提供工具」：现有 MCP Server 设置，提取为 `MCPServerSettingsView`。
- 「使用外部工具」：新增 `MCPClientSettingsView`。
- 两个页面共享 MCP Pro 权益，但不能共享服务开关、端口、凭据或运行状态。

### 13.2 外部服务列表

```text
使用外部工具
──────────────────────────────────────────────
[✓] 允许 Agent 使用外部 MCP 工具

MCP 服务
● GitHub MCP          HTTP      12 个工具   [✓]
  https://mcp.example.com
  已连接 · 刚刚验证                         [刷新]

○ Filesystem MCP      本地命令    已停用      [ ]
  /opt/homebrew/bin/mcp-filesystem

                                  [添加服务]
```

每个 Server Row 必须稳定展示：

- 状态图标和文字：已停用、连接中、需授权、可用、能力变化、连接失败。
- 用户设置的服务名称。
- HTTP 或本地命令 Transport。
- URL host 或 executable 摘要，不显示 Token 和敏感参数。
- 已允许 Tool 数量与最后验证时间。
- 启用开关、刷新按钮和编辑入口。

状态不能只依赖颜色表达；刷新入口复用 `SyncIconButton`。空状态只保留简短说明和右对齐的「添加服务」主操作。

### 13.3 添加/编辑服务 Sheet

编辑器包含服务连接和 Tool 列表两个滚动区域，应使用固定尺寸 AppKit Sheet 承载 SwiftUI，建议 `680 × 640`，并使用 `SheetCloseButton`。不扩大整个 Settings Window，也不在现有 Form 内嵌第三层滚动。

#### 基本信息

- 显示名称。
- Transport：Streamable HTTP / 本地命令。
- 可选的用户备注。

#### Streamable HTTP

- 固定 Endpoint URL。
- 认证方式：无认证、Bearer Token、OAuth 2.1。
- Token / OAuth 凭据只写 Keychain。
- 「测试连接并读取工具」操作。

#### 本地命令

- 使用文件选择器选择 executable，不能输入一整段 shell command。
- 参数逐项编辑。
- 可选工作目录。
- 环境变量白名单；敏感值写入 Keychain。
- 禁止 `/bin/sh -c`、未解析变量、自动下载和运行时安装包。

#### Tool 权限

```text
搜索工具……

[✓] search_issues        读取网络数据       每次确认
[✓] create_issue         写入外部系统       每次确认
[ ] delete_issue         破坏性操作         已禁用
[!] complex_query        Schema 不兼容      不可启用
```

列表按名称、风险和兼容状态搜索/过滤。每个 Tool 保存远端名称、描述、输入/输出 Schema、annotations、Schema hash、Allowlist 状态、生效权限和不兼容原因。只有连接测试成功且完成 Tool 选择后才允许保存。

### 13.4 Agent 工作台选择

Agent Composer 附近增加「外部工具 N」入口，打开本次 Run 的 Tool 选择 Popover：

- 默认不选择任何外部 Tool，不因 Server 启用而自动全部暴露。
- 支持按 Server 全选兼容 Tool，也支持逐项选择。
- 选择默认仅对当前 Run 生效。
- 后续可增加「记住为该 Agent 默认值」，但必须保存稳定 Tool ID，不能保存宽泛的“所有 Tool”。
- Run 开始后冻结选择；设置页中途修改不影响当前 Run。

UI 继续遵循 `DESIGN.md` 和设置页规范：`Form + grouped Section`、独立操作按钮右对齐、只使用 `.primary/.secondary`、plain Button 禁用 focus effect、支持键盘与 VoiceOver、所有文案进入现有多语言 Catalog。

## 14. 产品模块使用边界

| 模块 | 首版策略 | 原因与边界 |
|---|---|---|
| 通用 Agent 工作台 | 启用 | MCP Client 的主入口；Run 级显式选择和审批 |
| Codex / DeepSeek Runtime | 启用 | 通过 Starcat `dynamicTools` / 临时受控桥暴露 Adapter；不开放 Runtime 自己的 MCP 配置 |
| Agent Timeline / Inspector | 启用 | 展示外部调用、耗时、Attempt、结果大小和失败原因 |
| 设置 / 诊断导出 | 启用 | 管理连接并导出脱敏后的配置和健康状态 |
| GitHub Weekly Agent | 默认关闭 | 保持固定、可复现的 Tool 集合；后续逐 Agent 评审 |
| Untagged 等后台 Agent | 默认关闭 | 避免后台任务隐式联网或产生外部副作用 |
| AI 摘要、翻译、标签推荐 | 不接入 | 继续维持确定性产品流程，不引入隐藏外部调用 |
| 仓库详情页 | 不直接接入 | 外部 Tool 统一从 Agent 工作台调用 |
| 知识库 RAG | 首版不接入 | RAG 必须先满足 Evidence、Citation 和来源契约 |

RAG 后续只能通过显式 `AgentKnowledgeSearching` / Evidence Adapter 使用经过评审的只读 MCP Tool。适配结果必须包含来源 URL、时间、Server、Tool、Call ID 和可引用片段；任意通用 MCP 返回值不能直接成为 RAG 引用证据。

## 15. Transport、分发渠道与认证

| 能力 | App Store | Direct |
|---|---:|---:|
| Streamable HTTP | 支持 | 支持 |
| 无认证 / Bearer Token | 支持 | 支持 |
| OAuth 2.1 | 后续阶段 | 后续阶段 |
| stdio 本地进程 | 不支持 | 支持 |
| 用户选择任意 executable | 不支持 | 通过安全门控后支持 |

### 15.1 HTTP

- 远程地址默认只允许 HTTPS。
- 明文 HTTP 只允许 loopback 或用户显式确认的可信 LAN，并持续显示风险提示。
- URL 中禁止携带 credential；重定向必须同源。
- Endpoint 是设置配置，不是 Tool 参数，模型不能覆盖。
- 连接超时默认 10 秒，`tools/list` 默认 15 秒，单次 `tools/call` 默认 60 秒。

### 15.2 stdio

stdio 只在 Direct 渠道开放，并通过 `DistributionGate` 统一门控。SDK `StdioTransport` 只负责文件描述符通信，Starcat 仍需自行管理 `Process + Pipe`：

- child stdout 只承载 MCP JSON-RPC。
- stderr 单独持续排空、限流并脱敏，禁止阻塞 child。
- 传入最小环境变量白名单，不继承无关 API Key 和 Token。
- 取消、超时、Server 停用和 App 退出时终止整个 process group。
- 处理 broken pipe、Malformed JSON、child 提前退出和 stderr 洪流。
- 任何退出路径都不得残留孤儿进程。

### 15.3 OAuth

OAuth 2.1 不阻塞第一阶段 HTTP MVP，但正式宣称完整远程 MCP 兼容前必须实现：

- 系统浏览器授权与回调。
- access token / refresh token 的 Keychain 存储。
- 授权取消、过期、刷新失败和撤销。
- Server identity 变化后清除旧授权，禁止跨 Endpoint 复用 token。

## 16. 配置、凭据与运行恢复

### 16.1 非敏感配置

新增独立 `MCPClientConfigurationStore`，使用版本化 Codable payload 保存到 UserDefaults：

```text
settings.mcp.client.servers.v1
```

`MCPClientServerProfile` 至少包含：

- 稳定 Server ID、revision、显示名称、启用状态。
- Transport、Endpoint 或 executable / args / working directory。
- 认证模式，但不包含认证值。
- 最后验证时间、协议版本、配置 fingerprint。
- 已发现 Tool Snapshot 和用户权限策略。

Client 配置不进入 SQLite 和 CloudKit，不与 MCP Server 的端口、配对设备或写权限混用。

### 16.2 凭据

`MCPClientCredentialStore` 按 Server ID 将以下内容写入 Keychain：

- Bearer Token。
- OAuth access / refresh token。
- Client secret。
- 敏感环境变量值。

UserDefaults、SQLite、Agent Run、Trace、错误、日志、诊断包和导出均不得出现凭据明文。

### 16.3 Tool Snapshot

每个 Tool Snapshot 保存：

- 远端 Tool name、title、description。
- inputSchema、outputSchema、annotations。
- Schema hash、兼容状态、不兼容原因。
- 用户 Allowlist 与 Starcat 生效权限。
- 最后发现时间和最后出现的 Server revision。

Snapshot 只用于设置展示和 Run 选择；真正调用前必须确认当前 Session 已连接，且实时 Tool identity 与 Run 快照一致。

### 16.4 Run 快照与恢复

在现有 `AgentRunContext` 的 `context_json` 增加可选 `externalMCPSelection`，冻结：

- Server ID 与配置 revision。
- Endpoint / executable fingerprint，不保存原始秘密。
- Tool 远端名称、稳定别名和 Schema hash。
- 本次 Run 的生效权限。

该变化采用可选字段向后兼容，首版不需要数据库 migration。恢复待确认或中断 Run 时：

- revision、fingerprint、Tool Schema 均一致才允许继续。
- Server 被删除、地址变化、Tool 消失或 Schema 变化时失败关闭。
- UI 明确提示“外部 MCP 配置已变化，请重新运行”，禁止静默转发到新目标。

## 17. Tool Schema、别名与结果映射

### 17.1 Schema 兼容范围

现有 `AgentJSONSchema` 首版只接收可无损转换的子集：

- `object`、`array`、`string`、`number`、`integer`、`boolean`。
- `properties`、`required`、`items`。
- `enum`、`default`、`additionalProperties`。

包含 `$ref`、`oneOf`、`anyOf`、`allOf`、复杂递归、无法表达的 `null` union，或超过深度/大小限制的 Tool，必须在设置页显示“不兼容”并禁止选择，不能静默弱化校验。

### 17.2 稳定别名

模型看到的 Tool 名称使用确定性别名：

```text
mcp_<serverShortID>_<toolSlug>_<schemaHash>
```

- 不同 Server 不冲突，满足模型工具名字符与长度限制。
- 远端原始 Tool name 单独保留在调用和审计中。
- Server revision 或 Schema 变化后生成新 identity，使旧审批自然失效。

### 17.3 结果映射

首版正式支持：

- text content。
- `structuredContent` / JSON。
- 有界的嵌入文本资源。

`resourceLink` 只保存为来源元数据，不自动下载。图片、音频和二进制结果首版显示明确的暂不支持错误，不做隐式落盘或有损转换；后续通过版本化 Artifact 合约单独接入。

建议默认限制：

| 项 | 默认值 |
|---|---:|
| 单 Server Tool 数量 | 100 |
| 模型可见结果 | 64 KiB |
| Transport 原始响应硬上限 | 8 MiB |
| 空闲连接回收 | 5 分钟 |
| Tool Call 自动重试 | 0 次 |

连接和 `tools/list` 可在明确无副作用时重试一次；`tools/call` 首版不自动重试，避免重复创建、修改或收费。

## 18. 权限与安全策略

外部 Server 的 Tool description、Schema、annotations、错误和结果都属于不可信输入。

### 18.1 默认权限

1. 新增 Server 默认停用。
2. Server 中所有 Tool 默认不进入 Allowlist。
3. 用户启用 Tool 后，首版每次调用仍必须确认。
4. `readOnlyHint`、`destructiveHint`、`idempotentHint`、`openWorldHint` 只作为风险提示，不能自动授予权限。
5. 后续若开放自动只读，必须同时满足用户显式信任、Starcat 本地策略允许、Server 声明只读、参数不包含疑似写入目标；任一无法判断都回退逐次确认。

### 18.2 审批内容

确认 UI 必须显示：

- MCP Server 名称。
- Endpoint host 或 executable identity。
- 远端 Tool name 与用途。
- 即将发送的完整参数。
- 风险类型、目标外部系统和是否开放网络。
- 本次允许 / 拒绝；首版不提供无限期信任按钮。

### 18.3 Client capability 边界

首版 Client 只消费 Tools：

- 不开放 sampling。
- 不开放 elicitation。
- 不提供 roots。
- 不把 prompts 自动注入 Agent。
- 不自动读取 Resources 或 Resource Link。
- 不允许 Server 返回内容修改系统、开发者或产品权限规则。

### 18.4 外部 Runtime

- Codex 继续禁用继承的用户 `mcp_servers`，只接收 Starcat 当前 Run 允许的 `dynamicTools`。
- DeepSeek 继续通过临时受控 Bridge 使用 Starcat Adapter，不直接读取 MCP Token。
- 外部 Runtime 只看得到 Tool Schema 和调用结果，看不到 Server 配置、Keychain、环境变量或未选择 Tool。
- Tool Adapter 的最终权限检查必须发生在 Starcat 进程内，不能只依赖 Runtime prompt。

### 18.5 Prompt Injection 与数据外发

- Tool description 和返回内容进入模型前添加不可信来源标记，并受字符、结构深度和总量限制。
- 模型不能根据 Tool 输出自行启用其它 Server、修改 Allowlist 或提升权限。
- 审批参数必须是实际即将发送的序列化值，不能只显示模型摘要。
- 诊断日志只记录 Server ID、host fingerprint、Tool、耗时、大小、状态和脱敏错误，不记录原始 Token 或完整敏感结果。

## 19. 错误、取消与审计

### 19.1 统一错误类型

Client Adapter 至少映射以下稳定错误：

- `authenticationRequired`
- `connectionFailed`
- `handshakeFailed`
- `protocolUnsupported`
- `toolListChanged`
- `schemaUnsupported`
- `toolDenied`
- `timeout`
- `cancelled`
- `remoteError`
- `resultTooLarge`
- `processExited`
- `configurationRevisionMismatch`

错误正文可以展示脱敏后的上游原因，但产品逻辑和恢复按钮只能依据稳定错误类型。

### 19.2 取消

- 用户停止 Run 时，先通过 SDK Request Context / `cancelRequest` 发送 MCP cancellation。
- 在取消宽限期内未结束时断开 HTTP Session；stdio 同时终止 process group。
- 晚到结果必须丢弃，不能写入已取消 Run 或继续触发模型推理。
- Timeline 记录取消请求、远端响应和最终回收结果，但不保存原始协议帧。

### 19.3 审计

在现有 Tool Audit / Trace payload 增加可选外部 MCP 信息：

- Server ID、显示名称和 Endpoint fingerprint。
- 远端 Tool name、稳定别名、协议版本。
- 配置 revision、Schema hash。
- Approval 结果、Attempt、耗时、请求/结果大小。
- 成功、远端错误、超时、取消或本地回收状态。

这些字段使用可选 JSON 扩展向后兼容；首版不因审计增加数据库 schema。

## 20. 预计代码范围

新增独立目录，禁止把 Client 逻辑堆入现有 Server Runtime：

```text
Starcat/Features/MCPClient/
├── Models/
│   ├── MCPClientServerProfile.swift
│   └── MCPClientToolSnapshot.swift
├── Storage/
│   ├── MCPClientConfigurationStore.swift
│   └── MCPClientCredentialStore.swift
├── Runtime/
│   ├── MCPClientService.swift
│   ├── MCPClientConnectionManager.swift
│   ├── MCPClientSession.swift
│   ├── MCPClientTransportFactory.swift
│   └── MCPStdioProcessHost.swift
├── Tools/
│   ├── MCPClientAgentTool.swift
│   ├── MCPClientToolCatalog.swift
│   ├── MCPJSONSchemaBridge.swift
│   └── MCPToolResultMapper.swift
└── UI/
    ├── MCPClientSettingsView.swift
    ├── MCPClientServerRow.swift
    ├── MCPClientServerEditorView.swift
    └── MCPClientToolPolicyRow.swift
```

预计最小现有文件接入点：

| 模块 | 现有文件 | 改动边界 |
|---|---|---|
| 依赖装配 | `Starcat/App/AppDependencies.swift` | 注入配置、凭据、连接和 Catalog 服务 |
| MCP 设置 | `Starcat/Features/MCP/MCPSettingsView.swift` | 拆分 Server / Client 双方向壳层 |
| Agent Tool | `Starcat/Features/Agents/Core/AgentTools.swift` | 复用权限、Approval、超时和结果契约 |
| Agent 配置 | `Starcat/Features/Agents/Core/AgentWorkspaceView.swift` | 注册本次 Run 选择的 MCP Adapter Tool |
| Agent 状态 | `Starcat/Features/Agents/Core/AgentWorkspaceViewModel.swift` | 管理 Tool 选择并冻结 Run 快照 |
| Run 模型 | `Starcat/Features/Agents/Core/AgentModels.swift` | 增加可选 MCP 选择与审计字段 |
| 外部 Runtime | `ExternalAgentRuntime.swift`、`CodexAppServerAdapter.swift` | 继续走受控 dynamic Tool，不恢复 Runtime 自带 MCP |
| 渠道门控 | `Starcat/Core/Distribution/DistributionGate.swift` | stdio / executable Direct-only |
| Pro 权益 | `Starcat/Core/Subscription/EntitlementGate.swift` | 复用 `.mcpService`，不新增第二套权益 |
| i18n | `Starcat/Resources/Localizable.xcstrings` | 按现有 Catalog 规范补齐全部支持语言 |

是否需要更细的文件拆分，以正式开工时的代码图谱和最小差异审计为准；本文不授权提前创建这些文件。

## 21. 分阶段实施

### 21.1 阶段 A：HTTP 最小生产闭环

- Client 基础设施和配置存储。
- Streamable HTTP，无认证与 Bearer Token。
- 设置页、连接测试、Tool 发现、Schema 检查和 Allowlist。
- 通用 Agent 工作台 Run 级选择。
- 每次调用确认，支持 text / JSON 结果。
- Timeline 基础状态、超时和取消。

退出门禁：真实 HTTP MCP Server 可以完成“配置 → 选择 → 审批 → 调用 → 结果 → 取消”，且日志、UserDefaults 和 Run 中没有 Token。

### 21.2 阶段 B：恢复、审计与外部 Runtime

- Run 快照、revision 校验和失败关闭。
- Inspector、Tool Audit 和脱敏诊断。
- Codex / DeepSeek 通过 Starcat 动态 Adapter 调用。
- Tool 列表变化、认证失效、协议变化和晚到结果处理。

退出门禁：Built-in Loop、Codex、DeepSeek 使用同一套 Tool Allowlist、审批和审计；外部 Runtime 无法读取凭据或绕过宿主调用 Tool。

### 21.3 阶段 C：Direct stdio

- executable picker、参数和环境变量白名单。
- Process / Pipe Host、stderr drain 和协议 framing。
- process group 取消、超时和退出清理。
- Direct 渠道门控。

退出门禁：正常退出、异常退出、broken pipe、Malformed JSON、stderr 洪流、超时、App 退出均无残留进程。

### 21.4 阶段 D：OAuth 与增强能力

- OAuth 2.1 授权、刷新和撤销。
- 版本化 Artifact 支持图片、音频和二进制结果。
- 经过单独安全评审的只读自动执行策略。
- 面向 RAG 的 Evidence Adapter。

退出门禁：OAuth token 全生命周期只存在于 Keychain / 受控内存；RAG 引用可以回溯到确定的 Server、Tool、Call ID 和证据片段。

## 22. 测试与验收矩阵

### 22.1 单元测试

- Profile Codable、版本迁移、删除和默认关闭。
- Token、OAuth secret、敏感环境变量不进入 UserDefaults、日志和诊断。
- URL、redirect、HTTP/LAN 和 executable 校验。
- Tool 别名稳定性、碰撞、长度与 revision 变化。
- Schema 支持、拒绝、深度和大小限制。
- MCP annotation 不会自动越权。
- 结果映射、截断、脱敏和错误映射。
- Run 恢复时 revision / fingerprint / Schema 不一致失败关闭。

### 22.2 协议与集成测试

- initialize 成功、协议不兼容和 capability 变化。
- `tools/list` 分页、Tool 新增/删除和 Schema 变化。
- `tools/call` 成功、`isError`、认证失败、超时、取消和晚到结果。
- HTTP 同源重定向、断网、Server 重启和超大响应。
- stdio 正常退出、提前退出、stderr 洪流、broken pipe、Malformed JSON 和进程树清理。

### 22.3 Agent 合约测试

- 模型只能看到本次 Run 选择的 Tool。
- 未确认、拒绝或 Tool 不在 Allowlist 时不得产生网络/进程调用。
- 审批显示的参数与实际发送参数一致。
- 取消后不继续推理，不接受晚到结果。
- Codex / DeepSeek 继续禁用继承 MCP，仅能调用 Starcat Adapter。
- 配置变化后待审批调用不能恢复到新 Endpoint。

### 22.4 UI 与可访问性

- 空、加载、可用、需授权、失败、停用、能力变化状态。
- 长 URL、长 Tool 名、长错误和全部已支持语言。
- 明暗主题、VoiceOver、键盘焦点、Reduce Motion。
- 设置页独立按钮右对齐、固定 Sheet 尺寸和滚动区域稳定。

### 22.5 构建与真实验收

自动化执行：

```bash
# 运行前关闭 Xcode IDE
make test
make build-appstore
make build-direct
```

人工验收分别记录：

- App Store：真实远程 HTTP MCP，确认不存在 stdio 入口。
- Direct：真实 HTTP MCP 与真实 stdio MCP。
- 认证过期、断网、Server 重启、用户拒绝、取消和 App 退出。
- Console、数据库、UserDefaults、诊断包和导出中不存在凭据。

自动化通过不能替代真实第三方 Server、双渠道和进程生命周期验收。

## 23. Pro 权益与最终决议

MCP Client 复用现有 `.mcpService` Pro 权益，将其产品语义扩展为“MCP 服务与连接”：

- 免费用户可以查看入口、能力说明和升级提示。
- 添加、测试、启用 Server，以及在 Agent 中执行外部 Tool 需要 Pro。
- MCP Server 与 Client 不再拆成两套零散权益和两套付费墙。

本专题冻结以下决议：

1. 设置页采用「提供工具 / 使用外部工具」双方向，Server 与 Client 实现保持隔离。
2. HTTP 支持 App Store 与 Direct；stdio 仅 Direct。
3. 首版所有外部 Tool Call 逐次确认，不信任 Server annotation。
4. 首版只接通用 Agent；外部 Runtime 通过 Starcat Adapter 接入，不恢复其原生 MCP 配置。
5. 首版只支持 Tools，不开放 prompts、resources 自动读取、sampling、elicitation 或 roots。
6. 非敏感配置进入版本化 UserDefaults Store，凭据进入 Keychain，Run 快照进入现有 `context_json`，首版不做数据库 migration。
7. 继续使用官方 Swift SDK `0.12.1`，不引入第二套 MCP 实现。
8. RAG 首版不接通用 MCP；后续必须通过 Evidence / Citation Adapter 单独验收。
9. 本次只冻结专题方案，不代表功能已实现，也不构成代码、主进度总览、Changelog、提交或发布授权。

## 24. MCP Client 首版明确不做

- 自动导入 Codex、Claude Desktop 或其它宿主的 MCP 配置。
- 允许外部 Runtime 继承用户全局 `mcp_servers`。
- 新 Server 默认启用，或默认把全部 Tool 暴露给模型。
- 仅根据 `readOnlyHint` 自动执行。
- App Store 渠道启动任意本地进程。
- 运行时通过 `npx`、`uvx`、Homebrew 等自动安装 MCP Server。
- 把凭据放入命令参数、环境继承、UserDefaults、数据库、日志或 Agent 上下文。
- 自动下载 Resource Link，或隐式保存图片、音频和二进制结果。
- 让任意 MCP 返回值直接进入 RAG 引用链。
- 公网 MCP 市场、Server 推荐、同步配置或 CloudKit 同步。
