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
 loopback HTTP                  可信网络 HTTPS + pinning
       │                                 │
       └────────────────┬────────────────┘
                        ▼
                 Starcat MCP Service
                        │
        Repository / 权限 / 审计 / AI Provider
```

外部进程禁止直接读取 SQLite、CloudKit、GitHub token、Local API Key 或 Starcat 加密凭据文件。

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
- 非敏感 profile 只保存 endpoint、设备 ID、协议版本、证书指纹和配对时间。

## 4. 配对协议

Starcat 设置页每次生成一个五分钟有效、只能使用一次的 URI：

```text
starcat-pair://connect?v=1&endpoint=...&fingerprint=...&secret=...
```

流程：

1. 用户在 Starcat 点击「复制配对命令」。
2. 在目标设备终端粘贴 `starcat pair "<URI>"` 并按回车；也可运行 `starcat pair` 后粘贴 URI 并按回车。
3. CLI 校验 endpoint：明文 HTTP 只允许 loopback；远程必须是 HTTPS。
4. HTTPS 连接严格 pin URI 中的证书 SHA-256 指纹。
5. CLI 向 `/pairing/exchange` 提交一次性 secret 与设备名、平台、架构、CLI 版本。
6. Starcat 显示设备确认 sheet；用户确认后签发独立 device token。
7. invitation 立即失效，CLI 把 token 写入系统安全存储。

目标域名解析失败时，CLI 在请求发出前尝试同端口的 `127.0.0.1`，继续使用 HTTPS 和原指纹；配对成功后保存实际连接地址。两次连接均失败时报告两次失败原因。证书不匹配时提示核实 App 后生成新 URI 重新配对，不自动更新信任，也不重放已提交的配对或业务请求。

`/pairing/exchange` 是 MCP listener 上唯一的非 MCP 窄路由，只交换设备凭据，不承载任何 Starcat 业务数据。

## 5. 网络与 TLS

- 默认关闭远程访问，只监听 `127.0.0.1`，使用 loopback HTTP。
- 用户显式开启「允许可信网络设备连接」后，listener 才绑定网络接口并强制 TLS 1.3。
- 可信网络默认地址来自 `SCDynamicStoreCopyLocalHostName` 的 Bonjour 名称加 `.local`，不使用可能来自公网 DNS 的 `ProcessInfo.hostName`。Bonjour 名称缺失时使用 HTTPS loopback；Host/Origin 白名单精确允许 Bonjour、本机地址和当前系统 DNS 名称。
- Starcat 使用 Security.framework 为当前 Mac 生成独立 P-256 私钥和自签名 X.509 certificate。
- CLI 不使用公共 CA/hostname 信任，而是 pin invitation 中的完整 certificate SHA-256。
- 不允许远程 HTTP 降级。公网暴露不属于本方案；推荐可信 LAN 或 Tailscale/WireGuard。

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
- Swift：pairing invitation、X.509 DER 解析、MCP runtime 与安装 prompt 定向测试。
- 设置页普通安装文本不包含 endpoint、Local API Key 或 Bearer token；配对按钮只复制五分钟、单次有效且仍需人工确认的完整配对命令。
- loopback、远程 TLS、一次性 secret、设备撤销和默认 dry-run 边界均有自动化或人工验证记录。
- `supports/starcat-cli`、`supports/starcat-skill` 保持独立仓库，不进入父仓库提交。

## 10. 暂不做

- 公网 relay、云端转发或 Starcat 托管服务。
- 备份恢复、公开发布、任意代码执行等暂缓项，见本次覆盖清单的接入条件。
- Stateful SSE/server push。
- 直接数据库 CLI 或第二套 REST 业务 API。

新增业务必须按[CLI 与 MCP 能力暴露规范](../../5-规范/CLI与MCP能力暴露规范.md)主动评估双入口、权限、预览和任务；自动检查脚本只验证已登记项，未登记动作仍需评审。
