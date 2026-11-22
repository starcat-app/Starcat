# Starcat CLI、Skill 与外部 MCP 桥接设计

> 范围更新（2026-10-07）：#119 的 MCP 配对时间剩余跟进取消；已有配对时间显示、连接修复和安全边界保留，不影响其他 CLI / MCP 工作。 逐项见[任务取消与范围同步](../../4-工程进度/2026-10-07-任务取消与范围同步.md)；本说明优先于下文同范围的旧排期与验收要求。

> 状态：公共契约 v2 已在专项 worktree 实施，自动化与双渠道构建结果见专项记录；真实连接及发布独立验收（2026-11-15）
>
> 目标：让 macOS、Linux、Windows 上的 Codex、Claude Code 等 Agent 安全操作另一台 Mac 上的 Starcat。

## 1. 架构结论

Starcat 对外能力收口为三层：

1. **Starcat App MCP Service**：唯一业务实现，负责数据访问、Pro、隐私开关、写权限、dry-run、审计和 AI Provider。
2. **`starcat-app/starcat-cli`**：Go 跨平台协议适配器。CLI 命令和 `starcat mcp` 都调用同一组 MCP Tools。
3. **`starcat-app/starcat-skill`**：描述 MCP 与结构化 CLI 两种 Agent 工作流，统一经过 `starcat`，不携带 HTTP client 或 Starcat 凭据。

两个外部项目在开发机分别位于 `supports/starcat-cli` 和 `supports/starcat-skill`，均拥有独立 Git history，不进入 Starcat 主仓库版本控制。

## 2. 运行拓扑

```text
Codex / Claude Code / 其它 Agent（macOS / Linux / Windows）
                        │
              ┌─────────┴─────────┐
              │                   │
        starcat CLI 命令      MCP stdio
              │                   │
              └─────────┬─────────┘
                        ▼
                starcat CLI（Go）
                        │
          MCP Streamable HTTP + Bearer
                        │
       ┌────────────────┴────────────────┐
       │                                 │
 回环地址 HTTP                     网络地址 HTTP（按需开启）
       │                                 │
       └────────────────┬────────────────┘
                        ▼
                 Starcat MCP Service
                        │
        Repository / 权限 / 审计 / AI Provider
```

外部进程禁止直接读取 SQLite、CloudKit、GitHub token、Local API Key 或 Starcat 加密凭据文件。

决策 REST 客户端直接向同一端口发送 `POST /v1/systemone`，与 CLI 和 MCP 共用 App 的决策执行器。

## 3. Go CLI

独立项目：`supports/starcat-cli`，module 为 `github.com/starcat-app/starcat-cli`。

目标平台：

- `darwin/arm64`、`darwin/amd64`
- `linux/arm64`、`linux/amd64`
- `windows/amd64`

核心命令：

```bash
starcat pair "starcat-pair://..."
starcat doctor
starcat capabilities
starcat tools list --json
starcat tools describe starcat.get_repo
starcat tools call starcat.get_repo --input request.json
starcat resources read starcat://capabilities
starcat stats --json
starcat repo search "local RAG" --semantic
starcat repo context owner/repo
starcat repo summary owner/repo --generate
printf '%s' "$NOTE" | starcat repo note set owner/repo --apply
starcat repo tags add owner/repo Swift macOS --apply
starcat mcp
```

约束：

- `help`、`version`、`pair`、`unpair`、`doctor`、`update` 默认输出终端文本；数据命令输出 JSON；`starcat mcp` 的 stdout 只承载 JSON-RPC。
- `doctor` 输出终端文本；`stats` 支持 `--json`，所有公共工具与资源均有通用 CLI 入口。
- 所有错误只写 stderr，未知 flag 必须报错，不能静默忽略。
- 写命令默认 `dry_run=true`，显式 `--apply` 才持久化。
- 笔记正文只从 stdin 读取，不进入进程参数。
- 长期设备 token 使用 macOS Keychain、Windows Credential Manager 或 Linux Secret Service。
- Profile 保存 endpoint、设备 ID、配对时的 App 版本、协议版本和配对时间。

## 4. 配对协议

Starcat 设置页每次生成一个五分钟有效、只能使用一次的 URI：

```text
starcat-pair://connect?v=1&endpoint=...&secret=...
```

流程：

1. 用户在 Starcat 复制终端配对命令，跨设备时选择「从其他设备配对」。
2. 在目标设备终端粘贴 `starcat pair "<URI>"` 并按回车；也可运行 `starcat pair` 后粘贴 URI 并按回车。
3. CLI 校验 HTTP endpoint 后向 `/pairing/exchange` 提交一次性 secret 与设备名、平台、架构、CLI 版本。
4. Starcat 显示设备确认 sheet，用户确认后签发独立设备 token。
5. 邀请失效，CLI 把 token 写入系统凭据存储。

