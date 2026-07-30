# Starcat MCP Service 实施方案

> 创建：2026-06-20
>
> 更新：2026-07-20
>
> 状态：v1.3 实现中（跨平台 Go CLI、逐设备配对、可信网络 TLS）

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

「设置 → MCP 服务」提供：

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
xcodegen generate
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/StarcatMCPRuntimeTests \
  -only-testing:StarcatTests/MCPAgentSetupPromptTests \
  -only-testing:StarcatTests/StarcatMCPPairingTests test
```

同时校验 `Localizable.xcstrings` JSON、禁用 i18n API 扫描、Skill `quick_validate.py` 和 `git diff --check`。

## 9. 暂不做

- 公网 relay 与云端转发。
- GitHub 远端 star/unstar。
- Stateful SSE/server push。
- 独立数据库 CLI、共享数据库路径或第二套 REST 业务 API。
