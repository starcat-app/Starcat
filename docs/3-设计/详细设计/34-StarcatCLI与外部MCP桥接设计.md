# Starcat CLI、Skill 与外部 MCP 桥接设计

> 状态：v3 实现中（2026-07-20）
>
> 目标：让 macOS、Linux、Windows 上的 Codex、Claude Code 等 Agent 安全操作另一台 Mac 上的 Starcat。

## 1. 架构结论

Starcat 对外能力收口为三层：

1. **Starcat App MCP Service**：唯一业务实现，负责数据访问、Pro、隐私开关、写权限、dry-run、审计和 AI Provider。
2. **`dong4j/starcat-cli`**：Go 跨平台协议适配器。CLI 命令和 `starcat mcp` 都调用同一组 MCP Tools。
3. **`dong4j/starcat-skill`**：只描述 Agent 工作流，统一执行 `starcat` CLI，不携带 Python HTTP client 或 Starcat 凭据。

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

独立项目：`supports/starcat-cli`，module 为 `github.com/dong4j/starcat-cli`。

目标平台：

- `darwin/arm64`、`darwin/amd64`
- `linux/arm64`、`linux/amd64`
- `windows/amd64`

核心命令：

```bash
starcat pair "starcat-pair://..."
starcat doctor --json
starcat capabilities --json
starcat repo search "local RAG" --semantic
starcat repo context owner/repo
starcat repo summary owner/repo --generate
printf '%s' "$NOTE" | starcat repo note set owner/repo --stdin --apply
starcat repo tags add owner/repo Swift macOS --apply
starcat mcp
```

约束：

- stdout 只输出 JSON 或 MCP JSON-RPC；错误只写 stderr。
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

1. 用户在 Starcat 点击「复制一次性配对命令」。
2. 外部 Agent 执行 `starcat pair <URI>`。
3. CLI 校验 endpoint：明文 HTTP 只允许 loopback；远程必须是 HTTPS。
4. HTTPS 连接严格 pin URI 中的证书 SHA-256 指纹。
5. CLI 向 `/pairing/exchange` 提交一次性 secret 与设备名、平台、架构、CLI 版本。
6. Starcat 显示设备确认 sheet；用户确认后签发独立 device token。
7. invitation 立即失效，CLI 把 token 写入系统安全存储。

`/pairing/exchange` 是 MCP listener 上唯一的非 MCP 窄路由，只交换设备凭据，不承载任何 Starcat 业务数据。

## 5. 网络与 TLS

- 默认关闭远程访问，只监听 `127.0.0.1`，使用 loopback HTTP。
- 用户显式开启「允许可信网络设备连接」后，listener 才绑定网络接口并强制 TLS 1.3。
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

Skill 不包含 Python 脚本、`.env` 或 endpoint/key 配置。每个工作流先运行 `starcat capabilities --json`，写入先 dry-run，正式写入后重新读取 context 验证。

## 8. MCP 工具边界

读取和生成：`starcat.get_capabilities`、`starcat.search_repos`、`starcat.semantic_search`、`starcat.get_repo`、`starcat.get_repo_context`、`starcat.get_repo_summary`、`starcat.generate_repo_summary`、`starcat.get_readme`、`starcat.list_tags`、`starcat.get_repo_note`。

写入：`starcat.upsert_repo_note`、`starcat.set_repo_status`、`starcat.create_tag`、`starcat.add_repo_tags`、`starcat.remove_repo_tags`、`starcat.set_repo_tags`。

CLI 和 Skill 不增加业务语义，只映射上述工具。

## 9. 验收

- Go：`go test ./...`、`go vet ./...`、`go build ./cmd/starcat`。
- Swift：pairing invitation、X.509 DER 解析、MCP runtime 与安装 prompt 定向测试。
- 设置页复制文本不包含 endpoint、Local API Key 或 Bearer token。
- loopback、远程 TLS、一次性 secret、设备撤销和默认 dry-run 边界均有自动化或人工验证记录。
- `supports/starcat-cli`、`supports/starcat-skill` 保持独立仓库，不进入父仓库提交。

## 10. 暂不做

- 公网 relay、云端转发或 Starcat 托管服务。
- GitHub 远端 star/unstar。
- 真正的 batch tool。
- Stateful SSE/server push。
- 直接数据库 CLI 或第二套 REST 业务 API。