读取旧 HTTPS profile 时，CLI 使用原设备 token 向同一主机和端口发送 HTTP 能力查询。确认读取成功后保存 HTTP 地址，遇到失败则保留原记录。用户可在 App 中重新复制配对命令以更换主机或端口。

`/pairing/exchange` 只交换设备凭据。

## 5. HTTP 监听

- 默认监听 `127.0.0.1`。「允许其他设备连接」打开后，监听范围扩大到网络接口。本机始终使用 `http://127.0.0.1:<port>`。
- 跨设备邀请优先使用 `SCDynamicStoreCopyLocalHostName` 返回的 Bonjour 名称加 `.local`，缺失时使用已启用的非回环接口 IPv4。MCP 与决策 REST 共用 Host/Origin 列表，远程模式允许上述地址及系统主机名。
- 服务启动时读取接口地址。若通过 IPv4 访问时遇到 IP 变化，重启服务以刷新地址列表。

## 6. 设备凭据

- Local API Key 继续兼容本机浏览器插件和既有客户端，但不会进入 Agent 安装文案。
- CLI 每台设备获得独立随机 token；Starcat 设置页列出设备并支持单独撤销。
- MCP 请求接受当前 Local API Key 或有效 device token，随后仍执行 Pro、隐私与写权限门控。
- 轮换、撤销或恢复出厂后，相关 CLI 必须重新配对。

## 7. Skill 结构

```text
starcat-skill/
├── SKILL.md
├── agents/openai.yaml
└── references/
    ├── commands.md
    └── workflows.md
```

Skill 的 Python 脚本只校验开发契约，不承担业务调用；不包含 `.env` 或 endpoint/key 配置。每个工作流先发现当前能力，写入先 dry-run，正式写入后按业务回读验证。

## 8. MCP 工具边界

App 目录由 `StarcatMCPToolRegistry` 与 `StarcatMCPPublicCatalog` 维护，本次基线 24 个工具扩展为 69 个。逐动作、权限、副作用和暂缓项见[能力覆盖清单](../../4-工程进度/CLI与MCP能力开放专项/能力覆盖清单.md)。CLI 和 Skill 读取实时目录，不复制业务执行，也不以工具数量代替 App 业务覆盖率。

`starcat://capabilities` 与 `get_capability_catalog` 返回目录及契约版本。App server `0.6.0` / `contract_version=2` 将省略 `dry_run` 的写入统一为预览；旧 MCP 消费方须在授权后显式传 `false`。通用 CLI 始终按 `--apply` 决定预览，不能从输入 JSON 绕过。

长任务由 App 持有，断开客户端继续运行；完成结果保留一小时，最多 100 个句柄，不持久化恢复。切号先阻止新请求，再等待已接受请求和任务结束后切库。取消能力来自真实执行器。导出返回内容，路径由 CLI 设备解释。详细契约与验证见[专项记录](../../4-工程进度/CLI与MCP能力开放专项/验证与交付记录.md)。

浏览器配对使用独立 Companion 设备 token。Chrome 可通过 `starcat browser-host` 代理 loopback 请求与 SSE；该长度前缀协议独立于 MCP stdio。Safari 当前仍为 background HTTP 通道例外；有限发现只覆盖保存地址与固定候选端口，不代表任意端口免地址。

## 9. 验收

- Go：`go test ./...`、`go vet ./...`、`go build ./cmd/starcat`。
- Swift 定向验证配对邀请、MCP runtime、决策 REST 及安装 prompt。
- 设置页普通安装文本不包含 endpoint、Local API Key 或 Bearer token；配对按钮只复制五分钟、单次有效且仍需人工确认的完整配对命令。
- 验证默认回环、跨设备 HTTP、本机端口切换、旧配对地址迁移、一次性 secret 与设备撤销。
- `supports/starcat-cli`、`supports/starcat-skill` 保持独立仓库，不进入父仓库提交。

## 10. 暂不做

- 公网 relay、云端转发或 Starcat 托管服务。
- 备份恢复、公开发布、任意代码执行等暂缓项，见本次覆盖清单的接入条件。
- Stateful SSE/server push。
- 直接数据库 CLI 或第二套 REST 业务 API。

新增业务必须按[CLI 与 MCP 能力暴露规范](../../5-规范/CLI与MCP能力暴露规范.md)主动评估双入口、权限、预览和任务；自动检查脚本只验证已登记项，未登记动作仍需评审。
